import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../../model/intermediate_model.dart';
import '../language_adapter.dart';

/// Adaptador de Dart: extrae símbolos usando `package:analyzer` (parse-only,
/// rápido). Es la implementación nativa del [LanguageAdapter] para Dart/Flutter.
class DartAdapter implements LanguageAdapter {
  @override
  String get language => 'dart';

  @override
  bool canHandle(String projectPath) =>
      File(p.join(projectPath, 'pubspec.yaml')).existsSync();

  @override
  Future<IndexResult> index(
    String projectPath, {
    void Function(IndexProgress progress)? onProgress,
  }) async {
    final libDir = Directory(p.join(projectPath, 'lib'));
    if (!libDir.existsSync()) return const IndexResult();

    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .where((path) => path.endsWith('.dart'))
        .toList()
      ..sort();

    final symbols = <CodeSymbol>[];
    var done = 0;
    for (final absPath in files) {
      final relPath = p.relative(absPath, from: projectPath);
      try {
        final result = parseFile(
          path: absPath,
          featureSet: FeatureSet.latestLanguageVersion(),
          throwIfDiagnostics: false,
        );
        result.unit.accept(_SymbolVisitor(relPath, result.lineInfo, symbols));
      } catch (_) {
        // Archivo no parseable; lo saltamos sin abortar el index.
      }
      done++;
      onProgress?.call(IndexProgress(
        filesProcessed: done,
        filesTotal: files.length,
        currentFile: relPath,
      ));
    }
    return IndexResult(symbols: symbols);
  }
}

/// Contenedor actual (clase/mixin/enum/extension) durante el recorrido.
class _Container {
  _Container(this.id, this.name);
  final String id;
  final String name;
}

/// Recorre el AST y emite [CodeSymbol] a `out`. Mantiene una pila de
/// contenedores para asignar `containerId` y construir ids estables.
class _SymbolVisitor extends RecursiveAstVisitor<void> {
  _SymbolVisitor(this.filePath, this.lineInfo, this.out);

  final String filePath;
  final LineInfo lineInfo;
  final List<CodeSymbol> out;
  final List<_Container> _stack = [];

  String? get _containerId => _stack.isEmpty ? null : _stack.last.id;
  String? get _containerName => _stack.isEmpty ? null : _stack.last.name;

  String _add({
    required String name,
    required SymbolKind kind,
    required int offset,
    String? signature,
    String? doc,
    String? idOverride,
  }) {
    final container = _containerName;
    final id = idOverride ??
        (container == null
            ? '$filePath::$name'
            : '$filePath::$container.$name');
    final loc = lineInfo.getLocation(offset);
    out.add(CodeSymbol(
      id: id,
      name: name,
      kind: kind,
      filePath: filePath,
      line: loc.lineNumber,
      column: loc.columnNumber,
      signature: signature,
      containerId: _containerId,
      doc: doc,
    ));
    return id;
  }

  String? _doc(Comment? c) => c?.tokens.map((t) => t.lexeme).join('\n');

