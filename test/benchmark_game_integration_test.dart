import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_game_work.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/jevman_benchmark.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';
import 'package:ghost_model_deck/manager_lifecycle.dart';
import 'package:ghost_model_deck/model_downloader.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Jevman shares the batch gate and all profile locks and preserves partial game history on cancellation',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await PlaygroundRuntime.create();
      final work = await _preparedWork(fixture.runtime.root);
      final store = BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/game-history'),
      );
      final runner = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      final arrived = Completer<void>(), release = Completer<void>();
      Future<BenchmarkRun>? pending;
      fixture.runtime.io.respond = (request, response) async {
        if (!(request['questions'] as Map).containsKey('warmup')) {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
        }
        return response;
      };
      try {
        final original = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final executing = runner.runJevman(
          work: work,
          modelNames: ['native-kev', 'quick', 'hard'],
        );
        pending = executing;
        await arrived.future.timeout(const Duration(seconds: 20));
        expect(runner.running, isTrue);
        for (final name in ['native-kev', 'quick', 'hard']) {
          expect(fixture.council.models.isEvaluationLocked(name), isTrue);
        }
        expect(
          () => runner.run(suite: original, model: 'native-kev'),
          throwsStateError,
        );
        expect(work.activeProcessId, isNotNull);
        runner.cancel();
        final result = await executing.timeout(const Duration(seconds: 10));
        expect(result.status, BenchmarkRunStatus.cancelled);
        expect(result.toJson()['schema_version'], 6);
        expect(result.summary['expected'], 300);
        expect(result.summary['attempted'], 1);
        expect(result.summary['complete'], isFalse);
        expect(result.evaluations, hasLength(3));
        expect(
          result.evaluations.every(
            (run) => run.toJson()['schema_version'] == 5,
          ),
          isTrue,
        );
        expect(
          result.evaluations.every((run) => run.summary['expected'] == 100),
          isTrue,
        );
        expect(
          result.evaluations
              .skip(1)
              .every(
                (run) =>
                    run.summary['attempted'] == 0 &&
                    run.status == BenchmarkRunStatus.cancelled,
              ),
          isTrue,
        );
        final active = result.evaluations.first;
        final game = active.items.single;
        expect(game['index'], 1);
        expect(game['complete'], isFalse);
        expect(JevmanRecording.parse(game['recording']).frames, isNotEmpty);
        expect(game['calls'], isNotEmpty);
        expect(
          (active.toJson()['source_summary'] as Map)['originalSummary'],
          isNull,
        );
        expect(active.summary['latency_success_p50_ms'], isNull);
        expect(active.summary['latency_success_p95_ms'], isNull);
        final latencyCoverage = active.toJson()['client_summary'] as Map;
        expect(latencyCoverage['game_successes'], 0);
        expect(latencyCoverage['latency_success_samples'], 0);
        expect(latencyCoverage['latency_success_coverage'], isNull);

        expect(work.activeProcessId, isNull);
        expect(fixture.gateway.activeOwnedRequests, 0);
        for (final name in ['native-kev', 'quick', 'hard']) {
          expect(fixture.council.models.isEvaluationLocked(name), isFalse);
        }
        final restored = await BenchmarkRunStore(directory: store.directory)
            .load(result.id);
        expect(restored.toJson(), result.toJson());
        final export = File('${fixture.runtime.root.path}/whole-game-run.json');
        await store.exportTo(result.id, export);
        final exported = BenchmarkRun.fromJson(
          Map<String, Object?>.from(
            jsonDecode(await export.readAsString()) as Map,
          ),
        );
        expect(exported.toJson(), restored.toJson());
        expect(exported.evaluations.first.items.single['calls'], game['calls']);
        expect(
          fixture.runtime.io.requests.where(
            (request) => !(request['questions'] as Map).containsKey('warmup'),
          ),
          hasLength(1),
        );
      } finally {
        if (!release.isCompleted) release.complete();
        runner.cancel();
        final operation = pending;
        if (operation != null) {
          await operation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
        }
        await runner.close();
        await work.close();
        await fixture.close();
      }
    }, _NetworkBoundary()),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'formal game latency coverage uses successful outer calls and excludes warmup and cancellation',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await PlaygroundRuntime.create();
      final work = await _preparedWork(fixture.runtime.root);
      final store = BenchmarkRunStore(
        directory: Directory(
          '${fixture.runtime.root.path}/game-latency-history',
        ),
      );
      final runner = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      final arrived = Completer<void>(), release = Completer<void>();
      Future<BenchmarkRun>? pending;
      var formalRequests = 0;
      fixture.runtime.io.respond = (request, response) async {
        if (!(request['questions'] as Map).containsKey('warmup')) {
          formalRequests++;
          if (formalRequests == 3) {
            arrived.complete();
            await release.future;
          }
        }
        return response;
      };
      try {
        // Partial real IPC/public HTTP fixture, not a 100-game model acceptance.
        final executing = runner.runJevman(work: work, model: 'native-kev');
        pending = executing;
        await arrived.future.timeout(const Duration(seconds: 20));
        runner.cancel();
        final cancelled = await executing.timeout(const Duration(seconds: 10));
        final gameCalls = (cancelled.items.single['calls'] as List).cast<Map>();
        final successes = gameCalls
            .where((call) => (call['result'] as Map?)?['status'] == 'success')
            .toList();
        expect(successes, hasLength(2));
        expect(
          gameCalls.where(
            (call) => (call['result'] as Map?)?['status'] == 'cancelled',
          ),
          hasLength(1),
        );
        expect(cancelled.toJson()['warmup_calls'], isNotEmpty);
        final observed = [
          for (final call in successes) call['elapsed_us'] as int,
        ]..sort();
        for (final call in successes) {
          expect(
            call['elapsed_us'] as int,
            greaterThanOrEqualTo((call['result'] as Map)['elapsed_us'] as int),
          );
        }
        // Independent two-observation quantiles: median is the midpoint and
        // the 95th percentile is 5% of the low plus 95% of the high observation.
        expect(
          cancelled.summary['latency_success_p50_ms'],
          closeTo((observed[0] + observed[1]) / 2000, .000001),
        );
        expect(
          cancelled.summary['latency_success_p95_ms'],
          closeTo((.05 * observed[0] + .95 * observed[1]) / 1000, .000001),
        );
        final client = cancelled.toJson()['client_summary'] as Map;
        expect(client['game_successes'], 2);
        expect(client['latency_success_samples'], 2);
        expect(client['latency_success_coverage'], 1.0);
        expect(
          client['latency_success_scope'],
          'formal_game_successful_public_calls',
        );
        expect(
          client['latency_time_source'],
          'outer_elapsed_us_discovery_and_request',
        );
        expect(cancelled.summary['complete'], isFalse);
        expect(
          (cancelled.toJson()['source_summary'] as Map)['originalSummary'],
          isNull,
        );
        final restored = await store.load(cancelled.id);
        expect(
          restored.summary['latency_success_p50_ms'],
          cancelled.summary['latency_success_p50_ms'],
        );
        expect(restored.toJson()['client_summary'], client);
      } finally {
        if (!release.isCompleted) release.complete();
        runner.cancel();
        final operation = pending;
        if (operation != null) {
          await operation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
        }
        await runner.close();
        await work.close();
        await fixture.close();
      }
    }, _NetworkBoundary()),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'closing game work during the zero-execution admission window seals interruption without starting inference',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await PlaygroundRuntime.create();
      final work = await _preparedWork(fixture.runtime.root);
      final store = _HeldInitialSave(
        Directory('${fixture.runtime.root.path}/game-admission-history'),
      );
      final runner = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      Future<BenchmarkRun>? pending;
      try {
        final executing = runner.runJevman(
          work: work,
          modelNames: ['native-kev', 'quick'],
        );
        pending = executing;
        await store.arrived.future.timeout(const Duration(seconds: 10));
        expect(fixture.runtime.io.requests, isEmpty);
        expect(work.activeProcessId, isNull);
        final shutting = Future.wait([runner.close(), work.close()]);
        store.release.complete();
        await shutting.timeout(const Duration(seconds: 10));
        final result = await executing.timeout(const Duration(seconds: 10));
        expect(result.status, BenchmarkRunStatus.interrupted);
        expect(result.toJson()['schema_version'], 6);
        expect(result.summary['expected'], 200);
        expect(result.summary['attempted'], 0);
        expect(result.summary['complete'], isFalse);
        expect(
          result.evaluations.every(
            (run) =>
                run.status == BenchmarkRunStatus.interrupted &&
                run.items.isEmpty,
          ),
          isTrue,
        );
        expect(fixture.runtime.io.requests, isEmpty);
        expect(work.activeProcessId, isNull);
        expect(runner.running, isFalse);
        expect(
          (await store.load(result.id)).status,
          BenchmarkRunStatus.interrupted,
        );
        expect(
          fixture.council.models.isEvaluationLocked('native-kev'),
          isFalse,
        );
        expect(fixture.council.models.isEvaluationLocked('quick'), isFalse);
      } finally {
        if (!store.release.isCompleted) store.release.complete();
        runner.cancel();
        final operation = pending;
        if (operation != null) {
          await operation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
        }
        await runner.close();
        await work.close();
        await fixture.close();
      }
    }, _NetworkBoundary()),
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'manager shutdown owns game resources and seals interrupted history before exit',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await PlaygroundRuntime.create();
      final work = await _preparedWork(fixture.runtime.root);
      final store = BenchmarkRunStore(
        directory: Directory(
          '${fixture.runtime.root.path}/manager-game-history',
        ),
      );
      final runner = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      final downloader = ModelDownloader();
      final manager = ManagerLifecycle(
        council: fixture.council,
        mcp: fixture.mcp,
        engines: fixture.runtime.catalog,
        downloader: downloader,
        gateway: fixture.gateway,
        benchmarks: runner,
        benchmarkGameWork: work,
      );
      final arrived = Completer<void>(), release = Completer<void>();
      Future<BenchmarkRun>? pending;
      fixture.runtime.io.respond = (request, response) async {
        if (!(request['questions'] as Map).containsKey('warmup')) {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
        }
        return response;
      };
      try {
        final executing = runner.runJevman(work: work, model: 'native-kev');
        pending = executing;
        await arrived.future.timeout(const Duration(seconds: 20));
        await manager.shutdown().timeout(const Duration(seconds: 10));
        final interrupted = await executing;
        expect(manager.state, ManagerLifecycleState.stopped);
        expect(interrupted.status, BenchmarkRunStatus.interrupted);
        expect(interrupted.toJson()['schema_version'], 5);
        expect(interrupted.summary['expected'], 100);
        expect(interrupted.summary['attempted'], 1);
        expect(interrupted.summary['complete'], isFalse);
        expect(work.activeProcessId, isNull);
        expect(
          (await store.load(interrupted.id)).status,
          BenchmarkRunStatus.interrupted,
        );
        await expectLater(
          work.prepare(DecisionCancellation()),
          throwsStateError,
        );
        expect(
          fixture.council.models.isEvaluationLocked('native-kev'),
          isFalse,
        );
        await manager.shutdown();
      } finally {
        if (!release.isCompleted) release.complete();
        runner.cancel();
        final operation = pending;
        if (operation != null) {
          await operation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
        }
        await runner.close();
        await work.close();
        await downloader.close();
        await fixture.close();
      }
    }, _NetworkBoundary()),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<BenchmarkGameWork> _preparedWork(Directory root) async {
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
  expect(work.identity['games'], 100);
  expect((work.identity['node'] as Map)['platform'], 'darwin-arm64');
  return work;
}

class _HeldInitialSave extends BenchmarkRunStore {
  _HeldInitialSave(Directory directory) : super(directory: directory);
  final arrived = Completer<void>(), release = Completer<void>();
  @override
  Future<void> save(BenchmarkRun run) async {
    if (!arrived.isCompleted &&
        run.status == BenchmarkRunStatus.running &&
        run.summary['attempted'] == 0) {
      arrived.complete();
      await release.future;
    }
    await super.save(run);
  }
}

class _NetworkBoundary extends HttpOverrides {}
