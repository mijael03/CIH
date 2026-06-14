import 'dart:convert';
import 'dart:io';

/// Harness de benchmark END-TO-END headless.
///
/// Corre `claude -p` sobre un set de preguntas en dos condiciones y mide
/// tokens, turnos, tiempo, costo y acierto — el comportamiento REAL del agente
/// resolviendo cada tarea (no un proxy de una sola consulta).
///
///   dart run tool/bench_e2e.dart [--model X] [--reps N] [--first N] [--skip N]
///
/// Ejemplos (ejecución por etapas para controlar costo):
///   dart run tool/bench_e2e.dart --first 5            # primeras 5 preguntas
///   dart run tool/bench_e2e.dart --skip 5             # las restantes
///   dart run tool/bench_e2e.dart --reps 1 --first 1   # smoke rápido y barato
///
/// Condiciones:
///   - baseline : SIN cih. Solo grep/herramientas nativas (comportamiento normal).
///   - cih      : cih expuesto + system prompt que FUERZA su uso (fallback a grep).
///
/// `--strict-mcp-config` en ambas aísla el experimento del `cih` que puedas
/// tener en scope user, para que baseline no lo vea.
///
/// Requisitos:
///   1. Índice fresco del proyecto:  `dart run bin/cih.dart index <proyecto>`
///   2. bench/questions.json  (copia bench/questions.example.json y complétalo)

// ── Configuración ──────────────────────────────────────────────────────────
const _projectUnderTest = '/Users/mijaelcama/Documents/trabajo/navia/zefiron';
const _permissionMode = 'bypassPermissions'; // headless read-only; ver README
const _defaultModel = 'haiku'; // modelo barato por defecto; override con --model
const _defaultReps = 3; // corridas por (pregunta × condición) → promedia ruido

Future<void> main(List<String> argv) async {
  final opts = _parseArgs(argv);
  final root = Directory.current.path;
  final qFile = File('$root/bench/questions.json');
  if (!qFile.existsSync()) {
    stderr.writeln('Falta bench/questions.json — copia '
        'bench/questions.example.json y complétalo con tus preguntas.');
    exit(64);
  }
  var questions = (json.decode(qFile.readAsStringSync()) as List)
      .map((e) => Question.fromJson(e as Map<String, dynamic>))
      .toList();
  if (opts.skip > 0) questions = questions.skip(opts.skip).toList();
  if (opts.first != null) questions = questions.take(opts.first!).toList();
  if (questions.isEmpty) {
    stderr.writeln('No quedaron preguntas tras aplicar --first/--skip.');
    exit(64);
  }

  final systemCih =
      File('$root/bench/system_cih.txt').readAsStringSync().trim();
  final cihConfig = '$root/bench/mcp/cih.json';
  final noneConfig = '$root/bench/mcp/none.json';

  stdout.writeln('modelo: ${opts.model} · repeticiones: ${opts.reps} · '
      'preguntas: ${questions.length}\n');

  final ts = DateTime.now().millisecondsSinceEpoch;
  final outDir = Directory('$root/bench/results')..createSync(recursive: true);
  final jsonl = File('${outDir.path}/run-$ts.jsonl').openWrite();

  const conditions = ['baseline', 'cih'];
  final total = questions.length * conditions.length * opts.reps;
  final all = <Metrics>[];
  var n = 0;

  for (final q in questions) {
    for (final cond in conditions) {
      for (var rep = 1; rep <= opts.reps; rep++) {
        n++;
        stdout.writeln('[$n/$total] ${q.id} · $cond · rep $rep ...');
        final m = await _run(q, cond, rep,
            model: opts.model,
            systemCih: systemCih,
            cihConfig: cihConfig,
            noneConfig: noneConfig);
        all.add(m);
        jsonl.writeln(json.encode(m.toJson()));
        await jsonl.flush();
        if (m.ok) {
          stdout.writeln('    tokens=${m.totalTokens}  turnos=${m.numTurns}  '
              'acierto=${m.correct}  costo=\$${m.costUsd.toStringAsFixed(4)}');
        }
      }
    }
  }
  await jsonl.close();

  final summary = _renderSummary(all, conditions);
  stdout.writeln('\n$summary');
  File('${outDir.path}/summary-$ts.md').writeAsStringSync(summary);
  stdout.writeln('Datos crudos: ${outDir.path}/run-$ts.jsonl');
}

