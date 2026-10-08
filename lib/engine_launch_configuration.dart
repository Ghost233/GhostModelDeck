import 'launch_argument_text.dart';
import 'engine_parameter_recognition.dart';

export 'launch_argument_text.dart' show LaunchArgumentTextException;

class EngineLaunchConfiguration {
  EngineLaunchConfiguration({
    Map<String, String> formValues = initialValues,
    this.argumentText = '',
  }) : formValues = Map.unmodifiable(formValues);

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
  final String argumentText;
  void validateArgumentText() => parseLaunchArgumentText(argumentText);

  EngineLaunchCommand command({
    required String executable,
    required String modelPath,
    String? alias,
    int? port,
    EngineParameterRecognition? recognition,
  }) {
    final rules = recognition ?? EngineParameterRecognition.builtIn();
    final tokens = parseLaunchArgumentText(argumentText);
    final managed = {
      '--model': modelPath,
      '--alias': alias ?? '<启动时分配的模型标识>',
      '--host': '127.0.0.1',
      '--port': port?.toString() ?? '<启动时分配的端口>',
    };
    final arguments = <String>[];
    final managedNames = <String>{};
    final overridden = <String>{};
    final notices = <String>{...rules.notices};
    for (var index = 0; index < tokens.length; index++) {
      final argument = tokens[index].value;
      final name = argument.split('=').first;
      final controlled = rules.canonicalName(name);
      if (managed.containsKey(controlled)) {
        managedNames.add(controlled);
        if (!argument.contains('=') &&
            index + 1 < tokens.length &&
            _isValue(tokens[index + 1])) {
          index++;
        }
        continue;
      }
      arguments.add(argument);
      final canonical = rules.canonicalName(name);
      final description = rules.descriptionFor(name);
      if (rules.status == EngineHelpStatus.available ||
          rules.status == EngineHelpStatus.partial) {
        if (description != null && description.description.isNotEmpty) {
          notices.add('$name：${description.description}');
        }
      }
      if (!formLabels.containsKey(canonical)) {
        if (_looksLikeOption(name) && !rules.recognizes(name)) {
          notices.add('未知参数 $name，保留并交由引擎判断。');
        } else if (index == 0 && !_looksLikeOption(name)) {
          notices.add('文本仅填写参数；可执行文件由软件提供。');
        }
        if (description != null && description.valueHint.isNotEmpty) {
          var remaining = description.valueHint.split(RegExp(r'\s+')).length;
          if (argument.contains('=')) remaining--;
          while (remaining > 0 &&
              index + 1 < tokens.length &&
              _isValue(tokens[index + 1])) {
            arguments.add(tokens[++index].value);
            remaining--;
          }
          if (remaining > 0) {
            notices.add('$name 缺少值，仍保留并交由引擎判断。');
          }
        }
        continue;
      }
      overridden.add(canonical);
      String? value;
      final separator = argument.indexOf('=');
      if (separator >= 0) {
        value = argument.substring(separator + 1);
      } else if (index + 1 < tokens.length && _isValue(tokens[index + 1])) {
        value = tokens[++index].value;
        arguments.add(value);
      }
      final notice = _valueNotice(canonical, value);
      if (notice != null) notices.add(notice);
    }
    for (final entry in formValues.entries) {
      if (overridden.contains(entry.key) || entry.value.isEmpty) continue;
      final notice = _valueNotice(entry.key, entry.value);
      if (notice != null) notices.add(notice);
    }
    return EngineLaunchCommand(
      executable: executable,
      provisional: alias == null || port == null,
      overriddenForm: overridden,
      notices: [
        for (final name in managedNames) '$name 由软件管理，实际采用 ${managed[name]}',
        ...notices,
      ],
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
          if (!overridden.contains(name) &&
              (formValues[name]?.isNotEmpty ?? false)) ...[
            name,
            formValues[name]!,
          ],
        ...arguments,
      ],
    );
  }

  static bool _looksLikeOption(String value) =>
      value.startsWith('-') && !RegExp(r'^-\d').hasMatch(value);

  static bool _isValue(LaunchArgumentToken token) =>
      token.hasLiteralPrefix || !_looksLikeOption(token.value);

  static String? _valueNotice(String name, String? value) {
    if (value == null || value.isEmpty) {
      return '$name 缺少值，仍保留并交由引擎判断。';
    }
    if (name != '--device' &&
        int.tryParse(value) == null &&
        !(name == '--n-gpu-layers' && ['auto', 'all'].contains(value))) {
      return '$name 通常需要整数值，仍保留并交由引擎判断。';
    }
    return null;
  }

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
    final text = value.containsKey('argumentText') ? value['argumentText'] : '';
    if (text is! String) throw const FormatException('引擎启动文本无效');
    return EngineLaunchConfiguration(formValues: values, argumentText: text);
  }

  Map<String, Object> toJson() => {
    'formValues': formValues,
    'argumentText': argumentText,
  };
}

class EngineLaunchCommand {
  EngineLaunchCommand({
    required this.executable,
    required List<String> arguments,
    this.provisional = false,
    Set<String> overriddenForm = const {},
    List<String> notices = const [],
  }) : arguments = List.unmodifiable(arguments),
       overriddenForm = Set.unmodifiable(overriddenForm),
       notices = List.unmodifiable(notices);

  final String executable;
  final List<String> arguments;
  final bool provisional;
  final Set<String> overriddenForm;
  final List<String> notices;

  /// Display and copying only. Execution receives the original argument array.
  String get displayText => [executable, ...arguments].map(_quote).join(' ');

  static final _unquoted = RegExp(r'^[a-zA-Z0-9_@%+=:,./-]+$');
  static String _quote(String value) => _unquoted.hasMatch(value)
      ? value
      : "'${value.replaceAll("'", "'\"'\"'")}'";
}
