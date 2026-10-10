import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:libbigdata/libbigdata.dart';

import 'frozen_question_suite.dart';
import 'jev_playground.dart';

class JevalSuite implements FrozenQuestionSuite {
  JevalSuite._(this.tasks);

  static const pin = '5d0253c34cf5e371b3ae99c21f0a7170d7289f63';
  static const parquetSha256 =
      '88f090a510e511d1236fdf5ddb428a8b965663ff0cc1061f950b88f0c99d2e82';
  static const canonicalOriginalFieldsSha256 =
      '8daba7b00874d3e0a83ca51cf580fb238dc2a6e28a6ee9f19d8678b9fd3a33a3';
  static const columns = [
    'id',
    'source',
    'state',
    'question_type',
    'questions_json',
    'label_json',
    'source_item_id',
  ];

  @override
  final List<FrozenQuestionTask> tasks;

  @override
  Map<String, Object?> get identity => const {
    'id': 'jeval',
    'pin': pin,
    'source': 'https://huggingface.co/datasets/carlosxiang/JEVal',
    'contentSha256': parquetSha256,
    'canonicalOriginalFieldsSha256': canonicalOriginalFieldsSha256,
    'questionCount': 11257,
    'classificationCount': 10938,
    'scoreCount': 319,
    'sourceCount': 58,
    'requestVersion': 'original-seven-column-state-questions',
    'scoringVersion': 'arxiv-2610.03935v1-eq4-6-eq13',
    'scoringSource': 'https://arxiv.org/html/2610.03935v1',
    'dataLicense': 'No unified license; original source conditions apply',
    'labelSource': 'original label_json, unchanged hard classification labels',
    'languageGrouping': 'author source-designated language; not text detection',
    'lengthGrouping':
        'UTF-8 bytes of original state and questions_json; auxiliary',
  };

  /// Decoding does not block the desktop isolate or alter the published inputs.
  static Future<JevalSuite> load(Directory root) =>
      Isolate.run(() => _load(root.path));

  static Future<JevalSuite> _load(String root) async {
    final file = File('$root/data/test.parquet');
    if (await file.length() != 33533925 ||
        (await sha256.bind(file.openRead()).first).toString() !=
            parquetSha256) {
      throw const FormatException('JEVal original Parquet identity mismatch');
    }
    final output = _DigestSink();
    final digest = sha256.startChunkedConversion(output);
    final tasks = <FrozenQuestionTask>[];
    final ids = <String>{};
    final sourceIds = <String>{};
    final sources = <String>{};
    final types = <String, int>{};
    final reader = ParquetReader(file.path);
    await for (final table in reader.readBatches(size: 128)) {
      if (table.columnCount != 7 ||
          table.schema.fields.map((field) => field.name).join('|') !=
              columns.join('|')) {
        throw const FormatException(
          'JEVal original seven-column schema mismatch',
        );
      }
      for (final decoded in table.toRows()) {
        final row = <String, String>{};
        for (final name in columns) {
          final value = decoded[name];
          if (value is! String) {
            throw const FormatException('JEVal non-string original column');
          }
          row[name] = value;
        }
        if (!ids.add(row['id']!) || !sourceIds.add(row['source_item_id']!)) {
          throw const FormatException('JEVal duplicate original identity');
        }
        final questions = jsonDecode(row['questions_json']!);
        final label = jsonDecode(row['label_json']!);
        final type = row['question_type']!;
        if (questions is! Map ||
            questions.length != 1 ||
            questions.keys.single is! String ||
            questions.values.single is! Map) {
          throw const FormatException('JEVal original question shape mismatch');
        }
        final question = questions.values.single as Map;
        final criteria = question['criteria'];
        if (question['type'] != type ||
            (type == 'choice' &&
                (criteria is! Map ||
                    label is! String ||
                    !criteria.containsKey(label))) ||
            (type == 'noul' && (label is! int || (label != 0 && label != 1))) ||
            (type == 'score' &&
                (criteria is! List ||
                    label is! int ||
                    label < 0 ||
                    label >= criteria.length)) ||
            !const ['choice', 'noul', 'score'].contains(type)) {
          throw const FormatException(
            'JEVal original label/type mapping mismatch',
          );
        }
        sources.add(row['source']!);
        types.update(type, (n) => n + 1, ifAbsent: () => 1);
        digest.add(utf8.encode('${jsonEncode(row)}\n'));
        final inputBytes =
            utf8.encode(row['state']!).length +
            utf8.encode(row['questions_json']!).length;
        tasks.add(
          FrozenQuestionTask(
            id: row['id']!,
            body: {'state': row['state'], 'questions': _freeze(questions)},
            metadata: {
              'original_fields': Map<String, String>.unmodifiable(row),
              'source': row['source'],
              'source_item_id': row['source_item_id'],
              'question_type': type,
              'question_id': questions.keys.single,
              'label': label,
              'domain': _domain(row['source']!),
              'language': _chineseSources.contains(row['source']) ? 'zh' : 'en',
              'input_bytes': inputBytes,
              'input_length_group': inputBytes <= 4096
                  ? '0-4096-bytes'
                  : inputBytes <= 16384
                  ? '4097-16384-bytes'
                  : inputBytes <= 65536
                  ? '16385-65536-bytes'
                  : '65537+-bytes',
            },
          ),
        );
      }
    }
    digest.close();
    if (tasks.length != 11257 ||
        sources.length != 58 ||
        types['choice'] != 9582 ||
        types['noul'] != 1356 ||
        types['score'] != 319 ||
        output.value.toString() != canonicalOriginalFieldsSha256) {
      throw const FormatException(
        'JEVal complete original row digest mismatch',
      );
    }
    return JevalSuite._(List.unmodifiable(tasks));
  }

