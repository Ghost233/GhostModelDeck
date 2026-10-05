import 'dart:convert';
import 'dart:io';

import 'model_library.dart';

class LocalModelVariant {
  LocalModelVariant({
    required this.id,
    required this.label,
    required List<LibraryArtifact> artifacts,
  }) : artifacts = List.unmodifiable(artifacts);
  final String id;
  final String label;
  final List<LibraryArtifact> artifacts;
  List<String> get artifactIds =>
      artifacts.map((artifact) => artifact.id).toList();
  List<LibraryFile> get files => {
    for (final artifact in artifacts)
      for (final file in artifact.files) file.path: file,
  }.values.toList();
  int get sizeBytes => files.fold(0, (sum, file) => sum + file.sizeBytes);
}

class LocalModelPackage {
  LocalModelPackage({
    required this.directoryPath,
    required this.name,
    required List<LocalModelVariant> variants,
    required List<LibraryArtifact> details,
  }) : variants = List.unmodifiable(variants),
       details = List.unmodifiable(details);
  String get id => directoryPath;
  final String directoryPath;
  final String name;
  final List<LocalModelVariant> variants;
  final List<LibraryArtifact> details;
  List<String> get artifactIds =>
      variants.expand((variant) => variant.artifactIds).toSet().toList();
  int get sizeBytes => {
    for (final variant in variants)
      for (final file in variant.files) file.path: file,
  }.values.fold(0, (sum, file) => sum + file.sizeBytes);
}

class LocalModelPackages {
  LocalModelPackages({
    required List<LocalModelPackage> packages,
    required List<LibraryArtifact> residualArtifacts,
  }) : packages = List.unmodifiable(packages),
       residualArtifacts = List.unmodifiable(residualArtifacts);
  final List<LocalModelPackage> packages;
  final List<LibraryArtifact> residualArtifacts;
  static Future<LocalModelPackages> discover(
    Directory root,
    Iterable<LibraryArtifact> artifacts,
  ) async {
    final rootPath = await root.resolveSymbolicLinks();
    final source = artifacts.toList();
    final configCache = <String, bool>{};
    Future<bool> configured(String directory) async {
      if (configCache.containsKey(directory)) return configCache[directory]!;
      for (final name in ['config.json', 'manifest.json']) {
        final file = File('$directory/$name');
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.resolveSymbolicLinks() != file.path ||
            await file.length() > 1024 * 1024) {
          continue;
        }
        try {
          final value = jsonDecode(await file.readAsString());
          if (value is! Map) continue;
          final modelConfig =
              name == 'config.json' &&
              (value['model_type'] is String ||
                  value['architectures'] is List &&
                      (value['architectures'] as List).isNotEmpty);
          final format = value['format'];
          final artifacts = value['artifacts'];
          final manifest =
              name == 'manifest.json' &&
              value['schema_version'] is int &&
              (value['schema_version'] as int) > 0 &&
              value['model'] is String &&
              (value['model'] as String).trim().isNotEmpty &&
              format is Map &&
              format['name'] is String &&
              (format['name'] as String).trim().isNotEmpty &&
              (artifacts is Map && artifacts.isNotEmpty ||
                  artifacts is List && artifacts.isNotEmpty);
          // This proves a model directory declaration, not support for its binary format.
          if (modelConfig || manifest) return configCache[directory] = true;
        } on FormatException {
          continue;
        }
      }
      return configCache[directory] = false;
    }

    Future<String?> configuredParent(String path) async {
      var directory = File(path).parent;
      while (directory.path == rootPath ||
          directory.path.startsWith('$rootPath/')) {
        if (await configured(directory.path)) return directory.path;
        if (directory.path == rootPath) break;
        directory = directory.parent;
      }
      return null;
    }

    String folder(String path) {
      final relative = path.substring(rootPath.length + 1).split('/');
      if (relative.length >= 3) {
        return '$rootPath/${relative[0]}/${relative[1]}';
      }
      if (relative.length == 2) return '$rootPath/${relative[0]}';
      return rootPath;
    }

