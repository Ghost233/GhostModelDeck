import 'hf_model_browser.dart';

enum PackageResolution { resolved, indexed, incomplete, ambiguous, unsupported }

/// A model family in one HF folder, with immutable revision-bound variants.
class ModelPackage {
  ModelPackage({
    required this.id,
    required this.label,
    required this.directory,
    required this.repository,
    required List<ModelVariant> variants,
  }) : variants = List.unmodifiable(variants);

  final String id;
  final String label;
  final String directory;
  final HfRepositoryFiles repository;
  final List<ModelVariant> variants;

  static List<ModelPackage> discover(HfRepositoryFiles repository) {
    final families = <String, Map<String, List<HfModelFile>>>{};
    final labels = <String, String>{};
    final directories = <String, String>{};
    for (final file in repository.files) {
      if (!file.path.toLowerCase().endsWith('.gguf')) continue;
      if (_isProjector(file.path)) continue;
      final slash = file.path.lastIndexOf('/');
      final directory = slash < 0 ? '' : file.path.substring(0, slash);
      final name = file.path.substring(slash + 1);
      final split = RegExp(
        r'^(.+)-\d{5}-of-\d{5}\.gguf$',
        caseSensitive: false,
      ).firstMatch(name);
      final stem = split?.group(1) ?? name.substring(0, name.length - 5);
      final quant = _quantization(stem);
      final family = quant == null ? stem : stem.substring(0, quant.start);
      final label = family.isEmpty
          ? repository.summary.id.split('/').last
          : family;
      final key = '$directory:${label.toLowerCase()}';
      labels[key] = label;
      directories[key] = directory;
      (families[key] ??= {}).putIfAbsent(stem, () => []).add(file);
    }
    final packages = <ModelPackage>[];
    for (final family in families.entries) {
      final variants = <ModelVariant>[];
      for (final entry in family.value.entries) {
        final seeds = entry.value..sort((a, b) => a.path.compareTo(b.path));
        final quant = _quantization(entry.key)?.group(1)?.toUpperCase();
        List<HfModelFile> files;
        PackageResolution resolution;
        String? reason;
        try {
          files = resolveAssetFiles(repository.files, [seeds.first]);
          resolution = PackageResolution.resolved;
        } on FormatException catch (error) {
          files = seeds;
          resolution =
              _projectors(repository.files, directories[family.key]!).length > 1
              ? PackageResolution.ambiguous
              : PackageResolution.incomplete;
          reason = error.message;
        }
        variants.add(
          ModelVariant(
            id: 'GGUF:${entry.key}',
            label: quant ?? entry.key,
            format: 'GGUF',
            quantization: quant,
            files: files,
            resolution: resolution,
            unavailableReason: reason,
          ),
        );
      }
      variants.sort((a, b) => a.label.compareTo(b.label));
      packages.add(
        ModelPackage(
          id: '${repository.summary.id}:${family.key}',
          label: labels[family.key]!,
          directory: directories[family.key]!,
          repository: repository,
          variants: variants,
        ),
      );
    }
    final native = <String, List<HfModelFile>>{};
    for (final file in repository.files) {
      final name = file.path.split('/').last;
      if (_isHeadFile(name)) continue;
      if (name.endsWith('.safetensors') ||
          name.endsWith('.safetensors.index.json') ||
          name.endsWith('.bin.index.json') ||
          RegExp(r'^(model|pytorch_model)(-\d{5}-of-\d{5})?\.bin$')
              .hasMatch(name)) {
        final slash = file.path.lastIndexOf('/');
        final directory = slash < 0 ? '' : file.path.substring(0, slash);
        (native[directory] ??= []).add(file);
      }
    }
    for (final entry in native.entries) {
      final variants = _nativeVariants(repository, entry.key, entry.value);
      final compatible = packages
          .where((package) => package.directory == entry.key)
          .toList();
      if (compatible.length == 1) {
        final previous = compatible.single;
        packages[packages.indexOf(previous)] = ModelPackage(
          id: previous.id,
          label: previous.label,
          directory: previous.directory,
          repository: repository,
          variants: [...previous.variants, ...variants],
        );
      } else {
        packages.add(
          ModelPackage(
            id: '${repository.summary.id}:${entry.key}:native',
            label: entry.key.isEmpty
                ? repository.summary.id.split('/').last
                : entry.key.split('/').last,
            directory: entry.key,
            repository: repository,
            variants: variants,
          ),
        );
      }
    }
    packages.sort((a, b) => a.label.compareTo(b.label));
    return List.unmodifiable(packages);
  }

