import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'benchmark_resources.dart';

class DecideBenchItem {
  const DecideBenchItem({
    required this.id,
    required this.pairId,
    required this.category,
    required this.difficulty,
    required this.state,
    required this.question,
    required this.options,
    required this.gold,
    this.examples = const {},
  });

  final String id;
  final String pairId;
  final String category;
  final String difficulty;
  final String state;
  final String question;
  final Map<String, String> options;
  final String gold;
  final Map<String, String> examples;

  Map<String, Object?> request(String publicModel) => {
    'model': publicModel,
    'state': state,
    'questions': {
      'decision': {
        'type': 'choice',
        'instructions': question,
        'criteria': {
          for (final option in options.entries)
            option.key: {
              'what': option.value,
              'examples': [examples[option.key]],
            },
        },
      },
    },
  };
  String? extractChoice(Object? response) {
    final answer = _answer(response);
    final choice = answer?['choice'];
    return choice is String && options.containsKey(choice) ? choice : null;
  }

  Map<String, double>? extractProbabilities(Object? response) {
    final raw = _answer(response)?['probabilities'];
    if (raw is! Map || raw.length != options.length) return null;
    final distribution = <String, double>{};
    for (final option in options.keys) {
      final value = raw[option];
      if (value is! num || !value.isFinite || value < 0 || value > 1) {
        return null;
      }
      distribution[option] = value.toDouble();
    }
    final total = distribution.values.fold(0.0, (sum, value) => sum + value);
    if ((total - 1).abs() > 1e-6) return null;
    return Map.unmodifiable(distribution);
  }

  Map<String, Object?>? _answer(Object? response) {
    if (response is! Map<String, Object?>) return null;
    final answers = response['answers'];
    if (answers is! Map<String, Object?>) return null;
    final decision = answers['decision'];
    return decision is Map<String, Object?> ? decision : null;
  }
}

class DecideBenchScore {
  const DecideBenchScore({
    required this.attempted,
    required this.missing,
    required this.correct,
    required this.pairsCorrect,
    required this.unusable,
    required this.complete,
    this.accuracy,
    this.pairAccuracy,
    this.brier,
    this.ece,
  });

  final int attempted;
  final int missing;
  final int correct;
  final int pairsCorrect;
  final int unusable;
  final bool complete;
  final double? accuracy;
  final double? pairAccuracy;
  final double? brier;
  final double? ece;
}

class DecideBenchSuite {
  DecideBenchSuite._(List<DecideBenchItem> items)
    : items = List.unmodifiable(items);

  final List<DecideBenchItem> items;
  Map<String, Object?> get identity => BenchmarkResources.identity;

  static Future<DecideBenchSuite> load(Directory checkedCache) async {
    // A supported pin means exact source bytes, including the original notices.
    for (final file in BenchmarkResources.files) {
      final bytes = await File('${checkedCache.path}/${file.path}')
          .readAsBytes();
      if (bytes.length != file.bytes ||
          sha256.convert(bytes).toString() != file.sha256) {
        throw FormatException('DecideBench resource mismatch: ${file.path}');
      }
    }
    final questions = <_SourceItem>[];
    final examples = <_SourceItem>[];
    for (final resource in BenchmarkResources.files) {
      if (!resource.path.endsWith('.jsonl')) continue;
      final content = await File('${checkedCache.path}/${resource.path}')
          .readAsString();
      final target = resource.path.contains('/examples/')
          ? examples
          : questions;
      for (final line in const LineSplitter().convert(content)) {
        if (line.trim().isEmpty) continue;
        target.add(_SourceItem.parse(jsonDecode(line), target == examples));
      }
    }
    if (questions.length != 400 || examples.length != 297) {
      throw const FormatException(
        'DecideBench requires all 400 items and 297 examples',
      );
    }
    final pairs = <String, List<_SourceItem>>{};
    final templates = <String, List<_SourceItem>>{};
    final ids = <String>{};
    for (final item in questions) {
      if (!ids.add(item.id) ||
          !['${item.groupId}a', '${item.groupId}b'].contains(item.id)) {
        throw const FormatException('Invalid DecideBench item identity');
      }
      pairs.putIfAbsent(item.groupId, () => []).add(item);
      templates.putIfAbsent(item.templateKey, () => []).add(item);
    }
    if (pairs.length != 200 || templates.length != 63) {
      throw const FormatException('Incomplete DecideBench pairs or templates');
    }
    for (final pair in pairs.values) {
      if (pair.length != 2 ||
          pair[0].templateKey != pair[1].templateKey ||
          pair[0].state == pair[1].state ||
          pair[0].gold == pair[1].gold) {
        throw const FormatException('Invalid DecideBench contrastive pair');
      }
    }
    final pool = <String, Map<String, String>>{};
    final states = questions.map((item) => item.state).toSet();
    for (final example in examples) {
      if (!templates.containsKey(example.templateKey) ||
          states.contains(example.state) ||
          example.id != '${example.groupId}-${example.gold}') {
        throw const FormatException('Invalid DecideBench worked example');
      }
      final byGold = pool.putIfAbsent(example.templateKey, () => {});
      if (byGold.containsKey(example.gold)) {
        throw const FormatException('Duplicate DecideBench worked example');
      }
      byGold[example.gold] = example.state;
    }
    final items = <DecideBenchItem>[];
    for (final item in questions) {
      final shots = pool[item.templateKey];
      if (shots == null ||
          shots.length != item.options.length ||
          !shots.keys.every(item.options.containsKey)) {
        throw const FormatException('Incomplete DecideBench worked examples');
      }
      items.add(
        DecideBenchItem(
          id: item.id,
          pairId: item.groupId,
          category: item.category,
          difficulty: item.difficulty,
          state: item.state,
          question: item.question,
          options: Map.unmodifiable(item.options),
          gold: item.gold,
          examples: Map.unmodifiable(shots),
        ),
      );
    }
    return DecideBenchSuite._(items);
  }

