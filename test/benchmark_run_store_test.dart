import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  test('saved benchmark evidence survives restart without resuming and preserves JEV task values', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-benchmark-records-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    const task = 'Authorization: allow';
    final request = <String, Object?>{
      'model': 'quick',
      'state': {'api_key': 'ordinary task value'},
      'questions': {
        'decision': {
          'type': 'choice',
          'instructions': task,
          'criteria': {'accept': task, 'reject': 'Reject'},
        },
      },
    };
    final run = _interruptedRun('run-restart-evidence');
    await store.save(run);
    final restarted = BenchmarkRunStore(directory: root);
    final history = await restarted.list();
    expect(history, hasLength(1));
    final restored = await restarted.load(run.id);
    expect(restored.status, BenchmarkRunStatus.interrupted);
    expect(restored.model, 'quick');
    expect(restored.timeout, const Duration(seconds: 30));
    final evidence = restored.toJson();
    expect((evidence['identity'] as Map)['api_key'], '[redacted]');
    final item = (evidence['items'] as List).single as Map;
    expect(item['request'], request);
    expect(jsonDecode(item['request_json'] as String), request);
    expect(item['result'], isNull);
    expect((evidence['summary'] as Map)['accuracy'], isNull);
    expect((evidence['groups'] as List).single['complete'], isFalse);
    expect(jsonEncode(evidence), isNot(contains('identity-secret')));
    expect(history.single.id, run.id);
  });
  test('history export refuses overwrite and deletion touches only the selected record', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-benchmark-safe-history-',
    );
    addTearDown(() => root.delete(recursive: true));
    final records = Directory('${root.path}/records');
    final store = BenchmarkRunStore(directory: records);
    final first = _interruptedRun('run-first');
    final second = _interruptedRun('run-other');
    await store.save(first);
    await store.save(second);
    final source = await File('${root.path}/source-original.json')
        .writeAsString('original source bytes');
    final model = await File('${root.path}/shared-model.gguf')
        .writeAsString('shared model bytes');
    final exported = File('${root.path}/exported.json');
    await store.exportTo(first.id, exported);
    final bytes = await exported.readAsString();
    expect(jsonDecode(bytes)['id'], first.id);
    expect(
      jsonDecode(bytes)['items'][0]['request']['state']['api_key'],
      'ordinary task value',
    );
    expect(bytes, isNot(contains('identity-secret')));
    await expectLater(
      store.exportTo(second.id, exported),
      throwsA(isA<FileSystemException>()),
    );
    expect(await exported.readAsString(), bytes);
    await store.delete(first.id);
    expect(
      (await BenchmarkRunStore(directory: records).list()).map((run) => run.id),
      [second.id],
    );
    await expectLater(
      store.load(first.id),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      store.delete('../source-original'),
      throwsA(isA<FormatException>()),
    );
    expect(await source.readAsString(), 'original source bytes');
    expect(await model.readAsString(), 'shared model bytes');
    expect(await exported.readAsString(), bytes);
  });
  test('corrupt persisted success cannot grant JEV task roles to invalid probability strings', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final record = await _publicRecord(fixture);
    expect(BenchmarkRun.fromJson(record).items, hasLength(1));
    final result = (record['items'] as List).single['result'] as Map;
    final output = result['output'] as Map;
    final probabilities = output['answers']['decision']['probabilities'] as Map;
    probabilities[probabilities.keys.first] =
        'Authorization: Bearer disguised-secret';
    result['raw_response'] = jsonEncode(output);
    expect(
      () => BenchmarkRun.fromJson(record),
      throwsA(isA<FormatException>()),
    );
  });

  test('inconsistent request snapshot cannot impersonate a different public model in history', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final record = await _publicRecord(fixture);
    expect(BenchmarkRun.fromJson(record).items, hasLength(1));
    final result = (record['items'] as List).single['result'] as Map;
    final changed = jsonDecode(result['request_json'] as String) as Map;
    changed['model'] = 'wrong-public-name';
    result['request_json'] = jsonEncode(changed);
    expect(
      () => BenchmarkRun.fromJson(record),
      throwsA(isA<FormatException>()),
    );
  });
  test(
    'public history load rejects summary fields that cannot be rendered safely',
    () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      final record = await _publicRecord(fixture);
      final store = BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/render-history'),
      );
      await store.save(BenchmarkRun.fromJson(record));
      final control = await store.load(record['id'] as String);
      expect(control.suite['questionCount'], 400);
      expect(control.items, hasLength(1));
      expect(control.summary['attempted'], 1);
      final path = File('${store.directory.path}/${control.id}.json');
      final corruptions = <String, Map<String, Object?>>{
        'attempted string': {'attempted': 'bad'},
        'attempted missing': {'attempted': null},
        'attempted negative': {'attempted': -1},
        'attempted above full coverage': {'attempted': 401},
        'completion string': {'complete': 'true'},
        'negative failure count': {'failures': -1},
        'score string': {'accuracy': 'bad'},
        'error object': {
          'error': {'message': 'bad'},
        },
      };
      final rejected = <String, bool>{};
      for (final corruption in corruptions.entries) {
        final invalid = jsonDecode(jsonEncode(record)) as Map;
        final summary = invalid['summary'] as Map;
        summary.addAll(corruption.value);
        if (corruption.key == 'attempted missing') summary.remove('attempted');
        await path.writeAsString(jsonEncode(invalid), flush: true);
        try {
          await store.load(control.id);
          rejected[corruption.key] = false;
        } on FormatException {
          rejected[corruption.key] = true;
        }
      }
      expect(rejected, {for (final name in corruptions.keys) name: true});
    },
  );

  test('different legal raw and parsed choices are rejected as inconsistent historical evidence', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final record = await _publicRecord(fixture);
    expect(BenchmarkRun.fromJson(record).items, hasLength(1));
    final item = (record['items'] as List).single as Map;
    final result = item['result'] as Map;
    final changedRaw = jsonDecode(result['raw_response'] as String) as Map;
    final answer = changedRaw['answers']['decision'] as Map;
    final probabilities = answer['probabilities'] as Map;
    final alternative = probabilities.keys.firstWhere(
      (key) => key != answer['choice'],
    );
    answer['choice'] = alternative;
    answer['confidence'] = 1.0;
    answer['probabilities'] = {
      for (final key in probabilities.keys) key: key == alternative ? 1.0 : 0.0,
    };
    result['raw_response'] = jsonEncode(changedRaw);
    final consistent = jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
    consistent['items'][0]['result']['output'] = changedRaw;
    consistent['items'][0]['prediction'] = alternative;
    expect(BenchmarkRun.fromJson(consistent).items, hasLength(1));
    expect(
      () => BenchmarkRun.fromJson(record),
      throwsA(isA<FormatException>()),
    );
  });
}

