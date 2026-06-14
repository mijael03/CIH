/// Modelo intermedio normalizado del CIH.
///
/// Es el **único contrato** entre los adaptadores de lenguaje y el core. El core
/// razona y responde consultas únicamente sobre estos tipos; nunca conoce el
/// lenguaje de origen ni la herramienta que produjo los datos. Por eso agregar
/// un lenguaje nuevo = escribir un adaptador que emita este modelo, sin tocar
/// el core.
library;

/// Clase de un símbolo en el código.
enum SymbolKind {
  class_,
  mixin_,
  enum_,
  extension_,
  extensionType,
  function,
  method,
  constructor,
  getter,
  setter,
  field,
  topLevelVariable,
  typedef_,
  parameter,
  library_,
  unknown,
}

/// Rol de una ocurrencia de un símbolo en un punto del código.
enum OccurrenceRole { definition, reference, write, import_, export_ }

/// Tipo de relación entre dos símbolos.
enum RelationshipKind {
  extends_,
  implements_,
  mixesIn,
  on_,

  /// Provee una dependencia (p. ej. GetX `Get.put<T>()`).
  provides,

  /// Consume una dependencia (p. ej. GetX `Get.find<T>()`).
  consumes,
}

/// Un símbolo: clase, método, función, campo, etc.
class CodeSymbol {
  /// Id estable y único (p. ej. `lib/foo/bar.dart::MyClass.myMethod`).
  final String id;
  final String name;
  final SymbolKind kind;
  final String filePath;
  final int line;
  final int column;

  /// Firma legible sin el cuerpo (p. ej. `Future<void> save(User u)`).
  final String? signature;

  /// Id del símbolo contenedor (la clase de un método, etc.); null si top-level.
  final String? containerId;

  /// Doc comment, si existe.
  final String? doc;

  const CodeSymbol({
    required this.id,
    required this.name,
    required this.kind,
    required this.filePath,
    required this.line,
    required this.column,
    this.signature,
    this.containerId,
    this.doc,
  });

  @override
  String toString() => '$kind $name ($filePath:$line)';
}

/// Una ocurrencia de un símbolo en un punto del código.
class Occurrence {
  final String symbolId;
  final String filePath;
  final int line;
  final int column;
  final OccurrenceRole role;

  /// Símbolo (método/función/campo) que CONTIENE esta ocurrencia, es decir
  /// "quién" hace la referencia. Base del call graph (N3). Null si no aplica.
  final String? enclosing;

  const Occurrence({
    required this.symbolId,
    required this.filePath,
    required this.line,
    required this.column,
    required this.role,
    this.enclosing,
  });
}

/// Una relación dirigida entre dos símbolos.
class Relationship {
  final String fromId;
  final String toId;
  final RelationshipKind kind;

  const Relationship({
    required this.fromId,
    required this.toId,
    required this.kind,
  });
}

/// Resultado de indexar un proyecto: lo que todo adaptador debe producir.
class IndexResult {
  final List<CodeSymbol> symbols;
  final List<Occurrence> occurrences;
  final List<Relationship> relationships;

  const IndexResult({
    this.symbols = const [],
    this.occurrences = const [],
    this.relationships = const [],
  });

  int get symbolCount => symbols.length;
}

/// Progreso de indexación, para reportar avance al llamador.
class IndexProgress {
  final int filesProcessed;
  final int filesTotal;
  final String? currentFile;

  const IndexProgress({
    required this.filesProcessed,
    required this.filesTotal,
    this.currentFile,
  });

  double get fraction => filesTotal == 0 ? 0 : filesProcessed / filesTotal;
}
