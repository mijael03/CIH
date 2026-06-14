import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../../model/intermediate_model.dart';

/// Resultado de buscar referencias a un símbolo.
class ReferenceResult {
  ReferenceResult(this.targetName, this.targetFile, this.references);

  final String targetName;

  /// Archivo (relativo) donde se localizó la definición del objetivo.
  final String? targetFile;
  final List<Occurrence> references;
}

/// Motor de referencias para Dart, basado en **resolución semántica**.
///
/// En vez de resolver el proyecto completo, hace un híbrido: pre-filtra por
/// texto los archivos candidatos (barato), los resuelve y compara *elementos*
/// (no texto). Resultado: cero falsos positivos, a diferencia de grep.
class DartReferences {
  DartReferences(this.projectPath);

  final String projectPath;

  Future<ReferenceResult> find(
    String name, {
    String? definitionFile,
    void Function(int done, int total)? onProgress,
  }) async {
    final libDir = Directory(p.join(projectPath, 'lib'));
    if (!libDir.existsSync()) return ReferenceResult(name, null, const []);

    // Pre-filtro textual: solo archivos que mencionan el nombre.
    final candidates = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      try {
        if (entity.readAsStringSync().contains(name)) {
          candidates.add(entity.path);
        }
      } catch (_) {
        // ignoramos archivos ilegibles
      }
    }

    final collection = AnalysisContextCollection(includedPaths: [projectPath]);

    // 1. Localizar el elemento objetivo (preferimos su archivo de definición).
    final defAbs =
        definitionFile != null ? p.join(projectPath, definitionFile) : null;
    final searchOrder = <String>[
      if (defAbs != null && File(defAbs).existsSync()) defAbs,
      ...candidates,
    ];

    Element? target;
    String? targetFileAbs;
    for (final f in searchOrder) {
      final unit = await collection.contextFor(f).currentSession
          .getResolvedUnit(f);
      if (unit is! ResolvedUnitResult) continue;
      final finder = _DeclFinder(name);
      unit.unit.accept(finder);
      if (finder.target != null) {
        target = finder.target;
        targetFileAbs = f;
        break;
      }
    }

    if (target == null) return ReferenceResult(name, null, const []);

    // 2. Recorrer candidatos y comparar elementos resueltos.
    final refs = <Occurrence>[];
    final seen = <String>{};
    var done = 0;
    for (final f in candidates) {
      final unit = await collection.contextFor(f).currentSession
          .getResolvedUnit(f);
      done++;
      onProgress?.call(done, candidates.length);
      if (unit is! ResolvedUnitResult) continue;
      final rel = p.relative(f, from: projectPath);
      unit.unit.accept(_RefVisitor(target, name, rel, unit.lineInfo, refs, seen));
    }

    final targetRel = targetFileAbs == null
        ? null
        : p.relative(targetFileAbs, from: projectPath);
    return ReferenceResult(name, targetRel, refs);
  }
}

/// Encuentra la declaración con el nombre dado y captura su [Element].
class _DeclFinder extends RecursiveAstVisitor<void> {
  _DeclFinder(this.name);

  final String name;
  Element? target;

  void _check(String? declName, Fragment? fragment) {
    if (target == null && declName == name && fragment != null) {
      target = fragment.element;
    }
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _check(node.namePart.typeName.lexeme, node.declaredFragment);
    super.visitClassDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _check(node.namePart.typeName.lexeme, node.declaredFragment);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _check(node.name.lexeme, node.declaredFragment);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _check(node.name?.lexeme, node.declaredFragment);
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is CompilationUnit) {
      _check(node.name.lexeme, node.declaredFragment);
    }
    super.visitFunctionDeclaration(node);
  }
}

/// Recorre un archivo resuelto y registra cada referencia al [target].
class _RefVisitor extends RecursiveAstVisitor<void> {
  _RefVisitor(
    this.target,
    this.targetName,
    this.filePath,
    this.lineInfo,
    this.out,
    this.seen,
  );

  final Element target;
  final String targetName;
  final String filePath;
  final LineInfo lineInfo;
  final List<Occurrence> out;
  final Set<String> seen;

  void _hit(Element? element, int offset) {
    if (element == null || element != target) return;
    final loc = lineInfo.getLocation(offset);
    final key = '$filePath:${loc.lineNumber}:${loc.columnNumber}';
    if (seen.add(key)) {
      out.add(Occurrence(
        symbolId: targetName,
        filePath: filePath,
        line: loc.lineNumber,
        column: loc.columnNumber,
        role: OccurrenceRole.reference,
      ));
    }
  }

  @override
  void visitNamedType(NamedType node) {
    _hit(node.element, node.offset);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _hit(node.element, node.offset);
    super.visitSimpleIdentifier(node);
  }
}
