import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'benchmark_random.dart';
import 'benchmark_statistics.dart';
import 'frozen_question_suite.dart';
import 'jev_playground.dart';

/// The original JevBench/jevbench-240 request plan, separate from JEVal.
class CoherenceSuite implements FrozenQuestionSuite {
  CoherenceSuite._(this.tasks, this._trials);

  static const pin = 'e18733694623aa93058e279c3534f8b8e2edefa3';
  static const suitePath = 'src/jevbench/suites/jevbench-240';
  static const resourceFiles = <Map<String, Object?>>[
    {
      'path': 'LICENSE',
      'bytes': 11358,
      'sha256':
          'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
    },
    {
      'path': 'NOTICE',
      'bytes': 170,
      'sha256':
          '81713e5b675aba6ea07ae34b1b44e00ff8ab73a1dc9e43ba48e92b82ea21eb18',
    },
    {
      'path': 'CITATION.cff',
      'bytes': 1233,
      'sha256':
          '39a7ef068e319585e8ce7627d4cb75f9138b3828f315cf3f63b398ef5ca24692',
    },
    {
      'path': 'README.md',
      'bytes': 13447,
      'sha256':
          'e7ad0650ddf37515204ad956e34677fb6d87cbdfbe7cd29ac28288546a1ba011',
    },
    {
      'path': 'src/jevbench/suites/jevbench-240/manifest.json',
      'bytes': 1516,
      'sha256':
          'e700db0cfc990a6910ebeb80f6c9e1c271043ecf5d771c042dbbdcefa8e8673a',
    },
    {
      'path': 'src/jevbench/suites/jevbench-240/cases.jsonl',
      'bytes': 796777,
      'sha256':
          '7725c67da08b335fd708621205b6444a9ac087b4ea1f76b745c5e5596fe226c5',
    },
    {
      'path': 'src/jevbench/suites/jevbench-240/rewrites.jsonl',
      'bytes': 827064,
      'sha256':
          'f19478f8d475dfdf6db5f78bd31c03ec7d33e0b62018e1ff92cd4646a769f833',
    },
    {
      'path': 'src/jevbench/suites/jevbench-240/tests.jsonl.gz',
      'bytes': 978928,
      'sha256':
          '9acc75335065f537a1ec2fa0caa9cdb7a9c3984741ebfd9a3ab184f73a86a377',
    },
  ];

  @override
  final List<FrozenQuestionTask> tasks;
  final List<_CoherenceTrial> _trials;

  @override
  Map<String, Object?> get identity => const {
    'id': 'coherence',
    'name': '一致性 JevBench',
    'source': 'https://github.com/JevBench/jevbench',
    'pin': pin,
    'suite': 'jevbench-240',
    'version': '1',
    'license': 'Apache-2.0',
    'cases': 240,
    'questions': 2240,
    'relations': 50,
    'tests': 12000,
    'requests': 10320,
    'files': resourceFiles,
    'scoring_reference_runtime': 'CPython 3.12.14',
    'upstream_historical_runtime': null,
    'sum_processing': 'CPython 3.12 finite-float Neumaier compensated sum',
    'probability_processing':
        'Original schema EPS=1e-6; nonnegative finite choice/score weights '
        'with positive sum are normalized; noul outside rounding slack fails.',
  };

  static Future<CoherenceSuite> load(Directory root) async {
    for (final item in resourceFiles) {
      final path = item['path'] as String;
      final bytes = await File('${root.path}/$path').readAsBytes();
      if (bytes.length != item['bytes'] ||
          sha256.convert(bytes).toString() != item['sha256']) {
        throw FormatException('Coherence resource mismatch: $path');
      }
    }
    final cases = <String, Map<String, Object?>>{};
    for (final row in _jsonLines(
      await File('${root.path}/$suitePath/cases.jsonl').readAsString(),
    )) {
      final id = row['id'];
      if (id is! String || cases.containsKey(id)) {
        throw const FormatException('Invalid coherence case id');
      }
      _questions(row['questions']);
      cases[id] = row;
    }
    final packed = await File('${root.path}/$suitePath/tests.jsonl.gz')
        .readAsBytes();
    final plan = _jsonLines(utf8.decode(gzip.decode(packed))).toList();
    final head = plan.removeAt(0);
    if (cases.length != 240 ||
        cases.values.fold(0, (n, c) => n + _map(c['questions']).length) !=
            2240 ||
        plan.length != 12000 ||
        head['format'] != 1 ||
        head['seed'] != 0 ||
        head['trials'] != 1 ||
        (head['relations'] as List).length != 50) {
      throw const FormatException('Incomplete frozen coherence suite');
    }
    final tasks = <FrozenQuestionTask>[];
    final unique = <String, String>{};
    String addRequest(
      Map<String, Object?> c,
      Map<String, Object?> qs,
      String stage,
    ) {
      final body = <String, Object?>{'state': c['state'], 'questions': qs};
      final serialized = jsonEncode(
        body,
      ); // Order is part of the original task.
      return unique.putIfAbsent(serialized, () {
        final id = 'coherence-request-${tasks.length}';
        tasks.add(
          FrozenQuestionTask(
            id: id,
            body: _freeze(body) as Map<String, Object?>,
            metadata: {
              'case_id': c['id'],
              'domain': c['domain'],
              'stage': stage,
              'question_ids': List<String>.unmodifiable(qs.keys),
            },
          ),
        );
        return id;
      });
    }

    final bases = <String, String>{};
    for (final c in cases.values) {
      bases[c['id'] as String] = addRequest(c, _map(c['questions']), 'base');
    }
    final trials = <_CoherenceTrial>[];
    // Frozen rows already use case and author taxonomy relation order.
    for (final row in plan) {
      final caseId = row['case'] as String;
      final c = cases[caseId];
      if (c == null) throw const FormatException('Unknown plan case');
      final requestIds = <String, String>{};
      for (final req in _map(row['requests']).entries) {
        final qs = <String, Object?>{};
        for (final entry in req.value as List) {
          final pair = entry as List;
          final key = pair[0] as String;
          final q = _map(pair[1]);
          qs[key] = q.length == 1 && q.containsKey('@')
              ? _map(c['questions'])[q['@']]
              : q;
        }
        _questions(qs);
        requestIds[req.key] = addRequest(c, qs, 'trial');
      }
      trials.add(
        _CoherenceTrial(
          row: _freeze(row) as Map<String, Object?>,
          baseId: bases[caseId]!,
          requestIds: Map.unmodifiable(requestIds),
        ),
      );
    }
    if (tasks.length != 10320 ||
        trials.map((t) => t.row['relation']).toSet().length != 50) {
      throw const FormatException('Frozen coherence request count mismatch');
    }
    return CoherenceSuite._(
      List.unmodifiable(tasks),
      List.unmodifiable(trials),
    );
  }

