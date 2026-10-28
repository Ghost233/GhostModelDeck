import 'chat_protocol.dart';
import 'decision_protocol.dart';
import 'generation_configuration.dart';
import 'generation_seed.dart';
import 'jev_models.dart';
import 'prefill_operation_ledger.dart';
import 'splash_operation_client.dart';

/// Validates tracked requests separately from ordinary positive-budget APIs.
class PublicPrefillRequest {
  PublicPrefillRequest._(
    this.path,
    this.kind,
    this.model,
    this.cacheSalt,
    this.body,
  );
  final SplashOperationPath path;
  final PrefillOperationKind kind;
  final String model, cacheSalt;
  final Map<String, Object?> body;

  /// Applies the selected instance defaults without replacing zero prefill.
  Map<String, Object?> toSplash({
    required String nativeModel,
    GenerationConfiguration defaults = const GenerationConfiguration.empty(),
  }) {
    if (nativeModel.trim().isEmpty) throw const FormatException('原生模型身份无效');
    if (path == SplashOperationPath.systemone) {
      return Map<String, Object?>.unmodifiable(
        {...body, 'model': nativeModel}..remove('debug'),
      );
    }
    final budget = (body['max_tokens'] ?? body['max_completion_tokens']) as int;
    final overrides = GenerationConfiguration({
      for (final key in GenerationConfiguration.acceptedKeys)
        if (body.containsKey(key) &&
            key != 'max_tokens' &&
            key != 'max_completion_tokens')
          key: body[key],
      'max_tokens': budget == 0 ? 1 : budget,
    });
    final native = defaults.withOverrides(overrides).nativeValues(splash: true);
    return Map<String, Object?>.unmodifiable({
      'model': nativeModel,
      'messages': body['messages'],
      'stream': false,
      ...native,
      if (kind == PrefillOperationKind.prefill) 'max_tokens': 0,
    });
  }

  static PublicPrefillRequest parse(
    SplashOperationPath path,
    Map<String, Object?> input,
  ) {
    final model = input['model'];
    final salt = input['cache_salt'];
    if (model is! String ||
        model.trim().isEmpty ||
        model != model.trim() ||
        salt is! String ||
        salt.isEmpty ||
        salt.length > 2048 ||
        input['stream'] != null && input['stream'] != false) {
      throw const FormatException('模型、缓存盐或非流式参数无效');
    }
    late final PrefillOperationKind kind;
    if (path == SplashOperationPath.chat) {
      const allowed = {
        'model',
        'messages',
        'stream',
        ...GenerationConfiguration.acceptedKeys,
      };
      if (input.keys.any((key) => !allowed.contains(key))) {
        throw const FormatException('请求包含不支持的字段');
      }
      final max = input['max_tokens'];
      final alias = input['max_completion_tokens'];
      if (max != null && (max is! int || max < 0) ||
          alias != null && (alias is! int || alias < 0) ||
          max == null && alias == null ||
          input.containsKey('max_tokens') &&
              input.containsKey('max_completion_tokens') &&
              max != alias ||
          input['seed'] is String) {
        throw const FormatException('输出预算无效或别名冲突');
      }
      final budget = (max ?? alias) as int;
      kind = budget == 0
          ? PrefillOperationKind.prefill
          : PrefillOperationKind.consume;
      final rawMessages = input['messages'];
      if (rawMessages is! List || rawMessages.isEmpty) {
        throw const FormatException('消息不能为空');
      }
      try {
        for (final entry in rawMessages) {
          if (entry is! Map ||
              entry.keys.any((key) => key != 'role' && key != 'content') ||
              entry['role'] is! String ||
              entry['content'] is! String) {
            throw const FormatException('消息格式无效');
          }
          TextMessage(
            role: entry['role'] as String,
            content: entry['content'] as String,
          );
        }
        final parameters = <String, Object?>{
          for (final key in GenerationConfiguration.acceptedKeys)
            if (input.containsKey(key) &&
                key != 'max_tokens' &&
                key != 'max_completion_tokens')
              key: input[key],
          'max_tokens': budget == 0 ? 1 : budget,
        };
        GenerationConfiguration(parameters).nativeValues(splash: true);
      } on TextProtocolException catch (error) {
        throw FormatException(error.message);
      }
    } else {
      const allowed = {
        'model',
        'state',
        'questions',
        'stream',
        'debug',
        'images',
        'cache_salt',
        'prefill_only',
      };
      if (input.keys.any((key) => !allowed.contains(key)) ||
          input['state'] == null ||
          input['prefill_only'] != null && input['prefill_only'] is! bool ||
          input['debug'] != null && input['debug'] is! bool) {
        throw const FormatException('决策请求字段无效');
      }
      final prefill = input['prefill_only'] == true;
      kind = prefill
          ? PrefillOperationKind.prefill
          : PrefillOperationKind.consume;
      if (prefill) {
        final questions = input['questions'];
        if (questions != null && (questions is! Map || questions.isNotEmpty)) {
          throw const FormatException('决策预填不能包含问题');
        }
      } else {
        try {
          JevModelRequest.parse({
            for (final entry in input.entries)
              if (entry.key != 'cache_salt' && entry.key != 'prefill_only')
                entry.key: entry.value,
          });
        } on DecisionProtocolException catch (error) {
          throw FormatException(error.message);
        }
      }
    }
    final copy = decodeGenerationRequest(encodeGenerationRequest(input));
    return PublicPrefillRequest._(
      path,
      kind,
      model,
      salt,
      _freeze(copy) as Map<String, Object?>,
    );
  }
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freeze(entry.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
