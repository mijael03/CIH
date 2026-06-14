import '../model/intermediate_model.dart';

/// Contrato que implementa cada lenguaje soportado.
///
/// El core depende solo de esta interfaz y del modelo intermedio. El adaptador
/// de Dart usa el `analyzer` nativo; los futuros (Python, TS, …) envolverán sus
/// indexadores SCIP/LSP, pero todos emiten el mismo [IndexResult].
abstract interface class LanguageAdapter {
  /// Identificador del lenguaje, p. ej. `'dart'`.
  String get language;

  /// Indica si este adaptador puede indexar el proyecto en [projectPath].
  bool canHandle(String projectPath);

  /// Indexa el proyecto y devuelve el modelo intermedio normalizado.
  Future<IndexResult> index(
    String projectPath, {
    void Function(IndexProgress progress)? onProgress,
  });
}
