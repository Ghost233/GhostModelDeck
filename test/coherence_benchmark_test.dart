import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/coherence_benchmark.dart';
import 'package:ghost_model_deck/frozen_question_suite.dart';
import 'package:ghost_model_deck/jev_playground.dart';

void main() {
  test(
    'full frozen coherence suite preserves original request batches',
    () async {
      final suite = await CoherenceSuite.load(
        Directory('benchmarks/sources/coherence'),
      );
      expect(suite.tasks, hasLength(10320));
      expect(suite.identity['cases'], 240);
      expect(suite.identity['questions'], 2240);
      expect(suite.identity['relations'], 50);
      expect(suite.identity['tests'], 12000);
      expect(suite.identity['pin'], 'e18733694623aa93058e279c3534f8b8e2edefa3');
      final first = suite.tasks.first;
      expect(first.metadata['stage'], 'base');
      expect(first.body['questions'] as Map, hasLength(12));
      expect(
        suite.tasks.take(240).every((t) => t.metadata['stage'] == 'base'),
        isTrue,
      );
      expect(first.request('kev-public')['model'], 'kev-public');
      expect(first.body.containsKey('model'), isFalse);
      // Independent original engine request order, resolved by the Python plan.
      final originalBodies = suite.tasks
          .map((task) => '${jsonEncode(task.body)}\n')
          .join();
      expect(
        sha256.convert(utf8.encode(originalBodies)).toString(),
        '9a91829af64a2282a3544b1cdc7dabd0b9fb351a6e95870c521d75cc7c9cc9ea',
      );
    },
  );
  test(
    'full original relations match two independent author scoring vectors',
    () async {
      final suite = await CoherenceSuite.load(
        Directory('benchmarks/sources/coherence'),
      );
      for (final positional in [false, true]) {
        final accumulator = suite.createAccumulator();
        for (final task in suite.tasks) {
          accumulator.record(task, _vectorReply(task, positional));
        }
        final score = accumulator.snapshot(complete: true);
        final summary = score.summary;
        final reference = positional ? _positionReference : _uniformReference;
        expect(summary['complete'], isTrue);
        expect(summary['attempted'], 10320);
        expect(summary['valid'], 10320);
        expect(summary['planned_tests'], 12000);
        expect(summary['judged_tests'], 12000);
        expect(summary['n_outcomes'], 14838);
        expect(
          summary['overall'],
          closeTo(reference['overall'] as double, 1e-12),
        );
        final actualRelations = summary['relations'] as Map;
        final expectedRelations = reference['relations'] as Map;
        expect(actualRelations.keys.toSet(), expectedRelations.keys.toSet());
        for (final relation in expectedRelations.keys) {
          expect(
            actualRelations[relation],
            closeTo(expectedRelations[relation] as double, 1e-12),
            reason: '$positional $relation binary',
          );
        }
        for (final dimension in ['groups', 'pillars']) {
          final actual = summary[dimension] as Map;
          for (final e in (reference[dimension] as Map).entries) {
            expect(
              actual[e.key],
              closeTo(e.value as double, 1e-12),
              reason: '$positional $dimension ${e.key}',
            );
          }
        }
        final actualGraded = summary['graded'] as Map;
        final expectedGraded = reference['graded'] as Map;
        expect(
          actualGraded['overall'],
          closeTo(expectedGraded['overall'] as double, 1e-12),
        );
        final gradedRelations = actualGraded['relations'] as Map;
        for (final e in (expectedGraded['relations'] as Map).entries) {
          expect(
            gradedRelations[e.key],
            closeTo(e.value as double, 1e-12),
            reason: '$positional ${e.key} graded',
          );
        }
        for (final row in (summary['checks'] as Map).values) {
          expect((row as Map)['n'], 240);
          expect(row['planned'], 240);
          expect(row['coverage'], 1.0);
        }
        final ci = summary['ci'] as Map;
        for (final e in (reference['ci'] as Map).entries) {
          final expected = e.value as List;
          final actual = ci[e.key] as List;
          expect(actual[0], closeTo(expected[0] as double, 1e-12));
          expect(actual[1], closeTo(expected[1] as double, 1e-12));
        }
      }
    },
  );
  test('original invalid probabilities stay unscored and rounding slack stays legal', () async {
    final suite = await CoherenceSuite.load(
      Directory('benchmarks/sources/coherence'),
    );
    final base = suite.tasks.first;
    final qs = base.body['questions'] as Map;
    final choiceId =
        qs.entries.firstWhere((e) => (e.value as Map)['type'] == 'choice').key
            as String;
    final noulId =
        qs.entries.firstWhere((e) => (e.value as Map)['type'] == 'noul').key
            as String;
    final options = ((qs[choiceId] as Map)['criteria'] as Map).keys
        .cast<String>()
        .toList();
    expect(options, hasLength(4));
    for (final invalid in [
      'negative',
      'zero',
      'missing',
      'nonfinite',
      'noul_high',
    ]) {
      final answers = _copyVectorAnswers(base);
      final choice = answers[choiceId] as Map;
      final probabilities = choice['probabilities'] as Map;
      switch (invalid) {
        case 'negative':
          probabilities[options.first] = -0.000002;
        case 'zero':
          for (final k in options) {
            probabilities[k] = 0;
          }
        case 'missing':
          probabilities.remove(options.first);
        case 'nonfinite':
          probabilities[options.first] = 'NaN';
        case 'noul_high':
          (answers[noulId] as Map)['noul'] = 1.000002;
      }
      final accumulator = suite.createAccumulator();
      final read = accumulator.record(base, _answersReply(answers));
      expect(read['source_valid'], isFalse, reason: invalid);
      expect(read['source_error'], isNotNull);
      expect(read['source_distributions'], isNull);
      final next = accumulator.record(
        suite.tasks[240],
        _vectorReply(suite.tasks[240], false),
      );
      expect(next['outcomes'], isEmpty);
      final unscored = next['unscored_trials'] as List;
      expect(unscored, isNotEmpty);
      expect((unscored.first as Map)['errors'] as Map, contains(base.id));
      final partial = accumulator.snapshot(complete: true).summary;
      expect(partial['complete'], isFalse);
      expect(partial['attempted'], 2);
      expect(partial['valid'], 1);
      expect(partial['invalid'], 1);
      expect(partial['unscored_tests'], greaterThan(0));
      expect(partial['overall'], isNull);
      expect((partial['graded'] as Map)['overall'], isNull);
      expect(partial['ci'], isEmpty);
    }
    final legal = _copyVectorAnswers(base);
    (legal[noulId] as Map)['noul'] = 1.0000005;
    final weights = (legal[choiceId] as Map)['probabilities'] as Map;
    weights[options.first] = 2;
    final read = suite.createAccumulator().record(base, _answersReply(legal));
    expect(read['source_valid'], isTrue);
    final distributions = read['source_distributions'] as Map;
    expect((distributions[noulId] as Map)['true'], 1.0);
    expect((distributions[noulId] as Map)['false'], 0.0);
    expect((distributions[choiceId] as Map)[options.first], .4);
    for (final option in options.skip(1)) {
      expect((distributions[choiceId] as Map)[option], .2);
    }
  });

  test('full original coverage threshold preserves failed base cases', () async {
    final suite = await CoherenceSuite.load(
      Directory('benchmarks/sources/coherence'),
    );
    for (final failedCases in [12, 13]) {
      final bad = suite.tasks.take(failedCases).map((t) => t.id).toSet();
      final accumulator = suite.createAccumulator();
      for (final task in suite.tasks) {
        accumulator.record(
          task,
          bad.contains(task.id)
              ? JevPlaygroundResult(
                  JevPlaygroundStatus.businessError,
                  'original base failure',
                  mode: JevPlaygroundMode.http,
                  timeout: const Duration(seconds: 30),
                  elapsed: const Duration(milliseconds: 1),
                )
              : _vectorReply(task, false),
        );
      }
      final summary = accumulator.snapshot(complete: true).summary;
      expect(summary['complete'], isTrue);
      expect(summary['attempted'], 10320);
      expect(summary['invalid'], failedCases);
      expect(summary['planned_tests'], 12000);
      expect(summary['judged_tests'], failedCases == 12 ? 11400 : 11350);
      expect(summary['unscored_tests'], failedCases == 12 ? 600 : 650);
      expect(summary['pending_tests'], 0);
      expect(summary['n_outcomes'], failedCases == 12 ? 14041 : 13970);
      for (final row in (summary['checks'] as Map).values) {
        expect((row as Map)['n'], failedCases == 12 ? 228 : 227);
        expect(row['planned'], 240);
        expect(row['coverage'], failedCases == 12 ? .95 : 227 / 240);
      }
      if (failedCases == 12) {
        // Original score.scores over all frozen outcomes except these 12 failed
        // base cases; 95% is scored, the original denominator is retained.
        expect(summary['overall'], closeTo(.8935500515995872, 1e-12));
        expect(summary['incomplete'], isEmpty);
      } else {
        expect(summary['overall'], isNull);
        expect((summary['graded'] as Map)['overall'], isNull);
        expect((summary['pillars'] as Map).values, everyElement(isNull));
        expect(summary['incomplete'] as List, hasLength(50));
        expect(summary['ci'], isEmpty);
      }
    }
  });
}

