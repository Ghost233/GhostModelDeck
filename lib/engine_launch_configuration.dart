import 'launch_argument_text.dart';
import 'engine_runtime.dart';
import 'engine_parameter_recognition.dart';

export 'launch_argument_text.dart' show LaunchArgumentTextException;

class EngineLaunchConfiguration {
  EngineLaunchConfiguration({
    Map<String, String>? formValues,
    this.family = EngineFamily.llamaCpp,
    this.argumentText = '',
  }) : formValues = Map.unmodifiable(
         formValues ??
             (family == EngineFamily.llamaCpp
                 ? initialValues
                 : const <String, String>{}),
       );

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

  static const omlxFormLabels = {
    '--max-concurrent-requests': '最大并发请求数',
    '--memory-guard': '内存保护级别',
    '--hot-cache-max-size': '内存缓存上限',
  };
  static const splashFormLabels = {
    '--max-context': '最大上下文',
    '--max-memory': '最大内存',
    '--kv-format': 'KV 缓存格式',
    '--queue-size': '请求队列大小',
  };
  static Map<String, String> labelsFor(EngineFamily family) => switch (family) {
    EngineFamily.llamaCpp => formLabels,
    EngineFamily.omlx => omlxFormLabels,
    EngineFamily.splash => splashFormLabels,
  };

  final EngineFamily family;
  final Map<String, String> formValues;
  final String argumentText;
  void validateArgumentText() => parseLaunchArgumentText(argumentText);

