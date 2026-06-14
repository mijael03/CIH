import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

/// Un símbolo invocado desde el cuerpo de otro (callee).
class Callee {
  Callee(this.symbol, this.file, this.callLine);
  final String symbol; // nombre cualificado del callee
  final String file; // archivo (relativo) donde se DEFINE el callee
  final int callLine; // línea donde se le invoca
}

/// Un símbolo X y los símbolos del proyecto que invoca (sus callees).
class CalleeGroup {
  CalleeGroup(this.symbol, this.file, this.line);
  final String symbol;
  final String file;
  final int line;
  final List<Callee> callees = [];
}

/// Motor de "a quién llama X" (N3 inverso) con resolución semántica.
///
/// Clave de eficiencia: solo resuelve el/los archivo(s) donde X se DEFINE (no
/// todo el proyecto). Y poda agresiva: solo conserva callees del PROYECTO
/// (descarta Flutter/SDK), que es ~el 10% de lo que invoca un widget.
class DartCallees {
  DartCallees(this.projectPath, this.packageName);
  final String projectPath;
  final String packageName;

  factory DartCallees.forProject(String projectPath) {
    var name = '';
    final pub = File(p.join(projectPath, 'pubspec.yaml'));
    if (pub.existsSync()) {
      for (final line in pub.readAsLinesSync()) {
        final m = RegExp(r'^name:\s*(\S+)').firstMatch(line);
        if (m != null) {
          name = m.group(1)!;
          break;
        }
      }
    }
    return DartCallees(projectPath, name);
  }

  /// Encuentra los callees de cada declaración de [name] hallada en
  /// [defFilesRel] (los archivos de definición; del índice).
  Future<List<CalleeGroup>> find(
    String name, {
    required Iterable<String> defFilesRel,
    AnalysisContextCollection? collection,
  }) async {
    final acc =
        collection ?? AnalysisContextCollection(includedPaths: [projectPath]);
    final groups = <CalleeGroup>[];
    for (final rel in defFilesRel.toSet()) {
      final abs = p.join(projectPath, rel);
      if (!File(abs).existsSync()) continue;
      final unit = await acc.contextFor(abs).currentSession.getResolvedUnit(abs);
      if (unit is! ResolvedUnitResult) continue;
      final finder = _DeclFinder(name);
      unit.unit.accept(finder);
      for (final d in finder.found) {
        final g = CalleeGroup(
          d.qualified,
          rel,
          unit.lineInfo.getLocation(d.nameOffset).lineNumber,
        );
        final v = _CalleeVisitor(packageName, unit.lineInfo);
        d.body.accept(v);
        g.callees.addAll(v.callees);
        groups.add(g);
      }
    }
    return groups;
  }
}

class _Decl {
  _Decl(this.qualified, this.nameOffset, this.body);
  final String qualified;
  final int nameOffset;
  final FunctionBody body;
}

/// Localiza las declaraciones con el nombre dado y captura su cuerpo.
class _DeclFinder extends RecursiveAstVisitor<void> {
  _DeclFinder(this.name);
  final String name;
  final List<_Decl> found = [];
  final List<String> _stack = [];

  String? get _owner => _stack.isEmpty ? null : _stack.last;
  String _q(String n) => _owner == null ? n : '$_owner.$n';

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _stack.add(node.namePart.typeName.lexeme);
    super.visitClassDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _stack.add(node.name.lexeme);
    super.visitMixinDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _stack.add(node.namePart.typeName.lexeme);
    super.visitEnumDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _stack.add(node.name?.lexeme ?? '<extension>');
    super.visitExtensionDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == name) {
      found.add(_Decl(_q(node.name.lexeme), node.name.offset, node.body));
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is CompilationUnit && node.name.lexeme == name) {
      found.add(_Decl(
        node.name.lexeme,
        node.name.offset,
        node.functionExpression.body,
      ));
    }
    super.visitFunctionDeclaration(node);
  }
}

/// Recorre un cuerpo y recolecta las invocaciones a símbolos DEL PROYECTO.
class _CalleeVisitor extends RecursiveAstVisitor<void> {
  _CalleeVisitor(this.packageName, this.lineInfo);
  final String packageName;
  final LineInfo lineInfo;
  final List<Callee> callees = [];
  final Set<String> _seen = {};

  void _add(Element? raw, int offset) {
    if (raw == null) return;
    final e = raw.baseElement;
    final uri = e.library?.uri;
    if (uri == null) return;
    final prefix = 'package:$packageName/';
    if (!uri.toString().startsWith(prefix)) return; // poda: solo proyecto
    final q = _qualified(e);
    if (!_seen.add(q)) return;
    final file = 'lib/${uri.toString().substring(prefix.length)}';
    callees.add(Callee(q, file, lineInfo.getLocation(offset).lineNumber));
  }

  String _qualified(Element e) {
    final n = e.name ?? '?';
    final owner = e.enclosingElement;
    if (owner != null && owner is! LibraryElement) {
      final on = owner.name;
      if (on != null && on.isNotEmpty) return '$on.$n';
    }
    return n;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _add(node.methodName.element, node.methodName.offset);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _add(node.constructorName.element, node.offset);
    super.visitInstanceCreationExpression(node);
  }
}
