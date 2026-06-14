// Spike del CIH: valida que `package:analyzer` indexa un proyecto Flutter real
// de forma programática, extrae símbolos y mide tiempos.
//
//   dart run bin/spike_analyzer.dart [ruta_del_proyecto]
//
// Fase 1: parse-only (rápido) → cuenta símbolos vía un AstVisitor.
// Fase 2: muestra de resolución (type resolution real, lo caro).

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

const _defaultProject = '/Users/mijaelcama/Documents/trabajo/navia/zefiron';

Future<void> main(List<String> args) async {
  final projectPath = args.isNotEmpty ? args.first : _defaultProject;
  final libDir = Directory('$projectPath/lib');

  if (!libDir.existsSync()) {
    stderr.writeln('✗ No existe ${libDir.path}');
    exitCode = 1;
    return;
  }

  stdout.writeln('CIH · spike del analyzer');
  stdout.writeln('proyecto: $projectPath');

  final files = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.dart'))
      .toList();
  stdout.writeln('archivos .dart en lib/: ${files.length}\n');

  // ── Fase 1: parse-only → índice de símbolos (sin resolución) ──
  final counter = _SymbolCounter();
  var parsed = 0, failed = 0;
  final sw = Stopwatch()..start();

  for (final path in files) {
    try {
      final result = parseFile(
        path: path,
        featureSet: FeatureSet.latestLanguageVersion(),
        throwIfDiagnostics: false,
      );
      result.unit.accept(counter);
      parsed++;
    } catch (_) {
      failed++;
    }
  }
  sw.stop();

  final secs = sw.elapsedMilliseconds / 1000;
  final perSec = secs == 0 ? files.length : (files.length / secs).round();

  stdout.writeln('— Fase 1: parse + símbolos —');
  stdout.writeln('parseados: $parsed   fallidos: $failed');
  stdout.writeln('símbolos:  ${counter.total}');
  final kinds = counter.counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in kinds) {
    stdout.writeln('  ${e.key.padRight(16)} ${e.value}');
  }
  stdout.writeln('tiempo:    ${secs.toStringAsFixed(2)} s  (~$perSec archivos/s)\n');

  // ── Fase 2: muestra de resolución (lo caro) ──
  // La resolución carga el element model de todo el closure de imports en los
  // primeros archivos (warm-up). Separamos ese costo del marginal (steady-state),
  // que es el que de verdad importa para la indexación incremental.
  stdout.writeln('— Fase 2: muestra de resolución —');
  final sample = files.take(120).toList();
  try {
    final collection = AnalysisContextCollection(includedPaths: [projectPath]);
    var resolved = 0, rfailed = 0;
    final times = <int>[];
    for (final path in sample) {
      final t = Stopwatch()..start();
      final ctx = collection.contextFor(path);
      final unit = await ctx.currentSession.getResolvedUnit(path);
      t.stop();
      if (unit is ResolvedUnitResult) {
        resolved++;
        times.add(t.elapsedMilliseconds);
      } else {
        rfailed++;
      }
    }
    stdout.writeln('resueltos: $resolved/${sample.length}  fallidos: $rfailed');
    if (times.isNotEmpty) {
      final warmup = times.first;
      final marginalList = times.length > 10 ? times.skip(10).toList() : times;
      final marginal = marginalList.reduce((a, b) => a + b) / marginalList.length;
      final estFull = marginal * files.length / 1000;
      stdout.writeln('warm-up (1er archivo):  $warmup ms');
      stdout.writeln('marginal (steady):      ${marginal.toStringAsFixed(1)} ms/archivo');
      stdout.writeln('estimado index full (marginal): ~${estFull.toStringAsFixed(1)} s');
    }
  } catch (e) {
    stdout.writeln('resolución no disponible: $e');
    stdout.writeln('(¿el proyecto tiene .dart_tool/package_config.json? '
        'corre `flutter pub get` en el proyecto)');
  }

  stdout.writeln('\n✓ spike completo');
}

/// Recorre el AST y cuenta símbolos por tipo. Usar un [RecursiveAstVisitor] es
/// estable entre versiones del analyzer (no depende de getters como `.members`).
class _SymbolCounter extends RecursiveAstVisitor<void> {
  final Map<String, int> counts = {};
  int total = 0;

  void _bump(String kind, [int by = 1]) {
    counts[kind] = (counts[kind] ?? 0) + by;
    total += by;
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _bump('class');
    super.visitClassDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _bump('mixin');
    super.visitMixinDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _bump('enum');
    super.visitEnumDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _bump('extension');
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _bump('function');
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _bump('method');
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _bump('constructor');
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    _bump('field', node.fields.variables.length);
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    _bump('topLevelVar', node.variables.variables.length);
    super.visitTopLevelVariableDeclaration(node);
  }
}