  ModelPackageSelection selectVariant(String variantId) {
    final matches = variants.where((variant) => variant.id == variantId);
    if (matches.length != 1) throw ArgumentError.value(variantId, 'variantId');
    return ModelPackageSelection(this, matches.single);
  }
}

RegExpMatch? _quantization(String stem) => RegExp(
  r'(?:^|[-_.])((?:IQ|TQ|Q)\d[A-Z0-9_]*|BF16|F16|F32)$',
  caseSensitive: false,
).firstMatch(stem);

List<ModelVariant> _nativeVariants(
  HfRepositoryFiles repository,
  String directory,
  List<HfModelFile> candidates,
) {
  final indexes = candidates
      .where((file) => isWeightIndexFile(file.path))
      .toList();
  final groups = <String, List<HfModelFile>>{};
  if (indexes.isNotEmpty) {
    for (final index in indexes) {
      groups[index.path] = [index];
    }
  } else {
    for (final file in candidates) {
      final stem = file.path.replaceFirst(
        RegExp(r'-\d{5}-of-\d{5}(?=\.(safetensors|bin)$)'),
        '',
      );
      (groups[stem] ??= []).add(file);
    }
  }
  final ambiguous =
      indexes.isEmpty &&
      groups.length > 1 &&
      groups.keys.any((path) => _quantization(_nativeStem(path)) == null);
  final variants = <ModelVariant>[];
  for (final group in groups.entries) {
    final first = (group.value..sort((a, b) => a.path.compareTo(b.path))).first;
    final format = first.path.contains('.safetensors')
        ? 'Safetensors'
        : 'PyTorch';
    final quant = _quantization(_nativeStem(group.key))
        ?.group(1)
        ?.toUpperCase();
    final indexed = indexes.isNotEmpty;
    List<HfModelFile> files;
    String? reason;
    var resolution = indexed
        ? PackageResolution.indexed
        : PackageResolution.resolved;
    try {
      files = resolveAssetFiles(repository.files, [first]);
    } on FormatException catch (error) {
      files = group.value;
      resolution = PackageResolution.incomplete;
      reason = error.message;
    }
    final prefix = directory.isEmpty ? '' : '$directory/';
    final hasConfig = files.any(
      (file) =>
          file.path == '${prefix}config.json' || file.path == 'config.json',
    );
    final hasInput = files.any(
      (file) => _inputFiles.contains(file.path.split('/').last),
    );
    if (ambiguous) {
      resolution = PackageResolution.ambiguous;
      reason = '同目录多个未索引权重，无法确认完整模型包';
    } else if (!hasConfig || !hasInput) {
      resolution = PackageResolution.incomplete;
      reason = !hasConfig ? '模型包缺少 config.json' : '模型包缺少分词器或处理器文件';
    }
    variants.add(
      ModelVariant(
        id: '$format:${group.key}',
        label: quant ?? '默认',
        format: format,
        quantization: quant,
        files: files,
        resolution: resolution,
        unavailableReason: reason,
      ),
    );
  }
  variants.sort((a, b) => a.id.compareTo(b.id));
  return variants;
}

String _nativeStem(String path) => path
    .split('/')
    .last
    .replaceFirst(RegExp(r'\.(safetensors|bin)(\.index\.json)?$'), '');

bool _isHeadFile(String name) => RegExp(
  r'^(decision_head|head|classifier)\.(safetensors|bin|pt|pth|npz|onnx)$',
).hasMatch(name);

const _inputFiles = {
  'tokenizer.json',
  'tokenizer.model',
  'vocab.txt',
  'vocab.json',
  'processor_config.json',
  'preprocessor_config.json',
};

class ModelVariant {
  ModelVariant({
    required this.id,
    required this.label,
    required this.format,
    this.quantization,
    required List<HfModelFile> files,
    this.resolution = PackageResolution.resolved,
    this.unavailableReason,
  }) : files = List.unmodifiable(files);

  final String id;
  final String label;
  final String format;
  final String? quantization;
  final List<HfModelFile> files;
  final PackageResolution resolution;
  final String? unavailableReason;

  bool get canDownload =>
      resolution == PackageResolution.resolved ||
      resolution == PackageResolution.indexed;

  int? get sizeBytes {
    if (!canDownload ||
        resolution == PackageResolution.indexed ||
        files.any((file) => file.sizeBytes == null)) {
      return null;
    }
    return files.fold<int>(0, (sum, file) => sum + file.sizeBytes!);
  }
}