  @override
  FrozenQuestionAccumulator createAccumulator() => _JevalAccumulator(tasks);
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

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

const _chineseSources = {
  'ceval',
  'cmmlu',
  'cmb',
  'cmexam',
  'med-qa',
  'disc-law-single',
  'disc-law-multi',
  'longbench-lsht',
  'longbench-retrieval-zh',
};

String _domain(String source) {
  if (source == 'cmb' || source == 'cmexam' || source.startsWith('med-qa')) {
    return 'medicine';
  }
  if (source == 'cuad' ||
      source.startsWith('disc-law-') ||
      source.startsWith('lex-glue-')) {
    return 'law';
  }
  if (source == 'financebench-yes-no' || source == 'finqa-yes-no') {
    return 'finance';
  }
  if (const {'commonsense-qa', 'hellaswag', 'winogrande'}.contains(source)) {
    return 'commonsense';
  }
  if (const {'agentharm', 'decider', 'jevbench', 'jevforge'}.contains(source)) {
    return 'agents-and-tools';
  }
  if (source.startsWith('halueval-') || source == 'truthfulqa') {
    return 'truthfulness';
  }
  if (source == 'helmet' || source.startsWith('longbench-')) {
    return 'long-context';
  }
  if (source == 'bbq' || source == 'global-opinions') return 'social-science';
  if (source.startsWith('communitybench-') ||
      source.startsWith('compred-') ||
      source.startsWith('prism-alignment')) {
    return 'personalization';
  }
  return 'general-knowledge';
}

class _JevalAccumulator implements FrozenQuestionAccumulator {
  _JevalAccumulator(List<FrozenQuestionTask> tasks)
    : _tasks = {for (final task in tasks) task.id: task} {
    for (final task in tasks) {
      _all.include(task);
      for (final group in _groupsFor(task)) {
        (_groups[group] ??= _JevalStats()).include(task);
      }
    }
  }

  final Map<String, FrozenQuestionTask> _tasks;
  final Set<String> _seen = {};
  final _JevalStats _all = _JevalStats();
  final Map<(String, String), _JevalStats> _groups = {};

  Iterable<(String, String)> _groupsFor(FrozenQuestionTask task) sync* {
    for (final dimension in const [
      'source',
      'domain',
      'language',
      'question_type',
      'input_length_group',
    ]) {
      yield (dimension, task.metadata[dimension] as String);
    }
  }

  @override
  Map<String, Object?> record(
    FrozenQuestionTask task,
    JevPlaygroundResult reply,
  ) {
    if (!identical(_tasks[task.id], task) || !_seen.add(task.id)) {
      throw StateError('JEVal unknown or repeated original task');
    }
    final scored = _score(task, reply);
    _all.record(task, reply, scored);
    for (final group in _groupsFor(task)) {
      _groups[group]!.record(task, reply, scored);
    }
    return Map.unmodifiable(scored);
  }

