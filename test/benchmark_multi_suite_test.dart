import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/benchmark_game_work.dart';
import 'package:ghost_model_deck/coherence_benchmark.dart';
import 'package:ghost_model_deck/adversarial_benchmark.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jeval.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  late DecideBenchSuite decide;
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttpOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _NetworkBoundary());
  tearDownAll(() => HttpOverrides.global = previousHttpOverrides);
  late JevalSuite jeval;
  late CoherenceSuite coherence;
  late AdversarialSuite adversarial;
  setUpAll(() async {
    decide = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    jeval = await JevalSuite.load(Directory('benchmarks/sources/jeval'));
    coherence = await CoherenceSuite.load(
      Directory('benchmarks/sources/coherence'),
    );
    adversarial = await AdversarialSuite.load(
      Directory('benchmarks/sources/adversarial'),
    );
  });
  for (final firstChannel in JevPlaygroundMode.values) {
    test(
      'multi-suite ${firstChannel.name} cancellation seals the whole original plan and mixed history',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        final store = BenchmarkRunStore(
          directory: Directory('${fixture.runtime.root.path}/mixed-history'),
        );
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        addTearDown(runner.close);
        final arrived = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        fixture.runtime.io.respond = (_, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
          return raw;
        };
        final channels = [
          firstChannel,
          JevPlaygroundMode.values.singleWhere((c) => c != firstChannel),
        ];
        final pending = runner.runBatch(
          suites: [decide, jeval],
          modelNames: ['native-kev', 'quick', 'hard'],
          channels: channels,
        );
        await arrived.future.timeout(const Duration(seconds: 20));
        expect(
          runner.current!.evaluations.map(
            (e) => [e.model, e.suite['id'], e.channel],
          ),
          [
            for (final model in ['native-kev', 'quick', 'hard'])
              for (final suite in ['decidebench', 'jeval'])
                for (final channel in channels) [model, suite, channel.name],
          ],
        );
        for (final model in ['native-kev', 'quick', 'hard']) {
          expect(fixture.council.models.isEvaluationLocked(model), isTrue);
        }
        runner.cancel();
        final record = await pending.timeout(const Duration(seconds: 10));
        release.complete();
        expect(record.status, BenchmarkRunStatus.cancelled);
        expect(record.summary['expected'], 6 * (400 + 11257));
        expect(record.summary['attempted'], 1);
        expect(record.summary['complete'], isFalse);
        expect(
          record.evaluations.every(
            (e) => e.status == BenchmarkRunStatus.cancelled,
          ),
          isTrue,
        );
        expect(fixture.runtime.io.requests, hasLength(1));
        expect(fixture.runtime.io.killedChildren, 0);
        final reopened = BenchmarkRunStore(directory: store.directory);
        addTearDown(reopened.close);
        final restored = await reopened.load(record.id);
        expect(restored.toJson(), record.toJson());
        final session = reopened.openHistory(record.id);
        addTearDown(session.close);
        final summary = await session.ready;
        expect(summary.evaluations.every((e) => e.items.isEmpty), isTrue);
        expect(session.itemCount(summary.evaluations.first.id), 1);
        final exported = File('${fixture.runtime.root.path}/mixed-export.json');
        await reopened.exportTo(record.id, exported);
        expect(
          BenchmarkRun.fromJson(
            Map<String, Object?>.from(
              jsonDecode(await exported.readAsString()) as Map,
            ),
          ).toJson(),
          restored.toJson(),
        );
        final protected = await File('${store.directory.path}/unrelated.txt')
            .writeAsString('keep');
        await reopened.delete(record.id);
        expect(await reopened.list(), isEmpty);
        expect(await protected.readAsString(), 'keep');
        expect(fixture.runtime.io.requests, hasLength(1));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  test('next suite starts only after both original channels complete and retains those reports on cancellation', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/transition-history'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final arrived = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final jevalRequest = jeval.tasks.first.request('native-kev');
    fixture.runtime.io.respond = (request, raw) async {
      if (jsonEncode(request['questions']) ==
          jsonEncode(jevalRequest['questions'])) {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
      }
      return raw;
    };
    final pending = runner.runBatch(
      suites: [decide, jeval],
      modelNames: ['native-kev'],
      channels: JevPlaygroundMode.values,
    );
    await arrived.future.timeout(const Duration(seconds: 90));
    final first = runner.current!.evaluations;
    expect(
      first.take(2).map((e) => e.status),
      everyElement(BenchmarkRunStatus.completed),
    );
    expect(first.take(2).map((e) => e.summary['attempted']), everyElement(400));
    expect(first.take(2).map((e) => e.summary['complete']), everyElement(true));
    runner.cancel();
    final cancelled = await pending.timeout(const Duration(seconds: 10));
    release.complete();
    expect(
      cancelled.evaluations.take(2).map((e) => e.status),
      everyElement(BenchmarkRunStatus.completed),
    );
    expect(
      cancelled.evaluations.skip(2).map((e) => e.status),
      everyElement(BenchmarkRunStatus.cancelled),
    );
    expect(fixture.runtime.io.requests, hasLength(801));
    expect((await store.load(cancelled.id)).toJson(), cancelled.toJson());
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('game preparation cancellation remains normal shutdown and prevents later suites', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final arrived = Completer<void>(), release = Completer<void>();
    final work = BenchmarkGameWork(
      Directory('${fixture.runtime.root.path}/held-game'),
      loadAsset: (path) async {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
        return ByteData.sublistView(await File(path).readAsBytes());
      },
    );
    addTearDown(work.close);
    final resources = BenchmarkResources(
      Directory('${fixture.runtime.root.path}/later-suite'),
    );
    addTearDown(resources.close);
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/held-game-history'),
      ),
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final pending = runner.runSelected(
      suiteIds: ['jevman', 'decidebench'],
      resources: resources,
      gameWork: work,
      modelNames: ['native-kev'],
    );
    final cancelled = expectLater(
      pending,
      throwsA(isA<BenchmarkResourceCancelled>()),
    );
    await arrived.future.timeout(const Duration(seconds: 5));
    final closing = runner.close();
    release.complete();
    await closing.timeout(const Duration(seconds: 5));
    await cancelled;
    expect(work.status, BenchmarkGamePreparationStatus.cancelled);
    expect(resources.status, BenchmarkResourceStatus.idle);
    expect(fixture.runtime.io.requests, isEmpty);
    expect(runner.running, isFalse);
  });

  test('target invalidation skips its later suite and proceeds to the next ready object', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/loss-history'),
      ),
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final first = Completer<void>(),
        peer = Completer<void>(),
        release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var count = 0;
    fixture.runtime.io.respond = (_, raw) async {
      count++;
      if (count == 1) first.complete();
      if (count == 2) peer.complete();
      await release.future;
      return raw;
    };
    final pending = runner.runBatch(
      suites: [jeval, decide],
      modelNames: ['native-kev', 'quick'],
    );
    await first.future.timeout(const Duration(seconds: 5));
    final binding = fixture.council.models.definitions
        .singleWhere((d) => d.name == 'native-kev')
        .bindings
        .single;
    final instance = fixture.runtime.engine.state.instances.singleWhere(
      (i) => i.asset.id == binding.artifactId,
    );
    await fixture.runtime.engine.stop(instance.id);
    await peer.future.timeout(const Duration(seconds: 5));
    runner.cancel();
    final result = await pending.timeout(const Duration(seconds: 10));
    release.complete();
    expect(
      result.evaluations.take(2).map((e) => e.status),
      everyElement(BenchmarkRunStatus.targetUnavailable),
    );
    expect(result.evaluations[1].summary['attempted'], 0);
    expect(result.evaluations[2].summary['attempted'], 1);
    expect(fixture.runtime.io.requests, hasLength(2));
    expect((await runner.store.load(result.id)).toJson(), result.toJson());
  });

  test('cancelling the first resource preparation prevents the next suite and closes the app-owned operation', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final arrived = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (!arrived.isCompleted) arrived.complete();
      await release.future;
      await request.response.close();
    });
    final resources = BenchmarkResources(
      Directory('${fixture.runtime.root.path}/preparation-cache'),
      createHttpClient: () => _ResourceClient(server.port),
    );
    addTearDown(resources.close);
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/preparation-history'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final pending = runner.runSelected(
      suiteIds: ['decidebench', 'jeval'],
      resources: resources,
      modelNames: ['native-kev'],
    );
    final cancelled = expectLater(
      pending,
      throwsA(isA<BenchmarkResourceCancelled>()),
    );
    await arrived.future.timeout(const Duration(seconds: 5));
    expect(runner.running, isTrue);
    expect(runner.selectedSuiteIds, ['decidebench', 'jeval']);
    expect(
      () => runner.runBatch(suites: [decide], modelNames: ['native-kev']),
      throwsStateError,
    );
    await runner.interrupt().timeout(const Duration(seconds: 5));
    await cancelled;
    expect(runner.running, isFalse);
    expect(runner.current, isNull);
    expect(resources.status, BenchmarkResourceStatus.cancelled);
    expect(requests, 1);
    expect(fixture.runtime.io.requests, isEmpty);
    expect(await store.list(), isEmpty);
    await runner.close();
  });

  for (final channel in JevPlaygroundMode.values) {
    test(
      'all five full suites retain mixed game history after ${channel.name} cancellation',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        final work = await _gameWork(fixture.runtime.root);
        addTearDown(work.close);
        final store = BenchmarkRunStore(
          directory: Directory('${fixture.runtime.root.path}/five-history'),
        );
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        addTearDown(runner.close);
        final arrived = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        fixture.runtime.io.respond = (request, raw) async {
          if (!(request['questions'] as Map).containsKey('warmup')) {
            if (!arrived.isCompleted) arrived.complete();
            await release.future;
          }
          return raw;
        };
        final pending = runner.runBatch(
          suites: [work, decide, jeval, coherence, adversarial],
          modelNames: ['native-kev', 'quick', 'hard'],
          channels: [channel],
        );
        await arrived.future.timeout(const Duration(seconds: 20));
        runner.cancel();
        final record = await pending.timeout(const Duration(seconds: 10));
        release.complete();
        expect(
          record.summary['expected'],
          3 * (100 + 400 + 11257 + 10320 + 11368),
        );
        expect(record.evaluations, hasLength(15));
        expect(record.evaluations.first.timeout, const Duration(seconds: 2));
        expect(record.evaluations[1].timeout, const Duration(seconds: 30));
        expect(record.evaluations.first.items.single['complete'], isFalse);
        expect(work.activeProcessId, isNull);
        final restored = await store.load(record.id);
        expect(restored.toJson(), record.toJson());
        expect(restored.comparisons, hasLength(10));
        expect(
          restored.comparisons.every(
            (row) =>
                row['comparable'] == false && row['accuracy_delta'] == null,
          ),
          isTrue,
        );
        expect(restored.comparisons.map((row) => row['suite']).toSet(), {
          'jevman',
          'decidebench',
          'jeval',
          'coherence',
          'adversarial',
        });
        final session = store.openHistory(record.id);
        addTearDown(session.close);
        final summary = await session.ready;
        expect(summary.evaluations.every((e) => e.items.isEmpty), isTrue);
        expect(session.journalFilePaths, hasLength(12));
        expect(session.itemCount(summary.evaluations.first.id), 1);
        final files = await store.recordFilePaths(record.id);
        expect(files, hasLength(13));
        expect(fixture.runtime.io.killedChildren, 0);
        final export = File('${fixture.runtime.root.path}/five-export.json');
        await store.exportTo(record.id, export);
        expect(
          BenchmarkRun.fromJson(
            Map<String, Object?>.from(
              jsonDecode(await export.readAsString()) as Map,
            ),
          ).toJson(),
          restored.toJson(),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<BenchmarkGameWork> _gameWork(Directory root) async {
  final cache = Directory('${root.path}/game-cache');
  final original = Directory(
    '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
  );
  final installation = Directory(
    '${cache.path}/node/${JevmanRuntime.archiveRoot}',
  );
  await Directory('${installation.path}/bin').create(recursive: true);
  await File('${original.path}/bin/node').copy('${installation.path}/bin/node');
  await File('${original.path}/LICENSE').copy('${installation.path}/LICENSE');
  expect(
    (await Process.run('/bin/chmod', [
      '700',
      '${installation.path}/bin/node',
    ])).exitCode,
    0,
  );
  final work = BenchmarkGameWork(cache);
  await work.prepare(DecisionCancellation());
  return work;
}

class _NetworkBoundary extends HttpOverrides {}

class _ResourceClient implements HttpClient {
  _ResourceClient(this.port);
  final int port;
  final HttpClient _client = HttpClient();
  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _client.getUrl(Uri.parse('http://127.0.0.1:$port/source'));
  @override
  void close({bool force = false}) => _client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
