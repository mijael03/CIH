import 'dart:convert';
import 'dart:io';

/// Reporta el benchmark E2E desde los .jsonl: métricas DURAS y objetivas
/// (tokens, turnos, tiempo, costo). El ACIERTO se juzga a mano: con `--answers`
/// imprime las respuestas del agente por pregunta/condición para revisarlas.
/// NO ejecuta claude.
///
///   dart run tool/bench_eval.dart [--answers] [archivo.jsonl ...]
///   (sin .jsonl: usa todos los bench/results/run-*.jsonl)

void main(List<String> argv) {
  final root = Directory.current.path;
  final showAnswers = argv.contains('--answers');
  final explicit = argv.where((a) => a.endsWith('.jsonl')).toList();
  final files = explicit.isNotEmpty
      ? explicit
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
      rows.add(json.decode(line) as Map<String, dynamic>);
    }
  }

  final ids = <String>[];
  for (final r in rows) {
    if (!ids.contains(r['questionId'])) ids.add(r['questionId'] as String);
  }

  // Métricas duras por pregunta/condición (el acierto NO se infiere aquí).
  stdout.writeln('# Benchmark E2E — métricas duras (el acierto se juzga a mano)\n');
  stdout.writeln('| Pregunta | cond | n | tokens | turnos | tiempo | costo |');
  stdout.writeln('|---|---|---|---|---|---|---|');
  for (final id in ids) {
    for (final c in const ['baseline', 'cih']) {
      final l = _sel(rows, id, c);
      if (l.isEmpty) continue;
      stdout.writeln('| $id | $c | ${l.length} '
          '| ${_avg(l, 'totalTokens').round()} '
          '| ${_avg(l, 'numTurns').toStringAsFixed(1)} '
          '| ${(_avg(l, 'durationMs') / 1000).toStringAsFixed(1)}s '
          '| \$${_avg(l, 'costUsd').toStringAsFixed(4)} |');
    }
  }

  stdout.writeln('\n## Consolidado (${rows.length} corridas)\n');
  for (final c in const ['baseline', 'cih']) {
    final l = rows.where((m) => m['condition'] == c && m['ok'] == true).toList();
    if (l.isEmpty) continue;
    stdout.writeln('- **$c** — ${_avg(l, 'totalTokens').round()} tokens · '
        '${_avg(l, 'numTurns').toStringAsFixed(1)} turnos · '
        '\$${_avg(l, 'costUsd').toStringAsFixed(4)}/corrida');
  }

  if (showAnswers) {
    stdout.writeln('\n## Respuestas (1 rep por condición) — juzga tú el acierto\n');
    for (final id in ids) {
      stdout.writeln('### $id');
      for (final c in const ['baseline', 'cih']) {
        final l = _sel(rows, id, c);
        if (l.isEmpty) continue;
        stdout.writeln('**$c:** ${(l.first['result'] ?? '').toString().trim()}\n');
      }
    }
  } else {
    stdout.writeln('\n(Usa `--answers` para imprimir las respuestas y juzgar el '
        'acierto a mano.)');
  }
}

List<Map<String, dynamic>> _sel(
        List<Map<String, dynamic>> rows, String id, String cond) =>
    rows
        .where((m) =>
            m['questionId'] == id && m['condition'] == cond && m['ok'] == true)
        .toList();

double _avg(List<Map<String, dynamic>> l, String k) =>
    l.isEmpty ? 0 : l.map((m) => (m[k] as num)).reduce((a, b) => a + b) / l.length;