  @override
  FrozenQuestionScore snapshot({required bool complete}) {
    final full = complete && _seen.length == _tasks.length;
    final ordered = _groups.keys.toList()
      ..sort((a, b) {
        final dimension = a.$1.compareTo(b.$1);
        return dimension == 0 ? a.$2.compareTo(b.$2) : dimension;
      });
    return FrozenQuestionScore(
      summary: Map.unmodifiable(_all.snapshot(full)),
      groups: List.unmodifiable([
        for (final key in ordered)
          Map<String, Object?>.unmodifiable({
            'dimension': key.$1,
            'group': key.$2,
            ..._groups[key]!.snapshot(full),
          }),
      ]),
    );
  }
}

Map<String, Object?> _score(
  FrozenQuestionTask task,
  JevPlaygroundResult reply,
) {
  Map<String, Object?> invalid(String reason) => {
    'valid': false,
    'correct': false,
    'prediction': null,
    'scoringError': reason,
  };
  if (reply.status != JevPlaygroundStatus.success) {
    return invalid('Public client returned ${reply.status.name}');
  }
  final answers = reply.output?['answers'];
  final questionId = task.metadata['question_id'];
  final type = task.metadata['question_type'];
  final label = task.metadata['label'];
  if (answers is! Map ||
      answers.length != 1 ||
      !answers.containsKey(questionId)) {
    return invalid(
      'Original question ID is missing or additional answers exist',
    );
  }
  final answer = answers[questionId];
  if (answer is! Map || answer['type'] != type) {
    return invalid('Returned type differs from the original question');
  }
  if (type == 'noul') {
    final probability = _bounded(answer['noul'], 1);
    if (answer.length != 2 || probability == null) {
      return invalid(
        'noul must contain only the original finite true probability',
      );
    }
    final prediction = probability >= 0.5 ? 1 : 0;
    final error = probability - (label as int);
    return {
      'valid': true,
      'prediction': prediction,
      'correct': prediction == label,
      'confidence': prediction == 1 ? probability : 1 - probability,
      'brier': 2 * error * error,
      'probabilitiesNormalized': true,
    };
  }
  final question = (task.body['questions'] as Map).values.single as Map;
  final criteria = question['criteria'];
  final keys = type == 'choice'
      ? (criteria as Map).keys.cast<String>().toList()
      : [for (var i = 0; i < (criteria as List).length; i++) '$i'];
  final probabilities = _probabilities(answer['probabilities'], keys);
  final confidence = _bounded(answer['confidence'], 1);
  if (probabilities == null || confidence == null) {
    return invalid(
      'Every original probability and confidence must be finite in [0,1]',
    );
  }
  final sum = probabilities.values.fold(0.0, (total, p) => total + p);
  final normalized = (sum - 1).abs() <= 1e-6;
  if (type == 'choice') {
    final prediction = answer['choice'];
    if (answer.length != 4 ||
        prediction is! String ||
        !keys.contains(prediction)) {
      return invalid('Returned choice is not an original candidate');
    }
    // The author scores the returned label, without replacing it by argmax or
    // normalizing its probability vector (paper v1 Appendix C.2).
    var brier = 0.0;
    for (final key in keys) {
      final error = probabilities[key]! - (key == label ? 1 : 0);
      brier += error * error;
    }
    return {
      'valid': true,
      'prediction': prediction,
      'correct': prediction == label,
      'confidence': confidence,
      'brier': brier,
      'probabilitiesNormalized': normalized,
    };
  }
  final score = _bounded(answer['score'], keys.length - 1);
  final legend = answer['legend'];
  if (answer.length != 5 ||
      score == null ||
      legend is! Map ||
      legend.length != keys.length ||
      keys.any(
        (key) =>
            !legend.containsKey(key) ||
            jsonEncode(legend[key]) !=
                jsonEncode((criteria as List)[int.parse(key)]),
      )) {
    return invalid('Returned score or original ordered legend is invalid');
  }
  var mode = 0;
  var expected = 0.0;
  for (var i = 0; i < keys.length; i++) {
    if (probabilities['$i']! > probabilities['$mode']!) mode = i;
    expected += i * probabilities['$i']!;
  }
  return {
    'valid': true,
    'prediction': score,
    'scoreAbsoluteError': (score - (label as int)).abs(),
    'scoreMode': mode,
    'scoreExpectedFromProbabilities': normalized ? expected : null,
    'scoreRounded': score.round(),
    'probabilitiesNormalized': normalized,
  };
}

double? _bounded(Object? value, num maximum) =>
    value is num && value.isFinite && value >= 0 && value <= maximum
    ? value.toDouble()
    : null;

Map<String, double>? _probabilities(Object? raw, List<String> keys) {
  if (raw is! Map || raw.length != keys.length) return null;
  final probabilities = <String, double>{};
  for (final key in keys) {
    final value = _bounded(raw[key], 1);
    if (value == null) return null;
    probabilities[key] = value;
  }
  return probabilities;
}

class _JevalStats {
  var total = 0;
  var classificationTotal = 0;
  var scoreTotal = 0;
  var attempted = 0;
  var valid = 0;
  var correct = 0;
  var probabilityCount = 0;
  var normalizedProbabilityCount = 0;
  var validScoreCount = 0;
  var timeouts = 0;
  var brierSum = 0.0;
  var absoluteErrorSum = 0.0;
  final Map<String, int> failures = {};
  final List<int> _binCounts = List.filled(10, 0);
  final List<int> _binCorrect = List.filled(10, 0);
  final List<double> _binConfidence = List.filled(10, 0);

