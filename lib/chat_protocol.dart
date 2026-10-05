import 'dart:convert';

/// Single-turn text, optionally streamed. Never implicitly loads a model.
class TextRequest {
  TextRequest({required this.prompt, this.maxTokens = 32}) {
    if (prompt.trim().isEmpty || maxTokens < 1 || maxTokens > 4096) {
      throw const TextProtocolException('需要非空文本与 1–4096 个生成 token 上限');
    }
  }
  final String prompt;
  final int maxTokens;

  Map<String, Object> toChat({required String model, bool stream = false}) => {
    'model': model,
    'messages': [
      {'role': 'user', 'content': prompt},
    ],
    'stream': stream,
    if (stream) 'stream_options': {'include_usage': true},
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

/// A delta is provisional; only a terminal result represents completed work.
class TextStreamEvent {
  const TextStreamEvent.delta(this.delta) : result = null;
  const TextStreamEvent.complete(this.result) : delta = '';
  final String delta;
  final TextResult? result;
}

/// Production incremental codec. Each SSE data event must bind to the alias.
class TextStreamDecoder {
  TextStreamDecoder({required this.expectedModel});
  final String expectedModel;
  final _text = StringBuffer();
  final _raw = StringBuffer();
  String? _finish;
  int? _tokens;
  bool _done = false;
  String get rawResponse => _raw.toString();

  TextStreamEvent? add(String data) {
    if (_done) throw const TextProtocolException('文本流在 DONE 后仍有数据');
    _raw.writeln('data: $data\n');
    if (data.trim() == '[DONE]') {
      if (_finish == null ||
          _tokens == null ||
          _text.toString().trim().isEmpty) {
        throw const TextProtocolException('文本流缺少实际生成、结束原因或用量');
      }
      _done = true;
      return null;
    }
    final dynamic value;
    try {
      value = jsonDecode(data);
    } on FormatException {
      throw const TextProtocolException('文本流数据不是有效 JSON');
    }
    if (value is! Map || value['model'] != expectedModel) {
      throw const TextProtocolException('文本流响应无法绑定到所选实例');
    }
    final choices = value['choices'];
    if (choices is! List || choices.length > 1) {
      throw const TextProtocolException('文本流需要单个生成结果');
    }
    String? content;
    if (choices.isNotEmpty) {
      final choice = choices.single;
      if (choice is! Map ||
          choice['index'] != 0 ||
          choice['delta'] is! Map ||
          _finish != null) {
        throw const TextProtocolException('文本流生成帧不合法或重复结束');
      }
      final delta = choice['delta'] as Map;
      final role = delta['role'];
      final text = delta['content'];
      if ((role != null && role != 'assistant') ||
          (text != null && text is! String)) {
        throw const TextProtocolException('文本流不是 assistant 文本');
      }
      content = text as String?;
      final finish = choice['finish_reason'];
      if (finish != null) {
        if (!['stop', 'length'].contains(finish)) {
          throw const TextProtocolException('文本流结束原因不合法');
        }
        _finish = finish as String;
      }
      if (content != null) _text.write(content);
    }
    final usage = value['usage'];
    if (usage != null) {
      if (usage is! Map ||
          usage['completion_tokens'] is! int ||
          (usage['completion_tokens'] as int) <= 0 ||
          _tokens != null ||
          _finish == null) {
        throw const TextProtocolException('文本流缺少正整数实际用量或重复用量');
      }
      _tokens = usage['completion_tokens'] as int;
    } else if (choices.isEmpty) {
      throw const TextProtocolException('文本流空结果帧缺少实际用量');
    }
    return content == null || content.isEmpty
        ? null
        : TextStreamEvent.delta(content);
  }

  TextResult finish() {
    if (!_done) throw const TextProtocolException('文本流未完整结束，缺少上游 DONE');
    return TextResult._(
      model: expectedModel,
      text: _text.toString(),
      finishReason: _finish!,
      outputTokens: _tokens!,
      rawResponse: rawResponse,
    );
  }
}

class TextProtocolException implements Exception {
  const TextProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}
