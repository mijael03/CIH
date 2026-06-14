import 'dart:io';

import 'package:cih/src/adapter/dart/dart_adapter.dart';
import 'package:cih/src/adapter/dart/dart_references.dart';
import 'package:cih/src/model/intermediate_model.dart';
import 'package:cih/src/store/symbol_store.dart';

const _dbDir = '.cih';
const _dbPath = '.cih/index.db';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }
  final rest = args.skip(1).toList();
  switch (args.first) {
    case 'index':
      await _index(rest);
    case 'find':
      _find(rest);
    case 'refs':
      await _refs(rest);
    case 'stats':
      _stats();
    default:
      stderr.writeln('Comando desconocido: ${args.first}\n');
      _usage();
      exitCode = 64;
  }
}

void _usage() {
  stdout.writeln('''
cih — Code Intelligence Harness

Uso:
  cih index <ruta_proyecto>   Indexa un proyecto Dart/Flutter
  cih find  <nombre>          Busca un símbolo por nombre
  cih refs  <nombre>          Encuentra referencias a un símbolo (semántico)
  cih stats                   Estadísticas del índice actual
''');
}

Future<void> _index(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Falta <ruta_proyecto>');
    exitCode = 64;
    return;
  }
  final projectPath = args.first;
  final adapter = DartAdapter();
  if (!adapter.canHandle(projectPath)) {
    stderr.writeln('No parece un proyecto Dart (falta pubspec.yaml): '
        '$projectPath');
    exitCode = 66;
    return;
  }

  stdout.writeln('Indexando $projectPath ...');
  final sw = Stopwatch()..start();
  final result = await adapter.index(
    projectPath,
    onProgress: (p) {
      if (p.filesProcessed % 200 == 0 || p.filesProcessed == p.filesTotal) {
        stdout.write('\r  ${p.filesProcessed}/${p.filesTotal} archivos ');
      }
    },
  );
  stdout.writeln();

  Directory(_dbDir).createSync(recursive: true);
  final store = SymbolStore.open(_dbPath);
  store.replaceAllSymbols(result);
  store.setMeta('project_path', Directory(projectPath).absolute.path);
  sw.stop();

  final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);
  stdout.writeln('✓ ${store.symbolCount} símbolos en ${secs}s  →  $_dbPath');
  store.close();
}

void _find(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Falta <nombre>');
    exitCode = 64;
    return;
  }
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final query = args.first;
  final store = SymbolStore.open(_dbPath);
  final results = store.findByName(query);

  if (results.isEmpty) {
    stdout.writeln('Sin resultados para "$query".');
  } else {
    stdout.writeln('${results.length} resultado(s) para "$query":\n');
    for (final s in results) {
      final sig = s.signature ?? s.name;
      stdout.writeln('  [${s.kind.name}] $sig');
      stdout.writeln('      ${s.filePath}:${s.line}');
      if (s.containerId != null) {
        stdout.writeln('      en ${s.containerId}');
      }
      stdout.writeln();
    }
  }
  store.close();
}

Future<void> _refs(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Falta <nombre>');
    exitCode = 64;
    return;
  }
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final query = args.first;

  final store = SymbolStore.open(_dbPath);
  final projectPath = store.getMeta('project_path');
  if (projectPath == null) {
    stderr.writeln('El índice no registró la ruta del proyecto. '
        'Re-indexa:  cih index <ruta>');
    store.close();
    exitCode = 69;
    return;
  }
  final defMatches = store.findByName(query, limit: 1);
  final defFile = defMatches.isNotEmpty ? defMatches.first.filePath : null;
  store.close();

  stdout.writeln('Buscando referencias a "$query" ...');
  final sw = Stopwatch()..start();
  final result = await DartReferences(projectPath).find(
    query,
    definitionFile: defFile,
    onProgress: (done, total) {
      if (done % 20 == 0 || done == total) {
        stdout.write('\r  resolviendo $done/$total candidatos ');
      }
    },
  );
  sw.stop();
  stdout.writeln();

  if (result.targetFile == null) {
    stdout.writeln('No se encontró la definición de "$query".');
    return;
  }

  final byFile = <String, List<Occurrence>>{};
  for (final r in result.references) {
    byFile.putIfAbsent(r.filePath, () => []).add(r);
  }

  final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);
  stdout.writeln('${result.references.length} referencia(s) en '
      '${byFile.length} archivo(s)  (${secs}s)  ·  def: ${result.targetFile}\n');

  final files = byFile.keys.toList()..sort();
  for (final f in files) {
    final occs = byFile[f]!..sort((a, b) => a.line.compareTo(b.line));
    final lines = occs.map((o) => o.line).join(', ');
    stdout.writeln('  $f');
    stdout.writeln('      líneas: $lines');
  }
}

void _stats() {
  if (!File(_dbPath).existsSync()) {
    stderr.writeln('No hay índice. Corre primero:  cih index <ruta>');
    exitCode = 69;
    return;
  }
  final store = SymbolStore.open(_dbPath);
  stdout.writeln('símbolos: ${store.symbolCount}\n');
  store.kindCounts().forEach((k, c) {
    stdout.writeln('  ${k.padRight(16)} $c');
  });
  store.close();
}
