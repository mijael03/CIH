import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../../model/intermediate_model.dart';

/// Una declaración objetivo (un símbolo concreto) con sus referencias.
///
/// Cuando hay homónimos (p. ej. dos `addPermissions` en clases distintas), cada
/// uno es un target separado → así se resuelve "quién llama a cada cual" por su
/// receptor, algo que grep no puede hacer.
class ReferenceTarget {
  ReferenceTarget({
    required this.name,
    required this.kind,
    required this.container,
    required this.file,
    required this.line,
  });

  final String name;
  final String kind; // class_, enum_, mixin_, method, getter, setter, field...
  final String? container; // clase/mixin/extension contenedora, si aplica
  final String file; // ruta relativa de la definición
  final int line;
  final List<Occurrence> references = [];
  final Set<String> _seen = {};

  /// Nombre cualificado legible: `Container.name` o `name`.
  String get qualified => container == null ? name : '$container.$name';
}

/// Resultado de buscar referencias: una entrada por cada declaración homónima.
class ReferenceResult {
  ReferenceResult(this.queryName, this.targets);

  final String queryName;
  final List<ReferenceTarget> targets;

  bool get found => targets.isNotEmpty;
  int get totalReferences =>
      targets.fold(0, (acc, t) => acc + t.references.length);
}

/// Motor de referencias para Dart, basado en **resolución semántica**.
///
/// Pre-filtra candidatos por texto (barato), resuelve y compara *elementos* (no
/// texto) → cero falsos positivos. Resuelve tanto tipos (clases/enums) como
/// miembros (métodos/getters/setters/campos), y agrupa por declaración para
/// distinguir homónimos por su receptor.
class DartReferences {
  DartReferences(this.projectPath);

  final String projectPath;

  Future<ReferenceResult> find(
    String name, {
    AnalysisContextCollection? collection,
    void Function(int done, int total)? onProgress,
  }) async {
    final libDir = Directory(p.join(projectPath, 'lib'));
    if (!libDir.existsSync()) return ReferenceResult(name, const []);

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

    final acc =
        collection ?? AnalysisContextCollection(includedPaths: [projectPath]);

    // Fase 1: recolectar TODAS las declaraciones con ese nombre (los targets).
    final targets = <Element, ReferenceTarget>{};
    for (final f in candidates) {
      final unit = await acc.contextFor(f).currentSession.getResolvedUnit(f);
      if (unit is! ResolvedUnitResult) continue;
      final rel = p.relative(f, from: projectPath);
      unit.unit.accept(_DeclCollector(name, rel, unit.lineInfo, targets));
    }
    if (targets.isEmpty) return ReferenceResult(name, const []);

    // Fase 2: recolectar referencias (la resolución ya quedó cacheada).
    var done = 0;
    for (final f in candidates) {
      final unit = await acc.contextFor(f).currentSession.getResolvedUnit(f);
      done++;
      onProgress?.call(done, candidates.length);
      if (unit is! ResolvedUnitResult) continue;
      final rel = p.relative(f, from: projectPath);
      unit.unit.accept(_RefCollector(targets, rel, unit.lineInfo));
    }

    return ReferenceResult(name, targets.values.toList());
  }
}

/// Recolecta cada declaración cuyo nombre coincide, junto con su [Element].
class _DeclCollector extends RecursiveAstVisitor<void> {
  _DeclCollector(this.name, this.filePath, this.lineInfo, this.targets);

  final String name;
  final String filePath;
  final LineInfo lineInfo;
  final Map<Element, ReferenceTarget> targets;
  final List<String> _stack = [];

  String? get _container => _stack.isEmpty ? null : _stack.last;