Future<Metrics> _run(
  Question q,
  String cond,
  int rep, {
  required String model,
  required String systemCih,
  required String cihConfig,
  required String noneConfig,
}) async {
  final args = <String>[
    '-p', q.prompt,
    '--output-format', 'json',
    '--permission-mode', _permissionMode,
    '--strict-mcp-config',
    if (model.isNotEmpty) ...['--model', model],
    if (cond == 'cih') ...[
      '--mcp-config', cihConfig,
      '--append-system-prompt', systemCih,
    ] else ...[
      '--mcp-config', noneConfig,
    ],
  ];

  try {
    final proc =
        await Process.run('claude', args, workingDirectory: _projectUnderTest);
    if (proc.exitCode != 0) {
      stderr.writeln('    ⚠ exit ${proc.exitCode}: '
          '${proc.stderr.toString().trim()}');
      return Metrics.failed(q.id, cond, rep);
    }
    final out = json.decode(proc.stdout as String) as Map<String, dynamic>;
    final usage = (out['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
    int u(String k) => (usage[k] as num?)?.toInt() ?? 0;
    final result = (out['result'] ?? '').toString();
    final correct = q.expectContains.isNotEmpty &&
        q.expectContains
            .every((s) => result.toLowerCase().contains(s.toLowerCase()));
    return Metrics(
      questionId: q.id,
      condition: cond,
      rep: rep,
      ok: true,
      inputTokens: u('input_tokens'),
      outputTokens: u('output_tokens'),
      cacheReadTokens: u('cache_read_input_tokens'),
      cacheCreationTokens: u('cache_creation_input_tokens'),
      numTurns: (out['num_turns'] as num?)?.toInt() ?? 0,
      durationMs: (out['duration_ms'] as num?)?.toInt() ?? 0,
      costUsd: (out['total_cost_usd'] as num?)?.toDouble() ?? 0,
      correct: correct,
      result: result,
    );
  } catch (e) {
    stderr.writeln('    ⚠ error: $e');
    return Metrics.failed(q.id, cond, rep);
  }
}

String _renderSummary(List<Metrics> all, List<String> conditions) {
  final b = StringBuffer('# Resultados benchmark E2E\n\n');
  b.writeln('Promedios por condición (${all.length} corridas):\n');
  b.writeln('| Condición | n | acierto | tokens_in | tokens_out | total '
      '| turnos | tiempo | costo |');
  b.writeln('|---|---|---|---|---|---|---|---|---|');

  final byCond = <String, List<Metrics>>{};
  for (final cond in conditions) {
    final cr = all.where((m) => m.condition == cond && m.ok).toList();
    byCond[cond] = cr;
    final acc = cr.isEmpty
        ? 0.0
        : cr.where((m) => m.correct).length / cr.length * 100;
    b.writeln('| $cond | ${cr.length} | ${acc.toStringAsFixed(0)}% '
        '| ${_avg(cr, (m) => m.inputTokens).round()} '
        '| ${_avg(cr, (m) => m.outputTokens).round()} '
        '| ${_avg(cr, (m) => m.totalTokens).round()} '
        '| ${_avg(cr, (m) => m.numTurns).toStringAsFixed(1)} '
        '| ${(_avg(cr, (m) => m.durationMs) / 1000).toStringAsFixed(1)}s '
        '| \$${_avg(cr, (m) => m.costUsd).toStringAsFixed(4)} |');
  }

  final bl = byCond['baseline'] ?? const <Metrics>[];
  final ci = byCond['cih'] ?? const <Metrics>[];
  if (bl.isNotEmpty && ci.isNotEmpty) {
    double ratio(num Function(Metrics) f) {
      final c = _avg(ci, f);
      return c == 0 ? 0 : _avg(bl, f) / c;
    }

    b.writeln('\n**Baseline ÷ CIH (× menos en CIH):** '
        'contexto total ${ratio((m) => m.totalTokens).toStringAsFixed(1)}× · '
        'turnos ${ratio((m) => m.numTurns).toStringAsFixed(1)}× · '
        'costo ${ratio((m) => m.costUsd).toStringAsFixed(1)}×');
    b.writeln('\nAcierto: baseline ${_acc(bl).toStringAsFixed(0)}% '
        'vs CIH ${_acc(ci).toStringAsFixed(0)}%');
  }
  return b.toString();
}

double _avg(List<Metrics> l, num Function(Metrics) f) =>
    l.isEmpty ? 0 : l.map(f).fold<num>(0, (a, b) => a + b) / l.length;

double _acc(List<Metrics> l) =>
    l.isEmpty ? 0 : l.where((m) => m.correct).length / l.length * 100;

class _Opts {
  _Opts({
    required this.model,
    required this.reps,
    required this.first,
    required this.skip,
  });
  final String model;
  final int reps;
  final int? first;
  final int skip;
}

_Opts _parseArgs(List<String> argv) {
  var model = _defaultModel;
  var reps = _defaultReps;
  int? first;
  var skip = 0;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--model':
        model = argv[++i];
      case '--reps':
        reps = int.parse(argv[++i]);
      case '--first':
        first = int.parse(argv[++i]);
      case '--skip':
        skip = int.parse(argv[++i]);
      default:
        stderr.writeln('Flag desconocido: ${argv[i]}');
    }
  }
  return _Opts(model: model, reps: reps, first: first, skip: skip);
}

class Question {
  Question(this.id, this.prompt, this.expectContains);
  final String id;
  final String prompt;
  final List<String> expectContains;
  factory Question.fromJson(Map<String, dynamic> j) => Question(
        j['id'] as String,
        j['prompt'] as String,
        ((j['expect_contains'] as List?) ?? const []).cast<String>(),
      );
}

class Metrics {
  Metrics({
    required this.questionId,
    required this.condition,
    required this.rep,
    required this.ok,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.numTurns = 0,
    this.durationMs = 0,
    this.costUsd = 0,
    this.correct = false,
    this.result = '',
  });
  factory Metrics.failed(String id, String cond, int rep) =>
      Metrics(questionId: id, condition: cond, rep: rep, ok: false);

  final String questionId;
  final String condition;
  final int rep;
  final bool ok;
  final int inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens;
  final int numTurns;
  final int durationMs;
  final double costUsd;
  final bool correct;
  final String result;

  int get totalTokens =>
      inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens;

  Map<String, dynamic> toJson() => {
        'questionId': questionId,
        'condition': condition,
        'rep': rep,
        'ok': ok,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'cacheReadTokens': cacheReadTokens,
        'cacheCreationTokens': cacheCreationTokens,
        'totalTokens': totalTokens,
        'numTurns': numTurns,
        'durationMs': durationMs,
        'costUsd': costUsd,
        'correct': correct,
        'result': result,
      };
}
