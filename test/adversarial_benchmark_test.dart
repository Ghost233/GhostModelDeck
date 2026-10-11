import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/adversarial_benchmark.dart';
import 'package:ghost_model_deck/frozen_question_suite.dart';
import 'package:ghost_model_deck/jev_playground.dart';

void main() {
  _effectsTests();
  test('every original uint64 metadata literal is retained with its pinned JSON pointer', () async {
    final suite = await AdversarialSuite.load(
      Directory('benchmarks/sources/adversarial'),
    );
    final literals = <String, String>{
      ...Map<String, String>.from(
        suite.identity['original_number_literals'] as Map,
      ),
      for (final task in suite.tasks)
        ...Map<String, String>.from(
          task.metadata['original_number_literals'] as Map,
        ),
    };
    // Fixed-source Python integers are exact. This all-file oracle predates
    // the Dart preservation implementation and includes the global seed.
    expect(literals, hasLength(4564));
    expect(
      literals['#/scenarios/0/questions/noul/0/adversarial/samples/1/metrics/seed'],
      '10412541446228332175',
    );
    final pointers = literals.keys.toList()..sort();
    final evidence = pointers.map((p) => '$p\t${literals[p]}\n').join();
    expect(
      sha256.convert(utf8.encode(evidence)).toString(),
      '5850e281676aabc4bd6e33bdbbe40e9aa1eeddcd3e5ff7ec387354fe74be7a1c',
    );
    final q2 = suite.tasks.firstWhere((t) => t.metadata['category'] == 'Q2');
    expect(
      q2.metadata['source_json_pointer'],
      '#/scenarios/0/questions/noul/0/adversarial/samples/1',
    );
    expect(
      q2.metadata['number_literal_encoding'],
      'original JSON numeric token, stored as text',
    );
    expect(suite.identity['pin'], '3218e05f98f2b72c69b6f8a1a4a42092955b7bc7');
    expect(suite.identity['sourceFiles'], contains('data/AdvBench1.0.json'));
  });
  test('public MCP invalid_input and local preflight rejection keep distinct delivery evidence', () async {
    final suite = await AdversarialSuite.load(
      Directory('benchmarks/sources/adversarial'),
    );
    final accumulator = suite.createAccumulator();
    final public = JevPlaygroundResult(
      JevPlaygroundStatus.businessError,
      'received public MCP error',
      mode: JevPlaygroundMode.mcp,
      timeout: const Duration(seconds: 30),
      elapsed: const Duration(milliseconds: 1),
      output: {
        'error': {'code': 'invalid_input', 'message': '包含不支持的字段：comment'},
      },
      request: suite.tasks[0].request('native'),
    );
    expect(
      accumulator.record(suite.tasks[0], public)['failure_class'],
      'protocolRejected',
    );
    final local = JevPlaygroundResult(
      JevPlaygroundStatus.businessError,
      '包含不支持的字段：comment',
      mode: JevPlaygroundMode.http,
      timeout: const Duration(seconds: 30),
      elapsed: Duration.zero,
    );
    expect(
      accumulator.record(suite.tasks[1], local)['failure_class'],
      'notDelivered',
    );
    expect(accumulator.snapshot(complete: false).summary['failureClasses'], {
      'protocolRejected': 1,
      'notDelivered': 1,
    });
  });
  test(
    'original raw Unicode and extra fields reach the public document unchanged',
    () async {
      final suite = await AdversarialSuite.load(
        Directory('benchmarks/sources/adversarial'),
      );
      final wire = suite.tasks
          .map((t) => '${t.requestDocument('__fixed_public_call_name__')}\n')
          .join();
      // Independent original Python request_bytes, including raw S2 escapes.
      expect(
        sha256.convert(utf8.encode(wire)).toString(),
        '22e6b840b346f3c089269a6c1c22b49f6306b6c2c47cf1eb3805963dc0500b2f',
      );
      final s2 = suite.tasks.firstWhere((t) => t.metadata['category'] == 'S2');
      expect(
        s2.requestDocument('native"name'),
        contains(r'\u0069\u006estructions'),
      );
      expect(
        jsonDecode(s2.requestDocument('native"name')),
        s2.request('native"name'),
      );
      expect(
        suite.tasks[9744].requestDocument('native'),
        suite.tasks[10556].requestDocument('native'),
      );
    },
  );
  test('public rejection context limits model errors and absent replies are distinct', () async {
    final suite = await AdversarialSuite.load(
      Directory('benchmarks/sources/adversarial'),
    );
    final score = suite.createAccumulator();
    final cases = [
      (
        JevPlaygroundStatus.businessError,
        413,
        'request_too_large',
        'protocolRejected',
      ),
      (
        JevPlaygroundStatus.businessError,
        400,
        'context_length_exceeded',
        'contextLimit',
      ),
      (
        JevPlaygroundStatus.businessError,
        500,
        'engine_inference_failed',
        'modelFailure',
      ),
      (JevPlaygroundStatus.transportError, null, null, 'noPublicResponse'),
    ];
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final reply = JevPlaygroundResult(
        c.$1,
        'public failure',
        httpStatus: c.$2,
        output: c.$3 == null
            ? null
            : {
                'error': {'code': c.$3},
              },
        mode: JevPlaygroundMode.http,
        timeout: const Duration(seconds: 30),
        elapsed: Duration.zero,
      );
      final fields = score.record(suite.tasks[i], reply);
      expect(fields['failure_class'], c.$4);
      expect(fields['benchmark_decision'], isNull);
      expect(fields['strict_label_consistent'], isNull);
    }
    final invalid = score.record(
      suite.tasks[4],
      _reply(suite.tasks[4], {'type': 'noul', 'noul': 1.1}),
    );
    expect(invalid['failure_class'], 'invalidResponse');
    expect(invalid['benchmark_decision'], isNull);
    final partial = score.snapshot(complete: false);
    expect(partial.summary['attempted'], 5);
    expect(partial.summary['valid'], 0);
    expect(partial.summary['failureClasses'], {
      'protocolRejected': 1,
      'contextLimit': 1,
      'modelFailure': 1,
      'noPublicResponse': 1,
      'invalidResponse': 1,
    });
    expect(
      partial.groups.every(
        (g) => g['flipPct'] == null && g['flipCi95'] == null,
      ),
      isTrue,
    );
    expect(partial.summary['complete'], isFalse);
  });
  test('published probability boundaries are retained without repairing a distribution', () async {
    final suite = await AdversarialSuite.load(
      Directory('benchmarks/sources/adversarial'),
    );
    final accumulator = suite.createAccumulator();
    final n = suite.tasks[0];
    expect(
      accumulator.record(
        n,
        _reply(n, {'type': 'noul', 'noul': 0.5}),
      )['benchmark_decision'],
      isTrue,
    );
    final s = suite.tasks.firstWhere(
      (t) => t.metadata['question_type'] == 'score',
    );
    expect(
      accumulator.record(
        s,
        _reply(s, {
          'type': 'score',
          'score': 1.0,
          'probabilities': {'0': 0.5, '1': 0.0, '2': 0.5},
          'confidence': 0.5,
        }),
      )['benchmark_decision'],
      0,
    );
    final c = suite.tasks.firstWhere(
      (t) => t.metadata['question_type'] == 'choice',
    );
    final bad = _baseline(c);
    final p = bad['probabilities'] as Map<String, double>;
    bad['probabilities'] = {for (final k in p.keys) k: 0.1};
    final fields = accumulator.record(c, _reply(c, bad));
    expect(fields['failure_class'], 'invalidResponse');
    expect(fields['benchmark_decision'], isNull);
    final partial = accumulator.snapshot(complete: true);
    expect(partial.summary['complete'], isFalse);
    expect(partial.summary['valid'], 2);
    expect(partial.groups.every((g) => g['flipPct'] == null), isTrue);
  });
  test(
    'all original attacks clean and independent reruns retain their source',
    () async {
      final suite = await AdversarialSuite.load(
        Directory('benchmarks/sources/adversarial'),
      );
      expect(suite.tasks, hasLength(11368));
      expect(suite.identity['questionCount'], 812);
      expect(suite.identity['scenarioCount'], 66);
      expect(suite.identity['humanReviewedCount'], 143);
      expect(suite.identity['modelConsensusCount'], 669);
      expect(suite.tasks.first.metadata['category'], 'Q1');
      expect(suite.tasks[9744].metadata['category'], 'clean');
      expect(suite.tasks[10556].metadata['category'], 'rerun');
      final requests = suite.tasks
          .map(
            (task) =>
                '${jsonEncode(task.request('__fixed_public_call_name__'))}\n',
          )
          .join();
      // Independent Python oracle follows the final pinned evaluator's item IDs
      // and ordering, without using the Dart suite or its source digest.
      expect(
        sha256.convert(utf8.encode(requests)).toString(),
        '8a36419f1c1aa42ceb0a5be8d878c1547058928e4dec284ab7f85e4d183760c3',
      );
      final s2 = suite.tasks.firstWhere(
        (task) => task.metadata['category'] == 'S2',
      );
      expect(
        s2.metadata['raw_question_text'],
        contains(r'\u0069\u006estructions'),
      );
      final variant = s2.metadata['variant'] as Map;
      expect(variant['target_path'], isNotNull);
      expect(variant['perturbed_state'], s2.body['state']);
      expect(variant['sampling'], isNotNull);
      final clean = suite.tasks[9744];
      final rerun = suite.tasks[10556];
      expect(clean.body, rerun.body);
      expect(clean.id, isNot(rerun.id));
      expect(clean.metadata['question_id'], rerun.metadata['question_id']);
    },
  );

  test(
    'full source scoring retains scenario statistics and rerun noise',
    () async {
      final suite = await AdversarialSuite.load(
        Directory('benchmarks/sources/adversarial'),
      );
      final accumulator = suite.createAccumulator();
      const changed = {
        'official-U-072c7cc17e6f/q000',
        'official-U-9aa3a460c5bd/gen-noul-01',
        'official-U-7f6406e52f1f/q000',
      };
      for (final task in suite.tasks) {
        final category = task.metadata['category'];
        final qid = task.metadata['question_id'];
        final answer = _baseline(task);
        if ((category == 'Q1' && changed.contains(qid)) ||
            (category == 'rerun' && qid == 'official-U-072c7cc17e6f/q000')) {
          answer['noul'] = 0.4;
        }
        accumulator.record(task, _reply(task, answer));
      }
      final score = accumulator.snapshot(complete: true);
      expect(score.summary['attempted'], 11368);
      expect(score.summary['valid'], 11368);
      final q1 = score.groups.firstWhere(
        (g) =>
            g['kind'] == 'flip_rates' &&
            g['category'] == 'Q1' &&
            g['primitive'] == 'all',
      );
      // Executed directly against the fixed author's common.py (seed 0),
      // including Python's RNG stream, not a new approximation to its CI.
      expect(q1['flipCount'], 3);
      expect(q1['flipPct'], closeTo(0.3694581280788177, 1e-12));
      expect(q1['flipCi95'], [0.0, 0.8321775312066574]);
      expect(q1['excessPct'], closeTo(0.24630541871921183, 1e-12));
      expect(q1['excessCi95'], [0.0, 0.6418485237483954]);
      expect(q1['permutationP'], closeTo(0.5001249937503125, 1e-14));
      expect(q1['mcnemarP'], 0.5);
      final rerun = score.groups.firstWhere(
        (g) =>
            g['kind'] == 'flip_rates' &&
            g['category'] == 'rerun' &&
            g['primitive'] == 'all',
      );
      expect(rerun['flipCount'], 1);
      expect(rerun['flipPct'], closeTo(0.12315270935960591, 1e-12));
      expect(rerun['flipCi95'], [0.0, 0.3937007874015748]);
      expect(score.summary['statistics'], {
        'clusters': 'original scenarios',
        'bootstrapSamples': 2000,
        'permutationSamples': 20000,
        'seed': 0,
      });
    },
  );
}