  @override
  FrozenQuestionAccumulator createAccumulator() => _CoherenceAccumulator(this);
}

class _CoherenceTrial {
  const _CoherenceTrial({
    required this.row,
    required this.baseId,
    required this.requestIds,
  });
  final Map<String, Object?> row;
  final String baseId;
  final Map<String, String> requestIds;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((k) => k is! String)) {
    throw const FormatException('Expected JSON object');
  }
  return Map<String, Object?>.from(value);
}

Iterable<Map<String, Object?>> _jsonLines(String text) sync* {
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isNotEmpty) yield _map(jsonDecode(line));
  }
}

void _questions(Object? value) {
  final qs = _map(value);
  if (qs.isEmpty) throw const FormatException('Empty coherence questions');
  for (final q in qs.values) {
    final row = _map(q);
    if (row['instructions'] is! String ||
        (row['instructions'] as String).trim().isEmpty) {
      throw const FormatException('Invalid original question instructions');
    }
    final c = row['criteria'];
    switch (row['type']) {
      case 'noul':
        if (c != null && (c is! Map || c.isNotEmpty)) {
          throw const FormatException('Invalid original noul criteria');
        }
      case 'choice':
        final options = _map(c);
        if (options.length < 2 || options.values.any((v) => v is! String)) {
          throw const FormatException('Invalid original choice criteria');
        }
      case 'score':
        if (c is! List || c.length < 2 || c.any((v) => v is! String)) {
          throw const FormatException('Invalid original score criteria');
        }
      default:
        throw const FormatException('Unknown original question type');
    }
  }
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final e in value.entries) e.key as String: _freeze(e.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

typedef _Distributions = Map<String, Map<String, double>>;

class _CoherenceReply {
  const _CoherenceReply(this.distributions, this.error);
  final _Distributions? distributions;
  final String? error;
}

class _CoherenceAccumulator implements FrozenQuestionAccumulator {
  _CoherenceAccumulator(this.suite) {
    for (final trial in suite._trials) {
      for (final id in {trial.baseId, ...trial.requestIds.values}) {
        _dependents.putIfAbsent(id, () => []).add(trial);
      }
    }
  }

  final CoherenceSuite suite;
  final _replies = <String, _CoherenceReply>{};
  final _dependents = <String, List<_CoherenceTrial>>{};
  final _judged = <_CoherenceTrial>{};
  final _cells = <String, Map<String, double>>{};
  final _unscored = <Map<String, Object?>>[];
  var _valid = 0;
  var _nOutcomes = 0;
  FrozenQuestionScore? _completeScore;

  @override
  Map<String, Object?> record(
    FrozenQuestionTask task,
    JevPlaygroundResult reply,
  ) {
    if (!suite.tasks.contains(task) || _replies.containsKey(task.id)) {
      throw StateError('Unknown or repeated coherence request');
    }
    _Distributions? distributions;
    String? error;
    if (reply.status != JevPlaygroundStatus.success) {
      error = '${reply.status.name}: ${reply.message}';
    } else {
      try {
        final answers = _map(reply.output?['answers']);
        distributions = Map.unmodifiable({
          for (final q in _map(task.body['questions']).entries)
            q.key: _distribution(_map(answers[q.key]), _map(q.value)),
        });
        _valid++;
      } on FormatException catch (e) {
        error = e.message;
      }
    }
    _replies[task.id] = _CoherenceReply(distributions, error);
    final outcomes = <Map<String, Object?>>[];
    final unscored = <Map<String, Object?>>[];
    for (final trial in _dependents[task.id] ?? <_CoherenceTrial>[]) {
      if (_judged.contains(trial)) continue;
      final dependencies = {trial.baseId, ...trial.requestIds.values};
      if (dependencies.any((id) => !_replies.containsKey(id))) continue;
      _judged.add(trial);
      final failed = dependencies.where((id) => _replies[id]!.error != null);
      if (failed.isNotEmpty) {
        final row = <String, Object?>{
          'trial_id': _trialId(trial.row),
          'case_id': trial.row['case'],
          'relation': trial.row['relation'],
          'target': trial.row['key'],
          'unscored': 'base or required frozen request failed',
          'errors': {for (final id in failed) id: _replies[id]!.error},
        };
        _unscored.add(row);
        unscored.add(row);
        continue;
      }
      final evaluated = _evaluate(
        trial.row,
        _replies[trial.baseId]!.distributions!,
        {
          for (final e in trial.requestIds.entries)
            e.key: _replies[e.value]!.distributions!,
        },
      );
      outcomes.addAll(evaluated);
      _nOutcomes += evaluated.length;
      final deviation = evaluated
          .map((o) => o['deviation'] as double)
          .reduce(math.max);
      _cells.putIfAbsent(
        trial.row['relation'] as String,
        () => {},
      )[trial.row['case'] as String] = deviation;
    }
    return {
      'source_valid': distributions != null,
      'source_error': error,
      'source_distributions': distributions,
      'outcomes': outcomes,
      'unscored_trials': unscored,
    };
  }

  @override
  FrozenQuestionScore snapshot({required bool complete}) {
    final finished = complete && _replies.length == suite.tasks.length;
    if (finished && _completeScore != null) return _completeScore!;
    final checks = <String, Object?>{};
    final binary = <String, double>{};
    final graded = <String, double>{};
    final incomplete = <String>[];
    var judgedTests = 0;
    for (final e in _relations.entries) {
      final values = _cells[e.key]?.values.toList() ?? <double>[];
      final n = values.length;
      judgedTests += n;
      final coverage = n / 240;
      final score = n == 0 ? null : 1 - values.where((d) => d > .05).length / n;
      final grade = n == 0 ? null : _mean(values.map(_graded));
      final excluded = coverage < .95
          ? 'coverage ${(coverage * 100).toStringAsFixed(0)}% < 95%'
          : n < 5
          ? 'n < 5'
          : null;
      if (coverage < .95) incomplete.add(e.key);
      if (excluded == null) {
        binary[e.key] = score!;
        graded[e.key] = grade!;
      }
      checks['${e.key}/${e.value['check']}'] = {
        'n': n,
        'planned': 240,
        'coverage': coverage,
        'violations': values.where((d) => d > .05).length,
        'score': finished ? score : null,
        'graded': finished ? grade : null,
        'excluded': ?excluded,
      };
    }
    incomplete.sort();
    final b = _aggregate(binary, incomplete, finished);
    final g = _aggregate(graded, incomplete, finished);
    final result = FrozenQuestionScore(
      summary: {
        'complete': finished,
        'attempted': _replies.length,
        'valid': _valid,
        'invalid': _replies.length - _valid,
        'unattempted': suite.tasks.length - _replies.length,
        'expected_requests': suite.tasks.length,
        'planned_tests': 12000,
        'judged_tests': judgedTests,
        'unscored_tests': _unscored.length,
        'pending_tests': 12000 - _judged.length,
        'n_outcomes': _nOutcomes,
        'checks': checks,
        ...b,
        'graded': g,
        'incomplete': incomplete,
        'tolerance': 'fixed 0.05',
        'min_n': 5,
        'min_coverage': .95,
        'bootstrap': 1000,
        'seed': 0,
        'ci': finished && incomplete.isEmpty
            ? _bootstrap(_cells, binary.keys)
            : <String, Object?>{},
        'n_cases': {for (final rel in binary.keys) ..._cells[rel]!.keys}.length,
        'n_checks': binary.length,
        'skipped_outcomes': 0,
        'excluded': const {'low_n': [], 'exploratory': [], 'diagnostic': []},
        'mean_repeat_noise': null,
      },
      groups: [
        for (final e in _relations.entries)
          {
            'relation': e.key,
            ...e.value,
            ..._map(checks['${e.key}/${e.value['check']}']),
          },
      ],
    );
    if (finished) _completeScore = result;
    return result;
  }
}

String _trialId(Map<String, Object?> row) =>
    '${row['relation']}:${row['case']}:${row['key']}:${row['t']}'
    '${row['v'] == 0 ? '' : ':v${row['v']}'}';

double _graded(double deviation) =>
    1 - math.min(1.0, math.max(0.0, deviation - .05) / .95);

double _mean(Iterable<double> values) =>
    values.fold(0.0, (sum, x) => sum + x) / values.length;

Map<String, Object?> _aggregate(
  Map<String, double> relations,
  List<String> incomplete,
  bool finished,
) {
  final byGroup = <String, List<double>>{};
  final byPillar = <String, List<double>>{};
  for (final e in relations.entries) {
    final group = _relations[e.key]!['group'] as String;
    byGroup.putIfAbsent(group, () => []).add(e.value);
    byPillar.putIfAbsent(group.split('.').first, () => []).add(e.value);
  }
  final groups = <String, double?>{
    for (final group in _relations.values.map((e) => e['group'] as String))
      group: finished && byGroup.containsKey(group)
          ? _mean(byGroup[group]!)
          : null,
  };
  final pillars = <String, double?>{
    for (final p in ['REP', 'BAT', 'MEA', 'LOG', 'CHO'])
      p: finished && byPillar.containsKey(p) ? _mean(byPillar[p]!) : null,
  };
  for (final rel in incomplete) {
    final group = _relations[rel]!['group'] as String;
    groups[group] = pillars[group.split('.').first] = null;
  }
  return {
    'relations': {
      for (final e in relations.entries) e.key: finished ? e.value : null,
    },
    'groups': groups,
    'pillars': pillars,
    'overall': pillars.values.every((v) => v != null)
        ? _mean(pillars.values.cast<double>())
        : null,
  };
}

/// Case resampling uses the original Python random stream, not Dart Random.
Map<String, Object?> _bootstrap(
  Map<String, Map<String, double>> cells,
  Iterable<String> included,
) {
  final relations = included.toList()..sort();
  final cases = {for (final r in relations) ...cells[r]!.keys}.toList()..sort();
  if (cases.length < 2) return {};
  final deviations = [
    for (final r in relations) [for (final c in cases) cells[r]![c]],
  ];
  const pillars = ['REP', 'BAT', 'MEA', 'LOG', 'CHO'];
  final dimensions = [
    for (final r in relations)
      pillars.indexOf((_relations[r]!['group'] as String).split('.').first),
  ];
  final random = BenchmarkRandom(seed: 0);
  final binary = <double>[];
  final graded = <double>[];
  for (var draw = 0; draw < 1000; draw++) {
    final repetitions = List<int>.filled(cases.length, 0);
    for (var i = 0; i < cases.length; i++) {
      repetitions[random.index(cases.length)]++;
    }
    final b = List<double>.filled(5, 0);
    final g = List<double>.filled(5, 0);
    final counts = List<int>.filled(5, 0);
    for (var r = 0; r < relations.length; r++) {
      var n = 0;
      var violations = 0;
      var grade = 0.0;
      for (var c = 0; c < cases.length; c++) {
        final deviation = deviations[r][c];
        if (deviation == null || repetitions[c] == 0) continue;
        final copies = repetitions[c];
        n += copies;
        if (deviation > .05) violations += copies;
        grade += _graded(deviation) * copies;
      }
      if (n == 0) continue;
      final dimension = dimensions[r];
      b[dimension] += 1 - violations / n;
      g[dimension] += grade / n;
      counts[dimension]++;
    }
    if (counts.any((n) => n == 0)) continue;
    binary.add(_mean(List.generate(5, (i) => b[i] / counts[i])));
    graded.add(_mean(List.generate(5, (i) => g[i] / counts[i])));
  }
  List<double> interval(List<double> values) {
    values.sort();
    return [
      values[(.025 * (values.length - 1)).floor()],
      values[(.975 * (values.length - 1)).floor()],
    ];
  }

  return {
    if (binary.isNotEmpty) 'overall': interval(binary),
    if (graded.isNotEmpty) 'graded_overall': interval(graded),
  };
}

Map<String, double> _distribution(
  Map<String, Object?> answer,
  Map<String, Object?> q,
) {
  double probability(Object? value) {
    final number = switch (value) {
      num v => v.toDouble(),
      String v => double.tryParse(v),
      bool v => v ? 1.0 : 0.0,
      _ => null,
    };
    if (number == null || !number.isFinite || number < -1e-6) {
      throw const FormatException(
        'Original probability is negative or nonfinite',
      );
    }
    return math.max(0.0, number);
  }

  if (q['type'] == 'noul') {
    final value = probability(answer['noul']);
    if (value > 1 + 1e-6) {
      throw const FormatException('Original noul probability exceeds one');
    }
    final p = math.min(1.0, value);
    return Map.unmodifiable({'false': 1 - p, 'true': p});
  }
  final raw = _map(answer['probabilities']);
  final keys = <String>[];
  final outputKeys = <String>[];
  if (q['type'] == 'choice') {
    keys.addAll(_map(q['criteria']).keys);
    outputKeys.addAll(keys);
  } else {
    final levels = q['criteria'] as List;
    final indices = List.generate(levels.length, (i) => '$i');
    final texts = levels.cast<String>();
    final hasIndices = indices.every(raw.containsKey);
    final hasTexts = texts.every(raw.containsKey);
    if (hasIndices && hasTexts && jsonEncode(indices) != jsonEncode(texts)) {
      throw const FormatException('Ambiguous original score level keys');
    }
    if (!hasIndices && !hasTexts) {
      throw const FormatException('Missing original score levels');
    }
    keys.addAll(hasIndices ? indices : texts);
    outputKeys.addAll(indices);
  }
  if (keys.any((k) => !raw.containsKey(k))) {
    throw const FormatException('Missing original choice options');
  }
  final weights = keys.map((k) => probability(raw[k])).toList();
  final total = benchmarkSum(weights);
  if (total <= 0) {
    throw const FormatException('Original probabilities have zero sum');
  }
  return Map.unmodifiable({
    for (var i = 0; i < keys.length; i++) outputKeys[i]: weights[i] / total,
  });
}

double _tv(Map<String, double> a, Map<String, double> b) =>
    .5 *
    benchmarkSum(
      {
        ...a.keys,
        ...b.keys,
      }.map((key) => ((a[key] ?? 0) - (b[key] ?? 0)).abs()),
    );

String _argmax(Map<String, double> d) =>
    d.entries.reduce((a, b) => b.value > a.value ? b : a).key;

Map<String, double> _restricted(Map<String, double> d, Iterable<String> keep) {
  final keys = keep.toList();
  final total = benchmarkSum(keys.map((k) => d[k]!));
  return {for (final k in keys) k: total > 0 ? d[k]! / total : 1 / keys.length};
}

List<Map<String, Object?>> _evaluate(
  Map<String, Object?> row,
  _Distributions base,
  Map<String, _Distributions> answers,
) {
  final name = row['relation'] as String;
  final targets = (row['targets'] as List).cast<String>();
  final key = targets.first;
  final params = _map(row['params']);
  final variant = answers['variant']!;
  final original = base[key]!;
  final output = <Map<String, Object?>>[];
  double p(String parameter) => variant[params[parameter]]!['true']!;
  void outcome(
    double deviation, {
    bool? flip,
    Map<String, Object?> detail = const {},
    List<String>? outcomeTargets,
  }) {
    output.add({
      'relation': name,
      'check': _relations[name]!['check'],
      'case_id': row['case'],
      'targets': outcomeTargets ?? targets,
      'deviation': deviation,
      'tolerance': .05,
      'tolerance_kind': name == 'threshold_sweep' ? 'own' : 'noise',
      'violated': deviation > .05,
      'flip': flip,
      'detail': detail,
      'trial_id': _trialId(row),
      'variant': row['v'],
    });
  }

  void equality(
    Map<String, double> d,
    Map<String, double> expected, {
    Map<String, Object?> detail = const {},
  }) {
    outcome(
      _tv(d, expected),
      flip: _argmax(d) != _argmax(expected),
      detail: detail,
    );
  }

  switch (name) {
    case 'option_permutation':
      var d = variant[key]!;
      if (params['order'] == 'reversed') {
        d = {
          for (final e in d.entries)
            '${d.length - 1 - int.parse(e.key)}': e.value,
        };
      }
      equality(d, original);
    case 'option_rename':
      final mapping = _map(params['mapping']);
      equality({
        for (final e in variant[key]!.entries)
          mapping[e.key] as String: e.value,
      }, original);
    case 'key_rename':
      equality(variant[params['new_key']]!, original);
    case 'noul_as_choice':
    case 'noul_as_score':
      final a = variant[key]![name == 'noul_as_choice' ? 'yes' : '1']!;
      final b = original['true']!;
      outcome(
        (a - b).abs(),
        flip: (a > .5) != (b > .5),
        detail: {
          name == 'noul_as_choice' ? 'p_choice' : 'p_score': a,
          'p_noul': b,
        },
      );
    case 'description_swap':
    case 'name_description_conflict':
      final pair = (params['pair'] as List).cast<String>();
      final d = {...variant[key]!};
      final temp = d[pair[0]]!;
      d[pair[0]] = d[pair[1]]!;
      d[pair[1]] = temp;
      equality(
        d,
        original,
        detail: {
          if (name == 'description_swap')
            'base_pair': pair.map((k) => original[k]).toList(),
        },
      );
    case 'typo_noise':
    case 'verbosity':
    case 'instruction_paraphrase':
    case 'description_paraphrase':
    case 'cross_lingual':
    case 'batch_solo':
    case 'batch_content':
      equality(
        variant[key]!,
        original,
        detail: {
          if (name == 'typo_noise') 'kind': params['kind'],
          if (name == 'instruction_paraphrase' ||
              name == 'description_paraphrase')
            'rewrite': params['rewrite'],
          if (name == 'description_paraphrase') 'option': params['option'],
          if (name == 'cross_lingual') ...{
            'language': params['language'],
            'translation': params['translation'],
          },
        },
      );
    case 'key_instruction_conflict':
      for (final e in _map(params['keys']).entries) {
        final d = variant[e.value]!;
        final b = base[e.key]!;
        outcome(
          _tv(d, b),
          flip: _argmax(d) != _argmax(b),
          outcomeTargets: [e.key],
          detail: {'sent_as': e.value},
        );
      }
    case 'clone_symmetry':
      final d = variant[key]!;
      final a = d[params['option']]!, b = d[params['clone']]!;
      outcome((a - b).abs(), detail: {'p_original': a, 'p_clone': b});
    case 'de_morgan':
      final a = p('nand'), b = p('or_not');
      outcome(
        (a - b).abs(),
        flip: (a > .5) != (b > .5),
        detail: {'p_nand': a, 'p_or_not': b},
      );
    case 'batch_order':
    case 'batch_size_sweep':
      for (final k in targets) {
        outcome(
          _tv(variant[k]!, base[k]!),
          flip: _argmax(variant[k]!) != _argmax(base[k]!),
          outcomeTargets: [k],
          detail: {if (name == 'batch_size_sweep') 'size': params['size']},
        );
      }
    case 'duplicate_question':
      final a = variant[key]!, b = variant[params['duplicate']]!;
      outcome(_tv(a, b), flip: _argmax(a) != _argmax(b));
    case 'natural_negation':
    case 'negation_wrapper':
      final a = original['true']!, b = p('negated');
      outcome(
        (a + b - 1).abs(),
        flip: (a > .5) == (b > .5),
        detail: {
          'p': a,
          'p_negated': b,
          if (name == 'natural_negation') 'rewrite': params['rewrite'],
        },
      );
    case 'choice_complement':
    case 'score_complement':
      final param = name == 'choice_complement' ? 'option' : 'level';
      final a = original[params[param]]!, b = p('probe');
      outcome(
        (a + b - 1).abs(),
        flip: (a > .5) == (b > .5),
        detail: {
          param: params[param],
          name == 'choice_complement' ? 'p_option' : 'p_level': a,
          name == 'choice_complement' ? 'p_not_option' : 'p_not_level': b,
        },
      );
    case 'choice_indicator':
      final ps = {
        for (final e in _map(params['probes']).entries)
          e.key: variant[e.value]!['true']!,
      };
      outcome(
        ps.entries
            .map((e) => (e.value - original[e.key]!).abs())
            .reduce(math.max),
        detail: {'nouls': ps, 'noul_sum': benchmarkSum(ps.values)},
      );
    case 'option_merge':
      final parts = (params['parts'] as List).cast<String>();
      final merged = params['merged'] as String;
      final expected = {
        for (final e in original.entries)
          if (!parts.contains(e.key)) e.key: e.value,
      };
      expected[merged] = original[parts[0]]! + original[parts[1]]!;
      equality(
        variant[key]!,
        expected,
        detail: {
          'p_merged': variant[key]![merged],
          'p_parts_sum': expected[merged],
        },
      );
    case 'option_clone':
      final d = {...variant[key]!};
      final option = params['option'] as String;
      final originalP = d[option]!, clone = d.remove(params['clone'])!;
      d[option] = originalP + clone;
      equality(
        d,
        original,
        detail: {
          'p_original': originalP,
          'p_clone': clone,
          'p_base': original[option],
        },
      );
    case 'option_split':
      final d = {...variant[key]!};
      final parts = (params['parts'] as List).cast<String>();
      final sum = d.remove(parts[0])! + d.remove(parts[1])!;
      final option = params['option'] as String;
      d[option] = sum;
      equality(
        d,
        original,
        detail: {
          'parts_sum': sum,
          'whole': original[option],
          'unpacking': sum - original[option]!,
        },
      );
    case 'option_closure':
      final replaced = params['replaced'] as String,
          nota = params['nota'] as String;
      final expected = {
        for (final e in original.entries)
          e.key == replaced ? nota : e.key: e.value,
      };
      // The original relation does not emit a flip for this check.
      outcome(
        _tv(variant[key]!, expected),
        detail: {
          'p_catch_all': variant[key]![nota],
          'p_replaced': original[replaced],
        },
      );
    case 'partition_hierarchy':
      final blocks = _map(params['blocks']);
      final expected = {
        for (final e in blocks.entries)
          e.key: benchmarkSum(
            (e.value as List).cast<String>().map((k) => original[k]!),
          ),
      };
      equality(variant[key]!, expected, detail: {'blocks': blocks});
    case 'extreme_level':
      final d = {...variant[key]!};
      final added = d.remove(params['added'])!;
      final top = '${original.length - 1}';
      d[top] = d[top]! + added;
      equality(
        d,
        original,
        detail: {
          'p_added': added,
          'lower_level_gain': original.keys
              .where((k) => k != top)
              .map((k) => d[k]! - original[k]!)
              .reduce(math.max),
        },
      );
    case 'similarity_effect':
      final d = {...variant[key]!};
      final option = params['option'] as String;
      final twin = d.remove(params['twin'])!;
      final taken = {
        for (final e in original.entries) e.key: e.value - d[e.key]!,
      };
      d[option] = d[option]! + twin;
      final newMass = benchmarkSum(taken.values);
      equality(
        d,
        original,
        detail: {
          'others_changed': original.keys
              .where((k) => k != option)
              .map((k) => (d[k]! - original[k]!).abs())
              .reduce(math.max),
          'share_taken_from_twin': newMass > 1e-9
              ? taken[option]! / newMass
              : null,
          'p_twin': twin,
        },
      );
    case 'score_cumulative':
      final tails = {
        for (var k = 1; k < original.length; k++)
          '$k': benchmarkSum(
            List.generate(original.length - k, (i) => original['${i + k}']!),
          ),
      };
      final nouls = {
        for (final e in _map(params['probes']).entries)
          e.key: variant[e.value]!['true']!,
      };
      outcome(
        tails.entries
            .map((e) => (nouls[e.key]! - e.value).abs())
            .reduce(math.max),
        detail: {'tails': tails, 'nouls': nouls},
      );
    case 'score_granularity':
      final blocks = params['blocks'] as List;
      final expected = {
        for (var j = 0; j < blocks.length; j++)
          '$j': benchmarkSum(
            (blocks[j] as List).cast<int>().map((i) => original['$i']!),
          ),
      };
      equality(variant[key]!, expected);
    case 'inclusion_exclusion':
    case 'frechet_and_upper':
      final a = original['true']!, b = base[targets[1]]!['true']!;
      final and = p('conj'), or = p('disj');
      outcome(
        name == 'inclusion_exclusion'
            ? (and + or - a - b).abs()
            : math.max(0.0, and - math.min(a, b)),
        detail: {
          'a': a,
          'b': b,
          'p_and': and,
          if (name == 'inclusion_exclusion') 'p_or': or,
        },
      );
    case 'compound_negation':
      final and = p('and'), nand = p('nand');
      outcome(
        (nand + and - 1).abs(),
        flip: (nand > .5) == (and > .5),
        detail: {'p_and': and, 'p_nand': nand},
      );
    case 'pair_choice_marginals':
      final a = original['true']!, b = base[targets[1]]!['true']!;
      final cell = variant[params['pair']]!;
      final pa = cell['10']! + cell['11']!, pb = cell['01']! + cell['11']!;
      outcome(
        math.max((pa - a).abs(), (pb - b).abs()),
        detail: {'a': a, 'b': b, 'pair_a': pa, 'pair_b': pb},
      );
    case 'entailment_strength':
      final a = original['true']!, strong = p('strong'), weak = p('weak');
      outcome(
        [0.0, strong - a, a - weak, strong - weak].reduce(math.max),
        detail: {'p': a, 'p_strong': strong, 'p_weak': weak},
      );
    case 'nary_and_upper':
    case 'nary_and_lower':
    case 'nary_or_upper':
    case 'nary_or_lower':
      final ps = targets.map((k) => base[k]!['true']!).toList();
      final all = p('all'), any = p('any');
      final sum = benchmarkSum(ps);
      final gap = switch (name) {
        'nary_and_upper' => all - ps.reduce(math.min),
        'nary_and_lower' => sum - (ps.length - 1) - all,
        'nary_or_upper' => any - math.min(1.0, sum),
        _ => ps.reduce(math.max) - any,
      };
      outcome(
        math.max(0.0, gap),
        detail: {'atomic': ps, 'p_all': all, 'p_any': any},
      );
    case 'quantifier_monotonicity':
      final all = p('all'), two = p('two'), any = p('any');
      outcome(
        [0.0, all - two, two - any, all - any].reduce(math.max),
        detail: {'p_all': all, 'p_two': two, 'p_any': any},
      );
    case 'count_upper':
    case 'count_lower':
      final sum = benchmarkSum(targets.map((k) => base[k]!['true']!));
      final two = p('two');
      outcome(
        math.max(
          0.0,
          name == 'count_upper'
              ? two - sum / 2
              : (sum - 1) / (targets.length - 1) - two,
        ),
        detail: {'expected_count': sum, 'p_two': two},
      );
    case 'threshold_sweep':
      final ps = {
        for (final e in _map(params['probes']).entries)
          int.parse(e.key): variant[e.value]!['true']!,
      };
      final keys = ps.keys.toList()..sort();
      var maximum = 0.0;
      for (var i = 0; i < keys.length; i++) {
        for (var j = i + 1; j < keys.length; j++) {
          maximum = math.max(maximum, ps[keys[j]]! - ps[keys[i]]!);
        }
      }
      outcome(
        maximum,
        detail: {
          'value': params['value'],
          'subject': params['subject'],
          'curve': {
            for (final k in keys) '$k': double.parse(ps[k]!.toStringAsFixed(4)),
          },
        },
      );
    case 'irrelevant_option':
      final d = variant[key]!;
      equality(
        _restricted(d, original.keys),
        original,
        detail: {'p_added': d[params['new']]},
      );
    case 'remove_option_iia':
    case 'pairwise_iia':
      final d = variant[key]!;
      equality(
        d,
        _restricted(original, d.keys),
        detail: {
          name == 'remove_option_iia' ? 'removed' : 'pair':
              params[name == 'remove_option_iia' ? 'removed' : 'pair'],
        },
      );
    default:
      throw StateError('Unsupported original coherence relation $name');
  }
  return output;
}

const _relations = <String, Map<String, Object?>>{
  "instruction_paraphrase": {
    "group": "REP.invariance",
    "check": "tv",
    "law": "E",
    "expectation": "A judged paraphrase of the instructions leaves the answer distribution unchanged.",
    "source": "Invariance to meaning-preserving rewording (CheckList INV).",
  },
  "cross_lingual": {
    "group": "REP.invariance",
    "check": "tv",
    "law": "E",
    "expectation": "Translating a question's instructions and criteria texts (keys unchanged, state unchanged) leaves the answer distribution unchanged.",
    "source": "Language invariance of the question; the state stays in its original language.",
  },
  "typo_noise": {
    "group": "REP.invariance",
    "check": "tv",
    "law": "E",
    "expectation": "Lowercasing, two letter swaps, or stripping punctuation from the instructions changes nothing.",
    "source": "Robustness to surface noise (CheckList INV: typos).",
  },
  "verbosity": {
    "group": "REP.invariance",
    "check": "tv",
    "law": "E",
    "expectation": "Wrapping the instructions in redundant, content-free guidance changes nothing.",
    "source": "Invariance to meaning-preserving additions (CheckList INV).",
  },
  "key_rename": {
    "group": "REP.invariance",
    "check": "tv",
    "law": "E",
    "expectation": "Renaming a question's key to a neutral id changes nothing; the instructions define the question.",
    "source": "Keys are program identifiers in the wire format.",
  },
  "description_paraphrase": {
    "group": "REP.invariance",
    "check": "tv",
    "law": "E",
    "expectation": "A judged paraphrase of one option's description leaves the answer distribution unchanged.",
    "source": "Invariance to meaning-preserving rewording (CheckList INV).",
  },
  "de_morgan": {
    "group": "REP.invariance",
    "check": "nand_vs_or_not",
    "law": "E",
    "expectation": "P(not (A and B)) = P(not A or not B): the two describe the same event.",
    "source": "De Morgan's laws: logically equivalent propositions.",
  },
  "option_permutation": {
    "group": "REP.equivariance",
    "check": "tv",
    "law": "E",
    "expectation": "Reordering Choice options (reversing Score levels) leaves each option's probability unchanged.",
    "source": "Invariance of the declared option set; CheckList INV (Ribeiro et al. 2020).",
  },
  "option_rename": {
    "group": "REP.equivariance",
    "check": "tv",
    "law": "E",
    "expectation": "Replacing Choice option ids with neutral ids, descriptions unchanged, changes nothing.",
    "source": "Descriptions define the options; ids are labels (cf. Type-Safe Is Not Error-Free, 2026).",
  },
  "clone_symmetry": {
    "group": "REP.equivariance",
    "check": "clone_symmetry",
    "law": "E",
    "expectation": "Two identical options (same description, different ids) receive equal probability.",
    "source":
        "Exchangeability: swapping the two copies maps the question to itself.",
  },
  "key_instruction_conflict": {
    "group": "REP.binding",
    "check": "tv",
    "law": "E",
    "expectation": "A misleading question key (negated, or swapped with another question's key) leaves the answer unchanged: answers follow instructions, not keys.",
    "source": "Keys are program identifiers in the wire format.",
  },
  "name_description_conflict": {
    "group": "REP.binding",
    "check": "tv",
    "law": "E",
    "expectation": "Exchanging the ids of two options, descriptions and positions fixed, leaves each description's probability where it was: answers follow descriptions, not ids.",
    "source": "Options are bound to descriptions (cf. Type-Safe Is Not Error-Free, 2026).",
  },
  "description_swap": {
    "group": "REP.binding",
    "check": "tv",
    "law": "E",
    "expectation": "Swapping two options' descriptions, ids fixed, moves their probabilities with the descriptions.",
    "source":
        "Options are bound to descriptions, not ids (sensitivity control).",
  },
  "noul_as_choice": {
    "group": "REP.type",
    "check": "abs_diff",
    "law": "E",
    "expectation": "A yes/no question gives the same P(yes) as a Noul and as a two-option Choice.",
    "source": "Equivalent answer types for a binary question.",
  },
  "noul_as_score": {
    "group": "REP.type",
    "check": "abs_diff",
    "law": "E",
    "expectation": "A yes/no question gives the same P(yes) as a Noul and as a two-level Score.",
    "source": "Equivalent answer types for a binary question.",
  },
  "batch_solo": {
    "group": "BAT.isolation",
    "check": "tv",
    "law": "E",
    "expectation":
        "A question asked alone gets the same answer as inside its batch.",
    "source": "Questions are evaluated independently against the shared state (Jev documentation).",
  },
  "batch_order": {
    "group": "BAT.isolation",
    "check": "tv",
    "law": "E",
    "expectation":
        "Reversing the order of questions in a batch changes no answer.",
    "source": "Questions are evaluated independently against the shared state (Jev documentation).",
  },
  "duplicate_question": {
    "group": "BAT.isolation",
    "check": "within_request_tv",
    "law": "E",
    "expectation": "The same question asked twice in one request gets the same answer both times.",
    "source":
        "Idempotence of a deterministic query; isolation between questions.",
  },
  "batch_content": {
    "group": "BAT.isolation",
    "check": "tv",
    "law": "E",
    "expectation": "Replacing the other questions with unrelated fillers, batch size fixed, changes nothing.",
    "source": "Questions are evaluated independently against the shared state (Jev documentation).",
  },
  "batch_size_sweep": {
    "group": "BAT.isolation",
    "check": "tv",
    "law": "E",
    "expectation": "Answers asked in the first 2, 5 or 10 questions of the batch match the full batch.",
    "source": "Questions are evaluated independently against the shared state (Jev documentation).",
  },
  "negation_wrapper": {
    "group": "MEA.complement",
    "check": "complement_gap",
    "law": "I",
    "expectation":
        "P(Q) + P(not Q) = 1 for a Noul and its logically negated wording.",
    "source": "Complement rule of probability.",
  },
  "natural_negation": {
    "group": "MEA.complement",
    "check": "complement_gap",
    "law": "I",
    "expectation": "P(Q) + P(Q') = 1 for a Noul Q and a judged natural rewrite Q' with the opposite answer.",
    "source": "Complement rule of probability.",
  },
  "choice_complement": {
    "group": "MEA.complement",
    "check": "complement_gap",
    "law": "I",
    "expectation":
        "P(answer is not o), asked as a Noul, equals 1 - P(o) from the Choice.",
    "source": "Complement rule of probability.",
  },
  "score_complement": {
    "group": "MEA.complement",
    "check": "complement_gap",
    "law": "I",
    "expectation":
        "P(level is not k), asked as a Noul, equals 1 - P(k) from the Score.",
    "source": "Complement rule of probability.",
  },
  "compound_negation": {
    "group": "MEA.complement",
    "check": "complement_gap",
    "law": "I",
    "expectation": "P(not (A and B)) + P(A and B) = 1.",
    "source": "Complement rule of probability, for a compound proposition.",
  },
  "option_merge": {
    "group": "MEA.partition",
    "check": "tv_to_coarsened",
    "law": "E",
    "expectation": "Merging options a and b into 'a or b' gives it P(a) + P(b) and leaves the others unchanged.",
    "source":
        "Additivity over a coarsened partition (law of total probability).",
  },
  "option_split": {
    "group": "MEA.partition",
    "check": "tv_after_collapse",
    "law": "E",
    "expectation": "Splitting option o into 'o, and X' and 'o, and not X' gives the two parts P(o) in total and leaves the other options unchanged.",
    "source": "Additivity over a refined partition; unpacking effect of support theory (Tversky & Koehler 1994), where judged parts sum to more than the whole.",
  },
  "option_clone": {
    "group": "MEA.partition",
    "check": "tv_after_collapse",
    "law": "E",
    "expectation": "Duplicating option o (same description, new id) gives the two copies P(o) together and leaves the others unchanged.",
    "source": "Additivity; clone consistency (red-bus/blue-bus, Debreu 1960).",
  },
  "similarity_effect": {
    "group": "MEA.partition",
    "check": "tv_after_collapse",
    "law": "E",
    "expectation": "A near-duplicate of option b, in other words, refines b: merged back into b, the distribution equals the original one.",
    "source": "Additivity; the similarity effect (Tversky 1972): a similar newcomer takes share mainly from its twin, which a Luce scorer cannot reproduce.",
  },
  "partition_hierarchy": {
    "group": "MEA.partition",
    "check": "tv_to_coarsened",
    "law": "E",
    "expectation": "Grouping all options into coarse blocks gives each block the sum of its options' probabilities.",
    "source":
        "Additivity over a coarsened partition (law of total probability).",
  },
  "score_granularity": {
    "group": "MEA.partition",
    "check": "tv_to_coarsened",
    "law": "E",
    "expectation": "Merging adjacent Score levels into pairs gives each coarse level the sum of its fine levels.",
    "source": "Additivity over a coarsened ordinal scale.",
  },
  "extreme_level": {
    "group": "MEA.partition",
    "check": "tv_after_collapse",
    "law": "E",
    "expectation": "Adding a level beyond the top of a Score refines the top level: the new and the old top level together keep P(top), and every lower level keeps its probability.",
    "source": "Additivity over a refined partition; the compromise effect (Simonson 1989) moves mass to the middle.",
  },
  "option_closure": {
    "group": "MEA.partition",
    "check": "catch_all_tv",
    "law": "E",
    "expectation": "Replacing an option o by 'none of the other options' gives the catch-all P(o) and leaves the rest unchanged, for every option in turn.",
    "source": "The catch-all relabels the event o within the menu (a Choice is conditioned on its options).",
  },
  "score_cumulative": {
    "group": "MEA.marginalisation",
    "check": "tail_gap_max",
    "law": "I",
    "expectation": "For every level k, the Noul 'is it level k or higher?' equals the Score's upper tail P(level >= k).",
    "source": "Marginalisation: the Noul asks for the indicator 1[level >= k] of the Score's outcome.",
  },
  "choice_indicator": {
    "group": "MEA.marginalisation",
    "check": "indicator_gap",
    "law": "I",
    "expectation": "For every option o, the Noul 'is the answer o?' equals P(o) from the Choice.",
    "source": "Marginalisation: the Noul asks for the indicator 1[answer = o] of the Choice's outcome.",
  },
  "pair_choice_marginals": {
    "group": "MEA.marginalisation",
    "check": "marginal_gap",
    "law": "I",
    "expectation": "A four-way Choice over the joint answers of two Nouls has the Nouls as its marginals.",
    "source": "Marginalisation of a joint distribution.",
  },
  "inclusion_exclusion": {
    "group": "MEA.marginalisation",
    "check": "inclusion_exclusion",
    "law": "I",
    "expectation": "P(A and B) + P(A or B) = P(A) + P(B).",
    "source": "Finite additivity: the four answers are projections of one joint distribution of (A, B).",
  },
  "frechet_and_upper": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "A conjunction is never more probable than either conjunct: P(A and B) <= min(P(A), P(B)).",
    "source": "Monotonicity under entailment (A and B entails A); conjunction fallacy (Tversky & Kahneman 1983).",
  },
  "nary_and_upper": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "P(all of A1..An) <= min_i P(Ai).",
    "source": "Monotonicity under entailment (the conjunction entails each conjunct).",
  },
  "nary_and_lower": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "P(all of A1..An) >= sum_i P(Ai) - (n - 1).",
    "source": "Bonferroni inequality.",
  },
  "nary_or_upper": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "P(at least one of A1..An) <= min(1, sum_i P(Ai)).",
    "source": "Union bound (Boole's inequality).",
  },
  "nary_or_lower": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "P(at least one of A1..An) >= max_i P(Ai).",
    "source": "Monotonicity under entailment (each disjunct entails the disjunction).",
  },
  "count_upper": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "P(at least two of A1..An) <= (sum_i P(Ai)) / 2.",
    "source": "Markov's inequality for the number N of true propositions: E[N] >= 2 P(N >= 2).",
  },
  "count_lower": {
    "group": "LOG.bounds",
    "check": "excess",
    "law": "L",
    "expectation": "P(at least two of A1..An) >= (sum_i P(Ai) - 1) / (n - 1).",
    "source":
        "E[N] <= 1 + (n - 1) P(N >= 2) for the number N of true propositions.",
  },
  "threshold_sweep": {
    "group": "LOG.monotonicity",
    "check": "monotonicity",
    "law": "L",
    "expectation": "P('more than k?') does not increase with k, for every pair of thresholds k < k'.",
    "source":
        "Monotonicity of upper tails; entailment between threshold questions.",
  },
  "entailment_strength": {
    "group": "LOG.monotonicity",
    "check": "chain",
    "law": "L",
    "expectation": "A stronger claim cannot be more probable than a weaker one it entails: P(explicitly established) <= P(Q) <= P(at least possible).",
    "source": "Monotonicity of probability under entailment.",
  },
  "quantifier_monotonicity": {
    "group": "LOG.monotonicity",
    "check": "chain",
    "law": "L",
    "expectation": "P(all three) <= P(at least two) <= P(at least one), for every pair of the chain.",
    "source": "Monotonicity of probability under entailment between counting quantifiers.",
  },
  "irrelevant_option": {
    "group": "CHO.conditioning",
    "check": "iia_tv",
    "law": "E",
    "expectation": "Adding an off-topic option leaves the distribution over the original options unchanged after renormalisation.",
    "source": "Conditioning on the original menu; Luce's choice axiom / IIA (Luce 1959).",
  },
  "remove_option_iia": {
    "group": "CHO.conditioning",
    "check": "iia_tv",
    "law": "E",
    "expectation": "Removing an option leaves the others with their renormalised probabilities, for every option in turn.",
    "source": "Conditioning on the smaller menu: P(a | not o) = P(a) / (1 - P(o)); Luce's choice axiom.",
  },
  "pairwise_iia": {
    "group": "CHO.conditioning",
    "check": "iia_tv",
    "law": "E",
    "expectation": "Asking any two options alone gives their renormalised probabilities from the full menu, for every pair.",
    "source": "Conditioning on a two-option menu; the binary form of Luce's choice axiom.",
  },
};