JevPlaygroundResult _vectorReply(FrozenQuestionTask task, bool positional) {
  final answers = <String, Object?>{};
  var position = 0;
  for (final entry in (task.body['questions'] as Map).entries) {
    final q = entry.value as Map;
    if (q['type'] == 'noul') {
      answers[entry.key as String] = {
        'type': 'noul',
        'noul': positional ? (position % 7 + 1) / 10 : .5,
      };
    } else {
      final criteria = q['criteria'];
      final keys = q['type'] == 'score'
          ? List.generate((criteria as List).length, (i) => '$i')
          : (criteria as Map).keys.cast<String>().toList();
      answers[entry.key as String] = {
        'type': q['type'],
        'probabilities': {
          for (var i = 0; i < keys.length; i++) keys[i]: positional ? i + 1 : 1,
        },
      };
    }
    position++;
  }
  return JevPlaygroundResult(
    JevPlaygroundStatus.success,
    'known vector',
    output: {'answers': answers},
    mode: JevPlaygroundMode.http,
    timeout: const Duration(seconds: 30),
    elapsed: const Duration(milliseconds: 1),
  );
}

Map<String, Object?> _copyVectorAnswers(FrozenQuestionTask task) =>
    Map<String, Object?>.from(
      jsonDecode(jsonEncode(_vectorReply(task, false).output!['answers']))
          as Map,
    );

