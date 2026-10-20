import 'dart:io';

class DrafterConfiguration {
  const DrafterConfiguration({required this.enabled, this.path, this.mode});
  final bool enabled;
  final String? path;
  final String? mode;
  bool get usesEmbeddedTarget => mode == 'draft-mtp' && path == null;

  static const modes = {
    'draft-simple': '普通 draft',
    'draft-eagle3': 'EAGLE3',
    'draft-mtp': 'MTP',
    'draft-dflash': 'DFlash',
    'draft-dspark': 'DSpark',
  };

  factory DrafterConfiguration.fromJson(Object? value) {
    if (value is! Map || value['enabled'] is! bool) {
      throw const FormatException('草稿模型配置无效');
    }
    final path = value['path'] ?? value['directory'];
    final mode = value['mode'];
    if (path != null && (path is! String || !path.startsWith('/')) ||
        mode != null && (mode is! String || !modes.containsKey(mode))) {
      throw const FormatException('草稿模型路径或模式无效');
    }
    return DrafterConfiguration(
      enabled: value['enabled'] as bool,
      path: path as String?,
      mode: mode as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'path': path,
    if (mode != null) 'mode': mode,
  };
}

enum DrafterStage {
  checking,
  filesReady,
  prepared,
  running,
  unverified,
  disabled,
  failed,
}

class DrafterCheck {
  const DrafterCheck({DrafterStage? stage, this.type, this.source, this.error})
    : stage =
          stage ??
          (error == null ? DrafterStage.checking : DrafterStage.failed);
  final DrafterStage stage;
  final String? type;
  final String? source;
  final String? error;
  bool? get active => switch (stage) {
    DrafterStage.running => true,
    DrafterStage.disabled => false,
    _ => null,
  };
  String get label => switch (stage) {
    DrafterStage.checking => '检查中',
    DrafterStage.filesReady => '文件齐全，启动时验证原生兼容性',
    DrafterStage.prepared => '准备检查完成，启动时加载',
    DrafterStage.running => '原生已启用',
    DrafterStage.unverified => '已请求，未核验原生启用',
    DrafterStage.disabled => '已关闭，不加载草稿资源',
    DrafterStage.failed => '检查失败',
  };
}

/// Reserves the selected local files; native loading validates their format and compatibility.
Future<List<String>> checkLlamaDrafterFiles(
  DrafterConfiguration? selected,
) async {
  if (selected?.enabled != true) return const [];
  if (!DrafterConfiguration.modes.containsKey(selected!.mode)) {
    throw const FormatException('已启用草稿模型，请明确选择推测模式');
  }
  if (selected.usesEmbeddedTarget) return const [];
  final requested = selected.path;
  if (requested == null || !requested.startsWith('/')) {
    throw const FormatException('已启用草稿模型，请选择本地 GGUF 文件');
  }
  final String canonical;
  try {
    canonical = await File(requested).resolveSymbolicLinks();
  } on FileSystemException {
    throw FormatException('草稿模型文件不存在：$requested');
  }
  final name = canonical.split(Platform.pathSeparator).last;
  final split = RegExp(r'^(.*)-(\d{5})-of-(\d{5})\.gguf$').firstMatch(name);
  final paths = <String>[];
  if (split != null) {
    final number = int.parse(split[2]!);
    final count = int.parse(split[3]!);
    if (number != 1 || count < 1) {
      throw FormatException('分片草稿模型请选择首片（00001）：$requested');
    }
    for (var index = 1; index <= count; index++) {
      paths.add(
        '${File(canonical).parent.path}/${split[1]}-'
        '${index.toString().padLeft(5, '0')}-of-${split[3]}.gguf',
      );
    }
  } else {
    paths.add(canonical);
  }
  final result = <String>[];
  for (final path in paths) {
    final file = File(path);
    if (!await file.exists()) throw FormatException('草稿模型缺少分片：$path');
    result.add(await file.resolveSymbolicLinks());
  }
  return List.unmodifiable(result);
}