  DecideBenchScore score(
    Map<String, String?> predictions, {
    Map<String, Map<String, double>> probabilities = const {},
  }) {
    final ids = items.map((item) => item.id).toSet();
    if (predictions.keys.any((id) => !ids.contains(id)) ||
        probabilities.keys.any((id) => !ids.contains(id))) {
      throw ArgumentError(
        'Predictions must identify original DecideBench items',
      );
    }
    var attempted = 0;
    var correct = 0;
    var unusable = 0;
    final pairs = <String, List<bool>>{};
    final calibrated = <(double, bool)>[];
    final brierScores = <double>[];
    for (final item in items) {
      if (!predictions.containsKey(item.id)) continue;
      attempted++;
      final prediction = predictions[item.id];
      final isCorrect = prediction == item.gold;
      if (isCorrect) correct++;
      if (prediction == null) unusable++;
      pairs.putIfAbsent(item.pairId, () => []).add(isCorrect);
      final raw = probabilities[item.id];
      final distribution = raw == null
          ? null
          : item.extractProbabilities({
              'answers': {
                'decision': {'probabilities': raw},
              },
            });
      if (distribution == null) continue;
      var brierScore = 0.0;
      for (final option in item.options.keys) {
        final difference =
            distribution[option]! - (option == item.gold ? 1 : 0);
        brierScore += difference * difference;
      }
      brierScores.add(brierScore);
      if (prediction != null) {
        calibrated.add((distribution.values.reduce(math.max), isCorrect));
      }
    }
    final complete = attempted == items.length;
    final pairsCorrect = pairs.values
        .where((pair) => pair.length == 2 && pair.every((value) => value))
        .length;
    double? ece;
    if (complete && calibrated.length >= items.length * 0.9) {
      var error = 0.0;
      for (var bin = 0; bin < 10; bin++) {
        final lower = bin / 10;
        final upper = (bin + 1) / 10;
        final bucket = calibrated
            .where(
              (value) =>
                  (lower < value.$1 && value.$1 <= upper) ||
                  (bin == 0 && value.$1 == 0),
            )
            .toList();
        if (bucket.isEmpty) continue;
        final confidence =
            bucket.fold(0.0, (sum, value) => sum + value.$1) / bucket.length;
        final accuracy =
            bucket.where((value) => value.$2).length / bucket.length;
        error +=
            bucket.length / calibrated.length * (confidence - accuracy).abs();
      }
      ece = error;
    }
    return DecideBenchScore(
      attempted: attempted,
      missing: items.length - attempted,
      correct: correct,
      pairsCorrect: pairsCorrect,
      unusable: unusable,
      complete: complete,
      accuracy: complete ? correct / items.length : null,
      pairAccuracy: complete ? pairsCorrect / 200 : null,
      brier: complete && brierScores.length >= items.length * 0.9
          ? brierScores.reduce((sum, value) => sum + value) / brierScores.length
          : null,
      ece: ece,
    );
  }
}

class _SourceItem {
  _SourceItem(
    this.id,
    this.groupId,
    this.category,
    this.difficulty,
    this.state,
    this.question,
    this.options,
    this.gold,
  );
  final String id;
  final String groupId;
  final String category;
  final String difficulty;
  final String state;
  final String question;
  final Map<String, String> options;
  final String gold;
  String get templateKey => jsonEncode([
    category,
    question,
    [
      for (final option in options.entries)
        {'key': option.key, 'description': option.value},
    ],
  ]);

  static _SourceItem parse(Object? value, bool example) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('DecideBench item must be an object');
    }
    String text(String key) {
      final result = value[key];
      if (result is! String) {
        throw FormatException('DecideBench $key must be a string');
      }
      return result;
    }

    final rawOptions = value['options'];
    if (rawOptions is! List || rawOptions.length < 2 || rawOptions.length > 8) {
      throw const FormatException('Invalid DecideBench option list');
    }
    final options = <String, String>{};
    for (final option in rawOptions) {
      if (option is! Map<String, Object?> ||
          option['key'] is! String ||
          option['description'] is! String) {
        throw const FormatException('Invalid DecideBench option');
      }
      final key = option['key'] as String;
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(key) ||
          options.containsKey(key)) {
        throw const FormatException('Invalid DecideBench option key');
      }
      options[key] = option['description'] as String;
    }
    final gold = text('gold');
    final category = text('category');
    final groupId = text(example ? 'template_id' : 'pair_id');
    final difficulty = example ? 'example' : text('difficulty');
    if (!options.containsKey(gold) ||
        !groupId.startsWith('$category-') ||
        (!example && difficulty != 'easy' && difficulty != 'hard')) {
      throw const FormatException('Invalid DecideBench label or group');
    }
    return _SourceItem(
      text('id'),
      groupId,
      category,
      difficulty,
      text('state'),
      text('question'),
      options,
      gold,
    );
  }
}