JevPlaygroundResult _answersReply(Map<String, Object?> answers) =>
    JevPlaygroundResult(
      JevPlaygroundStatus.success,
      'original schema vector',
      output: {'answers': answers},
      mode: JevPlaygroundMode.http,
      timeout: const Duration(seconds: 30),
      elapsed: const Duration(milliseconds: 1),
    );

// Produced by the pinned original Python engine/REGISTRY/score before the
// Dart scorer existed; both use all 12000 tests and default 1000/seed0 bootstrap.
const _uniformReference = <String, Object?>{
  "overall": 0.893578431372549,
  "relations": {
    "batch_content": 1.0,
    "batch_order": 1.0,
    "batch_size_sweep": 1.0,
    "batch_solo": 1.0,
    "choice_complement": 0.0,
    "choice_indicator": 0.0,
    "clone_symmetry": 1.0,
    "compound_negation": 1.0,
    "count_lower": 1.0,
    "count_upper": 1.0,
    "cross_lingual": 1.0,
    "de_morgan": 1.0,
    "description_paraphrase": 1.0,
    "description_swap": 1.0,
    "duplicate_question": 1.0,
    "entailment_strength": 1.0,
    "extreme_level": 0.0,
    "frechet_and_upper": 1.0,
    "inclusion_exclusion": 1.0,
    "instruction_paraphrase": 1.0,
    "irrelevant_option": 1.0,
    "key_instruction_conflict": 1.0,
    "key_rename": 1.0,
    "name_description_conflict": 1.0,
    "nary_and_lower": 1.0,
    "nary_and_upper": 1.0,
    "nary_or_lower": 1.0,
    "nary_or_upper": 1.0,
    "natural_negation": 1.0,
    "negation_wrapper": 1.0,
    "noul_as_choice": 1.0,
    "noul_as_score": 1.0,
    "option_clone": 0.0,
    "option_closure": 1.0,
    "option_merge": 0.0,
    "option_permutation": 1.0,
    "option_rename": 1.0,
    "option_split": 0.0,
    "pair_choice_marginals": 1.0,
    "pairwise_iia": 1.0,
    "partition_hierarchy": 1.0,
    "quantifier_monotonicity": 1.0,
    "remove_option_iia": 1.0,
    "score_complement": 0.0,
    "score_cumulative": 0.0,
    "score_granularity": 0.9541666666666667,
    "similarity_effect": 0.0,
    "threshold_sweep": 1.0,
    "typo_noise": 1.0,
    "verbosity": 1.0,
  },
  "groups": {
    "REP.invariance": 1.0,
    "REP.equivariance": 1.0,
    "REP.binding": 1.0,
    "REP.type": 1.0,
    "BAT.isolation": 1.0,
    "MEA.complement": 0.6,
    "MEA.partition": 0.3692708333333333,
    "MEA.marginalisation": 0.5,
    "LOG.bounds": 1.0,
    "LOG.monotonicity": 1.0,
    "CHO.conditioning": 1.0,
  },
  "pillars": {
    "REP": 1.0,
    "BAT": 1.0,
    "MEA": 0.4678921568627451,
    "LOG": 1.0,
    "CHO": 1.0,
  },
  "graded": {
    "relations": {
      "batch_content": 1.0,
      "batch_order": 1.0,
      "batch_size_sweep": 1.0,
      "batch_solo": 1.0,
      "choice_complement": 0.7894736842105263,
      "choice_indicator": 0.7894736842105263,
      "clone_symmetry": 1.0,
      "compound_negation": 1.0,
      "count_lower": 1.0,
      "count_upper": 1.0,
      "cross_lingual": 1.0,
      "de_morgan": 1.0,
      "description_paraphrase": 1.0,
      "description_swap": 1.0,
      "duplicate_question": 1.0,
      "entailment_strength": 1.0,
      "extreme_level": 0.89546783625731,
      "frechet_and_upper": 1.0,
      "inclusion_exclusion": 1.0,
      "instruction_paraphrase": 1.0,
      "irrelevant_option": 1.0,
      "key_instruction_conflict": 1.0,
      "key_rename": 1.0,
      "name_description_conflict": 1.0,
      "nary_and_lower": 1.0,
      "nary_and_upper": 1.0,
      "nary_or_lower": 1.0,
      "nary_or_upper": 1.0,
      "natural_negation": 1.0,
      "negation_wrapper": 1.0,
      "noul_as_choice": 1.0,
      "noul_as_score": 1.0,
      "option_clone": 0.8947368421052632,
      "option_closure": 1.0,
      "option_merge": 0.8771929824561404,
      "option_permutation": 1.0,
      "option_rename": 1.0,
      "option_split": 0.8947368421052632,
      "pair_choice_marginals": 1.0,
      "pairwise_iia": 1.0,
      "partition_hierarchy": 1.0,
      "quantifier_monotonicity": 1.0,
      "remove_option_iia": 1.0,
      "score_complement": 0.7868421052631579,
      "score_cumulative": 0.7872807017543859,
      "score_granularity": 0.9975877192982456,
      "similarity_effect": 0.8947368421052632,
      "threshold_sweep": 1.0,
      "typo_noise": 1.0,
      "verbosity": 1.0,
    },
    "groups": {
      "REP.invariance": 1.0,
      "REP.equivariance": 1.0,
      "REP.binding": 1.0,
      "REP.type": 1.0,
      "BAT.isolation": 1.0,
      "MEA.complement": 0.9152631578947369,
      "MEA.partition": 0.9318073830409357,
      "MEA.marginalisation": 0.8941885964912281,
      "LOG.bounds": 1.0,
      "LOG.monotonicity": 1.0,
      "CHO.conditioning": 1.0,
    },
    "pillars": {
      "REP": 1.0,
      "BAT": 1.0,
      "MEA": 0.9180899552803578,
      "LOG": 1.0,
      "CHO": 1.0,
    },
    "overall": 0.9836179910560715,
  },
  "ci": {
    "overall": [0.893235294117647, 0.8938235294117647],
    "graded_overall": [0.9835706914344685, 0.9836549707602339],
  },
};
const _positionReference = <String, Object?>{
  "overall": 0.4690343137254902,
  "relations": {
    "batch_content": 1.0,
    "batch_order": 0.0,
    "batch_size_sweep": 1.0,
    "batch_solo": 0.4458333333333333,
    "choice_complement": 0.02083333333333337,
    "choice_indicator": 0.0,
    "clone_symmetry": 0.0,
    "compound_negation": 0.0,
    "count_lower": 1.0,
    "count_upper": 0.8125,
    "cross_lingual": 1.0,
    "de_morgan": 0.0,
    "description_paraphrase": 1.0,
    "description_swap": 0.0,
    "duplicate_question": 0.4291666666666667,
    "entailment_strength": 0.3458333333333333,
    "extreme_level": 0.0,
    "frechet_and_upper": 0.3583333333333333,
    "inclusion_exclusion": 0.1958333333333333,
    "instruction_paraphrase": 1.0,
    "irrelevant_option": 0.4083333333333333,
    "key_instruction_conflict": 1.0,
    "key_rename": 1.0,
    "name_description_conflict": 1.0,
    "nary_and_lower": 1.0,
    "nary_and_upper": 0.1791666666666667,
    "nary_or_lower": 0.4541666666666667,
    "nary_or_upper": 0.9958333333333333,
    "natural_negation": 0.04166666666666663,
    "negation_wrapper": 0.04166666666666663,
    "noul_as_choice": 0.11250000000000004,
    "noul_as_score": 0.01666666666666672,
    "option_clone": 0.0,
    "option_closure": 1.0,
    "option_merge": 0.0,
    "option_permutation": 0.0,
    "option_rename": 1.0,
    "option_split": 0.0,
    "pair_choice_marginals": 0.004166666666666652,
    "pairwise_iia": 0.33333333333333337,
    "partition_hierarchy": 0.23333333333333328,
    "quantifier_monotonicity": 0.8333333333333334,
    "remove_option_iia": 0.5,
    "score_complement": 0.054166666666666696,
    "score_cumulative": 0.0,
    "score_granularity": 0.9541666666666667,
    "similarity_effect": 0.0,
    "threshold_sweep": 0.0,
    "typo_noise": 1.0,
    "verbosity": 1.0,
  },
  "groups": {
    "REP.invariance": 0.8571428571428571,
    "REP.equivariance": 0.3333333333333333,
    "REP.binding": 0.6666666666666666,
    "REP.type": 0.06458333333333338,
    "BAT.isolation": 0.575,
    "MEA.complement": 0.03166666666666666,
    "MEA.partition": 0.2734375,
    "MEA.marginalisation": 0.04999999999999999,
    "LOG.bounds": 0.6857142857142857,
    "LOG.monotonicity": 0.39305555555555555,
    "CHO.conditioning": 0.4138888888888889,
  },
  "pillars": {
    "REP": 0.6086111111111111,
    "BAT": 0.575,
    "MEA": 0.1497549019607843,
    "LOG": 0.5979166666666667,
    "CHO": 0.4138888888888889,
  },
  "graded": {
    "relations": {
      "batch_content": 1.0,
      "batch_order": 0.6074561403508771,
      "batch_size_sweep": 1.0,
      "batch_solo": 0.8730263157894737,
      "choice_complement": 0.6094298245614035,
      "choice_indicator": 0.8070175438596491,
      "clone_symmetry": 0.9824561403508772,
      "compound_negation": 0.6885964912280702,
      "count_lower": 1.0,
      "count_upper": 0.9682017543859649,
      "cross_lingual": 1.0,
      "de_morgan": 0.8596491228070176,
      "description_paraphrase": 1.0,
      "description_swap": 0.881140350877193,
      "duplicate_question": 0.9151315789473684,
      "entailment_strength": 0.9054824561403508,
      "extreme_level": 0.8425229741019216,
      "frechet_and_upper": 0.8899122807017543,
      "inclusion_exclusion": 0.7879385964912281,
      "instruction_paraphrase": 1.0,
      "irrelevant_option": 0.997644679881522,
      "key_instruction_conflict": 1.0,
      "key_rename": 1.0,
      "name_description_conflict": 1.0,
      "nary_and_lower": 1.0,
      "nary_and_upper": 0.8445175438596491,
      "nary_or_lower": 0.9532894736842106,
      "nary_or_upper": 0.9989035087719298,
      "natural_negation": 0.662719298245614,
      "negation_wrapper": 0.6425438596491229,
      "noul_as_choice": 0.7983187134502925,
      "noul_as_score": 0.6779239766081872,
      "option_clone": 0.8970760233918128,
      "option_closure": 1.0,
      "option_merge": 0.8244152046783626,
      "option_permutation": 0.7333333333333333,
      "option_rename": 1.0,
      "option_split": 0.8928362573099415,
      "pair_choice_marginals": 0.5800438596491228,
      "pairwise_iia": 0.968671679197995,
      "partition_hierarchy": 0.860672514619883,
      "quantifier_monotonicity": 0.9035087719298246,
      "remove_option_iia": 0.9928989139515456,
      "score_complement": 0.6119152046783626,
      "score_cumulative": 0.4546783625730994,
      "score_granularity": 0.9959795321637427,
      "similarity_effect": 0.8922514619883041,
      "threshold_sweep": 0.6162280701754386,
      "typo_noise": 1.0,
      "verbosity": 1.0,
    },
    "groups": {
      "REP.invariance": 0.9799498746867168,
      "REP.equivariance": 0.9052631578947369,
      "REP.binding": 0.9603801169590643,
      "REP.type": 0.7381213450292399,
      "BAT.isolation": 0.8791228070175439,
      "MEA.complement": 0.6430409356725146,
      "MEA.partition": 0.900719246031746,
      "MEA.marginalisation": 0.6574195906432748,
      "LOG.bounds": 0.9506892230576441,
      "LOG.monotonicity": 0.808406432748538,
      "CHO.conditioning": 0.9864050910103542,
    },
    "pillars": {
      "REP": 0.9288547758284601,
      "BAT": 0.8791228070175439,
      "MEA": 0.7676845299523318,
      "LOG": 0.9080043859649123,
      "CHO": 0.9864050910103542,
    },
    "overall": 0.8940143179547204,
  },
  "ci": {
    "overall": [0.46019281045751637, 0.4780964052287582],
    "graded_overall": [0.8919252971257615, 0.8961590688198016],
  },
};
