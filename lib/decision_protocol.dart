import 'dart:collection';
import 'dart:convert';

/// The tolerance admits floating point softmax rounding, not arbitrary scores.
const decisionProbabilitySumTolerance = 0.0001;

class DecisionRequest {
  DecisionRequest({
    required Object state,
    required Object instructions,
    required Map<String, Object?> options,
  }) : state = _jsonSnapshot(state)!,
       instructions = _jsonSnapshot(instructions)!,
       options = _jsonSnapshot(options) as Map<String, Object?> {
    _validateOptions(this.options);
  }
  final Object state;
  final Object instructions;
  final Map<String, Object?> options;

  Map<String, Object?> toSystemone({String? model}) => {
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

/// Application resource limits, not model context or upstream limits.
const decisionMaxResponseBytes = 1024 * 1024;
const decisionMaxRequestBytes = 256 * 1024;
const decisionMaxQuestions = 32;

enum DecisionPrimitive { choice, score, noul }

sealed class DecisionQuestion {
  DecisionQuestion({required Object instructions})
    : instructions = _jsonSnapshot(instructions)!;
  final Object instructions;
  DecisionPrimitive get type;
  Map<String, Object?> toJson();
}

final class ChoiceQuestion extends DecisionQuestion {
  ChoiceQuestion({
    required super.instructions,
    required Map<String, Object?> options,
  }) : options = _jsonSnapshot(options) as Map<String, Object?> {
    _validateOptions(this.options);
  }
  final Map<String, Object?> options;
  @override
  DecisionPrimitive get type => DecisionPrimitive.choice;
  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'instructions': instructions,
    'criteria': options,
  };
}

final class ScoreQuestion extends DecisionQuestion {
  ScoreQuestion({required super.instructions, required List<Object?> levels})
    : levels = _jsonSnapshot(levels) as List<Object?> {
    if (levels.length < 2 || levels.length > 10) {
      throw const DecisionProtocolException('score 需要 2–10 个有序级别');
    }
  }
  final List<Object?> levels;
  Map<String, Object?> get legend => Map.unmodifiable({
    for (var i = 0; i < levels.length; i++) '$i': levels[i],
  });
  @override
  DecisionPrimitive get type => DecisionPrimitive.score;
  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'instructions': instructions,
    'criteria': levels,
  };
}

final class NoulQuestion extends DecisionQuestion {
  NoulQuestion({
    required Object instructions,
    required Object? falseText,
    required Object? trueText,
  }) : this.fromCriteria(
         instructions: instructions,
         criteria: {'false': falseText, 'true': trueText},
         hasCriteria: true,
       );

  NoulQuestion.fromCriteria({
    required super.instructions,
    Object? criteria,
    required this.hasCriteria,
  }) : criteria = _jsonSnapshot(criteria) {
    if (!hasCriteria && criteria != null) {
      throw const DecisionProtocolException('未提供 noul criteria 时不能携带描述');
    }
    if (criteria != null && criteria is! Map) {
      throw const DecisionProtocolException('noul criteria 需要是对象或 null');
    }
  }
  final bool hasCriteria;
  final Object? criteria;
  Object? get falseText => criteria is Map ? (criteria as Map)['false'] : null;
  Object? get trueText => criteria is Map ? (criteria as Map)['true'] : null;
  @override
  DecisionPrimitive get type => DecisionPrimitive.noul;
  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'instructions': instructions,
    if (hasCriteria) 'criteria': criteria,
  };
}

class DecisionBatchRequest {
  DecisionBatchRequest({
    required Object state,
    required Map<String, DecisionQuestion> questions,
    Map<String, Object?> extensions = const {},
    bool stream = false,
  }) : state = _jsonSnapshot(state)!,
       questions = Map.unmodifiable(questions),
       extensions = _jsonSnapshot(extensions) as Map<String, Object?> {
    if (stream) throw const DecisionProtocolException('typed 决策不支持 streaming');
    if (questions.isEmpty ||
        questions.length > decisionMaxQuestions ||
        questions.keys.any((id) => id.trim().isEmpty)) {
      throw const DecisionProtocolException('需要 1–32 个有效问题 ID');
    }
    for (final field in extensions.keys) {
      if (field != 'images') {
        throw DecisionProtocolException('包含不支持的字段：$field');
      }
    }
    final images = extensions['images'];
    if (images != null && (images is! List || images.isNotEmpty)) {
      throw const DecisionProtocolException('当前 JEV 输入仅支持 images 为 null 或空数组');
    }
    if (utf8.encode(jsonEncode(toSystemone())).length >
        decisionMaxRequestBytes) {
      throw const DecisionProtocolException('typed 请求超出字节上限');
    }
  }
  final Object state;
  final Map<String, DecisionQuestion> questions;
  final Map<String, Object?> extensions;
  Map<String, Object?> toSystemone({String? model}) => {
    'model': ?model,
    'state': state,
    'questions': {for (final q in questions.entries) q.key: q.value.toJson()},
    ...extensions,
  };
}