  String _typeSig(
    String keyword,
    String name,
    TypeParameterList? tp,
    List<String> clauses,
  ) {
    final b = StringBuffer(keyword)
      ..write(' ')
      ..write(name);
    if (tp != null) b.write(tp.toSource());
    for (final c in clauses) {
      if (c.isNotEmpty) {
        b
          ..write(' ')
          ..write(c);
      }
    }
    return b.toString();
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    // Dart 3.12+: el nombre vive en namePart (soporta constructores primarios).
    final nameToken = node.namePart.typeName;
    final id = _add(
      name: nameToken.lexeme,
      kind: SymbolKind.class_,
      offset: nameToken.offset,
      signature: _typeSig(
        'class',
        nameToken.lexeme,
        node.namePart.typeParameters,
        [
          node.extendsClause?.toSource() ?? '',
          node.withClause?.toSource() ?? '',
          node.implementsClause?.toSource() ?? '',
        ],
      ),
      doc: _doc(node.documentationComment),
    );
    _stack.add(_Container(id, nameToken.lexeme));
    super.visitClassDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    final id = _add(
      name: node.name.lexeme,
      kind: SymbolKind.mixin_,
      offset: node.name.offset,
      signature: _typeSig('mixin', node.name.lexeme, node.typeParameters, [
        node.onClause?.toSource() ?? '',
        node.implementsClause?.toSource() ?? '',
      ]),
      doc: _doc(node.documentationComment),
    );
    _stack.add(_Container(id, node.name.lexeme));
    super.visitMixinDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final nameToken = node.namePart.typeName;
    final id = _add(
      name: nameToken.lexeme,
      kind: SymbolKind.enum_,
      offset: nameToken.offset,
      signature: _typeSig(
          'enum', nameToken.lexeme, node.namePart.typeParameters, const []),
      doc: _doc(node.documentationComment),
    );
    _stack.add(_Container(id, nameToken.lexeme));
    super.visitEnumDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name?.lexeme;
    final String id;
    if (name != null) {
      id = _add(
        name: name,
        kind: SymbolKind.extension_,
        offset: node.name!.offset,
        signature: _typeSig('extension', name, node.typeParameters, const []),
        doc: _doc(node.documentationComment),
      );
    } else {
      id = '$filePath::<extension@${node.offset}>';
    }
    _stack.add(_Container(id, name ?? '<extension>'));
    super.visitExtensionDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    _add(
      name: node.name.lexeme,
      kind: SymbolKind.field,
      offset: node.name.offset,
      doc: _doc(node.documentationComment),
    );
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final kind = node.isGetter
        ? SymbolKind.getter
        : node.isSetter
            ? SymbolKind.setter
            : SymbolKind.method;
    final b = StringBuffer();
    if (node.returnType != null) b.write('${node.returnType!.toSource()} ');
    if (node.isGetter) b.write('get ');
    if (node.isSetter) b.write('set ');
    b.write(node.name.lexeme);
    if (node.typeParameters != null) b.write(node.typeParameters!.toSource());
    if (node.parameters != null) b.write(node.parameters!.toSource());
    _add(
      name: node.name.lexeme,
      kind: kind,
      offset: node.name.offset,
      signature: b.toString(),
      doc: _doc(node.documentationComment),
    );
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final className = _containerName ?? '';
    final ctorName = node.name?.lexeme;
    final name = ctorName == null ? className : '$className.$ctorName';
    final offset = node.name?.offset ?? node.offset;
    final sig = StringBuffer(className);
    if (ctorName != null) sig.write('.$ctorName');
    sig.write(node.parameters.toSource());
    _add(
      name: name,
      kind: SymbolKind.constructor,
      offset: offset,
      signature: sig.toString(),
      doc: _doc(node.documentationComment),
      idOverride: '$filePath::$name',
    );
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    final type = node.fields.type?.toSource();
    for (final v in node.fields.variables) {
      _add(
        name: v.name.lexeme,
        kind: SymbolKind.field,
        offset: v.name.offset,
        signature: type == null ? v.name.lexeme : '$type ${v.name.lexeme}',
        doc: _doc(node.documentationComment),
      );
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // Solo funciones/getters/setters top-level (no funciones locales anidadas).
    if (node.parent is CompilationUnit) {
      final kind = node.isGetter
          ? SymbolKind.getter
          : node.isSetter
              ? SymbolKind.setter
              : SymbolKind.function;
      final fe = node.functionExpression;
      final b = StringBuffer();
      if (node.returnType != null) b.write('${node.returnType!.toSource()} ');
      if (node.isGetter) b.write('get ');
      if (node.isSetter) b.write('set ');
      b.write(node.name.lexeme);
      if (fe.typeParameters != null) b.write(fe.typeParameters!.toSource());
      if (fe.parameters != null) b.write(fe.parameters!.toSource());
      _add(
        name: node.name.lexeme,
        kind: kind,
        offset: node.name.offset,
        signature: b.toString(),
        doc: _doc(node.documentationComment),
      );
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    final type = node.variables.type?.toSource();
    for (final v in node.variables.variables) {
      _add(
        name: v.name.lexeme,
        kind: SymbolKind.topLevelVariable,
        offset: v.name.offset,
        signature: type == null ? v.name.lexeme : '$type ${v.name.lexeme}',
        doc: _doc(node.documentationComment),
      );
    }
    super.visitTopLevelVariableDeclaration(node);
  }
}
