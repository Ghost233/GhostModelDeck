import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ghost_model_deck/frozen_question_suite.dart';
import 'package:ghost_model_deck/jeval.dart';
import 'package:ghost_model_deck/jev_playground.dart';

void main() {
  test(
    'JEVal decodes every original row and retains published boundaries',
    () async {
      final suite = await JevalSuite.load(
        Directory('benchmarks/sources/jeval'),
      );
      expect(suite.tasks, hasLength(11257));
      expect(
        suite.identity['canonicalOriginalFieldsSha256'],
        '8daba7b00874d3e0a83ca51cf580fb238dc2a6e28a6ee9f19d8678b9fd3a33a3',
      );
      final originals = suite.tasks.map(
        (task) => task.metadata['original_fields'] as Map,
      );
      final canonical = originals.map((row) => '${jsonEncode(row)}\n').join();
      expect(
        sha256.convert(utf8.encode(canonical)).toString(),
        '8daba7b00874d3e0a83ca51cf580fb238dc2a6e28a6ee9f19d8678b9fd3a33a3',
      );
      expect(suite.tasks.map((task) => task.id).toSet(), hasLength(11257));
      final types = <String, int>{};
      var emptyCandidates = 0;
      var duplicateCandidates = 0;
      var emptyArcStates = 0;
      for (final task in suite.tasks) {
        final row = task.metadata['original_fields'] as Map;
        final type = row['question_type'] as String;
        types.update(type, (n) => n + 1, ifAbsent: () => 1);
        expect(task.body['state'], row['state']);
        expect(
          task.body['questions'],
          jsonDecode(row['questions_json'] as String),
        );
        expect(task.body.containsKey('label'), isFalse);
        final questions = task.body['questions'] as Map;
        final question = questions.values.single as Map;
        if (type == 'choice') {
          final values = (question['criteria'] as Map).values.toList();
          if (values.any((value) => value == '' || value == null)) {
            emptyCandidates++;
          }
          if (values.map(jsonEncode).toSet().length != values.length) {
            duplicateCandidates++;
          }
        }
        if ((row['source'] as String).startsWith('ai2-arc-') &&
            row['state'] == '') {
          emptyArcStates++;
        }
      }
      expect(types, {'choice': 9582, 'noul': 1356, 'score': 319});
      expect(emptyCandidates, 3303);
      expect(duplicateCandidates, 3401);
      expect(emptyArcStates, 206);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test('JEVal original scoring keeps returned decisions and ordinal measures separate', () async {
    final suite = await JevalSuite.load(Directory('benchmarks/sources/jeval'));
    final accumulator = suite.createAccumulator();
    final choice = suite.tasks.firstWhere(
      (task) => task.metadata['question_type'] == 'choice',
    );
    final binary = suite.tasks.firstWhere(
      (task) =>
          task.metadata['question_type'] == 'noul' &&
          task.metadata['label'] == 0,
    );
    final ordinal = suite.tasks.firstWhere(
      (task) =>
          task.metadata['question_type'] == 'score' &&
          task.metadata['label'] == 2 &&
          ((task.body['questions'] as Map).values.single as Map)['criteria']
              is List &&
          ((((task.body['questions'] as Map).values.single as Map)['criteria'])
                      as List)
                  .length ==
              5,
    );
    for (final task in suite.tasks) {
      final answer = _goldAnswer(task);
      if (identical(task, choice)) {
        final probabilities = answer['probabilities'] as Map<String, Object?>;
        final gold = task.metadata['label'];
        final other = probabilities.keys.firstWhere((key) => key != gold);
        probabilities.updateAll((key, value) => key == other ? 1.0 : 0.0);
        answer['confidence'] = 0.2;
      }
      if (identical(task, binary)) answer['noul'] = 0.5;
      if (identical(task, ordinal)) {
        answer['score'] = 2.5;
        answer['probabilities'] = {
          '0': 0.4,
          '1': 0.1,
          '2': 0.2,
          '3': 0.3,
          '4': 0.0,
        };
      }
      final scored = accumulator.record(task, _reply(task, answer));
      expect(scored['valid'], isTrue);
      if (identical(task, choice)) expect(scored['correct'], isTrue);
      if (identical(task, binary)) {
        expect(scored['prediction'], 1);
        expect(scored['correct'], isFalse);
      }
      if (identical(task, ordinal)) {
        expect(scored['prediction'], 2.5);
        expect(scored['scoreMode'], 0);
        expect(scored['scoreExpectedFromProbabilities'], closeTo(1.4, 1e-12));
        expect(scored['scoreRounded'], 3);
        expect(scored['scoreAbsoluteError'], 0.5);
      }
    }
    final score = accumulator.snapshot(complete: true);
    expect(score.summary['attempted'], 11257);
    expect(score.summary['valid'], 11257);
    expect(score.summary['classificationTotal'], 10938);
    expect(score.summary['scoreTotal'], 319);
    expect(score.summary['accuracy'], closeTo(10937 / 10938, 1e-12));
    expect(score.summary['brier'], closeTo(2.5 / 10938, 1e-12));
    expect(score.summary['ece'], closeTo(1.3 / 10938, 1e-12));
    expect(score.summary['scoreMae'], closeTo(0.5 / 319, 1e-12));
    final domains = {
      for (final group in score.groups.where(
        (group) => group['dimension'] == 'domain',
      ))
        group['group']: group['total'],
    };
    expect(domains, {
      'general-knowledge': 2598,
      'medicine': 800,
      'law': 1800,
      'finance': 59,
      'commonsense': 600,
      'agents-and-tools': 800,
      'truthfulness': 1000,
      'long-context': 1400,
      'social-science': 400,
      'personalization': 1800,
    });
    final languages = {
      for (final group in score.groups.where(
        (group) => group['dimension'] == 'language',
      ))
        group['group']: group['total'],
    };
    expect(languages, {'en': 9457, 'zh': 1800});
    expect(
      score.groups.where((group) => group['dimension'] == 'source'),
      hasLength(58),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('JEVal rejects invalid replies, keeps failures and never grades a partial run', () async {
    final suite = await JevalSuite.load(Directory('benchmarks/sources/jeval'));
    final accumulator = suite.createAccumulator();
    final first = suite.tasks.first;
    final invalid = _goldAnswer(first);
    invalid['unexpected'] = true;
    expect(accumulator.record(first, _reply(first, invalid))['valid'], isFalse);
    final second = suite.tasks[1];
    final timeout = JevPlaygroundResult(
      JevPlaygroundStatus.timedOut,
      'normal public deadline',
      mode: JevPlaygroundMode.http,
      timeout: const Duration(seconds: 30),
      elapsed: const Duration(seconds: 30),
    );
    expect(accumulator.record(second, timeout)['valid'], isFalse);
    final partial = accumulator.snapshot(complete: true);
    expect(partial.summary['complete'], isFalse);
    expect(partial.summary['attempted'], 2);
    expect(partial.summary['failed'], 2);
    expect(partial.summary['missing'], 11255);
    expect(partial.summary['timeouts'], 1);
    expect(partial.summary['failures'], {'invalidResponse': 1, 'timedOut': 1});
    for (final key in ['accuracy', 'brier', 'ece', 'scoreMae']) {
      expect(partial.summary[key], isNull);
      expect(partial.groups.every((group) => group[key] == null), isTrue);
    }
    expect(
      () => accumulator.record(first, _reply(first, _goldAnswer(first))),
      throwsStateError,
    );
    final impostor = FrozenQuestionTask(
      id: suite.tasks[2].id,
      body: {'state': 'changed'},
      metadata: {},
    );
    expect(() => accumulator.record(impostor, timeout), throwsStateError);
    expect(accumulator.snapshot(complete: false).summary['attempted'], 2);
    final failure = JevPlaygroundResult(
      JevPlaygroundStatus.businessError,
      'original task exceeds actual model or public limits',
      mode: JevPlaygroundMode.http,
      timeout: const Duration(seconds: 30),
      elapsed: const Duration(milliseconds: 1),
    );
    for (final task in suite.tasks.skip(2)) {
      accumulator.record(task, failure);
    }
    final full = accumulator.snapshot(complete: true);
    expect(full.summary['complete'], isTrue);
    expect(full.summary['attempted'], 11257);
    expect(full.summary['failed'], 11257);
    expect(full.summary['valid'], 0);
    expect(full.summary['missing'], 0);
    expect(full.summary['accuracy'], 0);
    expect(full.summary['scoreMae'], isNull);
    expect(full.summary['brier'], isNull);
    expect(full.summary['ece'], isNull);
    expect(partial.summary['attempted'], 2);
    expect(partial.summary['failures'], {'invalidResponse': 1, 'timedOut': 1});
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('JEVal retains finite unnormalized original probabilities and immutable raw inputs', () async {
    final suite = await JevalSuite.load(Directory('benchmarks/sources/jeval'));
    final task = suite.tasks.firstWhere(
      (task) => task.metadata['question_type'] == 'choice',
    );
    final request = task.request('public-model');
    expect(request.keys.toSet(), {'model', 'state', 'questions'});
    expect(request.containsKey('label'), isFalse);
    expect(request.containsKey('source_item_id'), isFalse);
    expect(
      () => (task.body['questions'] as Map).clear(),
      throwsUnsupportedError,
    );
    final question = (task.body['questions'] as Map).values.single as Map;
    expect(() => (question['criteria'] as Map).clear(), throwsUnsupportedError);
    expect(
      () => (task.metadata['original_fields'] as Map).clear(),
      throwsUnsupportedError,
    );
    final answer = _goldAnswer(task);
    final probabilities = answer['probabilities'] as Map;
    probabilities.updateAll((key, value) => 0.0);
    final scored = suite.createAccumulator().record(task, _reply(task, answer));
    expect(scored['valid'], isTrue);
    expect(scored['correct'], isTrue);
    expect(scored['brier'], 1);
    expect(scored['probabilitiesNormalized'], isFalse);
    expect(probabilities.values.every((value) => value == 0.0), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'JEVal malformed output classes stay invalid without response repair',
    () async {
      final suite = await JevalSuite.load(
        Directory('benchmarks/sources/jeval'),
      );
      for (final type in ['choice', 'noul', 'score']) {
        final task = suite.tasks.firstWhere(
          (task) => task.metadata['question_type'] == type,
        );
        final cases = <Map<String, Object?>>[];
        final missing = _goldAnswer(task)
          ..remove(type == 'noul' ? 'noul' : 'confidence');
        cases.add(missing);
        cases.add(_goldAnswer(task)..['type'] = 'different');
        if (type == 'noul') {
          for (final value in [
            double.nan,
            double.infinity,
            -0.1,
            1.1,
            'true',
            null,
          ]) {
            cases.add(_goldAnswer(task)..['noul'] = value);
          }
        } else {
          for (final value in [
            double.nan,
            double.infinity,
            -0.1,
            1.1,
            '1',
            null,
          ]) {
            final answer = _goldAnswer(task);
            (answer['probabilities']
                    as Map)[(answer['probabilities'] as Map).keys.first] =
                value;
            cases.add(answer);
          }
          final foreign = _goldAnswer(task);
          final p = foreign['probabilities'] as Map;
          p.remove(p.keys.first);
          p['foreign'] = 1.0;
          cases.add(foreign);
          if (type == 'choice') {
            cases.add(_goldAnswer(task)..['choice'] = 'foreign');
          }
          if (type == 'score') {
            cases.add(_goldAnswer(task)..['score'] = -0.1);
            cases.add(_goldAnswer(task)..['score'] = 999);
            final legend = _goldAnswer(task);
            (legend['legend'] as Map)[(legend['legend'] as Map).keys.first] =
                'changed';
            cases.add(legend);
          }
        }
        for (final answer in cases) {
          final accumulator = suite.createAccumulator();
          final result = accumulator.record(task, _reply(task, answer));
          expect(result['valid'], isFalse, reason: type);
          final score = accumulator.snapshot(complete: true);
          expect(score.summary['failed'], 1);
          expect(score.summary['valid'], 0);
          expect(score.summary['accuracy'], isNull);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('JEVal fixed manifest preserves original source conditions and actual files', () async {
    final manifest = jsonDecode(
      await File('benchmarks/manifests/jeval.json').readAsString(),
    ) as Map;
    expect(manifest['pin'], '5d0253c34cf5e371b3ae99c21f0a7170d7289f63');
    expect(manifest['dataLicense'], contains('No unified license'));
    final conditions = manifest['originalSourceConditions'] as List;
    expect(conditions, hasLength(36));
    final sources = conditions
        .expand((condition) => ((condition as Map)['sources'] as List))
        .toSet();
    expect(sources, hasLength(58));
    expect(
      conditions.every(
        (condition) =>
            (condition as Map)['exact_exporter_revision_known'] == false,
      ),
      isTrue,
    );
    for (final descriptor in manifest['files'] as List) {
      final file = descriptor as Map;
      final input = File('benchmarks/sources/jeval/${file['path']}');
      expect(await input.length(), file['bytes']);
      expect(
        (await sha256.bind(input.openRead()).first).toString(),
        file['sha256'],
      );
      expect(
        file['url'],
        contains('/resolve/5d0253c34cf5e371b3ae99c21f0a7170d7289f63/'),
      );
    }
  });
}

Map<String, Object?> _goldAnswer(FrozenQuestionTask task) {
  final type = task.metadata['question_type'];
  final label = task.metadata['label'];
  final question = (task.body['questions'] as Map).values.single as Map;
  if (type == 'noul') {
    return {'type': 'noul', 'noul': (label as int).toDouble()};
  }
  if (type == 'choice') {
    final criteria = question['criteria'] as Map;
    return {
      'type': 'choice',
      'choice': label,
      'confidence': 1.0,
      'probabilities': <String, Object?>{
        for (final key in criteria.keys)
          key as String: key == label ? 1.0 : 0.0,
      },
    };
  }
  final levels = question['criteria'] as List;
  return {
    'type': 'score',
    'score': (label as int).toDouble(),
    'confidence': 1.0,
    'legend': {for (var i = 0; i < levels.length; i++) '$i': levels[i]},
    'probabilities': <String, Object?>{
      for (var i = 0; i < levels.length; i++) '$i': i == label ? 1.0 : 0.0,
    },
  };
}

JevPlaygroundResult _reply(
  FrozenQuestionTask task,
  Map<String, Object?> answer,
) => JevPlaygroundResult(
  JevPlaygroundStatus.success,
  'synthetic scorer oracle, no model evaluation',
  output: {
    'answers': {task.metadata['question_id'] as String: answer},
  },
  mode: JevPlaygroundMode.http,
  timeout: const Duration(seconds: 30),
  elapsed: const Duration(milliseconds: 1),
);