BenchmarkRun _interruptedRun(String id) {
  const task = 'Authorization: allow';
  final request = <String, Object?>{
    'model': 'quick',
    'state': {'api_key': 'ordinary task value'},
    'questions': {
      'decision': {
        'type': 'choice',
        'instructions': task,
        'criteria': {'accept': task, 'reject': 'Reject'},
      },
    },
  };
  return BenchmarkRun.fromJson({
    'schema_version': 1,
    'id': id,
    'created_at': '2026-10-09T00:00:00.000Z',
    'finished_at': '2026-10-09T00:01:00.000Z',
    'status': 'interrupted',
    'model': 'quick',
    'source': 'council',
    'channel': 'http',
    'timeout_us': 30000000,
    'suite': {
      'name': 'DecideBench',
      'commit': '18e9c5eedd2855257ae534b5879ebba613479586',
      'item_count': 400,
      'pair_count': 200,
    },
    'identity': {
      'model': 'quick',
      'generation': 3,
      'api_key': 'identity-secret',
    },
    'items': [
      {
        'id': 'original-case-a',
        'pair_id': 'original-case',
        'category': 'original-family',
        'difficulty': 'easy',
        'gold': 'accept',
        'prediction': null,
        'status': 'interrupted',
        'elapsed_us': 250000,
        'request': request,
        'request_json': jsonEncode(request),
        'result': null,
        'error': 'ordinary client interrupted before a public response',
      },
    ],
    'groups': [
      {
        'pair_id': 'original-case',
        'members': ['original-case-a', 'original-case-b'],
        'attempted': 1,
        'complete': false,
        'correct': false,
      },
    ],
    'summary': {
      'expected': 400,
      'attempted': 1,
      'complete': false,
      'accuracy': null,
      'pair_accuracy': null,
    },
  });
}

Future<Map<String, Object?>> _publicRecord(PlaygroundRuntime fixture) async {
  final suite = await DecideBenchSuite.load(
    Directory('benchmarks/sources/decidebench'),
  );
  final item = suite.items.first;
  final public = await fixture.playground.run(
    JevPlaygroundMode.http,
    jsonEncode(item.request('native-kev')),
  );
  expect(public.status, JevPlaygroundStatus.success);
  final selection = await fixture.council.models.lockForEvaluation(
    'native-kev',
  );
  final identity = selection.identity;
  selection.release();
  return jsonDecode(
    jsonEncode({
      ..._interruptedRun('run-public-evidence').toJson(),
      'model': 'native-kev',
      'source': 'native',
      'identity': identity,
      'suite': suite.identity,
      'items': [
        {
          'id': item.id,
          'pair_id': item.pairId,
          'category': item.category,
          'difficulty': item.difficulty,
          'gold': item.gold,
          'prediction': item.extractChoice(public.output),
          'status': 'success',
          'elapsed_us': public.elapsed.inMicroseconds,
          'request': public.request,
          'request_json': public.requestBody,
          'result': public.toJson(),
          'error': null,
        },
      ],
    }),
  ) as Map<String, dynamic>;
}
