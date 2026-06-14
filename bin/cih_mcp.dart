import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:cih/src/adapter/dart/dart_callees.dart';
import 'package:cih/src/adapter/dart/dart_dependencies.dart';
import 'package:cih/src/adapter/dart/dart_references.dart';
import 'package:cih/src/store/symbol_store.dart';
import 'package:mcp_dart/mcp_dart.dart';

const _defaultDb = '.cih/index.db';

/// Servidor MCP del CIH (stdio). Expone el índice a agentes como Claude Code.
///
/// Proceso de larga vida: abre el índice y mantiene un AnalysisContextCollection
/// "caliente" reusado entre consultas, de modo que el warmup del analyzer se
/// paga una sola vez y `find_references` responde rápido en llamadas sucesivas.
///
/// El índice se ubica con la variable de entorno CIH_DB (ruta al index.db) o,
/// en su defecto, .cih/index.db relativo al directorio de trabajo.
Future<void> main() async {
  final dbPath = Platform.environment['CIH_DB'] ?? _defaultDb;
  if (!File(dbPath).existsSync()) {
    stderr.writeln('CIH: no hay índice en $dbPath. '
        'Indexa con `dart run bin/cih.dart index <ruta>` '
        'o define CIH_DB con la ruta al index.db.');
    exitCode = 69;
    return;
  }
  final store = SymbolStore.open(dbPath);
  final projectPath = store.getMeta('project_path');
  if (projectPath == null) {
    stderr.writeln('CIH: el índice no registró project_path. Re-indexa.');
    exitCode = 69;
    return;
  }

  // Estado caliente: una sola colección reusada entre queries.
  AnalysisContextCollection? warm;
  AnalysisContextCollection hot() =>
      warm ??= AnalysisContextCollection(includedPaths: [projectPath]);

  final server = McpServer(
    const Implementation(name: 'cih', version: '0.0.1'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );

  server.registerTool(
    'find_symbol',
    description:
        'Localiza la definición de un símbolo (clase/método/función/campo/enum) '
        'por nombre: tipo, firma y file:line, sin el cuerpo.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(description: 'Nombre del símbolo a buscar.'),
        'limit': JsonSchema.number(description: 'Máximo de resultados (def. 20).'),
      },
      required: ['name'],
    ),
    callback: (args, extra) async {
      final name = args['name'] as String;
      final limit = (args['limit'] as num?)?.toInt() ?? 20;
      final results = store.findByName(name, limit: limit);
      final payload = {
        'query': name,
        'count': results.length,
        'symbols': [
          for (final s in results)
            {
              'name': s.name,
              'kind': s.kind.name,
              if (s.signature != null) 'signature': s.signature,
              'location': '${s.filePath}:${s.line}',
              if (s.containerId != null) 'container': s.containerId,
            },
        ],
      };
      return CallToolResult.fromContent(
        [TextContent(text: const JsonEncoder.withIndent('  ').convert(payload))],
      );
    },
  );

  server.registerTool(
    'find_references',
    description:
        'Usos reales de un símbolo por resolución semántica (cero falsos '
        'positivos vs grep). Agrupa por declaración (separa homónimos por '
        'receptor) con archivo y líneas.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(description: 'Nombre del símbolo.'),
      },
      required: ['name'],
    ),
    callback: (args, extra) async {
      final name = args['name'] as String;
      final result =
          await DartReferences(projectPath).find(name, collection: hot());
      final payload = {
        'query': name,
        'targetCount': result.targets.length,
        'totalReferences': result.totalReferences,
        'targets': [for (final t in result.targets) _targetToJson(t)],
      };
      return CallToolResult.fromContent(
        [TextContent(text: const JsonEncoder.withIndent('  ').convert(payload))],
      );
    },
  );

  server.registerTool(
    'find_callers',
    description:
        'Call graph: quién LLAMA a un símbolo. Devuelve los métodos/funciones '
        'que lo referencian, agrupados por llamador con archivo:línea '
        '(resolución semántica; separa homónimos por receptor).',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(description: 'Nombre del símbolo.'),
      },
      required: ['name'],
    ),
    callback: (args, extra) async {
      final name = args['name'] as String;
      final result =
          await DartReferences(projectPath).find(name, collection: hot());
      final payload = {
        'query': name,
        'targetCount': result.targets.length,
        'targets': [for (final t in result.targets) _callersJson(t)],
      };
      return CallToolResult.fromContent(
        [TextContent(text: const JsonEncoder.withIndent('  ').convert(payload))],
      );
    },
  );

  server.registerTool(
    'module_dependencies',
    description:
        'Dependencias de un módulo (N4): de qué otros módulos depende y cuáles '
        'lo usan, según los imports internos del proyecto.',
    inputSchema: JsonSchema.object(
      properties: {
        'module': JsonSchema.string(
            description: 'Nombre del módulo (p. ej. "commercial" o '
                '"modules/commercial").'),
      },
      required: ['module'],
    ),
    callback: (args, extra) async {
      final raw = args['module'] as String;
      final graph = DartDependencies.forProject(projectPath).analyze();
      final modules = <String>{for (final n in graph.nodes.values) n.module};
      final module = modules.contains(raw)
          ? raw
          : (modules.contains('modules/$raw') ? 'modules/$raw' : raw);
      final payload = {
        'module': module,
        'found': modules.contains(module),
        'dependsOn': graph.moduleDeps(module).toList()..sort(),
        'usedBy': graph.moduleDependents(module).toList()..sort(),
        if (!modules.contains(module))
          'availableModules': modules.toList()..sort(),
      };
      return CallToolResult.fromContent(
        [TextContent(text: const JsonEncoder.withIndent('  ').convert(payload))],
      );
    },
  );

  server.registerTool(
    'layer_violations',
    description:
        'Posibles violaciones de capa de Clean Architecture (N4). INFORMATIVO: '
        'muchas pueden ser intencionales o convención del proyecto; NO es un '
        'error y no bloquea nada. Devuelve resumen por tipo con ejemplos.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      final graph = DartDependencies.forProject(projectPath).analyze();
      final byKind = <String, List<LayerViolation>>{};
      for (final x in graph.violations) {
        (byKind['${x.fromLayer.name} -> ${x.toLayer.name}'] ??= []).add(x);
      }
      final kinds = byKind.keys.toList()..sort();
      final payload = {
        'total': graph.violations.length,
        'note': 'Informativo: pueden ser decisiones conscientes o convención '
            'del proyecto; no es un error bloqueante.',
        'byKind': [
          for (final k in kinds)
            {
              'kind': k,
              'count': byKind[k]!.length,
              'examples': [
                for (final x in byKind[k]!.take(8))
                  '${x.fromPath}:${x.line} -> ${x.toPath}',
              ],
            },
        ],
      };
      return CallToolResult.fromContent(
        [TextContent(text: const JsonEncoder.withIndent('  ').convert(payload))],
      );
    },
  );

  server.registerTool(
    'find_callees',
    description:
        'Call graph: a qué símbolos DEL PROYECTO llama X (poda Flutter/SDK). '
        'Resuelve solo el archivo donde X se define, por eso es barato.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(description: 'Nombre del símbolo.'),
      },
      required: ['name'],
    ),
    callback: (args, extra) async {
      final name = args['name'] as String;
      final syms = store.findByName(name, limit: 10);
      final groups = await DartCallees.forProject(projectPath).find(
        name,
        defFilesRel: {for (final s in syms) s.filePath},
        collection: hot(),
      );
      final payload = {
        'query': name,
        'targetCount': groups.length,
        'targets': [
          for (final g in groups)
            {
              'symbol': g.symbol,
              'definition': '${g.file}:${g.line}',
              'calleeCount': g.callees.length,
              'callees': [
                for (final c in g.callees)
                  {'symbol': c.symbol, 'at': '${c.file}:${c.callLine}'},
              ],
            },
        ],
      };
      return CallToolResult.fromContent(
        [TextContent(text: const JsonEncoder.withIndent('  ').convert(payload))],
      );
    },
  );

  server.connect(StdioServerTransport());
}

Map<String, dynamic> _callersJson(ReferenceTarget t) {
  final byCaller = <String, List<String>>{};
  for (final r in t.references) {
    (byCaller[r.enclosing ?? '(nivel superior)'] ??= [])
        .add('${r.filePath}:${r.line}');
  }
  final callers = byCaller.keys.toList()..sort();
  return {
    'symbol': t.qualified,
    'kind': t.kind,
    'definition': '${t.file}:${t.line}',
    'callerCount': callers.length,
    'callers': [
      for (final c in callers) {'caller': c, 'sites': byCaller[c]},
    ],
  };
}

Map<String, dynamic> _targetToJson(ReferenceTarget t) {
  final byFile = <String, List<int>>{};
  for (final r in t.references) {
    (byFile[r.filePath] ??= <int>[]).add(r.line);
  }
  final files = byFile.keys.toList()..sort();
  return {
    'symbol': t.qualified,
    'kind': t.kind,
    'definition': '${t.file}:${t.line}',
    'total': t.references.length,
    'fileCount': files.length,
    'files': [
      for (final f in files) {'file': f, 'lines': byFile[f]!..sort()},
    ],
  };
}