sealed class DecisionAnswer {
  const DecisionAnswer();
  DecisionPrimitive get type;
  Map<String, Object> toJson();
}

final class ChoiceAnswer extends DecisionAnswer {
  ChoiceAnswer._(
    this.choice,
    Map<String, double> probabilities,
    this.confidence,
  ) : probabilities = Map.unmodifiable(probabilities);
  final String choice;
  final Map<String, double> probabilities;
  final double confidence;
  @override
  DecisionPrimitive get type => DecisionPrimitive.choice;
  @override
  Map<String, Object> toJson() => {
    'type': type.name,
    'choice': choice,
    'probabilities': probabilities,
    'confidence': confidence,
  };
}

final class ScoreAnswer extends DecisionAnswer {
  ScoreAnswer._(
    this.score,
    Map<String, Object?> legend,
    Map<String, double> probabilities,
    this.confidence,
  ) : legend = _jsonSnapshot(legend) as Map<String, Object?>,
      probabilities = Map.unmodifiable(probabilities);
  final double score;
  final Map<String, Object?> legend;
  final Map<String, double> probabilities;
  final double confidence;
  @override
  DecisionPrimitive get type => DecisionPrimitive.score;
  @override
  Map<String, Object> toJson() => {
    'type': type.name,
    'score': score,
    'legend': legend,
    'probabilities': probabilities,
    'confidence': confidence,
  };
}

final class NoulAnswer extends DecisionAnswer {
  const NoulAnswer._(this.noul);
  final double noul;
  @override
  DecisionPrimitive get type => DecisionPrimitive.noul;
  @override
  Map<String, Object> toJson() => {'type': type.name, 'noul': noul};
}

class DecisionBatchResult {
  DecisionBatchResult._({
    required this.model,
    required Map<String, DecisionAnswer> answers,
    required this.inputTokens,
    required this.rawResponse,
    required this.elapsed,
  }) : answers = Map.unmodifiable(answers);
  final String model;
  final Map<String, DecisionAnswer> answers;
  final int inputTokens;
  final String rawResponse;
  final Duration elapsed;

  Map<String, Object> toJson({String? publicModel}) => {
    'model': publicModel ?? model,
    'answers': {for (final a in answers.entries) a.key: a.value.toJson()},
    'usage': {'input_tokens': inputTokens, 'output_tokens': 0},
  };

