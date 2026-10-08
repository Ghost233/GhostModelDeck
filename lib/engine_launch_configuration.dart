class EngineLaunchConfiguration {
  EngineLaunchConfiguration({Map<String, String> formValues = initialValues})
    : formValues = Map.unmodifiable(formValues);

  static const formLabels = {
    '--ctx-size': '上下文大小',
    '--batch-size': '批量大小',
    '--ubatch-size': '微批量大小',
    '--parallel': '并行数量',
    '--n-gpu-layers': 'GPU 层数',
    '--device': '设备',
  };
  static const initialValues = {
    '--ctx-size': '4096',
    '--batch-size': '4096',
    '--ubatch-size': '4096',
    '--parallel': '1',
    '--n-gpu-layers': '99',
    '--device': 'MTL0',
  };

  final Map<String, String> formValues;

  EngineLaunchCommand command({
    required String executable,
    required String modelPath,
    String? alias,
    int? port,
  }) => EngineLaunchCommand(
    executable: executable,
    provisional: alias == null || port == null,
    arguments: [
      '--model',
      modelPath,
      '--alias',
      alias ?? '<启动时分配的模型标识>',
      '--host',
      '127.0.0.1',
      '--port',
      port?.toString() ?? '<启动时分配的端口>',
      for (final name in formLabels.keys)
        if (formValues[name]?.isNotEmpty ?? false) ...[name, formValues[name]!],
    ],
  );

  factory EngineLaunchConfiguration.fromJson(Object? value) {
    if (value is! Map || value['formValues'] is! Map) {
      throw const FormatException('引擎启动配置无效');
    }
    final values = <String, String>{};
    for (final entry in (value['formValues'] as Map).entries) {
      if (entry.key is! String ||
          !formLabels.containsKey(entry.key) ||
          entry.value is! String) {
        throw const FormatException('引擎启动表单无效');
      }
      values[entry.key as String] = entry.value as String;
    }
    return EngineLaunchConfiguration(formValues: values);
  }

  Map<String, Object> toJson() => {'formValues': formValues};
}

class EngineLaunchCommand {
  EngineLaunchCommand({
    required this.executable,
    required List<String> arguments,
    this.provisional = false,
  }) : arguments = List.unmodifiable(arguments);

  final String executable;
  final List<String> arguments;
  final bool provisional;

  /// Display and copying only. Execution receives the original argument array.
  String get displayText => [executable, ...arguments].map(_quote).join(' ');

  static final _unquoted = RegExp(r'^[a-zA-Z0-9_@%+=:,./-]+$');
  static String _quote(String value) => _unquoted.hasMatch(value)
      ? value
      : "'${value.replaceAll("'", "'\"'\"'")}'";
}
