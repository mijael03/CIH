import 'package:sqlite3/sqlite3.dart';

import '../model/intermediate_model.dart';

/// Persistencia del índice en SQLite. Guarda el modelo intermedio y resuelve
/// las consultas del query engine. El costo de indexar se paga una vez; las
/// consultas son en milisegundos.
class SymbolStore {
  SymbolStore(this.db);

  final Database db;

  /// Abre (o crea) la base en [path] y aplica el schema.
  factory SymbolStore.open(String path) {
    final store = SymbolStore(sqlite3.open(path));
    store._migrate();
    return store;
  }

  void _migrate() {
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS files (
        path     TEXT PRIMARY KEY,
        language TEXT NOT NULL,
        hash     TEXT
      );
      CREATE TABLE IF NOT EXISTS symbols (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        kind         TEXT NOT NULL,
        file         TEXT NOT NULL,
        line         INTEGER NOT NULL,
        col          INTEGER NOT NULL,
        signature    TEXT,
        container_id TEXT,
        doc          TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
      CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file);
    ''');
  }

  /// Reemplaza por completo el índice de símbolos (index full).
  void replaceAllSymbols(IndexResult result) {
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM symbols');
      final stmt = db.prepare(
        'INSERT OR REPLACE INTO symbols '
        '(id, name, kind, file, line, col, signature, container_id, doc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      );
      for (final s in result.symbols) {
        stmt.execute([
          s.id,
          s.name,
          s.kind.name,
          s.filePath,
          s.line,
          s.column,
          s.signature,
          s.containerId,
          s.doc,
        ]);
      }
      stmt.close();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  int get symbolCount =>
      db.select('SELECT COUNT(*) AS c FROM symbols').first['c'] as int;

  /// Distribución de símbolos por tipo (kind -> conteo).
  Map<String, int> kindCounts() {
    final rows =
        db.select('SELECT kind, COUNT(*) AS c FROM symbols GROUP BY kind '
            'ORDER BY c DESC');
    return {for (final r in rows) r['kind'] as String: r['c'] as int};
  }

  /// Busca símbolos por nombre: exacto primero, luego prefijo, luego substring.
  List<CodeSymbol> findByName(String query, {int limit = 20}) {
    final rows = db.select(
      '''
      SELECT *,
        CASE
          WHEN name = ?1 THEN 0
          WHEN name LIKE ?1 || '%' THEN 1
          ELSE 2
        END AS rank,
        CASE kind
          WHEN 'class_' THEN 0
          WHEN 'enum_' THEN 0
          WHEN 'mixin_' THEN 0
          WHEN 'extension_' THEN 0
          WHEN 'extensionType' THEN 0
          WHEN 'typedef_' THEN 0
          WHEN 'function' THEN 0
          ELSE 1
        END AS kind_rank
      FROM symbols
      WHERE name = ?1 OR name LIKE '%' || ?1 || '%'
      ORDER BY rank, kind_rank, length(name), name
      LIMIT ?2
      ''',
      [query, limit],
    );
    return rows.map(_rowToSymbol).toList();
  }

  CodeSymbol _rowToSymbol(Row r) => CodeSymbol(
        id: r['id'] as String,
        name: r['name'] as String,
        kind: SymbolKind.values.byName(r['kind'] as String),
        filePath: r['file'] as String,
        line: r['line'] as int,
        column: r['col'] as int,
        signature: r['signature'] as String?,
        containerId: r['container_id'] as String?,
        doc: r['doc'] as String?,
      );

  void close() => db.close();
}