  void _maybe(String declName, String kind, Fragment? fragment, int offset) {
    if (declName != name || fragment == null) return;
    // baseElement normaliza miembros de tipos genéricos a su declaración.
    final el = fragment.element.baseElement;
    targets.putIfAbsent(el, () {
      final loc = lineInfo.getLocation(offset);
      return ReferenceTarget(
        name: name,
        kind: kind,
        container: _container,
        file: filePath,
        line: loc.lineNumber,
      );
    });
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final n = node.namePart.typeName.lexeme;
    _maybe(n, 'class_', node.declaredFragment, node.namePart.typeName.offset);
    _stack.add(n);
    super.visitClassDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final n = node.namePart.typeName.lexeme;
    _maybe(n, 'enum_', node.declaredFragment, node.namePart.typeName.offset);
    _stack.add(n);
    super.visitEnumDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _maybe(node.name.lexeme, 'mixin_', node.declaredFragment, node.name.offset);
    _stack.add(node.name.lexeme);
    super.visitMixinDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final n = node.name?.lexeme;
    if (n != null) {
      _maybe(n, 'extension_', node.declaredFragment, node.name!.offset);
    }
    _stack.add(n ?? '<extension>');
    super.visitExtensionDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final kind = node.isGetter
        ? 'getter'
        : node.isSetter
            ? 'setter'
            : 'method';
    _maybe(node.name.lexeme, kind, node.declaredFragment, node.name.offset);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is CompilationUnit) {
      final kind = node.isGetter
          ? 'getter'
          : node.isSetter
              ? 'setter'
              : 'function';
      _maybe(node.name.lexeme, kind, node.declaredFragment, node.name.offset);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (final v in node.fields.variables) {
      _maybe(v.name.lexeme, 'field', v.declaredFragment, v.name.offset);
    }
    super.visitFieldDeclaration(node);
  }
}

/// Recorre un archivo resuelto y registra cada referencia a algún target.
class _RefCollector extends RecursiveAstVisitor<void> {
  _RefCollector(this.targets, this.filePath, this.lineInfo);

  final Map<Element, ReferenceTarget> targets;
  final String filePath;
  final LineInfo lineInfo;

  void _hit(Element? element, AstNode node) {
    if (element == null) return;
    final t = targets[element.baseElement];
    if (t == null) return;
    final loc = lineInfo.getLocation(node.offset);
    final key = '$filePath:${loc.lineNumber}:${loc.columnNumber}';
    if (t._seen.add(key)) {
      t.references.add(Occurrence(
        symbolId: t.qualified,
        filePath: filePath,
        line: loc.lineNumber,
        column: loc.columnNumber,
        role: OccurrenceRole.reference,
        enclosing: _enclosingSymbol(node),
      ));
    }
  }

  @override
  void visitNamedType(NamedType node) {
    _hit(node.element, node);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _hit(node.element, node);
    super.visitSimpleIdentifier(node);
  }
}

/// Nombre cualificado del símbolo (método/función/constructor/campo) que
/// CONTIENE el nodo dado — es decir, "quién" hace la referencia. Base de N3.
String? _enclosingSymbol(AstNode node) {
  for (AstNode? n = node; n != null; n = n.parent) {
    if (n is MethodDeclaration) {
      final o = _ownerName(n);
      return o == null ? n.name.lexeme : '$o.${n.name.lexeme}';
    }
    if (n is FunctionDeclaration && n.parent is CompilationUnit) {
      return n.name.lexeme;
    }
    if (n is ConstructorDeclaration) {
      final o = _ownerName(n) ?? '';
      final cn = n.name?.lexeme;
      return cn == null ? o : '$o.$cn';
    }
    if (n is FieldDeclaration) {
      final o = _ownerName(n);
      final vs = n.fields.variables;
      final v = vs.isEmpty ? '' : vs.first.name.lexeme;
      return o == null ? v : '$o.$v';
    }
  }
  return null;
}

/// Nombre del tipo contenedor (clase/mixin/enum/extension) del nodo.
String? _ownerName(AstNode node) {
  for (AstNode? n = node.parent; n != null; n = n.parent) {
    if (n is ClassDeclaration) return n.namePart.typeName.lexeme;
    if (n is MixinDeclaration) return n.name.lexeme;
    if (n is EnumDeclaration) return n.namePart.typeName.lexeme;
    if (n is ExtensionDeclaration) return n.name?.lexeme ?? '<extension>';
  }
  return null;
}
