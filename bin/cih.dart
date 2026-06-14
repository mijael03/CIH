import 'dart:io';

import 'package:cih/src/adapter/dart/dart_adapter.dart';
import 'package:cih/src/adapter/dart/dart_callees.dart';
import 'package:cih/src/adapter/dart/dart_dependencies.dart';
import 'package:cih/src/adapter/dart/dart_references.dart';
import 'package:cih/src/model/intermediate_model.dart';
import 'package:cih/src/store/symbol_store.dart';

const _dbDir = '.cih';
const _dbPath = '.cih/index.db';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }
  final rest = args.skip(1).toList();
  switch (args.first) {
    case 'index':
      await _index(rest);
    case 'find':
      _find(rest);
    case 'refs':
      await _refs(rest);
    case 'callers':
      await _callers(rest);
    case 'callees':
      await _callees(rest);
    case 'deps':
      _deps(rest);
    case 'layers':
      _layers(rest);
    case 'stats':
      _stats();
    default:
      stderr.writeln('Comando desconocido: ${args.first}\n');
      _usage();
      exitCode = 64;
  }
}

void _usage() {
  stdout.writeln('''
cih — Code Intelligence Harness

Uso:
  cih index <ruta_proyecto>   Indexa un proyecto Dart/Flutter
  cih find  <nombre>          Busca un símbolo por nombre
  cih refs    <nombre>        Encuentra referencias a un símbolo (semántico)
  cih callers <nombre>        Quién llama a un símbolo (call graph, N3)
  cih callees <nombre>        A quién llama un símbolo (call graph, N3)
  cih deps    [módulo]        Dependencias entre módulos (N4)
  cih layers                  Posibles violaciones de capa (informativo, N4)
  cih stats                   Estadísticas del índice actual
''');
}

Future<void> _index(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Falta <ruta_proyecto>');
    exitCode = 64;
    return;
  }
  final projectPath = args.first;
  final adapter = DartAdapter();
  if (!adapter.canHandle(projectPath)) {
    stderr.writeln('No parece un proyecto Dart (falta pubspec.yaml): '
        '$projectPath');
    exitCode = 66;
    return;
  }

  stdout.writeln('Indexando $projectPath ...');
  final sw = Stopwatch()..start();
  final result = await adapter.index(
    projectPath,
    onProgress: (p) {
      if (p.filesProcessed % 200 == 0 || p.filesProcessed == p.filesTotal) {
        stdout.write('\r  ${p.filesProcessed}/${p.filesTotal} archivos ');
      }
    },
  );
  stdout.writeln();

  Directory(_dbDir).createSync(recursive: true);
  final store = SymbolStore.open(_dbPath);
  store.replaceAllSymbols(result);
  store.setMeta('project_path', Directory(projectPath).absolute.path);
  sw.stop();

  final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);
  stdout.writeln('✓ ${store.symbolCount} símbolos en ${secs}s  →  $_dbPath');
  store.close();
}

void _find(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Falta <nombre>');
    exitCode = 64;
    return;
  }
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final query = args.first;
  final store = SymbolStore.open(_dbPath);
  final results = store.findByName(query);

  if (results.isEmpty) {
    stdout.writeln('Sin resultados para "$query".');
  } else {
    stdout.writeln('${results.length} resultado(s) para "$query":\n');
    for (final s in results) {
      final sig = s.signature ?? s.name;
      stdout.writeln('  [${s.kind.name}] $sig');
      stdout.writeln('      ${s.filePath}:${s.line}');
      if (s.containerId != null) {
        stdout.writeln('      en ${s.containerId}');
      }
      stdout.writeln();
    }
  }
  store.close();
}

Future<void> _refs(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Falta <nombre>');
    exitCode = 64;
    return;
  }
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final query = args.first;

  final store = SymbolStore.open(_dbPath);
  final projectPath = store.getMeta('project_path');
  store.close();
  if (projectPath == null) {
    stderr.writeln('El índice no registró la ruta del proyecto. '
        'Re-indexa:  cih index <ruta>');
    exitCode = 69;
    return;
  }

  stdout.writeln('Buscando referencias a "$query" ...');
  final sw = Stopwatch()..start();
  final result = await DartReferences(projectPath).find(
    query,
    onProgress: (done, total) {
      if (done % 20 == 0 || done == total) {
        stdout.write('\r  resolviendo $done/$total candidatos ');
      }
    },
  );
  sw.stop();
  stdout.writeln();

  if (!result.found) {
    stdout.writeln('No se encontró la definición de "$query".');
    return;
  }

  final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);
  stdout.writeln('${result.targets.length} símbolo(s) "$query" · '
      '${result.totalReferences} referencia(s)  (${secs}s)\n');

  for (final t in result.targets) {
    final byFile = <String, List<int>>{};
    for (final r in t.references) {
      (byFile[r.filePath] ??= <int>[]).add(r.line);
    }
    stdout.writeln('▸ ${t.qualified}  [${t.kind}]  def ${t.file}:${t.line}'
        '  ·  ${t.references.length} ref en ${byFile.length} archivo(s)');
    final files = byFile.keys.toList()..sort();
    for (final f in files) {
      final lines = (byFile[f]!..sort()).join(', ');
      stdout.writeln('    $f  →  $lines');
    }
    stdout.writeln();
  }
}

