/// CIH — Code Intelligence Harness.
///
/// Punto de entrada de la librería: modelo intermedio, interfaz de adaptadores,
/// el adaptador de Dart y la persistencia. El core depende solo del modelo y la
/// interfaz; los adaptadores y el store son intercambiables.
library;

export 'src/adapter/dart/dart_adapter.dart';
export 'src/adapter/dart/dart_dependencies.dart';
export 'src/adapter/dart/dart_references.dart';
export 'src/adapter/language_adapter.dart';
export 'src/model/intermediate_model.dart';
export 'src/store/symbol_store.dart';