  void include(FrozenQuestionTask task) {
    total++;
    if (task.metadata['question_type'] == 'score') {
      scoreTotal++;
    } else {
      classificationTotal++;
    }
  }

  void record(
    FrozenQuestionTask task,
    JevPlaygroundResult reply,
    Map<String, Object?> scored,
  ) {
    attempted++;
    if (scored['valid'] != true) {
      final status = reply.status == JevPlaygroundStatus.success
          ? JevPlaygroundStatus.invalidResponse.name
          : reply.status.name;
      failures.update(status, (n) => n + 1, ifAbsent: () => 1);
      if (reply.status == JevPlaygroundStatus.timedOut) timeouts++;
      return;
    }
    valid++;
    if (task.metadata['question_type'] == 'score') {
      validScoreCount++;
      absoluteErrorSum += scored['scoreAbsoluteError'] as double;
      return;
    }
    if (scored['correct'] == true) correct++;
    probabilityCount++;
    if (scored['probabilitiesNormalized'] == true) normalizedProbabilityCount++;
    brierSum += scored['brier'] as double;
    final confidence = scored['confidence'] as double;
    final bin = (confidence * 10).floor().clamp(0, 9);
    _binCounts[bin]++;
    if (scored['correct'] == true) _binCorrect[bin]++;
    _binConfidence[bin] += confidence;
  }

  Map<String, Object?> snapshot(bool complete) {
    var ece = 0.0;
    for (var i = 0; i < 10; i++) {
      if (_binCounts[i] == 0) continue;
      ece += (_binCorrect[i] - _binConfidence[i]).abs();
    }
    return {
      'total': total,
      'attempted': attempted,
      'missing': total - attempted,
      'valid': valid,
      'failed': attempted - valid,
      'timeouts': timeouts,
      'failures': Map<String, int>.unmodifiable(failures),
      'complete': complete,
      'classificationTotal': classificationTotal,
      'scoreTotal': scoreTotal,
      'correct': correct,
      'probabilityCount': probabilityCount,
      'normalizedProbabilityCount': normalizedProbabilityCount,
      'probabilityCoverage': classificationTotal == 0
          ? null
          : probabilityCount / classificationTotal,
      'validScoreCount': validScoreCount,
      'accuracy': complete && classificationTotal > 0
          ? correct / classificationTotal
          : null,
      'brier': complete && probabilityCount > 0
          ? brierSum / probabilityCount
          : null,
      'ece': complete && probabilityCount > 0 ? ece / probabilityCount : null,
      'scoreMae': complete && validScoreCount > 0
          ? absoluteErrorSum / validScoreCount
          : null,
      'labelSource':
          'original label_json hard labels; score uses original ordinal scale',
      'probabilityPolicy': 'original finite reported values; no normalization; independent returned confidence (noul: p or 1-p)',
      'scorePolicy': 'returned score MAE on valid score answers; mode/expectation/rounding are auxiliary only',
    };
  }
}
