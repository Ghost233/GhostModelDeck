import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine_runtime.dart';
import 'generation_configuration.dart';
import 'generation_seed.dart';

enum NativeTextEndpoint {
  chat('/v1/chat/completions'),
  responses('/v1/responses'),
  messages('/v1/messages'),
  messagesCountTokens('/v1/messages/count_tokens');

  const NativeTextEndpoint(this.path);
  final String path;
  bool get isAnthropic => this == messages || this == messagesCountTokens;

  Map<String, Object> errorBody(int status, String type, String message) => {
    if (isAnthropic) 'type': 'error',
    'error': {
      'type': !isAnthropic
          ? type
          : switch (status) {
              400 => 'invalid_request_error',
              404 => 'not_found_error',
              413 => 'request_too_large',
              _ => 'api_error',
            },
      'message': message,
    },
  };
}

typedef NativeTextConsumer = Future<void> Function(
  HttpClientResponse response,
  String Function(String) redact,
  DecisionCancellation cancellation,
);

/// An optional ability of an engine that serves these wire formats natively.
abstract interface class NativeTextRuntime implements EngineRuntime {
  Future<void> runNativeText(
    String instanceId, {
    required int expectedGeneration,
    required NativeTextCall call,
    required DecisionCancellation cancellation,
    required NativeTextConsumer consume,
  });
}

class NativeTextFailure implements DecisionCallFailure {
  const NativeTextFailure(this.kind);
  @override
  final DecisionFailureKind kind;
  @override
  String get message => kind.name;
  @override
  String? get rawResponse => null;
}

class NativeTextCall {
  const NativeTextCall(this.endpoint, this.body, this.headers, this.timeout);
  final NativeTextEndpoint endpoint;
  final Map<String, Object?> body;
  final Map<String, String> headers;
  final Duration timeout;

  /// The owning runtime supplies the endpoint, model, authentication and permit.
  Future<void> forward({
    required Uri address,
    required String model,
    required Map<String, String> authentication,
    required String Function(String) redact,
    required Duration remaining,
    required DecisionCancellation cancellation,
    required NativeTextConsumer consume,
  }) async {
    if (cancellation.isCancelled) {
      throw const NativeTextFailure(DecisionFailureKind.cancelled);
    }
    if (remaining <= Duration.zero) {
      throw const NativeTextFailure(DecisionFailureKind.timedOut);
    }
    final client = HttpClient()..connectionTimeout = remaining;
    final remove = cancellation.listen(() => client.close(force: true));
    try {
      await (() async {
        final request = await client.postUrl(address.resolve(endpoint.path));
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        authentication.forEach(request.headers.set);
        request.headers.contentType = ContentType.json;
        final bytes = utf8.encode(
          encodeGenerationRequest({...body, 'model': model}),
        );
        request.contentLength = bytes.length;
        request.add(bytes);
        await consume(await request.close(), redact, cancellation);
      })().timeout(remaining);
      if (cancellation.isCancelled) {
        throw const NativeTextFailure(DecisionFailureKind.cancelled);
      }
    } on TimeoutException {
      cancellation.cancel();
      throw const NativeTextFailure(DecisionFailureKind.timedOut);
    } catch (_) {
      if (cancellation.isCancelled) {
        throw const NativeTextFailure(DecisionFailureKind.cancelled);
      }
      rethrow;
    } finally {
      remove();
      client.close(force: true);
    }
  }
}