void _effectsTests() {
  test(
    'original shifts gates unions and label provenance remain separate',
    () async {
      final suite = await AdversarialSuite.load(
        Directory('benchmarks/sources/adversarial'),
      );
      final accumulator = suite.createAccumulator();
      String? firstChoice;
      String? firstScore;
      for (final task in suite.tasks) {
        final type = task.metadata['question_type'];
        final category = task.metadata['category'];
        final qid = task.metadata['question_id'] as String;
        if (type == 'choice') firstChoice ??= qid;
        if (type == 'score') firstScore ??= qid;
        final answer = _baseline(task);
        if (category == 'T1' && qid == 'official-U-072c7cc17e6f/q000') {
          answer['noul'] = 0.79;
        }
        if (category == 'Q1' && qid == firstChoice) {
          final p = answer['probabilities'] as Map<String, double>;
          answer['probabilities'] = {
            for (final key in p.keys)
              key: key == p.keys.first ? 0.6 : 0.4 / (p.length - 1),
          };
          answer['confidence'] = 0.6;
        }
        if (category == 'Q1' && qid == firstScore) {
          final p = answer['probabilities'] as Map<String, double>;
          answer['probabilities'] = {
            for (final key in p.keys)
              key: key == '0'
                  ? 0.75
                  : key == '1'
                  ? 0.25
                  : 0.0,
          };
          answer['score'] = 0.25;
          answer['confidence'] = 0.75;
        }
        final fields = accumulator.record(task, _reply(task, answer));
        if (category == 'clean' && qid == firstScore) {
          // Author's first human-reviewed exact score is .228: raw 0 fails
          // legacy strict equality, but satisfies its separate .5 tolerance.
          expect(fields['label_source'], 'human_review');
          expect(fields['strict_label_consistent'], isFalse);
          expect(fields['human_label_tolerant_consistent'], isTrue);
        }
      }
      final result = accumulator.snapshot(complete: true);
      final shift = result.groups.firstWhere(
        (g) => g['kind'] == 'shift' && g['category'] == 'Q1',
      );
      expect(shift['flipCount'], 0);
      expect(shift['shiftNoFlipCount'], 2);
      expect(shift['shiftNoFlipPct'], closeTo(0.24630541871921183, 1e-12));
      final gate = result.groups.firstWhere(
        (g) => g['kind'] == 'confidence_gate' && g['category'] == 'Q1',
      );
      expect(gate['confidentCleanCount'], 498);
      expect(gate['pushedBelowCount'], 2);
      expect(gate['decisionUnchangedCount'], 2);
      expect(gate['pushedBelowPct'], closeTo(0.40160642570281124, 1e-12));
      final union = result.groups.firstWhere(
        (g) =>
            g['kind'] == 'union' &&
            g['name'] == 'any_of_12' &&
            g['primitive'] == 'all',
      );
      expect(union['flipCount'], 0);
      expect(union['flipPct'], 0.0);
      expect(union['flipCi95'], [0.0, 0.0]);
      final delivery = result.groups.firstWhere(
        (g) => g['kind'] == 'delivery' && g['category'] == 'S2',
      );
      expect(delivery['publicTokenPairs'], 0);
      expect(delivery['meanDeltaBilledTokens'], isNull);
      expect(delivery['modelRepresentation'], 'unobservable');
      expect(
        result.groups.where((g) => g['kind'] == 'human_label_accuracy'),
        hasLength(14),
      );
      expect(
        result.groups.where((g) => g['kind'] == 'injection_slot'),
        hasLength(8),
      );
      expect(result.summary['auroc_all_delivered_attack_conf'], isNull);
    },
  );
}