class ModelPackageSelection {
  const ModelPackageSelection(this.modelPackage, this.variant);
  final ModelPackage modelPackage;
  final ModelVariant variant;
}

List<HfModelFile> resolveAssetFiles(
  List<HfModelFile> available,
  List<HfModelFile> selected, {
  bool requiredSidecars = false,
}) {
  final paths = selected.map((file) => file.path).toSet();
  final needsSidecars =
      requiredSidecars ||
      selected.any(
        (file) =>
            RegExp(r'\.(gguf|safetensors|bin|pt|pth|onnx|npz)$')
                .hasMatch(file.path) ||
            isWeightIndexFile(file.path),
      );
  final directories = <String>{''};
  final componentDirectories = <String>{};
  for (final file in selected) {
    validateAssetPath(file.path);
    final slash = file.path.lastIndexOf('/');
    final directory = slash < 0 ? '' : file.path.substring(0, slash + 1);
    directories.add(directory);
    if (RegExp(r'\.(safetensors|bin)(?:\.index\.json)?$').hasMatch(file.path) &&
        available.any(
          (item) => item.path == '${directory}rl_agent_config.json',
        )) {
      paths.add('${directory}rl_agent_config.json');
      componentDirectories.addAll([
        '${directory}encoder/',
        '${directory}tokenizer/',
      ]);
    }
    final name = file.path.substring(slash + 1);
    final split = RegExp(r'^(.+)-(\d{5})-of-(\d{5})\.(gguf|safetensors|bin)$')
        .firstMatch(name);
    if (split != null) {
      final count = int.parse(split.group(3)!);
      for (var i = 1; i <= count; i++) {
        final path =
            '$directory${split.group(1)}-'
            '${i.toString().padLeft(5, '0')}-of-${split.group(3)}.'
            '${split.group(4)}';
        if (!available.any((item) => item.path == path)) {
          throw const FormatException('此版本缺少必要权重分片');
        }
        paths.add(path);
      }
      final index = '$directory${split.group(1)}.${split.group(4)}.index.json';
      if (available.any((item) => item.path == index)) paths.add(index);
    }
  }
  for (final file in available) {
    final slash = file.path.lastIndexOf('/');
    final directory = slash < 0 ? '' : file.path.substring(0, slash + 1);
    final name = file.path.substring(slash + 1);
    if (needsSidecars &&
        (directories.contains(directory) ||
            componentDirectories.contains(directory)) &&
        (_sidecarNames.contains(name) ||
            RegExp(
              r'^(decision_head|head|classifier)\.(safetensors|bin|pt|pth|npz|onnx)$',
            ).hasMatch(name))) {
      paths.add(file.path);
    }
  }
  if (selected.any(
    (file) =>
        file.path.toLowerCase().endsWith('.gguf') && !_isProjector(file.path),
  )) {
    final projectors = available.where((file) {
      final slash = file.path.lastIndexOf('/');
      final directory = slash < 0 ? '' : file.path.substring(0, slash + 1);
      return directories.contains(directory) && _isProjector(file.path);
    }).toList();
    if (projectors.length > 1) {
      throw const FormatException('模型包有多个 projector，无法确认关联');
    }
    if (projectors.isNotEmpty) paths.add(projectors.single.path);
  }
  return available.where((file) => paths.contains(file.path)).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

bool _isProjector(String path) =>
    path.toLowerCase().endsWith('.gguf') &&
    RegExp(
      r'^mmproj(?:[-_.]|$)',
      caseSensitive: false,
    ).hasMatch(path.split('/').last);

List<HfModelFile> _projectors(List<HfModelFile> files, String directory) =>
    files.where((file) {
      final slash = file.path.lastIndexOf('/');
      final parent = slash < 0 ? '' : file.path.substring(0, slash);
      return (parent.isEmpty || parent == directory) && _isProjector(file.path);
    }).toList();

bool isWeightIndexFile(String path) =>
    RegExp(r'\.(gguf|safetensors|bin)\.index\.json$').hasMatch(path);

const _sidecarNames = {
  'config.json',
  'tokenizer.json',
  'tokenizer_config.json',
  'special_tokens_map.json',
  'generation_config.json',
  'vocab.json',
  'vocab.txt',
  'merges.txt',
  'tokenizer.model',
  'added_tokens.json',
  'adapter_config.json',
  'chat_template.jinja',
  'preprocessor_config.json',
  'processor_config.json',
};

void validateAssetPath(String path) {
  if (path.isEmpty ||
      path.contains('\\') ||
      path.contains('\u0000') ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('无效文件路径');
  }
}
