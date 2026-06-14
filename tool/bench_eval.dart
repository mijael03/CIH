import 'dart:convert';
import 'dart:io';

/// Re-evalúa el acierto de corridas YA guardadas (.jsonl) con un criterio
/// NORMALIZADO: ignora mayúsculas y todo lo no alfanumérico, de modo que el
/// nombre de archivo (`role_view_dialog.dart`) y el de clase (`RoleViewDialog`)
/// cuenten como el mismo acierto. NO ejecuta claude — solo procesa texto.
///
///   dart run tool/bench_eval.dart [archivo.jsonl ...]
///   (sin args: usa todos los bench/results/run-*.jsonl)

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

void main(List<String> argv) {
  final root = Directory.current.path;
  final expectsById = <String, List<String>>{
    for (final e in json.decode(
            File('$root/bench/questions.json').readAsStringSync()) as List)
      (e as Map)['id'] as String:
          ((e['expect_contains'] as List?) ?? const []).cast<String>(),
  };

  final files = argv.isNotEmpty
      ? argv
      : (Directory('$root/bench/results')
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.contains('run-') && p.endsWith('.jsonl'))
          .toList()
        ..sort());
  if (files.isEmpty) {
    stderr.writeln('No hay .jsonl en bench/results/');
    exit(64);
  }

  final rows = <Map<String, dynamic>>[];
  for (final f in files) {
    for (final line in File(f).readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final r = json.decode(line) as Map<String, dynamic>;
      final expects = expectsById[r['questionId']] ?? const <String>[];
      final result = _norm((r['result'] ?? '').toString());
      r['correctEval'] = expects.isNotEmpty &&
          expects.every((e) => result.contains(_norm(e)));
      rows.add(r);
    }
  }

  // Tabla por pregunta (baseline vs cih), con tokens/turnos/acierto.
  final ids = <String>[];
  for (final r in rows) {
    if (!ids.contains(r['questionId'])) ids.add(r['questionId'] as String);
  }
  stdout.writeln('# Re-evaluación normalizada (sin re-correr)\n');
  stdout.writeln('| Pregunta | cond | n | acierto | tokens | turnos | costo |');
  stdout.writeln('|---|---|---|---|---|---|---|');
  for (final id in ids) {
    for (final c in const ['baseline', 'cih']) {
      final l = rows
          .where((m) =>
              m['questionId'] == id && m['condition'] == c && m['ok'] == true)
          .toList();
      if (l.isEmpty) continue;
      stdout.writeln('| $id | $c | ${l.length} | ${_acc(l).toStringAsFixed(0)}% '
          '| ${_avg(l, 'totalTokens').round()} '
          '| ${_avg(l, 'numTurns').toStringAsFixed(1)} '
          '| \$${_avg(l, 'costUsd').toStringAsFixed(4)} |');
    }
  }

  // Consolidado.
  stdout.writeln('\n## Consolidado (${rows.length} corridas)\n');
  for (final c in const ['baseline', 'cih']) {
    final l = rows.where((m) => m['condition'] == c && m['ok'] == true).toList();
    if (l.isEmpty) continue;
    stdout.writeln('- **$c** — acierto ${_acc(l).toStringAsFixed(0)}% · '
        '${_avg(l, 'totalTokens').round()} tokens · '
        '${_avg(l, 'numTurns').toStringAsFixed(1)} turnos · '
        '\$${_avg(l, 'costUsd').toStringAsFixed(4)}/corrida');
  }
}

double _avg(List<Map<String, dynamic>> l, String k) =>
    l.isEmpty ? 0 : l.map((m) => (m[k] as num)).reduce((a, b) => a + b) / l.length;

double _acc(List<Map<String, dynamic>> l) =>
    l.isEmpty ? 0 : l.where((m) => m['correctEval'] == true).length / l.length * 100;
