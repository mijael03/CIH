import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:cih/src/adapter/dart/dart_references.dart';
import 'package:cih/src/model/intermediate_model.dart';
import 'package:cih/src/store/symbol_store.dart';

const _dbPath = '.cih/index.db';

/// Estimación de tokens (~4 chars/token). El ratio A/B es robusto a esta
/// constante (se cancela), así que sirve para comparar contexto entregado.
int _tok(String s) => (s.length / 4).ceil();

/// Benchmark de **contexto entregado al LLM**: output crudo de `grep -rn`
/// (lo que un agente debe leer) vs la respuesta JSON de CIH, para la misma
/// pregunta. Conservador: NO suma las lecturas de archivo que el agente con
/// grep haría además para filtrar/confirmar → el ahorro real es mayor.
Future<void> main() async {
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre: dart run bin/cih.dart index <ruta>');
    exitCode = 69;
    return;
  }
  final store = SymbolStore.open(_dbPath);
  final project = store.getMeta('project_path');
  if (project == null) {
    stderr.writeln('Índice sin project_path. Re-indexa.');
    return;
  }
  final libDir = '$project/lib';
  final hot = AnalysisContextCollection(includedPaths: [project]);

  const refsQueries = [
    'LeadModel',
    'LeadController',
    'CustomerController',
    'TicketHeaderModel',
  ];
  const defQueries = [
    'LeadUseCase',
    'LeadAdapter',
    'LeadDetailController',
    'ProcessInstanceController',
  ];

  final rows = <List<String>>[];
  var totalA = 0, totalB = 0;

  Future<int> grepTokens(String name) async {
    final r = await Process.run('grep', ['-rn', name, libDir]);
    return _tok(r.stdout is String ? r.stdout as String : '');
  }

  // find_references: A = grep -rn ; B = JSON de CIH
  for (final name in refsQueries) {
    final a = await grepTokens(name);
    final res = await DartReferences(project).find(name, collection: hot);
    final b = _tok(_refsJson(name, res));
    totalA += a;
    totalB += b;
    rows.add([name, 'refs', '$a', '$b', '${(a / b).toStringAsFixed(1)}x']);
  }

  // find_symbol: A = grep -rn ; B = JSON de CIH
  for (final name in defQueries) {
    final a = await grepTokens(name);
    final syms = store.findByName(name, limit: 5);
    final b = _tok(_symbolJson(name, syms));
    totalA += a;
    totalB += b;
    rows.add([name, 'def', '$a', '$b', '${(a / b).toStringAsFixed(1)}x']);
  }

  stdout.writeln('CIH · benchmark de contexto entregado al LLM '
      '(tokens ≈ chars/4)\n');
  stdout.writeln('${'consulta'.padRight(26)}${'tipo'.padRight(6)}'
      '${'grep'.padLeft(9)}${'CIH'.padLeft(8)}${'ahorro'.padLeft(9)}');
  stdout.writeln('-' * 58);
  for (final r in rows) {
    stdout.writeln('${r[0].padRight(26)}${r[1].padRight(6)}'
        '${r[2].padLeft(9)}${r[3].padLeft(8)}${r[4].padLeft(9)}');
  }
  stdout.writeln('-' * 58);
  stdout.writeln('${'TOTAL'.padRight(26)}${''.padRight(6)}'
      '${'$totalA'.padLeft(9)}${'$totalB'.padLeft(8)}'
      '${'${(totalA / totalB).toStringAsFixed(1)}x'.padLeft(9)}');
  stdout.writeln('\nReducción de contexto global: '
      '${(totalA / totalB).toStringAsFixed(1)}x  '
      '($totalA → $totalB tokens estimados)');
  stdout.writeln('Nota: piso conservador — no cuenta las lecturas de archivo '
      'que el agente con grep haría para filtrar falsos positivos.');
  store.close();
}

String _refsJson(String name, ReferenceResult res) {
  return const JsonEncoder.withIndent('  ').convert({
    'query': name,
    'targetCount': res.targets.length,
    'totalReferences': res.totalReferences,
    'targets': [for (final t in res.targets) _targetMap(t)],
  });
}

Map<String, dynamic> _targetMap(ReferenceTarget t) {
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
    'files': [for (final f in files) {'file': f, 'lines': byFile[f]!..sort()}],
  };
}

String _symbolJson(String name, List<CodeSymbol> syms) {
  return const JsonEncoder.withIndent('  ').convert({
    'query': name,
    'count': syms.length,
    'symbols': [
      for (final s in syms)
        {
          'name': s.name,
          'kind': s.kind.name,
          if (s.signature != null) 'signature': s.signature,
          'location': '${s.filePath}:${s.line}',
          if (s.containerId != null) 'container': s.containerId,
        },
    ],
  });
}
