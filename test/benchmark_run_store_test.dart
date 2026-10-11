import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  test('active history file locations do not read an appending journal and reject foreign ownership or links', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-history-active-files-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    const id = 'run-active-files';
    final suite = jsonDecode(
      await File('benchmarks/manifests/jevman.json').readAsString(),
    ) as Map<String, Object?>;
    final active = BenchmarkRun.gameSnapshot(
      header: {
        'schema_version': 5,
        'id': id,
        'created_at': '2026-10-09T00:00:00.000Z',
        'finished_at': null,
        'status': 'running',
        'model': 'native-kev',
        'source': 'native',
        'channel': 'http',
        'timeout_us': 2000000,
        'suite': suite,
        'identity': {},
        'source_summary': {
          'complete': false,
          'summary': null,
          'originalSummary': null,
        },
        'warmup_calls': [],
        'client_summary': {},
        'groups': [],
        'summary': {
          'expected': 100,
          'attempted': 0,
          'missing': 100,
          'complete': false,
          'valid': 0,
          'failures': 0,
          'client_timeouts': 0,
          'server_timeouts': 0,
          'timeouts': 0,
        },
      },
      items: [],
    );
    await store.save(active);
    final header = File('${root.path}/$id.json');
    final journal = File('${root.path}/$id-0.items.jsonl');
    // A producer can be between append and header publication. These partial
    // bytes deliberately cannot pass full body validation and must not be read.
    await journal.writeAsString(
      '{"pending":',
      mode: FileMode.append,
      flush: true,
    );
    final headerBytes = await header.readAsBytes();
    final journalBytes = await journal.readAsBytes();
    expect(await store.recordFilePaths(id), [
      header.absolute.path,
      journal.absolute.path,
    ]);
    expect(await header.readAsBytes(), headerBytes);
    expect(await journal.readAsBytes(), journalBytes);
    final foreign = jsonDecode(utf8.decode(headerBytes)) as Map;
    foreign['journal']['file'] = 'foreign.items.jsonl';
    await header.writeAsString(jsonEncode(foreign), flush: true);
    await expectLater(
      store.recordFilePaths(id),
      throwsA(isA<FileSystemException>()),
    );
    await header.writeAsBytes(headerBytes, flush: true);
    final protected = await journal.rename('${root.path}/preserved-journal');
    await Link(journal.path).create(protected.path);
    await expectLater(
      store.recordFilePaths(id),
      throwsA(isA<FileSystemException>()),
    );
    expect(await protected.readAsBytes(), journalBytes);
    expect(await header.readAsBytes(), headerBytes);
  });
  test('history reader ignores opaque legacy extensions and exposes only declared summary fields', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-history-legacy-extra-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    final input = jsonDecode(
      jsonEncode(_interruptedRun('run-legacy-extra').toJson()),
    ) as Map<String, Object?>;
    input['source_summary'] = 'opaque legacy extension';
    input['client_summary'] = 'opaque legacy extension';
    input['warmup_calls'] = 'opaque legacy extension';
    input['source_fields'] = {
      'bootstrap': [1, 2, 3],
      'raw': 'ordinary extension context',
    };
    final original = BenchmarkRun.fromJson(input);
    await store.save(original);
    final file = File('${root.path}/${original.id}.json');
    final before = await file.readAsBytes();
    expect((await store.load(original.id)).toJson(), original.toJson());
    final reader = store.openHistory(original.id);
    addTearDown(reader.close);
    final summary = await reader.ready;
    expect(summary.id, original.id);
    expect(summary.items, isEmpty);
    expect(summary.toJson().containsKey('source_fields'), isFalse);
    expect(summary.toJson()['source_summary'], isEmpty);
    expect(reader.warmupCount(original.id), 0);
    expect(
      await reader.items(evaluationId: original.id, offset: 0),
      hasLength(1),
    );
    expect(await file.readAsBytes(), before);
    expect((await store.load(original.id)).toJson(), original.toJson());
  });
  test('history list returns only legacy record summaries while full evidence remains in its original file', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-history-summary-list-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    final original = _interruptedRun('run-list-summary');
    await store.save(original);
    final file = File('${root.path}/${original.id}.json');
    final before = await file.readAsBytes();
    final history = await store.list();
    expect(history, hasLength(1));
    expect(history.single.id, original.id);
    expect(history.single.status, original.status);
    expect(history.single.summary['attempted'], 1);
    expect(
      history.single.items,
      isEmpty,
      reason: 'The history list must not preload request/response payloads from legacy records into UI.',
    );
    expect(history.single.groups, isEmpty);
    expect(await file.readAsBytes(), before);
    expect((await store.load(original.id)).toJson(), original.toJson());
  });
  test('full history load performs file reads outside the caller isolate and keeps complete evidence', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-history-background-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    final original = _interruptedRun('run-background-load');
    await store.save(original);
    final observer = _HistoryReadObserver();
    final restored = await IOOverrides.runWithIOOverrides(
      () => store.load(original.id),
      observer,
    );
    expect(restored.toJson(), original.toJson());
    expect(restored.items, hasLength(1));
    expect(
      observer.reads,
      isEmpty,
      reason: 'Complete history validation must not read and process its payload on the UI/public-gateway caller isolate. This observes File I/O ownership, not a substitute latency threshold.',
    );
  });
  test('history reader publishes a validated light summary and bounded immutable pages until closed', () async {
    final root = await Directory.systemTemp.createTemp('gmd-history-reader-');
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    final original = _interruptedRun('run-reader-pages');
    await store.save(original);
    final reader = store.openHistory(original.id);
    addTearDown(reader.close);
    final summary = await reader.ready;
    expect(summary.id, original.id);
    expect(summary.status, BenchmarkRunStatus.interrupted);
    expect(summary.summary['attempted'], 1);
    expect(summary.items, isEmpty);
    expect(summary.groups, isEmpty);
    expect(reader.itemCount(original.id), 1);
    final page = await reader.items(
      evaluationId: original.id,
      offset: 0,
      limit: 20,
    );
    expect(page, hasLength(1));
    expect(page.single['id'], original.items.single['id']);
    expect(page.single.containsKey('request'), isFalse);
    expect(page.single.containsKey('request_json'), isFalse);
    expect(page.single.containsKey('result'), isFalse);
    expect(page.single.containsKey('recording'), isFalse);
    expect(summary.identity['api_key'], '[redacted]');
    expect(() => page.clear(), throwsUnsupportedError);
    expect(() => page.single['id'] = 'changed', throwsUnsupportedError);
    expect(
      reader.recordFilePath,
      File('${root.path}/${original.id}.json').absolute.path,
    );
    expect(reader.journalFilePaths, isEmpty);
    expect(
      await reader.items(evaluationId: original.id, offset: 1, limit: 20),
      isEmpty,
    );
    await reader.close();
    await expectLater(
      reader.items(evaluationId: original.id, offset: 0, limit: 20),
      throwsStateError,
    );
    expect(
      (await store.load(original.id)).items.single['request'],
      original.items.single['request'],
    );
  });
  test('a comparison seals caller-owned evidence and keeps nested history immutable', () {
    final input = jsonDecode(
      jsonEncode(_interruptedRun('run-caller-leaf').toJson()),
    ) as Map<String, Object?>;
    final leaf = BenchmarkRun.fromJson(input);
    final selected = [leaf];
    final batch = BenchmarkRun.batch(
      id: 'run-sealed-comparison',
      createdAt: leaf.createdAt,
      status: BenchmarkRunStatus.interrupted,
      evaluations: selected,
    );
    final sealed = jsonEncode(batch.toJson());
    (input['identity'] as Map)['generation'] = 99;
    final originalItem = (input['items'] as List).single as Map;
    ((originalItem['request'] as Map)['state'] as Map)['api_key'] = 'changed';
    (input['items'] as List).clear();
    selected.clear();
    expect(jsonEncode(batch.toJson()), sealed);
    expect(batch.evaluations, hasLength(1));
    final evidence = batch.evaluations.single;
    expect((evidence.identity)['generation'], 3);
    expect(evidence.items, hasLength(1));
    expect(
      () =>
          ((evidence.items.single['request'] as Map)['state']
                  as Map)['api_key'] =
              'changed',
      throwsUnsupportedError,
    );
    expect(() => evidence.summary['attempted'] = 0, throwsUnsupportedError);
    expect(() => evidence.items.clear(), throwsUnsupportedError);
    expect(() => batch.evaluations.clear(), throwsUnsupportedError);
  });
  test('comparison saves match full JSON bytes and new sealed identities invalidate late-secret echoes across channels', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-cached-comparison-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(directory: root);
    const lateSecret = 'newly-discovered-credential';
    Map<String, Object?> input(String channel) {
      final raw = jsonDecode(
        jsonEncode(_interruptedRun('leaf-$channel').toJson()),
      ) as Map<String, Object?>;
      raw['channel'] = channel;
      final item = (raw['items'] as List).single as Map;
      (item['request'] as Map)['state'] = {'echo': lateSecret};
      item['request_json'] = jsonEncode(item['request']);
      return raw;
    }

    final rawHttp = input('http'), rawMcp = input('mcp');
    final original = [
      BenchmarkRun.fromJson(rawHttp),
      BenchmarkRun.fromJson(rawMcp),
    ];
    BenchmarkRun batch(List<BenchmarkRun> evaluations) => BenchmarkRun.batch(
      id: 'run-cache-by-snapshot',
      createdAt: original.first.createdAt,
      status: BenchmarkRunStatus.interrupted,
      evaluations: evaluations,
    );
    final first = batch(original);
    await store.save(first);
    final path = File('${root.path}/${first.id}.json');
    expect(await path.readAsString(), jsonEncode(first.toJson()));
    final oldBytes = jsonEncode(first.toJson());
    expect(oldBytes, contains(lateSecret));
    for (final raw in [rawHttp, rawMcp]) {
      (raw['identity'] as Map)['api_key'] = lateSecret;
    }
    final sealed = [
      BenchmarkRun.fromJson(rawHttp),
      BenchmarkRun.fromJson(rawMcp),
    ];
    expect(identical(sealed.first.toJson(), original.first.toJson()), isFalse);
    final changed = batch(sealed);
    await store.save(changed);
    expect(await path.readAsString(), jsonEncode(changed.toJson()));
    expect(await path.readAsString(), isNot(contains(lateSecret)));
    expect(jsonEncode(first.toJson()), oldBytes);
    final reader = BenchmarkRunStore(directory: root);
    expect((await reader.load(changed.id)).toJson(), changed.toJson());
    final repeated = batch(sealed);
    await store.save(repeated);
    expect(await path.readAsString(), jsonEncode(repeated.toJson()));
    final cancelled = BenchmarkRun.batch(
      id: repeated.id,
      createdAt: repeated.createdAt,
      status: BenchmarkRunStatus.cancelled,
      evaluations: sealed,
    );
    await store.save(cancelled);
    expect(await path.readAsString(), jsonEncode(cancelled.toJson()));
  });
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

final class _HistoryReadObserver extends IOOverrides {
  final reads = <String>[];
  @override
  File createFile(String path) =>
      _HistoryObservedFile(super.createFile(path), reads);
}

class _HistoryObservedFile implements File {
  _HistoryObservedFile(this.original, this.reads);
  final File original;
  final List<String> reads;
  @override
  String get path => original.path;
  @override
  Uri get uri => original.uri;
  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    reads.add('readAsString');
    return original.readAsString(encoding: encoding);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    reads.add('openRead');
    return original.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