Future<void> _callers(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Falta <nombre>');
    exitCode = 64;
    return;
  }
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final query = args.first;
  final store = SymbolStore.open(_dbPath);
  final projectPath = store.getMeta('project_path');
  store.close();
  if (projectPath == null) {
    stderr.writeln('El índice no registró la ruta del proyecto. Re-indexa.');
    exitCode = 69;
    return;
  }

  stdout.writeln('¿Quién llama a "$query"? ...');
  final result = await DartReferences(projectPath).find(
    query,
    onProgress: (done, total) {
      if (done % 20 == 0 || done == total) {
        stdout.write('\r  resolviendo $done/$total candidatos ');
      }
    },
  );
  stdout.writeln();
  if (!result.found) {
    stdout.writeln('No se encontró la definición de "$query".');
    return;
  }

  for (final t in result.targets) {
    final byCaller = <String, List<Occurrence>>{};
    for (final r in t.references) {
      (byCaller[r.enclosing ?? '(nivel superior)'] ??= []).add(r);
    }
    stdout.writeln('▸ ${t.qualified}  [${t.kind}]  ·  '
        '${byCaller.length} llamador(es)');
    final callers = byCaller.keys.toList()..sort();
    for (final c in callers) {
      final sites = (byCaller[c]!..sort((a, b) => a.line.compareTo(b.line)))
          .map((o) => '${o.filePath}:${o.line}')
          .join(', ');
      stdout.writeln('    $c  ←  $sites');
    }
    stdout.writeln();
  }
}

String? _projectPathOrExit() {
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return null;
  }
  final store = SymbolStore.open(_dbPath);
  final pp = store.getMeta('project_path');
  store.close();
  if (pp == null) {
    stderr.writeln('El índice no registró la ruta del proyecto. Re-indexa.');
    exitCode = 69;
    return null;
  }
  return pp;
}

void _deps(List<String> args) {
  final projectPath = _projectPathOrExit();
  if (projectPath == null) return;
  final graph = DartDependencies.forProject(projectPath).analyze();
  final modules = <String>{for (final n in graph.nodes.values) n.module};

  if (args.isEmpty) {
    final mods = modules.toList()..sort();
    stdout.writeln('Módulos (${mods.length}). Uso: cih deps <módulo>\n');
    for (final m in mods) {
      stdout.writeln('  $m');
    }
    return;
  }

  var module = args.first;
  if (!modules.contains(module) && modules.contains('modules/$module')) {
    module = 'modules/$module';
  }
  if (!modules.contains(module)) {
    stderr.writeln('Módulo no encontrado: $module (usa `cih deps` para listar)');
    exitCode = 69;
    return;
  }
  final deps = graph.moduleDeps(module).toList()..sort();
  final dependents = graph.moduleDependents(module).toList()..sort();
  stdout.writeln('Módulo: $module\n');
  stdout.writeln('Depende de (${deps.length}):');
  for (final d in deps) {
    stdout.writeln('  → $d');
  }
  stdout.writeln('\nLo usan (${dependents.length}):');
  for (final d in dependents) {
    stdout.writeln('  ← $d');
  }
}

void _layers(List<String> args) {
  final projectPath = _projectPathOrExit();
  if (projectPath == null) return;
  final graph = DartDependencies.forProject(projectPath).analyze();
  final v = graph.violations;

  stdout.writeln('Posibles violaciones de capa (Clean Architecture): ${v.length}');
  stdout.writeln('NOTA: informativo — pueden ser decisiones conscientes; '
      'no bloquean nada.\n');

  final byKind = <String, List<LayerViolation>>{};
  for (final x in v) {
    (byKind['${x.fromLayer.name} → ${x.toLayer.name}'] ??= []).add(x);
  }
  final kinds = byKind.keys.toList()..sort();
  for (final k in kinds) {
    final list = byKind[k]!;
    stdout.writeln('▸ $k  (${list.length})');
    for (final x in list.take(12)) {
      stdout.writeln('    ${x.fromPath}:${x.line}  →  ${x.toPath}');
    }
    if (list.length > 12) stdout.writeln('    … y ${list.length - 12} más');
    stdout.writeln();
  }
}

Future<void> _callees(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Falta <nombre>');
    exitCode = 64;
    return;
  }
  final projectPath = _projectPathOrExit();
  if (projectPath == null) return;
  final query = args.first;
  final store = SymbolStore.open(_dbPath);
  final syms = store.findByName(query, limit: 10);
  store.close();
  if (syms.isEmpty) {
    stdout.writeln('No se encontró "$query" en el índice.');
    return;
  }

  stdout.writeln('¿A quién llama "$query"? (solo símbolos del proyecto)\n');
  final groups = await DartCallees.forProject(projectPath)
      .find(query, defFilesRel: {for (final s in syms) s.filePath});
  if (groups.isEmpty) {
    stdout.writeln('Sin callees del proyecto.');
    return;
  }
  for (final g in groups) {
    stdout.writeln('▸ ${g.symbol}  (${g.file}:${g.line})  ·  '
        '${g.callees.length} callee(s) del proyecto');
    for (final c in g.callees) {
      stdout.writeln('    → ${c.symbol}   ${c.file}:${c.callLine}');
    }
    stdout.writeln();
  }
}

void _stats() {
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final store = SymbolStore.open(_dbPath);
  stdout.writeln('símbolos: ${store.symbolCount}\n');
  store.kindCounts().forEach((k, c) {
    stdout.writeln('  ${k.padRight(16)} $c');
  });
  store.close();
}