/// Adapt saved Chat-style defaults to the native request dialect. Only
/// protocol fields understood by the selected backend are filled in.
Map<String, Object?> nativeTextBody(
  NativeTextEndpoint endpoint,
  Map<String, Object?> input,
  GenerationConfiguration defaults, {
  required bool splash,
}) {
  final body = {...input};
  final extra = <String, Object?>{};
  final suppliedExtra = body['extra_params'];
  if (suppliedExtra != null) {
    if (suppliedExtra is! Map ||
        suppliedExtra.keys.any(
          (key) =>
              !GenerationConfiguration.acceptedKeys.contains(key) ||
              key == 'cache_salt' ||
              key == 'timeout',
        )) {
      throw const FormatException('extra_params 只允许受支持的生成参数');
    }
    extra.addAll(Map<String, Object?>.from(suppliedExtra));
  }
  if (endpoint == NativeTextEndpoint.chat) {
    final parameters = GenerationConfiguration({
      for (final entry in input.entries)
        if (GenerationConfiguration.acceptedKeys.contains(entry.key))
          entry.key: entry.value,
    });
    return {
      for (final entry in input.entries)
        if (!GenerationConfiguration.acceptedKeys.contains(entry.key))
          entry.key: entry.value,
      ...defaults.withOverrides(parameters).nativeValues(splash: splash),
    };
  }
  final responses = endpoint == NativeTextEndpoint.responses;
  if (endpoint == NativeTextEndpoint.messagesCountTokens) return body;
  final nativeDefaults = defaults.nativeValues(
    splash: splash,
    unlimitedAsNegativeOne: !splash,
  );
  final outputKey = responses ? 'max_output_tokens' : 'max_tokens';
  if (nativeDefaults.containsKey('max_tokens') &&
      !extra.containsKey('max_tokens') &&
      !extra.containsKey('max_completion_tokens')) {
    final limit = nativeDefaults['max_tokens'];
    // Anthropic Messages requires a positive output limit.
    if (responses || limit is int && limit > 0) {
      body.putIfAbsent(outputKey, () => limit);
    }
  }
  final stopKey = responses ? 'stop' : 'stop_sequences';
  final stop = nativeDefaults['stop'];
  if (stop != null && !extra.containsKey('stop')) {
    body.putIfAbsent(
      stopKey,
      () => !responses && stop is String ? [stop] : stop,
    );
  }
  for (final entry in nativeDefaults.entries) {
    final key = entry.key;
    if (const {
      'max_tokens',
      'stop',
      'response_format',
      'reasoning_effort',
    }.contains(key)) {
      continue;
    }
    if (!responses &&
        body.containsKey('thinking') &&
        (key == 'reasoning_budget_tokens' || key == 'thinking_token_budget')) {
      continue;
    }
    if (body.containsKey(key) || extra.containsKey(key)) continue;
    if (responses ||
        const {
          'temperature',
          'top_p',
          'top_k',
          'chat_template_kwargs',
        }.contains(key) ||
        splash &&
            const {'seed', 'priority', 'timeout', 'cache_salt'}.contains(key)) {
      body[key] = entry.value;
    } else if (!splash) {
      extra[key] = entry.value;
    }
  }
  final effort = nativeDefaults['reasoning_effort'];
  if (effort != null && !extra.containsKey('reasoning_effort')) {
    if (responses) {
      final reasoning = body['reasoning'];
      if (!body.containsKey('reasoning') ||
          reasoning is Map && !reasoning.containsKey('effort')) {
        body['reasoning'] = {
          if (reasoning is Map) ...reasoning,
          'effort': effort,
        };
      }
    } else if (!splash && !body.containsKey('thinking')) {
      extra['reasoning_effort'] = effort;
    }
  }
  if (splash && !responses && !body.containsKey('thinking')) {
    final budget = nativeDefaults['thinking_token_budget'];
    final outputConfig = body['output_config'];
    final requestedEffort =
        outputConfig is Map && outputConfig.containsKey('effort');
    if (budget == 0 || effort == 'none' && !requestedEffort) {
      body['thinking'] = {'type': 'disabled'};
    } else if (budget is int && budget >= 1024 ||
        effort != null && effort != 'none') {
      body['thinking'] = budget is int && budget >= 1024
          ? {'type': 'enabled', 'budget_tokens': budget}
          : {'type': 'adaptive'};
      if (const {'low', 'medium', 'high', 'xhigh', 'max'}.contains(effort) &&
          !requestedEffort &&
          (outputConfig == null || outputConfig is Map)) {
        body['output_config'] = {
          if (outputConfig is Map) ...outputConfig,
          'effort': effort,
        };
      }
    }
  }
  final defaultFormat = nativeDefaults['response_format'];
  final containerKey = responses ? 'text' : 'output_config';
  final container = body[containerKey];
  if (container != null && container is! Map) {
    throw FormatException('$containerKey 需要是对象');
  }
  final legacyFormat = responses ? null : body['output_format'];
  var format = container is Map ? container['format'] : null;
  if (format != null && legacyFormat != null) {
    throw const FormatException('output_config.format 和 output_format 不能同时使用');
  }
  format ??= legacyFormat;
  if (format == null &&
      defaultFormat is Map &&
      defaultFormat['type'] != 'text' &&
      !body.containsKey('response_format') &&
      !extra.containsKey('response_format') &&
      !body.containsKey('output_format') &&
      (!body.containsKey(containerKey) ||
          container is Map && !container.containsKey('format'))) {
    final schema = defaultFormat['json_schema'];
    format = {
      'type': responses ? defaultFormat['type'] : 'json_schema',
      if (schema is Map)
        ...schema
      else if (!responses)
        'schema': {'type': 'object'},
    };
    body[containerKey] = {if (container is Map) ...container, 'format': format};
  }
  // b12110 converts the request to Chat, but leaves these two schema fields
  // untranslated. Give its Chat parser the constraint in the form it reads.
  if (!splash && format != null) {
    if (format is! Map) throw const FormatException('输出格式需要是对象');
    final type = format['type'];
    if (type == 'json_schema') {
      final schema = format['schema'];
      if (schema is! Map && schema is! bool) {
        throw const FormatException('json_schema 需要提供 schema');
      }
      extra['response_format'] = {
        'type': 'json_schema',
        'json_schema': {
          for (final entry in format.entries)
            if (entry.key != 'type') entry.key: entry.value,
        },
      };
    } else if (responses && type == 'json_object') {
      extra['response_format'] = {'type': 'json_object'};
    } else if (!responses || type != 'text') {
      throw const FormatException('不支持的输出格式');
    }
  }
  if (extra.isNotEmpty) body['extra_params'] = extra;
  return body;
}