    bool modelWeight(String path) =>
        RegExp(
          r'\.(bin|pt|pth|onnx|ggml|weights|model)$',
          caseSensitive: false,
        ).hasMatch(path) &&
        !RegExp(
          r'(^|/)(banner|\.DS_Store)(\.|$)',
          caseSensitive: false,
        ).hasMatch(path);
    bool transfer(String path) =>
        path.endsWith('.part') ||
        path.split('/').last.startsWith('downloading_');
    final groups = <String, List<LibraryArtifact>>{};
    final consumed = <String>{};
    for (final artifact in source) {
      if (artifact.files.isEmpty ||
          artifact.files.any(
            (file) =>
                !file.path.startsWith('$rootPath/') ||
                file.path.startsWith('$rootPath/.ghostmodeldeck/') ||
                transfer(file.path),
          )) {
        continue;
      }
      final path = artifact.files.first.path;
      final recognized = ['GGUF', 'Safetensors'].contains(artifact.format);
      final configuration = await configuredParent(path);
      if (!recognized &&
          (configuration == null ||
              !artifact.files.any((file) => modelWeight(file.path)))) {
        continue;
      }
      final directory = configuration ?? folder(path);
      groups.putIfAbsent(directory, () => []).add(artifact);
      consumed.add(artifact.id);
    }
    final packages = <LocalModelPackage>[];
    for (final entry in groups.entries) {
      final variants = <LocalModelVariant>[];
      final unknown = <LibraryArtifact>[];
      final projectors = entry.value
          .where(
            (artifact) =>
                artifact.format == 'GGUF' &&
                artifact.architecture == 'clip' &&
                artifact.files.first.path
                    .split('/')
                    .last
                    .toLowerCase()
                    .startsWith('mmproj'),
          )
          .toList();
      var fallbackVariant = 1;
      final ordered = entry.value.toList()
        ..sort((a, b) => a.files.first.path.compareTo(b.files.first.path));
      for (final artifact in ordered) {
        if (projectors.contains(artifact)) continue;
        if (!['GGUF', 'Safetensors'].contains(artifact.format)) {
          unknown.add(artifact);
          continue;
        }
        final name = artifact.files.first.path
            .split('/')
            .last
            .replaceFirst(
              RegExp(r'-\d{5}-of-\d{5}\.gguf$', caseSensitive: false),
              '.gguf',
            );
        // Filename token is a display label; artifact format/status remain authoritative.
        final quant = RegExp(
          r'(?:^|[-_.])((?:IQ[1-4]|Q[1-8])(?:_[a-z0-9]+)+|BF16|F16|F32|MXFP4|NVFP4)(?=$|[-.])',
          caseSensitive: false,
        ).firstMatch(name)?.group(1)?.toUpperCase();
        variants.add(
          LocalModelVariant(
            id: artifact.id,
            label: '${artifact.format} · ${quant ?? '变体 ${fallbackVariant++}'}',
            artifacts: [
              artifact,
              if (projectors.length == 1) projectors.single,
            ],
          ),
        );
      }
      if (unknown.isNotEmpty) {
        final ids = unknown.map((artifact) => artifact.id).toList()..sort();
        variants.add(
          LocalModelVariant(
            id: ids.join(':'),
            label: '未支持 · 无法确认完整包',
            artifacts: unknown,
          ),
        );
      }
      variants.sort((a, b) => a.label.compareTo(b.label));
      if (variants.isEmpty) {
        consumed.removeAll(entry.value.map((artifact) => artifact.id));
        continue;
      }
      final repoIds = entry.value
          .map((artifact) => artifact.repoId)
          .whereType<String>()
          .toSet();
      final label = repoIds.length == 1
          ? repoIds.single
          : entry.key == rootPath
          ? root.uri.pathSegments.where((segment) => segment.isNotEmpty).last
          : entry.key.substring(rootPath.length + 1);
      packages.add(
        LocalModelPackage(
          directoryPath: entry.key,
          name: label,
          variants: variants,
          details: source
              .where(
                (artifact) => artifact.files.any(
                  (file) => file.path.startsWith('${entry.key}/'),
                ),
              )
              .toList(),
        ),
      );
    }
    packages.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return LocalModelPackages(
      packages: packages,
      residualArtifacts: source
          .where((artifact) => !consumed.contains(artifact.id))
          .toList(),
    );
  }
}
