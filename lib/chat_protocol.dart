import 'dart:convert';

/// Deliberately limited to non-streaming, single-turn text. No implicit loading.
class TextRequest {
  TextRequest({required this.prompt, this.maxTokens = 32}) {
    if (prompt.trim().isEmpty || maxTokens < 1 || maxTokens > 4096) {
      throw const TextProtocolException('需要非空文本与 1–4096 个生成 token 上限');
    }
  }
  final String prompt;
  final int maxTokens;

  Map<String, Object> toChat({required String model}) => {
    'model': model,
    'messages': [
      {'role': 'user', 'content': prompt},
    ],
    'stream': false,
    'temperature': 0,
    'max_tokens': maxTokens,
  };
}

class TextResult {
  const TextResult._({
    required this.model,
    required this.text,
    required this.finishReason,
    required this.outputTokens,
    required this.rawResponse,
  });
  final String model;
  final String text;
  final String finishReason;
  final int outputTokens;
  final String rawResponse;

  static TextResult parse(String raw, {required String expectedModel}) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['model'] != expectedModel) {
        throw const TextProtocolException('文本响应无法绑定到所选实例');
      }
      final choices = value['choices'];
      final usage = value['usage'];
      if (choices is! List ||
          choices.length != 1 ||
          choices.single is! Map ||
          usage is! Map) {
        throw const TextProtocolException('文本响应需要单个生成结果与实际用量');
      }
      final choice = choices.single as Map;
      final message = choice['message'];
      final finish = choice['finish_reason'];
      final tokens = usage['completion_tokens'];
      if (choice['index'] != 0 ||
          message is! Map ||
          message['role'] != 'assistant' ||
          message['content'] is! String ||
          (message['content'] as String).trim().isEmpty ||
          !['stop', 'length'].contains(finish) ||
          tokens is! int ||
          tokens <= 0) {
        throw const TextProtocolException('响应不是已完成的非空文本生成');
      }
      return TextResult._(
        model: expectedModel,
        text: message['content'] as String,
        finishReason: finish as String,
        outputTokens: tokens,
        rawResponse: raw,
      );
    } on FormatException {
      throw const TextProtocolException('文本响应不是有效 JSON');
    }
  }
}

class TextProtocolException implements Exception {
  const TextProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}