/// Bound both complete JSON replies and streams, as the existing Chat reader does.
Stream<String> nativeTextChunks(HttpClientResponse response) {
  var size = 0;
  return response
      .map((chunk) {
        size += chunk.length;
        if (size > 4 * 1024 * 1024) {
          throw const NativeTextFailure(DecisionFailureKind.invalidResponse);
        }
        return chunk;
      })
      .transform(utf8.decoder);
}

Map<String, Object?> nativeTextReply(
  String raw,
  String model,
  String Function(String) redact, {
  bool error = false,
  String? previousResponseId,
}) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('上游协议响应需要是 JSON 对象');
  }
  if (decoded['model'] is String) decoded['model'] = model;
  if (previousResponseId != null && decoded['object'] == 'response') {
    decoded['previous_response_id'] = previousResponseId;
  }
  for (final key in ['response', 'message']) {
    final item = decoded[key];
    if (item is Map<String, Object?> && item['model'] is String) {
      item['model'] = model;
      if (key == 'response' && previousResponseId != null) {
        item['previous_response_id'] = previousResponseId;
      }
    }
  }
  Object? safe(Object? value) => switch (value) {
    String text => redact(text),
    List items => items.map(safe).toList(),
    Map fields => {
      for (final entry in fields.entries)
        redact(entry.key as String): safe(entry.value),
    },
    _ => value,
  };
  if (error || decoded['type'] == 'error') {
    return safe(decoded) as Map<String, Object?>;
  }
  if (decoded['error'] != null) decoded['error'] = safe(decoded['error']);
  final response = decoded['response'];
  if (response is Map && response['error'] != null) {
    response['error'] = safe(response['error']);
  }
  return decoded;
}

Stream<({String wire, bool terminal, Map<String, Object?>? response})>
nativeTextEvents(
  Stream<String> chunks,
  String model,
  String Function(String) redact, {
  required NativeTextEndpoint endpoint,
  String? previousResponseId,
}) async* {
  final fields = <String>[];
  final data = <String>[];
  await for (final line in chunks.transform(const LineSplitter())) {
    if (line.isEmpty) {
      final raw = data.join('\n');
      var terminal = false;
      Map<String, Object?>? response;
      if (raw == '[DONE]') {
        fields.add('data: [DONE]');
      } else if (raw.isNotEmpty) {
        final value = nativeTextReply(
          raw,
          model,
          redact,
          previousResponseId: previousResponseId,
        );
        terminal = const {
          'response.completed',
          'response.incomplete',
          'message_stop',
        }.contains(value['type']);
        if (terminal && endpoint == NativeTextEndpoint.responses) {
          final item = value['response'];
          if (item is Map<String, Object?>) response = item;
        }
        final choices = value['choices'];
        if (endpoint == NativeTextEndpoint.chat && choices is List) {
          terminal = choices.any(
            (choice) => choice is Map && choice['finish_reason'] is String,
          );
        }
        fields.add('data: ${jsonEncode(value)}');
      }
      if (fields.isNotEmpty) {
        yield (
          wire: '${fields.join('\n')}\n\n',
          terminal: terminal,
          response: response,
        );
      }
      fields.clear();
      data.clear();
    } else if (line == 'data' || line.startsWith('data:')) {
      final value = line == 'data' ? '' : line.substring(5);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    } else {
      fields.add(line);
    }
  }
  if (fields.isNotEmpty || data.isNotEmpty) {
    throw const FormatException('上游事件未完整结束');
  }
}
