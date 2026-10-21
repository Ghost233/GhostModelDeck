import 'dart:convert';

import 'launch_argument_text.dart';
import 'engine_runtime.dart';
import 'engine_parameter_recognition.dart';
import 'generation_configuration.dart';
import 'jev_debug.dart';
import 'engine_parameter_definitions.dart';

import 'drafter_configuration.dart';
export 'drafter_configuration.dart';

export 'launch_argument_text.dart' show LaunchArgumentTextException;

class EngineLaunchConfiguration {
  EngineLaunchConfiguration({
    Map<String, String>? formValues,
    this.family = EngineFamily.llamaCpp,
    this.argumentText = '',
    this.drafter,
    this.generation = const GenerationConfiguration.empty(),
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
  static Map<String, String> labelsFor(EngineFamily family) => {
    for (final field in EngineParameterDefinitions.known(family))
      if (!field.managed) field.name: field.label,
  };

  final EngineFamily family;
  final Map<String, String> formValues;
  final String argumentText;

  /// Null preserves an unmigrated selection; false explicitly ignores old drafts.
  final DrafterConfiguration? drafter;
  final GenerationConfiguration generation;

  /// Request defaults do not change the identity of a loaded configuration.
  String get loadingIdentity => jsonEncode({
    'family': family.name,
    'formValues': {
      for (final key in formValues.keys.toList()..sort())
        if (formValues[key]!.isNotEmpty) key: formValues[key],
    },
    'argumentText': argumentText,
    'drafter': drafter?.toJson(),
  });
  void validateArgumentText() => parseLaunchArgumentText(argumentText);

  /// Old CLI values are repair hints, never an implicit model selection.
  DrafterConfiguration? get legacyLlamaDrafter {
    if (family != EngineFamily.llamaCpp || drafter != null) return null;
    final List<LaunchArgumentToken> tokens;
    try {
      tokens = parseLaunchArgumentText(argumentText);
    } on LaunchArgumentTextException {
      return null;
    }
    final rules = EngineParameterRecognition.builtIn();
    var found = false;
    String? path;
    String? mode;
    for (var index = 0; index < tokens.length; index++) {
      final parts = tokens[index].value.split('=');
      final name = rules.canonicalName(parts.first);
      final value = parts.length > 1
          ? parts.skip(1).join('=')
          : index + 1 < tokens.length
          ? tokens[index + 1].value
          : '';
      if (['--spec-draft-model', '--spec-draft-hf'].contains(name) ||
          ['--fim-qwen-7b-spec', '--fim-qwen-14b-spec'].contains(name)) {
        found = true;
      }
      if (name == '--spec-draft-model' && value.startsWith('/')) path = value;
      if (name == '--spec-type') {
        final drafts = value
            .split(',')
            .where((v) => v.startsWith('draft-'))
            .toList();
        if (drafts.isNotEmpty) found = true;
        if (drafts.length == 1 &&
            DrafterConfiguration.modes.containsKey(drafts.single)) {
          mode = drafts.single;
        }
      }
    }
    return found
        ? DrafterConfiguration(enabled: true, path: path, mode: mode)
        : null;
  }

  static const _llamaModelSources = {
    '--hf-repo',
    '--hf-file',
    '--hf-token',
    '--model-url',
    '--docker-repo',
    '--spec-draft-model',
    '--spec-draft-hf',
    '--models-dir',
    '--models-preset',
  };
  static const _llamaModelPresets = {
    '--fim-qwen-1.5b-default',
    '--fim-qwen-3b-default',
    '--fim-qwen-7b-default',
    '--fim-qwen-7b-spec',
    '--fim-qwen-14b-spec',
    '--fim-qwen-30b-default',
  };

  int? get contextLength => contextLengthFor();

  int? contextLengthFor({EngineParameterRecognition? recognition}) {
    if (family == EngineFamily.omlx) return null;
    final name = family == EngineFamily.splash ? '--max-context' : '--ctx-size';
    final normalized = argumentValue(
      name,
      recognition: recognition,
    )?.trim().toUpperCase();
    final match = RegExp(
      family == EngineFamily.splash ? r'^(\d+)(K)?$' : r'^(\d+)$',
    ).firstMatch(normalized ?? '');
    if (match == null) return null;
    final count = int.tryParse(match[1]!);
    if (count == null || count <= 0) return null;
    return count * (match.groupCount > 1 && match[2] == 'K' ? 1024 : 1);
  }

  /// Native inference parallelism; HTTP admission and queue sizes are separate.
  int? get inferenceConcurrency {
    if (family != EngineFamily.llamaCpp) return null;
    final value = int.tryParse(argumentValue('--parallel') ?? '');
    return value != null && value > 0 ? value : null;
  }

  String? argumentValue(
    String name, {
    EngineParameterRecognition? recognition,
  }) {
    final rules =
        recognition ?? EngineParameterRecognition.builtIn(family: family);
    final List<String> arguments;
    try {
      arguments = command(
        executable: '',
        modelPath: '',
        recognition: rules,
        // Reading one value must not validate unrelated optional features.
        validateSupport: false,
      ).arguments;
    } on LaunchArgumentTextException {
      return null;
    }
    String? value;
    for (var i = 0; i < arguments.length; i++) {
      final pieces = arguments[i].split('=');
      if (rules.canonicalName(pieces.first) != name) continue;
      value = pieces.length > 1
          ? pieces.skip(1).join('=')
          : i + 1 < arguments.length
          ? arguments[++i]
          : null;
    }
    return value;
  }

  EngineLaunchCommand command({
    required String executable,
    required String modelPath,
    String? alias,
    int? port,
    EngineParameterRecognition? recognition,
    List<String> executableArguments = const [],
    Map<String, String> managedArguments = const {},
    bool validateSupport = true,
  }) {
    final rules =
        recognition ?? EngineParameterRecognition.builtIn(family: family);
    final definitions = {
      for (final field in EngineParameterDefinitions.forEngine(
        family,
        recognition: rules,
      ))
        field.name: field,
    };
    final labels = {
      for (final entry in definitions.entries)
        if (!entry.value.managed) entry.key: entry.value.label,
      for (final key in formValues.keys)
        if (!definitions.containsKey(key)) key: key,
    };
    final configurationOnly = family == EngineFamily.omlx;
    final heldModelTokenizer = rules.usesSplashModelRootTokenizer;
    final tokens = parseLaunchArgumentText(argumentText);
    final ngram = <String>{};
    var textSpecType = false;
    if (family == EngineFamily.llamaCpp) {
      for (var index = 0; index < tokens.length; index++) {
        final parts = tokens[index].value.split('=');
        if (parts.first == '--spec-default') ngram.add('ngram-mod');
        if (rules.canonicalName(parts.first) != '--spec-type') continue;
        textSpecType = true;
        final value = parts.length > 1
            ? parts.skip(1).join('=')
            : index + 1 < tokens.length
            ? tokens[index + 1].value
            : '';
        ngram.addAll(value.split(',').where((s) => s.startsWith('ngram-')));
      }
      if (!textSpecType) {
        ngram.addAll(
          (formValues['--spec-type'] ?? '')
              .split(',')
              .where((s) => s.startsWith('ngram-')),
        );
        if (formValues['--spec-default'] == 'true') ngram.add('ngram-mod');
      }
    }
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
            if (drafter != null || ngram.isNotEmpty)
              '--spec-type': drafter?.enabled == true
                  ? drafter?.mode ?? '<请选择草稿模式>'
                  : ngram.isEmpty
                  ? 'none'
                  : ngram.join(','),
            if (drafter?.enabled == true &&
                drafter?.usesEmbeddedTarget != true &&
                drafter?.path != null)
              '--spec-draft-model': drafter!.path!,
            ...managedArguments,
          };
    String controlledName(String name) {
      final canonical = rules.canonicalName(name);
      if (family != EngineFamily.splash ||
          rules.recognizes(name) ||
          !name.startsWith('--')) {
        return canonical;
      }
      final matches = {...rules.parameters.keys, ...managed.keys}
          .where((option) => option.startsWith(name))
          .map(rules.canonicalName)
          .toSet();
      return matches.length == 1 ? matches.single : canonical;
    }

    bool managedForm(String name) {
      final canonical = controlledName(name);
      return managed.containsKey(canonical) ||
          definitions[canonical]?.managed == true ||
          family == EngineFamily.llamaCpp &&
              (_llamaModelSources.contains(canonical) ||
                  _llamaModelPresets.contains(canonical) ||
                  canonical == '--spec-default');
    }

    final arguments = <String>[];
    final managedNames = <String>{};
    final overridden = <String>{};
    final notices = <String>{...rules.notices};
    if (heldModelTokenizer) {
      notices.add('分词器来自 Splash 锁定的模型目录；不传递独立 --tokenizer。');
    }
    final unsupportedQuantizedFfn =
        validateSupport &&
        family == EngineFamily.splash &&
        !rules.recognizes('--experimental-quantized-ffn');
    String? unsupportedQuantizedFfnTextValue;
    void checkQuantizedFfn(String? value) {
      if (value != 'off') {
        throw const FormatException(
          '当前 Splash 引擎帮助未确认支持 --experimental-quantized-ffn；请更新引擎或关闭实验性量化 FFN。',
        );
      }
      notices.add('当前 Splash 引擎不支持实验性量化 FFN；关闭值已保留，不传递此参数。');
    }

    if (drafter?.enabled == true && ngram.isNotEmpty) {
      notices.add('草稿模型已开启，本次不激活 ngram；文本中的设置仍保留。');
    }
    for (var index = 0; index < tokens.length; index++) {
      final argument = tokens[index].value;
      final name = argument.split('=').first;
      var controlled = controlledName(name);
      if (unsupportedQuantizedFfn &&
          controlled == '--experimental-quantized-ffn') {
        final separator = argument.indexOf('=');
        unsupportedQuantizedFfnTextValue = separator >= 0
            ? argument.substring(separator + 1)
            : index + 1 < tokens.length && _isValue(tokens[index + 1])
            ? tokens[++index].value
            : null;
        overridden.add('--experimental-quantized-ffn');
        continue;
      }
      if (family == EngineFamily.llamaCpp &&
          (_llamaModelSources.contains(controlled) ||
              _llamaModelPresets.contains(controlled) ||
              controlled == '--spec-default' ||
              (drafter?.enabled != true &&
                  controlled.startsWith('--spec-draft-')))) {
        final flagOnly =
            _llamaModelPresets.contains(controlled) ||
            [
              '--spec-default',
              '--spec-draft-backend-sampling',
              '--no-spec-draft-backend-sampling',
              '--spec-draft-cpu-moe',
            ].contains(controlled);
        notices.add('$name 由当前模型与草稿配置管理；文本设置保留，不直接应用。');
        if (!flagOnly &&
            !argument.contains('=') &&
            index + 1 < tokens.length &&
            _isValue(tokens[index + 1])) {
          index++;
        }
        continue;
      }
      if (family == EngineFamily.splash &&
          drafter?.enabled == false &&
          name.startsWith('--compact-draft-')) {
        notices.add('$name 已保留；草稿关闭时不应用。');
        if (!argument.contains('=') &&
            index + 1 < tokens.length &&
            _isValue(tokens[index + 1])) {
          index++;
        }
        continue;
      }
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
        if (controlled == '--spec-type') overridden.add(controlled);
        if (!argument.contains('=') &&
            index + 1 < tokens.length &&
            _isValue(tokens[index + 1])) {
          index++;
        }
        continue;
      }
      arguments.add(argument);
      final canonical =
          definitions.values
              .where((field) => field.negativeFlag == rules.canonicalName(name))
              .firstOrNull
              ?.name ??
          rules.canonicalName(name);
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
      if (formValues[canonical]?.isNotEmpty ?? false) {
        overridden.add(canonical);
      }
      if (definitions[canonical]?.kind == ParameterKind.flag) continue;
      String? value;
      final separator = argument.indexOf('=');
      if (separator >= 0) {
        value = argument.substring(separator + 1);
      } else if (index + 1 < tokens.length && _isValue(tokens[index + 1])) {
        value = tokens[++index].value;
        arguments.add(value);
      }
      // Help may describe multi-value options. Consume every literal value
      // before interpreting the next token as another managed option.
      var remaining = description == null || description.valueHint.isEmpty
          ? 0
          : description.valueHint.split(RegExp(r'\s+')).length - 1;
      while (remaining > 0 &&
          index + 1 < tokens.length &&
          _isValue(tokens[index + 1])) {
        arguments.add(tokens[++index].value);
        remaining--;
      }
      final notice = _valueNotice(canonical, value, family);
      if (notice != null) notices.add(notice);
    }
    if (unsupportedQuantizedFfn &&
        overridden.contains('--experimental-quantized-ffn')) {
      checkQuantizedFfn(unsupportedQuantizedFfnTextValue);
    }
    for (final entry in formValues.entries) {
      if (overridden.contains(entry.key) || entry.value.isEmpty) continue;
      if (unsupportedQuantizedFfn &&
          entry.key == '--experimental-quantized-ffn') {
        checkQuantizedFfn(entry.value);
        continue;
      }
      if (rules.hasObservedHelp && !rules.recognizes(entry.key)) {
        notices.add('${entry.key} 的支持情况尚未由当前版本帮助确认；启动时由引擎校验。');
      }
      final notice = _valueNotice(entry.key, entry.value, family);
      if (notice != null) notices.add(notice);
    }
    return EngineLaunchCommand(
      executable: executable,
      secretOptions: {
        '--api-key',
        for (final field in definitions.values)
          if (field.kind == ParameterKind.secret) ...[
            field.name,
            if (family == EngineFamily.splash)
              for (var length = 3; length < field.name.length; length++)
                field.name.substring(0, length),
          ],
        for (final name in rules.parameters.keys)
          if (definitions[rules.canonicalName(name)]?.kind ==
              ParameterKind.secret)
            name,
      },
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
                        if (!heldModelTokenizer) '--tokenizer',
                        '--binary',
                      ].every(managedArguments.containsKey))),
      isConfigurationOnly: configurationOnly,
      overriddenForm: overridden,
      notices: [
        for (final name in managedNames)
          configurationOnly
              ? '$name 由软件管理；在实例运行时分配实际值。'
              : heldModelTokenizer && name == '--tokenizer'
              ? '--tokenizer 由锁定的模型目录提供，文本设置不应用。'
              : '$name 由软件管理，实际采用 ${managed[name]}',
        ...notices,
      ],
      arguments: [
        if (!configurationOnly) ...executableArguments,
        if (!configurationOnly && family != EngineFamily.splash)
          for (final entry in managed.entries) ...[entry.key, entry.value],
        for (final name in labels.keys)
          if (!overridden.contains(name) &&
              !(unsupportedQuantizedFfn &&
                  name == '--experimental-quantized-ffn') &&
              !managedForm(name) &&
              (formValues[name]?.isNotEmpty ?? false) &&
              !(definitions[name]?.group == 'draft' &&
                  drafter?.enabled != true))
            ...(definitions[name] ??
                    EngineParameterDefinition(
                      name,
                      name,
                      'extra',
                      ParameterKind.text,
                    ))
                .arguments(formValues[name]!),
        ...arguments,
        if (family == EngineFamily.splash)
          for (final entry in managed.entries)
            if (!(heldModelTokenizer && entry.key == '--tokenizer')) ...[
              entry.key,
              entry.value,
            ],
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
    if (family == EngineFamily.llamaCpp && !formLabels.containsKey(name)) {
      final definition = EngineParameterDefinitions.known(family)
          .where((d) => d.name == name)
          .firstOrNull;
      if (definition?.kind == ParameterKind.integer &&
          int.tryParse(value) == null) {
        return '$name 通常需要整数值，仍保留并交由引擎判断。';
      }
      if (definition?.kind == ParameterKind.decimal &&
          double.tryParse(value) == null) {
        return '$name 通常需要数值，仍保留并交由引擎判断。';
      }
      return null;
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
      } else if (name == '--kv-format' &&
          !['int8', 'bf16', 'q4h', 'q4_0', 'q4_0_unrotated'].contains(value)) {
        return '$name 不属于当前内置格式，仍保留并交由引擎判断。';
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
    if (family == EngineFamily.omlx && value['drafter'] != null) {
      throw const FormatException('此引擎不支持草稿模型配置');
    }
    final values = <String, String>{};
    for (final entry in (value['formValues'] as Map).entries) {
      if (entry.key is! String ||
          !RegExp(r'^--[A-Za-z0-9][A-Za-z0-9_-]*$')
              .hasMatch(entry.key as String) ||
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
      generation: GenerationConfiguration.fromJson(value['generation']),
      drafter: (value['drafter'] ?? value['splashDrafter']) == null
          ? null
          : DrafterConfiguration.fromJson(
              value['drafter'] ?? value['splashDrafter'],
            ),
    );
  }

  Map<String, Object> toJson() => {
    if (family != EngineFamily.llamaCpp) 'family': family.name,
    'formValues': formValues,
    'argumentText': argumentText,
    if (drafter != null) 'drafter': drafter!.toJson(),
    if (generation.values.isNotEmpty) 'generation': generation.toJson(),
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
    Set<String> secretOptions = const {'--api-key'},
  }) : arguments = List.unmodifiable(arguments),
       overriddenForm = Set.unmodifiable(overriddenForm) {
    final secrets = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      final parts = arguments[index].split('=');
      if (!secretOptions.contains(parts.first.replaceAll('_', '-'))) continue;
      final value = parts.length > 1
          ? parts.skip(1).join('=')
          : index + 1 < arguments.length
          ? arguments[++index]
          : '';
      secrets.addAll([value, ...value.split(',')]);
    }
    final display = sealDebugJson({
      'credentials': [
        for (final secret in secrets) {'api_key': secret},
      ],
      'executable': executable,
      'arguments': arguments,
      'notices': notices,
    });
    _displayExecutable = display['executable']! as String;
    _displayArguments = (display['arguments']! as List).cast<String>();
    this.notices = List.unmodifiable(
      (display['notices']! as List).cast<String>(),
    );
  }

  final String executable;
  final List<String> arguments;
  final bool provisional;
  final bool isConfigurationOnly;
  final Set<String> overriddenForm;
  late final List<String> notices;
  late final String _displayExecutable;
  late final List<String> _displayArguments;

  /// Display and copying only. Execution receives the original argument array.
  String get displayText => [
    if (!isConfigurationOnly) _displayExecutable,
    ..._displayArguments,
  ].map(_quote).join(' ');

  static final _unquoted = RegExp(r'^[a-zA-Z0-9_@%+=:,./-]+$');
  static String _quote(String value) => _unquoted.hasMatch(value)
      ? value
      : "'${value.replaceAll("'", "'\"'\"'")}'";
}