  static DecisionBatchResult parse(
    String raw,
    DecisionBatchRequest request, {
    required String expectedModel,
    Duration elapsed = Duration.zero,
  }) {
    if (utf8.encode(raw).length > decisionMaxResponseBytes) {
      throw const DecisionProtocolException('typed 响应超出字节上限');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['model'] != expectedModel) {
        throw const DecisionProtocolException('响应无法绑定到所选实例');
      }
      final usage = value['usage'];
      final answers = value['answers'];
      if (usage is! Map ||
          usage['output_tokens'] is! int ||
          usage['output_tokens'] != 0 ||
          usage['input_tokens'] is! int ||
          (usage['input_tokens'] as int) < 0) {
        throw const DecisionProtocolException('响应不是零生成 token 的 typed 判断');
      }
      if (answers is! Map ||
          answers.length != request.questions.length ||
          answers.keys.any((id) => !request.questions.containsKey(id))) {
        throw const DecisionProtocolException('响应问题 ID 与请求不一致');
      }
      final parsed = <String, DecisionAnswer>{};
      for (final entry in request.questions.entries) {
        final answer = answers[entry.key];
        final question = entry.value;
        if (answer is! Map || answer['type'] != question.type.name) {
          throw const DecisionProtocolException('响应题型与请求不一致');
        }
        if (question is NoulQuestion) {
          if (answer.length != 2 || !answer.containsKey('noul')) {
            throw const DecisionProtocolException('noul 只能返回 scalar');
          }
          parsed[entry.key] = NoulAnswer._(_finite(answer['noul'], 1));
        } else if (question is ChoiceQuestion) {
          final probabilities = _distribution(
            answer['probabilities'],
            question.options.keys,
          );
          final choice = answer['choice'];
          if (choice is! String ||
              !probabilities.containsKey(choice) ||
              probabilities.values.any(
                (p) => p > probabilities[choice]! + 1e-12,
              )) {
            throw const DecisionProtocolException('响应选择不是最高概率候选');
          }
          parsed[entry.key] = ChoiceAnswer._(
            choice,
            probabilities,
            _finite(answer['confidence'], 1),
          );
        } else if (question is ScoreQuestion) {
          final legend = answer['legend'];
          if (legend is! Map ||
              legend.length != question.levels.length ||
              !_jsonEqual(legend, question.legend)) {
            throw const DecisionProtocolException('score legend 与有序级别不一致');
          }
          final probabilities = _distribution(
            answer['probabilities'],
            question.legend.keys,
          );
          final score = _finite(answer['score'], question.levels.length - 1);
          final expected = ordinalExpectation(probabilities);
          if ((score - expected).abs() > decisionProbabilitySumTolerance) {
            throw const DecisionProtocolException('score 不是概率期望索引');
          }
          parsed[entry.key] = ScoreAnswer._(
            score,
            Map<String, Object?>.from(legend),
            probabilities,
            _finite(answer['confidence'], 1),
          );
        }
      }
      return DecisionBatchResult._(
        model: expectedModel,
        answers: parsed,
        inputTokens: usage['input_tokens'] as int,
        rawResponse: raw,
        elapsed: elapsed,
      );
    } on FormatException {
      throw const DecisionProtocolException('决策响应不是有效 JSON');
    }
  }
}

/// Computes an ordinal index, never a normalized score or modal level.
double ordinalExpectation(Map<String, double> probabilities) => probabilities
    .entries
    .fold(0.0, (sum, entry) => sum + int.parse(entry.key) * entry.value);

double _finite(Object? value, num maximum) {
  if (value is! num || !value.isFinite || value < 0 || value > maximum) {
    throw const DecisionProtocolException('响应数值无效');
  }
  return value.toDouble();
}

Map<String, double> _distribution(Object? value, Iterable<String> ids) {
  if (value is! Map ||
      value.length != ids.length ||
      value.keys.any((id) => !ids.contains(id))) {
    throw const DecisionProtocolException('响应候选 ID 与请求不一致');
  }
  final result = {for (final id in ids) id: _finite(value[id], 1)};
  if ((result.values.fold(0.0, (a, b) => a + b) - 1).abs() >
      decisionProbabilitySumTolerance) {
    throw const DecisionProtocolException('响应概率未归一化');
  }
  return result;
}

class DecisionProtocolException implements Exception {
  const DecisionProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

void _validateOptions(Map<String, Object?> options) {
  if (options.isEmpty ||
      options.length > 255 ||
      options.keys.any((id) => id.trim().isEmpty)) {
    throw const DecisionProtocolException('choice 需要 1–255 个有效候选 ID');
  }
}

// Copy and freeze at DTO construction, before any asynchronous admission work.
Object? _jsonSnapshot(Object? value, [Set<Object>? active]) {
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  final parents = active ?? HashSet<Object>.identity();
  if (value is! List && value is! Map || !parents.add(value)) {
    throw const DecisionProtocolException('输入包含非 JSON 值或循环引用');
  }
  try {
    if (value is List) {
      return List<Object?>.unmodifiable([
        for (final item in value) _jsonSnapshot(item, parents),
      ]);
    }
    final map = value as Map;
    if (map.keys.any((key) => key is! String)) {
      throw const DecisionProtocolException('JSON 对象键需要是字符串');
    }
    return Map<String, Object?>.unmodifiable({
      for (final entry in map.entries)
        entry.key as String: _jsonSnapshot(entry.value, parents),
    });
  } finally {
    parents.remove(value);
  }
}

bool _jsonEqual(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _jsonEqual(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_jsonEqual(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
