import 'dart:convert';
import 'dart:math' as math;

/// Text-only OpenAI-compatible embedding input. Model limits belong to engines.
class EmbeddingRequest {
  EmbeddingRequest._({
    required this.model,
    required List<String> input,
    required this.singleInput,
    this.dimensions,
  }) : input = List.unmodifiable(input);

  factory EmbeddingRequest.fromJson(Map<String, Object?> value) {
    final model = value['model'];
    final rawInput = value['input'];
    final dimensions = value['dimensions'];
    if (model is! String || model.trim().isEmpty) {
      throw const EmbeddingProtocolException('model 需要非空公开模型标识');
    }
    final input = <String>[];
    if (rawInput is String) {
      input.add(rawInput);
    } else if (rawInput is List && rawInput.every((value) => value is String)) {
      input.addAll(rawInput.cast<String>());
    } else {
      throw const EmbeddingProtocolException('input 仅支持文本或文本数组');
    }
    if (input.isEmpty || input.any((value) => value.trim().isEmpty)) {
      throw const EmbeddingProtocolException('input 需要至少一条非空文本');
    }
    if (value.containsKey('encoding_format') &&
        value['encoding_format'] != 'float') {
      throw const EmbeddingProtocolException('encoding_format 仅支持 float');
    }
    if (value.containsKey('dimensions') &&
        (dimensions is! int || dimensions <= 0)) {
      throw const EmbeddingProtocolException('dimensions 需要正整数');
    }
    const fields = {'model', 'input', 'encoding_format', 'dimensions'};
    if (value.keys.any((key) => !fields.contains(key))) {
      throw const EmbeddingProtocolException('嵌入请求包含不支持的字段');
    }
    return EmbeddingRequest._(
      model: model,
      input: input,
      singleInput: rawInput is String,
      dimensions: dimensions as int?,
    );
  }

  final String model;
  final List<String> input;
  final bool singleInput;
  final int? dimensions;
  String get encodingFormat => 'float';

  Map<String, Object?> toJson({String? model}) => {
    'model': model ?? this.model,
    'input': singleInput ? input.single : input,
    'encoding_format': 'float',
    if (dimensions != null) 'dimensions': dimensions,
  };
}

class EmbeddingResult {
  EmbeddingResult._({
    required this.model,
    required List<List<double>> vectors,
    required Map<String, Object?> usage,
    required this.rawResponse,
  }) : vectors = List.unmodifiable(vectors.map(List<double>.unmodifiable)),
       usage = Map.unmodifiable(usage);

  static EmbeddingResult parse(
    String raw, {
    required EmbeddingRequest request,
    String? expectedModel,
  }) {
    final model = expectedModel ?? request.model;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const EmbeddingProtocolException('嵌入响应不是有效 JSON');
    }
    if (decoded is! Map || decoded['model'] != model) {
      throw const EmbeddingProtocolException('嵌入响应无法绑定到所选实例');
    }
    final data = decoded['data'];
    final usage = decoded['usage'];
    if (data is! List || data.length != request.input.length || usage is! Map) {
      throw const EmbeddingProtocolException('响应需要每条输入的向量与实际用量');
    }
    final promptTokens = usage['prompt_tokens'];
    final totalTokens = usage['total_tokens'];
    if (promptTokens is! int ||
        promptTokens < 0 ||
        totalTokens is! int ||
        totalTokens < promptTokens) {
      throw const EmbeddingProtocolException('嵌入响应用量无效');
    }
    final vectors = List<List<double>?>.filled(data.length, null);
    int? dimensions;
    for (final row in data) {
      if (row is! Map) throw const EmbeddingProtocolException('嵌入响应条目无效');
      final index = row['index'];
      final embedding = row['embedding'];
      if (index is! int ||
          index < 0 ||
          index >= vectors.length ||
          vectors[index] != null ||
          embedding is! List ||
          embedding.isEmpty ||
          embedding.any((value) => value is! num || !value.isFinite)) {
        throw const EmbeddingProtocolException('嵌入响应索引或向量无效');
      }
      dimensions ??= embedding.length;
      if (embedding.length != dimensions ||
          (request.dimensions != null &&
              embedding.length != request.dimensions)) {
        throw const EmbeddingProtocolException('嵌入响应维度与批次或请求不一致');
      }
      vectors[index] = embedding
          .map((value) => (value as num).toDouble())
          .toList();
    }
    return EmbeddingResult._(
      model: model,
      vectors: vectors.cast<List<double>>(),
      usage: Map<String, Object?>.from(usage),
      rawResponse: raw,
    );
  }

  final String model;
  final List<List<double>> vectors;
  final Map<String, Object?> usage;
  final String rawResponse;
  int get dimensions => vectors.first.length;

  /// Scaled arithmetic avoids overflow for finite, unnormalized engine vectors.
  double norm(int index) {
    final vector = vectors[index];
    final scale = vector.fold(
      0.0,
      (value, coordinate) => math.max(value, coordinate.abs()),
    );
    if (scale == 0) return 0;
    return scale *
        math.sqrt(
          vector.fold(0.0, (sum, value) {
            final normalized = value / scale;
            return sum + normalized * normalized;
          }),
        );
  }

  double? cosineSimilarity(int first, int second) {
    final a = vectors[first];
    final b = vectors[second];
    final scaleA = a.fold(0.0, (scale, value) => math.max(scale, value.abs()));
    final scaleB = b.fold(0.0, (scale, value) => math.max(scale, value.abs()));
    if (scaleA == 0 || scaleB == 0) return null;
    var dot = 0.0;
    var squareA = 0.0;
    var squareB = 0.0;
    for (var index = 0; index < a.length; index++) {
      final x = a[index] / scaleA;
      final y = b[index] / scaleB;
      dot += x * y;
      squareA += x * x;
      squareB += y * y;
    }
    return (dot / math.sqrt(squareA * squareB)).clamp(-1.0, 1.0);
  }

  Map<String, Object?> toJson() => {
    'object': 'list',
    'model': model,
    'data': [
      for (var index = 0; index < vectors.length; index++)
        {'object': 'embedding', 'index': index, 'embedding': vectors[index]},
    ],
    'usage': usage,
  };
}

class EmbeddingProtocolException implements Exception {
  const EmbeddingProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}