Map<String, Object?> _baseline(FrozenQuestionTask task) {
  final question = (task.body['questions'] as Map).values.single as Map;
  switch (question['type']) {
    case 'noul':
      return {'type': 'noul', 'noul': 0.9};
    case 'choice':
      final options = (question['criteria'] as Map).keys
          .cast<String>()
          .toList();
      return {
        'type': 'choice',
        'choice': options.first,
        'probabilities': {
          for (final key in options) key: key == options.first ? 1.0 : 0.0,
        },
        'confidence': 1.0,
      };
    default:
      final levels = question['criteria'] as List;
      return {
        'type': 'score',
        'score': 0.0,
        'probabilities': {
          for (var i = 0; i < levels.length; i++) '$i': i == 0 ? 1.0 : 0.0,
        },
        'confidence': 1.0,
      };
  }
}

JevPlaygroundResult _reply(
  FrozenQuestionTask task,
  Map<String, Object?> answer,
) => JevPlaygroundResult(
  JevPlaygroundStatus.success,
  'ordinary public response',
  output: {
    'model': 'native',
    'answers': {task.metadata['item_id'] as String: answer},
  },
  mode: JevPlaygroundMode.http,
  timeout: const Duration(seconds: 30),
  elapsed: const Duration(milliseconds: 10),
);
