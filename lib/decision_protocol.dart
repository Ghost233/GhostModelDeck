import 'dart:convert';

/// The tolerance admits floating point softmax rounding, not arbitrary scores.
const decisionProbabilitySumTolerance = 0.0001;

class DecisionRequest {
  DecisionRequest({
    required this.state,
    required this.instructions,
    required Map<String, String> options,
  }) : options = Map.unmodifiable(options) {
    if (options.length < 2 ||
        options.length > 255 ||
        options.entries.any(
          (entry) => entry.key.trim().isEmpty || entry.value.trim().isEmpty,
        ) ||
        instructions.trim().isEmpty) {
      throw const DecisionProtocolException('需要问题与 2–255 个有效候选项');
    }
  }
  final String state;
  final String instructions;
  final Map<String, String> options;

  Map<String, Object> toSystemone({String? model}) => {
    'model': ?model,
    'state': state,
    'questions': {
      'council_choice': {
        'type': 'choice',
        'instructions': instructions,
        'criteria': options,
      },
    },
  };
}

class DecisionResult {
  DecisionResult._({
    required this.model,
    required this.choice,
    required Map<String, double> probabilities,
    required this.rawResponse,
    required this.elapsed,
  }) : probabilities = Map.unmodifiable(probabilities);
  final String model;
  final String choice;
  final Map<String, double> probabilities;
  final String rawResponse;
  final Duration elapsed;

  static DecisionResult parse(
    String raw,
    DecisionRequest request, {
    required String expectedModel,
    Duration elapsed = Duration.zero,
  }) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['model'] != expectedModel) {
        throw const DecisionProtocolException('响应无法绑定到所选实例');
      }
      final answers = value['answers'];
      final answer = answers is Map ? answers['council_choice'] : null;
      final usage = value['usage'];
      if (answer is! Map ||
          answer['type'] != 'choice' ||
          usage is! Map ||
          usage['output_tokens'] != 0) {
        throw const DecisionProtocolException('响应不是零生成 token 的 typed choice');
      }
      final rawProbabilities = answer['probabilities'];
      if (rawProbabilities is! Map ||
          rawProbabilities.length != request.options.length ||
          rawProbabilities.keys.any(
            (key) => !request.options.containsKey(key),
          )) {
        throw const DecisionProtocolException('响应候选 ID 与请求不一致');
      }
      final probabilities = <String, double>{};
      for (final id in request.options.keys) {
        final number = rawProbabilities[id];
        if (number is! num || !number.isFinite || number < 0 || number > 1) {
          throw const DecisionProtocolException('响应概率无效');
        }
        probabilities[id] = number.toDouble();
      }
      final sum = probabilities.values.fold(0.0, (a, b) => a + b);
      if ((sum - 1).abs() > decisionProbabilitySumTolerance) {
        throw const DecisionProtocolException('响应概率未归一化');
      }
      final choice = answer['choice'];
      if (choice is! String || !request.options.containsKey(choice)) {
        throw const DecisionProtocolException('响应选择不在候选项中');
      }
      return DecisionResult._(
        model: expectedModel,
        choice: choice,
        probabilities: probabilities,
        rawResponse: raw,
        elapsed: elapsed,
      );
    } on FormatException {
      throw const DecisionProtocolException('决策响应不是有效 JSON');
    }
  }
}

class DecisionProtocolException implements Exception {
  const DecisionProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}
