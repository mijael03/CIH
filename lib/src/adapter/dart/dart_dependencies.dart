import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// Capa arquitectónica de un archivo, inferida de su ruta. Tolera las variantes
/// que aparecen en proyectos reales (es/en, typos): `aplication`,
/// `infraestructure`/`infrastructure`.
enum Layer { application, domain, infrastructure, presentation, other }

Layer layerOf(String relPath) {
  for (final s in p.split(relPath)) {
    switch (s.toLowerCase()) {
      case 'application':
      case 'aplication':
        return Layer.application;
      case 'domain':
        return Layer.domain;
      case 'infraestructure':
      case 'infrastructure':
        return Layer.infrastructure;
      case 'presentation':
        return Layer.presentation;
    }
  }
  return Layer.other;
}

/// Módulo de negocio de un archivo: `modules/<dominio>`, `interface`, etc.
String moduleOf(String relPath) {
  final segs = p.split(relPath);
  final m = segs.indexOf('modules');
  if (m >= 0 && m + 1 < segs.length) return 'modules/${segs[m + 1]}';
  final i = segs.indexOf('interface');
  if (i >= 0) return 'interface';
  return segs.length > 1 ? segs[0] == 'lib' ? 'lib' : segs[0] : 'lib';
}

class DepEdge {
  DepEdge(this.toPath, this.line);
  final String toPath; // ruta relativa del archivo importado
  final int line;
}

class DepNode {
  DepNode(this.path, this.module, this.layer);
  final String path;
  final String module;
  final Layer layer;
  final List<DepEdge> imports = [];
}

/// Una dependencia que cruza capas en dirección no-canónica de Clean
/// Architecture. **Informativa**: puede ser intencional; nunca bloquea nada.
class LayerViolation {
  LayerViolation(
      this.fromPath, this.fromLayer, this.toPath, this.toLayer, this.line);
  final String fromPath;
  final Layer fromLayer;
  final String toPath;
  final Layer toLayer;
  final int line;
}

class DependencyGraph {
  DependencyGraph(this.nodes, this.violations);
  final Map<String, DepNode> nodes;
  final List<LayerViolation> violations;

  /// Módulos de los que depende [module] (vía imports).
  Set<String> moduleDeps(String module) {
    final out = <String>{};
    for (final n in nodes.values) {
      if (n.module != module) continue;
      for (final e in n.imports) {
        final t = nodes[e.toPath];
        if (t != null && t.module != module) out.add(t.module);
      }
    }
    return out;
  }

  /// Módulos que dependen de [module].
  Set<String> moduleDependents(String module) {
    final out = <String>{};
    for (final n in nodes.values) {
      if (n.module == module) continue;
      for (final e in n.imports) {
        final t = nodes[e.toPath];
        if (t != null && t.module == module) {
          out.add(n.module);
          break;
        }
      }
    }
    return out;
  }
}

/// Motor de dependencias para Dart (parse-only de los `import`).
class DartDependencies {
  DartDependencies(this.projectPath, this.packageName);
  final String projectPath;
  final String packageName;

  /// Lee `name:` del pubspec del proyecto (para resolver `package:<name>/...`).
  factory DartDependencies.forProject(String projectPath) {
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
    return DartDependencies(projectPath, name);
  }

  DependencyGraph analyze({void Function(int done, int total)? onProgress}) {
    final libDir = Directory(p.join(projectPath, 'lib'));
    final files = libDir.existsSync()
        ? (libDir
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path)
            .where((x) => x.endsWith('.dart'))
            .toList()
          ..sort())
        : <String>[];

    final nodes = <String, DepNode>{};
    for (final abs in files) {
      final rel = p.relative(abs, from: projectPath);
      nodes[rel] = DepNode(rel, moduleOf(rel), layerOf(rel));
    }

    var done = 0;
    for (final abs in files) {
      final rel = p.relative(abs, from: projectPath);
      try {
        final result = parseFile(
          path: abs,
          featureSet: FeatureSet.latestLanguageVersion(),
          throwIfDiagnostics: false,
        );
        for (final d in result.unit.directives) {
          if (d is! ImportDirective) continue;
          final uri = d.uri.stringValue;
          if (uri == null) continue;
          final toRel = _resolve(uri, abs);
          if (toRel == null || !nodes.containsKey(toRel)) continue;
          final line = result.lineInfo.getLocation(d.offset).lineNumber;
          nodes[rel]!.imports.add(DepEdge(toRel, line));
        }
      } catch (_) {
        // archivo no parseable; lo saltamos
      }
      done++;
      onProgress?.call(done, files.length);
    }

    final violations = <LayerViolation>[];
    for (final n in nodes.values) {
      for (final e in n.imports) {
        final t = nodes[e.toPath]!;
        if (_violates(n.layer, t.layer)) {
          violations.add(
              LayerViolation(n.path, n.layer, t.path, t.layer, e.line));
        }
      }
    }
    return DependencyGraph(nodes, violations);
  }

  /// Resuelve el URI de un import a una ruta relativa del proyecto, o null si
  /// es externo (dart:, otro package).
  String? _resolve(String uri, String fromAbs) {
    String abs;
    if (packageName.isNotEmpty && uri.startsWith('package:$packageName/')) {
      abs = p.join(projectPath, 'lib', uri.substring('package:$packageName/'.length));
    } else if (uri.startsWith('package:') || uri.startsWith('dart:')) {
      return null;
    } else {
      abs = p.normalize(p.join(p.dirname(fromAbs), uri));
    }
    if (!abs.endsWith('.dart')) return null;
    return p.relative(abs, from: projectPath);
  }

  /// Dirección de dependencia NO permitida en Clean Architecture.
  bool _violates(Layer from, Layer to) {
    if (from == Layer.other || to == Layer.other || from == to) return false;
    switch (from) {
      case Layer.domain:
        return to != Layer.domain; // el dominio no debe depender de nadie
      case Layer.application:
        return !(to == Layer.application || to == Layer.domain);
      case Layer.infrastructure:
        return !(to == Layer.infrastructure || to == Layer.domain);
      case Layer.presentation:
        return !(to == Layer.presentation ||
            to == Layer.application ||
            to == Layer.domain);
      case Layer.other:
        return false;
    }
  }
}
