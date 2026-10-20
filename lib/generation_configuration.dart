import 'dart:convert';

import 'generation_seed.dart';

/// Missing values inherit; an explicit null output limit disables that limit.
class GenerationConfiguration {
  const GenerationConfiguration.empty() : values = const {};

  factory GenerationConfiguration(Map<String, Object?> input) {
    final values = <String, Object?>{};
    for (final entry in input.entries) {
      if (!acceptedKeys.contains(entry.key)) {
        throw FormatException('不支持的生成参数：${entry.key}');
      }
      final key = canonicalKey(entry.key);
      if (entry.value == null &&
          key != 'max_tokens' &&
          !disabledSamplingValues.containsKey(key) &&
          !disabledThinkingValues.containsKey(key) &&
          !nativeDefaultValues.contains(key)) {
        continue;
      }
      if (entry.key == 'thinking_budget_tokens' &&
          input.containsKey('reasoning_budget_tokens')) {
        continue;
      }
      if (key == 'max_tokens' &&
          entry.key == 'max_tokens' &&
          input.containsKey('max_completion_tokens')) {
        continue;
      }
      if (values.containsKey(key) && values[key] != entry.value) {
        throw FormatException('生成参数别名冲突：$key');
      }
      values[key] = entry.value;
    }
    void invalid(String key, String reason) =>
        throw FormatException('$key $reason');
    for (final entry in values.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value == null) continue;
      switch (key) {
        case 'max_tokens':
          if (value is! int || value < 1) {
            invalid(key, '需要是正整数，或 null 明确关闭限制');
          }
        case 'temperature':
          if (value is! num || !value.isFinite || value < 0) {
            invalid(key, '需要是非负有限数');
          }
        case 'top_p':
          if (value is! num || !value.isFinite || value < 0 || value > 1) {
            invalid(key, '需要在 0 到 1 之间');
          }
        case 'min_p':
          if (value is! num || !value.isFinite || value < 0 || value > 1) {
            invalid(key, '需要在 0 到 1 之间');
          }
        case 'top_k':
          if (value is! int || value < -1) invalid(key, '需要是 -1、0 或正整数');
        case 'repeat_penalty':
          if (value is! num ||
              !value.isFinite ||
              value < minPositiveFloat32 ||
              value > maxFiniteFloat32) {
            invalid(key, '需要是可表示的正有限 float32 数');
          }
        case 'presence_penalty' || 'frequency_penalty':
          if (value is! num ||
              !value.isFinite ||
              value.abs() > maxFiniteFloat32) {
            invalid(key, '需要是可表示的有限 float32 数');
          }
        case 'seed':
          final parsed = value is String ? parseGenerationSeed(value) : value;
          final integer = generationSeedInteger(parsed);
          if (integer == null ||
              integer < -(BigInt.one << 63) ||
              integer >= (BigInt.one << 64)) {
            invalid(key, '需要是 -2^63 到 2^64-1 的精确整数');
          }
          values[key] = parsed;
        case 'reasoning_budget_tokens':
          if (value is! int || value < -1 || value > 2147483647) {
            invalid(key, '需要是 -1 或 0 到 2147483647 的整数');
          }
        case 'thinking_token_budget':
          if (value is! int || value < -1) invalid(key, '需要是 -1 或非负整数');
        case 'ignore_eos' || 'preserve_thinking':
          if (value is! bool) invalid(key, '需要是布尔值');
        case 'stop':
          if (!(value is String && value.isNotEmpty) &&
              !(value is List &&
                  value.every((v) => v is String && v.isNotEmpty))) {
            invalid(key, '需要是非空字符串或字符串数组');
          }
        case 'reasoning_effort':
          if (![
            'none',
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
          ].contains(value)) {
            invalid(key, '不是支持的思考强度');
          }
        case 'priority':
          if (!['foreground', 'normal', 'background'].contains(value)) {
            invalid(key, '需要是 foreground、normal 或 background');
          }
        case 'timeout':
          if (value is! num || !value.isFinite || value <= 0) {
            invalid(key, '需要是正有限秒数');
          }
          final micros = (value as num) * Duration.microsecondsPerSecond;
          if (!micros.isFinite || micros > 9223372036854775807) {
            invalid(key, '超出网关可表示的时限');
          }
        case 'cache_salt':
          if (value is! String || value.isEmpty) invalid(key, '需要是非空字符串');
        case 'chat_template_kwargs':
          if (value is! Map || value.keys.any((key) => key is! String)) {
            invalid(key, '需要是对象');
          }
          final kwargs = value as Map;
          for (final key in [
            'enable_thinking',
            'preserve_thinking',
            'preserve_reasoning',
          ]) {
            if (kwargs[key] != null && kwargs[key] is! bool) {
              invalid('chat_template_kwargs.$key', '需要是布尔值或 null');
            }
          }
        case 'response_format':
          if (value is! Map ||
              !['text', 'json_object', 'json_schema'].contains(value['type'])) {
            invalid(key, '需要指定 text、json_object 或 json_schema');
          }
          if ((value as Map)['type'] == 'json_schema') {
            final schema = value['json_schema'];
            if (schema is! Map || schema['schema'] is! Map) {
              invalid(key, '需要 json_schema.schema 对象');
            }
          }
      }
    }
    // Validate JSON ownership at this I/O seam and freeze nested objects too.
    final json = jsonDecode(jsonEncode(values)) as Map<String, dynamic>;
    if (values['seed'] is ExactGenerationSeed) json['seed'] = values['seed'];
    return GenerationConfiguration._(
      Map.unmodifiable(json.map((key, value) => MapEntry(key, _freeze(value)))),
    );
  }

  const GenerationConfiguration._(this.values);
  final Map<String, Object?> values;

  static const minPositiveFloat32 = 1.401298464324817e-45;
  static const maxFiniteFloat32 = 3.4028234663852886e38;

  /// Explicit null disables a filter/penalty with the native neutral value.
  static const disabledSamplingValues = <String, num>{
    'top_k': 0,
    'top_p': 1.0,
    'min_p': 0.0,
    'repeat_penalty': 1.0,
    'presence_penalty': 0.0,
    'frequency_penalty': 0.0,
  };

  static const disabledThinkingValues = <String, int>{
    'thinking_token_budget': 0,
    'reasoning_budget_tokens': 0,
  };

  /// Explicit null clears an instance override and uses the native service.
  static const nativeDefaultValues = {'timeout', 'cache_salt'};

  static const acceptedKeys = {
    'max_tokens',
    'max_completion_tokens',
    'temperature',
    'top_p',
    'top_k',
    'min_p',
    'repeat_penalty',
    'repetition_penalty',
    'presence_penalty',
    'frequency_penalty',
    'seed',
    'stop',
    'ignore_eos',
    'response_format',
    'reasoning_effort',
    'thinking_token_budget',
    'reasoning_budget_tokens',
    'thinking_budget_tokens',
    'preserve_thinking',
    'chat_template_kwargs',
    'priority',
    'timeout',
    'cache_salt',
  };

  static String canonicalKey(String key) => switch (key) {
    'max_completion_tokens' => 'max_tokens',
    'repetition_penalty' => 'repeat_penalty',
    'thinking_budget_tokens' => 'reasoning_budget_tokens',
    _ => key,
  };

  factory GenerationConfiguration.fromJson(Object? value) {
    if (value == null) return const GenerationConfiguration.empty();
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('生成默认值需要是对象');
    }
    return GenerationConfiguration(Map<String, Object?>.from(value));
  }

  GenerationConfiguration withOverrides(GenerationConfiguration overrides) =>
      GenerationConfiguration({...values, ...overrides.values});

  Map<String, Object?> toJson() => values;

  Map<String, Object> nativeValues({
    bool splash = false,
    bool unlimitedAsNegativeOne = false,
  }) {
    if (splash) {
      if (values.containsKey('reasoning_budget_tokens')) {
        throw const FormatException(
          'reasoning_budget_tokens 仅适用于当前 llama.cpp；Splash 使用 thinking_token_budget',
        );
      }
      final template = values['chat_template_kwargs'];
      if (template is Map) {
        for (final key in [
          'add_generation_prompt',
          'chat_template',
          'continue_final_message',
          'conversation',
          'documents',
          'messages',
          'return_dict',
          'tokenize',
          'tools',
        ]) {
          if (template.containsKey(key)) {
            throw FormatException('当前 Splash chat_template_kwargs 不能覆盖 $key');
          }
        }
      }
      final topP = values['top_p'];
      if (topP is num && topP < minPositiveFloat32) {
        throw const FormatException('当前 Splash top_p 需要是正 float32 数，最大为 1');
      }
      for (final key in ['presence_penalty', 'frequency_penalty']) {
        final value = values[key];
        if (value is num && (value < -2 || value > 2)) {
          throw FormatException('当前 Splash $key 需要在 -2 到 2 之间');
        }
      }
      final temperature = values['temperature'];
      if (temperature is num && temperature > 2) {
        throw const FormatException('当前 Splash temperature 需要在 0 到 2 之间');
      }
      final format = values['response_format'];
      if (values['ignore_eos'] == true &&
          format is Map &&
          ['json_object', 'json_schema'].contains(format['type'])) {
        throw const FormatException('当前 Splash ignore_eos 不能与结构化输出同时启用');
      }
      final stop = values['stop'];
      if (stop is List && stop.length > 4) {
        throw const FormatException('当前 Splash 最多支持 4 个停止字符串');
      }
    } else {
      final seed = generationSeedInteger(values['seed']);
      if (seed != null && (seed < -BigInt.one || seed >= (BigInt.one << 32))) {
        throw const FormatException(
          '当前 llama.cpp seed 需要是 -1（随机）或 0 到 4294967295',
        );
      }
      for (final key in [
        'thinking_token_budget',
        'preserve_thinking',
        'priority',
        'timeout',
        'cache_salt',
      ]) {
        if (values.containsKey(key)) {
          throw FormatException('此生成参数仅适用于当前 Splash：$key');
        }
      }
    }
    return {
      for (final entry in values.entries)
        if (entry.value != null ||
            entry.key != 'max_tokens' &&
                !nativeDefaultValues.contains(entry.key))
          (splash && entry.key == 'repeat_penalty'
                  ? 'repetition_penalty'
                  : entry.key):
              entry.value ??
              disabledSamplingValues[entry.key] ??
              disabledThinkingValues[entry.key]!
        else if (entry.key == 'max_tokens' && !splash && unlimitedAsNegativeOne)
          'max_tokens': -1,
    };
  }
}

Object? _freeze(Object? value) => switch (value) {
  Map value => Map<String, Object?>.unmodifiable(
    value.map((key, value) => MapEntry(key as String, _freeze(value))),
  ),
  List value => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