  EngineLaunchCommand command({
    required String executable,
    required String modelPath,
    String? alias,
    int? port,
    EngineParameterRecognition? recognition,
    List<String> executableArguments = const [],
    Map<String, String> managedArguments = const {},
  }) {
    final rules =
        recognition ?? EngineParameterRecognition.builtIn(family: family);
    final labels = labelsFor(family);
    final configurationOnly = family == EngineFamily.omlx;
    final tokens = parseLaunchArgumentText(argumentText);
    final managed = configurationOnly
        ? {
            '--model-dir': '当前未分配实际模型目录',
            '--host': '当前未分配实际监听地址',
            '--port': '当前未分配实际监听端口',
            '--base-path': '当前未分配私有数据目录',
            '--api-key': '当前未分配软件鉴权凭据',
          }
        : family == EngineFamily.splash
        ? {
            '--model': '<绑定的 Splash 模型身份>',
            '--tokenizer': '<绑定的本地 tokenizer 目录>',
            '--binary': '<已核验的 Splash 原生程序>',
            '--host': '127.0.0.1',
            '--port': port?.toString() ?? '<启动时分配的端口>',
            '--served-model-name': alias ?? '<启动时分配的模型标识>',
            ...managedArguments,
          }
        : {
            '--model': modelPath,
            '--alias': alias ?? '<启动时分配的模型标识>',
            '--host': '127.0.0.1',
            '--port': port?.toString() ?? '<启动时分配的端口>',
            ...managedArguments,
          };
    final arguments = <String>[];
    final managedNames = <String>{};
    final overridden = <String>{};
    final notices = <String>{...rules.notices};
    for (var index = 0; index < tokens.length; index++) {
      final argument = tokens[index].value;
      final name = argument.split('=').first;
      var controlled = rules.canonicalName(name);
      if (family == EngineFamily.splash &&
          name.startsWith('--') &&
          name.length > 2 &&
          !rules.recognizes(name)) {
        final matches = rules.parameters.keys
            .where((option) => option.startsWith(name))
            .map(rules.canonicalName)
            .toSet();
        if (matches.length == 1 && managed.containsKey(matches.single)) {
          controlled = matches.single;
        }
      }
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
      if (!labels.containsKey(canonical)) {
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
      final notice = _valueNotice(canonical, value, family);
      if (notice != null) notices.add(notice);
    }
    for (final entry in formValues.entries) {
      if (overridden.contains(entry.key) || entry.value.isEmpty) continue;
      final notice = _valueNotice(entry.key, entry.value, family);
      if (notice != null) notices.add(notice);
    }
    return EngineLaunchCommand(
      executable: executable,
      provisional:
          !configurationOnly &&
          (alias == null &&
                  !managedArguments.containsKey(
                    family == EngineFamily.splash
                        ? '--served-model-name'
                        : '--alias',
                  ) ||
              port == null && !managedArguments.containsKey('--port') ||
              family == EngineFamily.splash &&
                  (executableArguments.isEmpty ||
                      ![
                        '--model',
                        '--tokenizer',
                        '--binary',
                      ].every(managedArguments.containsKey))),
      isConfigurationOnly: configurationOnly,
      overriddenForm: overridden,
      notices: [
        for (final name in managedNames)
          configurationOnly
              ? '$name 由软件管理；生产运行尚未接通，当前未确定实际值。'
              : '$name 由软件管理，实际采用 ${managed[name]}',
        ...notices,
      ],
      arguments: [
        if (!configurationOnly) ...executableArguments,
        if (!configurationOnly && family != EngineFamily.splash)
          for (final entry in managed.entries) ...[entry.key, entry.value],
        for (final name in labels.keys)
          if (!overridden.contains(name) &&
              (formValues[name]?.isNotEmpty ?? false)) ...[
            name,
            formValues[name]!,
          ],
        ...arguments,
        if (family == EngineFamily.splash)
          for (final entry in managed.entries) ...[entry.key, entry.value],
      ],
    );
  }

  static bool _looksLikeOption(String value) =>
      value.startsWith('-') && !RegExp(r'^-\d').hasMatch(value);

  static bool _isValue(LaunchArgumentToken token) =>
      token.hasLiteralPrefix || !_looksLikeOption(token.value);

  static String? _valueNotice(String name, String? value, EngineFamily family) {
    if (value == null || value.isEmpty) {
      return '$name 缺少值，仍保留并交由引擎判断。';
    }
    if (family == EngineFamily.omlx) {
      if (name == '--max-concurrent-requests' && int.tryParse(value) == null) {
        return '$name 通常需要整数值，仍保留并交由引擎判断。';
      }
      if (name == '--memory-guard' &&
          !['off', 'safe', 'balanced', 'aggressive'].contains(value)) {
        return '$name 常用值为 off、safe、balanced、aggressive，仍保留并交由引擎判断。';
      }
      return null;
    }
    if (family == EngineFamily.splash) {
      final normalized = value.trim().toUpperCase();
      if (name == '--max-context' || name == '--max-memory') {
        if (normalized == 'AUTO') return null;
        final suffix = name == '--max-context'
            ? RegExp(r'K$')
            : RegExp(r'[KMG](?:IB|B)?$');
        final count = normalized.replaceFirst(suffix, '').trim();
        if (!RegExp(r'^[+]?\d+$').hasMatch(count) ||
            (int.tryParse(count) ?? 0) <= 0) {
          return '$name 通常需要 auto 或正整数及受支持的单位，仍保留并交由引擎判断。';
        }
      } else if (name == '--kv-format' && !['int8', 'bf16'].contains(value)) {
        return '$name 常用值为 int8、bf16，仍保留并交由引擎判断。';
      } else if (name == '--queue-size' &&
          (!RegExp(r'^[+]?\d+$').hasMatch(value.trim()) ||
              (int.tryParse(value) ?? 0) <= 0)) {
        return '$name 通常需要正整数值，仍保留并交由引擎判断。';
      }
      return null;
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
    final familyValue = value.containsKey('family')
        ? value['family']
        : 'llamaCpp';
    final family = EngineFamily.values
        .where((item) => item.name == familyValue)
        .singleOrNull;
    if (family == null) throw const FormatException('引擎启动配置家族无效');
    final labels = labelsFor(family);
    final values = <String, String>{};
    for (final entry in (value['formValues'] as Map).entries) {
      if (entry.key is! String ||
          !labels.containsKey(entry.key) ||
          entry.value is! String) {
        throw const FormatException('引擎启动表单无效');
      }
      values[entry.key as String] = entry.value as String;
    }
    final text = value.containsKey('argumentText') ? value['argumentText'] : '';
    if (text is! String) throw const FormatException('引擎启动文本无效');
    return EngineLaunchConfiguration(
      family: family,
      formValues: values,
      argumentText: text,
    );
  }

  Map<String, Object> toJson() => {
    if (family != EngineFamily.llamaCpp) 'family': family.name,
    'formValues': formValues,
    'argumentText': argumentText,
  };
}

class EngineLaunchCommand {
  EngineLaunchCommand({
    required this.executable,
    required List<String> arguments,
    this.provisional = false,
    this.isConfigurationOnly = false,
    Set<String> overriddenForm = const {},
    List<String> notices = const [],
  }) : arguments = List.unmodifiable(arguments),
       overriddenForm = Set.unmodifiable(overriddenForm),
       notices = List.unmodifiable(notices);

  final String executable;
  final List<String> arguments;
  final bool provisional;
  final bool isConfigurationOnly;
  final Set<String> overriddenForm;
  final List<String> notices;

  /// Display and copying only. Execution receives the original argument array.
  String get displayText => [
    if (!isConfigurationOnly) executable,
    ...arguments,
  ].map(_quote).join(' ');

  static final _unquoted = RegExp(r'^[a-zA-Z0-9_@%+=:,./-]+$');
  static String _quote(String value) => _unquoted.hasMatch(value)
      ? value
      : "'${value.replaceAll("'", "'\"'\"'")}'";
}
