import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/playground_runtime.dart';
import 'fixtures/council_runtime.dart';

void main() {
  test('one ready public HTTP target executes the complete original 400 items and persists 200 pairs', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite);
    final directory = Directory(
      '${fixture.runtime.root.path}/benchmark-history',
    );
    final store = BenchmarkRunStore(directory: directory);
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final completed = await runner.run(suite: suite, model: 'native-kev');
    expect(completed.status, BenchmarkRunStatus.completed);
    expect(completed.model, 'native-kev');
    expect(completed.source, 'native');
    expect(completed.timeout, const Duration(seconds: 30));
    expect(completed.items, hasLength(400));
    expect(completed.groups, hasLength(200));
    expect(completed.summary['complete'], isTrue);
    expect(completed.summary['attempted'], 400);
    expect(completed.summary['accuracy'], 1.0);
    expect(completed.summary['pair_accuracy'], 1.0);
    expect(completed.summary['valid'], 400);
    expect(completed.summary['failures'], 0);
    expect(fixture.runtime.io.requests, hasLength(400));
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
    expect(
      completed.items.map((item) => item['id']),
      orderedEquals(suite.items.map((item) => item.id)),
    );
    expect(
      completed.items.first['request'],
      suite.items.first.request('native-kev'),
    );
    expect(
      (completed.items.first['result'] as Map)['raw_response'],
      contains('native-kev'),
    );
    final restored = await BenchmarkRunStore(directory: directory)
        .load(completed.id);
    expect(restored.items, hasLength(400));
    expect(restored.groups, hasLength(200));
    expect(restored.summary['accuracy'], 1.0);
    expect(restored.toJson()['identity'], isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('complete original suite uses ordinary MCP discovery and tools with separate channel evidence', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite);
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/mcp-history'),
      ),
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final completed = await runner.run(
      suite: suite,
      model: 'native-kev',
      channels: [JevPlaygroundMode.mcp],
    );
    expect(completed.status, BenchmarkRunStatus.completed);
    expect(completed.toJson()['channel'], 'mcp');
    expect(completed.items, hasLength(400));
    expect(completed.summary['accuracy'], 1.0);
    expect(
      completed.items.every(
        (item) => (item['result'] as Map)['channel'] == 'mcp',
      ),
      isTrue,
    );
    expect(
      (await runner.store.load(completed.id)).toJson(),
      completed.toJson(),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('multi-object batch locks all selected names and MCP cancellation seals every planned channel', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final held = Completer<void>(), arrived = Completer<void>();
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/multi-cancel'),
      ),
      models: fixture.council.models,
    );
    Future<BenchmarkRun>? pending;
    try {
      pending = runner.run(
        suite: suite,
        modelNames: ['quick', 'native-kev', 'hard'],
        channels: [JevPlaygroundMode.mcp, JevPlaygroundMode.http],
      );
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(
        [
          'quick',
          'native-kev',
          'hard',
        ].every(fixture.council.models.isEvaluationLocked),
        isTrue,
      );
      for (final definition in fixture.council.models.definitions) {
        await expectLater(
          fixture.council.models.save(definition),
          throwsA(isA<DecisionProtocolException>()),
        );
        await expectLater(
          fixture.council.models.delete(definition.name),
          throwsA(isA<DecisionProtocolException>()),
        );
      }
      runner.cancel();
      final batch = await pending.timeout(const Duration(seconds: 5));
      expect(batch.status, BenchmarkRunStatus.cancelled);
      expect(batch.evaluations, hasLength(6));
      expect(batch.evaluations.map((run) => '${run.model}/${run.channel}'), [
        'quick/mcp',
        'quick/http',
        'native-kev/mcp',
        'native-kev/http',
        'hard/mcp',
        'hard/http',
      ]);
      expect(
        batch.evaluations.every((run) => run.summary['complete'] == false),
        isTrue,
      );
      expect(
        batch.evaluations.skip(1).every((run) => run.items.isEmpty),
        isTrue,
      );
      expect(
        [
          'quick',
          'native-kev',
          'hard',
        ].any(fixture.council.models.isEvaluationLocked),
        isFalse,
      );
      expect((await runner.store.load(batch.id)).toJson(), batch.toJson());
      final changed =
          jsonDecode(jsonEncode(batch.toJson())) as Map<String, dynamic>;
      changed['evaluations'][1]['identity']['configuration']['timeout_us'] =
          123456;
      expect(
        () => BenchmarkRun.fromJson(changed),
        throwsA(isA<FormatException>()),
      );
      expect(held.isCompleted, isFalse);
      expect(fixture.gateway.activeOwnedRequests, 0);
    } finally {
      if (!held.isCompleted) held.complete();
      await runner.close();
      if (pending != null) await pending;
      await fixture.close();
    }
  });
  test('native and two named councils execute all six original object/channel suites with independent gains and costs', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite);
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/complete-six'),
      ),
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final transitions = <String>[];
    var overlaps = false;
    final subscription = runner.changes.listen((batch) {
      final entries = batch.evaluations;
      final active = entries.indexWhere(
        (entry) =>
            entry.items.isNotEmpty &&
            entry.status == BenchmarkRunStatus.running,
      );
      if (active >= 0) {
        final key = '${entries[active].model}/${entries[active].channel}';
        if (transitions.isEmpty || transitions.last != key) {
          transitions.add(key);
        }
        overlaps |= entries
            .take(active)
            .any((entry) => entry.summary['complete'] != true);
      }
    });
    addTearDown(subscription.cancel);
    final batch = await runner.run(
      suite: suite,
      modelNames: ['native-kev', 'quick', 'hard'],
      channels: [JevPlaygroundMode.http, JevPlaygroundMode.mcp],
    );
    expect(batch.status, BenchmarkRunStatus.completed);
    expect(batch.evaluations, hasLength(6));
    expect(transitions, [
      'native-kev/http',
      'native-kev/mcp',
      'quick/http',
      'quick/mcp',
      'hard/http',
      'hard/mcp',
    ]);
    expect(overlaps, isFalse);
    expect(batch.summary['attempted'], 2400);
    expect(batch.summary.containsKey('accuracy'), isFalse);
    for (final evaluation in batch.evaluations) {
      expect(evaluation.items, hasLength(400));
      expect(evaluation.groups, hasLength(200));
      expect(
        evaluation.items.map((item) => item['id']),
        orderedEquals(suite.items.map((item) => item.id)),
      );
      expect(evaluation.summary['accuracy'], 1.0);
      expect(evaluation.summary['pair_accuracy'], 1.0);
      expect(evaluation.summary['probability_coverage'], 400);
      expect(
        evaluation.items.every(
          (item) =>
              (item['request'] as Map)['model'] == evaluation.model &&
              (item['result'] as Map)['channel'] == evaluation.channel,
        ),
        isTrue,
      );
    }
    expect(batch.comparisons, hasLength(4));
    expect(
      batch.comparisons.every(
        (row) =>
            row['comparable'] == true &&
            row['accuracy_delta'] == 0.0 &&
            row['successful_seat_coverage'] == null,
      ),
      isTrue,
    );
    expect(
      batch.comparisons.every(
        (row) => row['latency_success_p50_ms_delta'] is double,
      ),
      isTrue,
    );
    final restarted = BenchmarkRunStore(directory: runner.store.directory);
    expect((await restarted.load(batch.id)).toJson(), batch.toJson());
    final exported = File('${fixture.runtime.root.path}/six-export.json');
    await restarted.exportTo(batch.id, exported);
    expect(
      BenchmarkRun.fromJson(
        Map<String, Object?>.from(
          jsonDecode(await exported.readAsString()) as Map,
        ),
      ).evaluations,
      hasLength(6),
    );
    await expectLater(
      restarted.exportTo(batch.id, exported),
      throwsA(isA<FileSystemException>()),
    );
    await restarted.delete(batch.id);
    expect(await restarted.list(), isEmpty);
    expect(await exported.exists(), isTrue);
    expect(
      fixture.runtime.engine.state.instances.every(
        (instance) => instance.status.name == 'ready',
      ),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('manual stop invalidates one selected object and its later channel while an independent council still completes', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite);
    final gold = fixture.runtime.io.respond!;
    final held = Completer<void>(), arrived = Completer<void>();
    var first = true;
    fixture.runtime.io.respond = (body, raw) async {
      if (first) {
        first = false;
        arrived.complete();
        await held.future;
      }
      return gold(body, raw);
    };
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/one-unavailable'),
      ),
      models: fixture.council.models,
    );
    Future<BenchmarkRun>? pending;
    try {
      pending = runner.run(
        suite: suite,
        modelNames: ['native-kev', 'quick'],
        channels: [JevPlaygroundMode.http, JevPlaygroundMode.mcp],
      );
      await arrived.future.timeout(const Duration(seconds: 5));
      final binding = fixture.council.models.definitions
          .singleWhere((entry) => entry.name == 'native-kev')
          .bindings
          .single;
      final instance = fixture.runtime.engine.state.instances.singleWhere(
        (entry) => entry.asset.id == binding.artifactId,
      );
      await fixture.runtime.engine.stop(instance.id);
      final batch = await pending.timeout(const Duration(minutes: 3));
      expect(batch.status, BenchmarkRunStatus.targetUnavailable);
      final native = batch.evaluations.take(2).toList();
      expect(
        native.every(
          (entry) => entry.status == BenchmarkRunStatus.targetUnavailable,
        ),
        isTrue,
      );
      expect(native.first.items, hasLength(1));
      expect(native.last.items, isEmpty);
      expect(native.first.summary['error'], contains('身份已变化'));
      expect(
        batch.evaluations
            .skip(2)
            .every(
              (entry) =>
                  entry.summary['complete'] == true &&
                  entry.items.length == 400,
            ),
        isTrue,
      );
      expect(
        batch.comparisons.every(
          (row) => row['comparable'] == false && row['accuracy_delta'] == null,
        ),
        isTrue,
      );
      expect(
        (await runner.store.load(batch.id))
            .evaluations
            .last
            .summary['accuracy'],
        1.0,
      );
      expect(held.isCompleted, isFalse);
    } finally {
      if (!held.isCompleted) held.complete();
      await runner.close();
      if (pending != null) await pending;
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
  for (final mode in JevPlaygroundMode.values) {
    test(
      'a first ${mode.name.toUpperCase()} client timeout records its failure and continues all remaining 399 original questions',
      () async {
        final fixture = await PlaygroundRuntime.create();
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        _originalGoldReplies(fixture, suite);
        final gold = fixture.runtime.io.respond!;
        final held = Completer<void>();
        var first = true;
        fixture.runtime.io.respond = (body, raw) async {
          if (first) {
            first = false;
            await held.future;
          }
          return gold(body, raw);
        };
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/one-client-timeout',
            ),
          ),
          models: fixture.council.models,
        );
        try {
          final completed = await runner.run(
            suite: suite,
            model: 'native-kev',
            channels: [mode],
            timeout: const Duration(milliseconds: 500),
          );
          expect(completed.status, BenchmarkRunStatus.completed);
          expect(completed.items, hasLength(400));
          expect(
            completed.items.first['status'],
            JevPlaygroundStatus.timedOut.name,
          );
          expect(completed.summary['client_timeouts'], 1);
          expect(completed.summary['valid'], 399);
          expect(completed.summary['probability_coverage'], 399);
          expect(completed.summary['accuracy'], 0.9975);
          expect(completed.summary['pair_accuracy'], 0.995);
          expect(fixture.runtime.io.requests, hasLength(400));
          expect(
            (await runner.store.load(completed.id)).summary['complete'],
            isTrue,
          );
          expect(held.isCompleted, isFalse);
        } finally {
          if (!held.isCompleted) held.complete();
          await runner.close();
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  for (final stop in ['cancel', 'interrupt']) {
    test(
      'already sealed first object stays byte-stable when the later object receives $stop',
      () async {
        final fixture = await PlaygroundRuntime.create();
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        _originalGoldReplies(fixture, suite);
        final gold = fixture.runtime.io.respond!;
        final arrived = Completer<void>(), held = Completer<void>();
        var requests = 0;
        fixture.runtime.io.respond = (body, raw) async {
          if (++requests == 401) {
            arrived.complete();
            await held.future;
          }
          return gold(body, raw);
        };
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/sealed-$stop'),
          ),
          models: fixture.council.models,
        );
        final sealed = Completer<String>();
        final subscription = runner.changes.listen((batch) {
          final first = batch.evaluations.first;
          if (first.status == BenchmarkRunStatus.completed &&
              !sealed.isCompleted) {
            sealed.complete(jsonEncode(first.toJson()));
          }
        });
        Future<BenchmarkRun>? pending;
        try {
          pending = runner.run(
            suite: suite,
            modelNames: ['quick', 'native-kev'],
          );
          await arrived.future.timeout(const Duration(minutes: 2));
          final bytes = await sealed.future.timeout(const Duration(seconds: 2));
          if (stop == 'cancel') {
            runner.cancel();
          } else {
            await runner.interrupt();
          }
          final batch = await pending.timeout(const Duration(seconds: 5));
          expect(
            batch.status,
            stop == 'cancel'
                ? BenchmarkRunStatus.cancelled
                : BenchmarkRunStatus.interrupted,
          );
          expect(jsonEncode(batch.evaluations.first.toJson()), bytes);
          expect(batch.evaluations.first.summary['complete'], isTrue);
          expect(batch.evaluations.last.summary['complete'], isFalse);
          expect(batch.evaluations.last.items, hasLength(1));
          final restored = await runner.store.load(batch.id);
          expect(jsonEncode(restored.evaluations.first.toJson()), bytes);
          final frozen = jsonEncode(restored.toJson());
          held.complete();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(
            jsonEncode((await runner.store.load(batch.id)).toJson()),
            frozen,
          );
          final restarted = BenchmarkRunner(
            client: fixture.playground,
            store: runner.store,
            models: fixture.council.models,
          );
          expect(restarted.running, isFalse);
          expect(restarted.current, isNull);
          expect((await restarted.store.list()).single.status, batch.status);
          expect(fixture.runtime.io.requests, hasLength(401));
          await restarted.close();
        } finally {
          if (!held.isCompleted) held.complete();
          await runner.close();
          if (pending != null) await pending;
          await subscription.cancel();
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
  for (final stop in ['cancel', 'interrupt', 'close']) {
    test(
      '$stop during second batch initial save preserves old cancelled history and seals unexecuted new batch',
      () async {
        final fixture = await PlaygroundRuntime.create();
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final firstArrived = Completer<void>(), firstHeld = Completer<void>();
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          if (!firstArrived.isCompleted) firstArrived.complete();
          await firstHeld.future;
          return raw;
        };
        final store = BenchmarkRunStore(
          directory: Directory(
            '${fixture.runtime.root.path}/startup-interruption',
          ),
        );
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        final entered = Completer<void>(), release = Completer<void>();
        Future<BenchmarkRun>? second;
        Future<void>? closing;
        try {
          final first = runner.run(suite: suite, model: 'native-kev');
          await firstArrived.future.timeout(const Duration(seconds: 5));
          runner.cancel();
          final previous = await first;
          final previousBytes = jsonEncode(
            (await store.load(previous.id)).toJson(),
          );
          firstHeld.complete();
          final filesystem = Zone.current;
          second = IOOverrides.runZoned(
            () => runner.run(
              suite: suite,
              modelNames: ['native-kev', 'quick'],
              channels: JevPlaygroundMode.values,
            ),
            fseGetType: (path, followLinks) async {
              if (path.startsWith('${store.directory.path}/run-') &&
                  path.endsWith('.json') &&
                  !path.contains(previous.id) &&
                  !entered.isCompleted) {
                entered.complete();
                await release.future;
              }
              return filesystem.run(
                () => FileSystemEntity.type(path, followLinks: followLinks),
              );
            },
          );
          await entered.future.timeout(const Duration(seconds: 5));
          expect(runner.current!.id, previous.id);
          if (stop == 'cancel') {
            runner.cancel();
          } else {
            closing = stop == 'close' ? runner.close() : runner.interrupt();
          }
          release.complete();
          final interrupted = await second!.timeout(const Duration(seconds: 5));
          if (closing != null) {
            await closing.timeout(const Duration(seconds: 5));
          }
          expect(
            interrupted.status,
            stop == 'cancel'
                ? BenchmarkRunStatus.cancelled
                : BenchmarkRunStatus.interrupted,
          );
          expect(interrupted.id, isNot(previous.id));
          expect(
            interrupted.evaluations.every(
              (entry) =>
                  entry.items.isEmpty && entry.summary['complete'] == false,
            ),
            isTrue,
          );
          expect(fixture.runtime.io.requests, hasLength(1));
          expect(
            jsonEncode((await store.load(previous.id)).toJson()),
            previousBytes,
          );
          expect(
            fixture.council.models.definitions.any(
              (entry) => fixture.council.models.isEvaluationLocked(entry.name),
            ),
            isFalse,
          );
          final restarted = BenchmarkRunner(
            client: fixture.playground,
            store: store,
            models: fixture.council.models,
          );
          expect(restarted.running, isFalse);
          expect(
            (await restarted.store.load(interrupted.id)).status,
            interrupted.status,
          );
          await restarted.close();
        } finally {
          if (!firstHeld.isCompleted) firstHeld.complete();
          if (!release.isCompleted) release.complete();
          await runner.close();
          if (second != null) await second;
          if (closing != null) await closing;
          await fixture.close();
        }
      },
    );
  }
  for (final mode in JevPlaygroundMode.values) {
    for (final stop in ['cancel', 'interrupt', 'close']) {
      test(
        '$stop during second batch actual ${mode.name} discovery seals an unexecuted plan instead of losing history',
        () async {
          final fixture = await PlaygroundRuntime.create();
          final suite = await DecideBenchSuite.load(
            Directory('benchmarks/sources/decidebench'),
          );
          final firstArrived = Completer<void>(), firstHeld = Completer<void>();
          fixture.runtime.io.requests.clear();
          fixture.runtime.io.respond = (body, raw) async {
            if (!firstArrived.isCompleted) firstArrived.complete();
            await firstHeld.future;
            return raw;
          };
          final store = BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/discovery-interruption',
            ),
          );
          final runner = BenchmarkRunner(
            client: fixture.playground,
            store: store,
            models: fixture.council.models,
          );
          final entered = Completer<void>(), release = Completer<void>();
          Socket? connection;
          Future<BenchmarkRun>? second;
          Future<void>? stopping;
          Object? stopError;
          try {
            final first = runner.run(suite: suite, model: 'native-kev');
            await firstArrived.future.timeout(const Duration(seconds: 5));
            runner.cancel();
            final previous = await first;
            final previousBytes = jsonEncode(
              (await store.load(previous.id)).toJson(),
            );
            firstHeld.complete();
            final network = Zone.current;
            second = IOOverrides.runZoned(
              () => runner.run(
                suite: suite,
                model: 'native-kev',
                channels: [mode],
              ),
              socketStartConnect:
                  (host, port, {sourceAddress, sourcePort = 0}) async {
                    final task = await network.run(
                      () => Socket.startConnect(
                        host,
                        port,
                        sourceAddress: sourceAddress,
                        sourcePort: sourcePort,
                      ),
                    );
                    if (port ==
                            (mode == JevPlaygroundMode.http
                                ? fixture.gateway.baseUrl!.port
                                : fixture.mcp.endpoint!.port) &&
                        !entered.isCompleted) {
                      connection = await task.socket;
                      entered.complete();
                      await release.future;
                    }
                    return task;
                  },
            );
            final outcome = second!.then<Object>(
              (record) => record,
              onError: (Object error) => error,
            );
            await entered.future.timeout(const Duration(seconds: 5));
            if (stop == 'cancel') {
              runner.cancel();
            } else {
              stopping = (stop == 'close' ? runner.close() : runner.interrupt())
                  .then<void>(
                    (_) {},
                    onError: (Object error) {
                      stopError = error;
                    },
                  );
            }
            release.complete();
            final result = await outcome.timeout(const Duration(seconds: 5));
            if (stopping != null) await stopping;
            expect(result, isA<BenchmarkRun>());
            final interrupted = result as BenchmarkRun;
            expect(
              interrupted.status,
              stop == 'cancel'
                  ? BenchmarkRunStatus.cancelled
                  : BenchmarkRunStatus.interrupted,
            );
            expect(interrupted.id, isNot(previous.id));
            expect(interrupted.items, isEmpty);
            expect(interrupted.summary['complete'], isFalse);
            expect(interrupted.summary['accuracy'], isNull);
            expect(
              (await store.load(interrupted.id)).status,
              interrupted.status,
            );
            expect(
              jsonEncode((await store.load(previous.id)).toJson()),
              previousBytes,
            );
            expect(fixture.runtime.io.requests, hasLength(1));
            expect(stopError, isNull);
            expect(
              fixture.council.models.isEvaluationLocked('native-kev'),
              isFalse,
            );
          } finally {
            if (!firstHeld.isCompleted) firstHeld.complete();
            if (!release.isCompleted) release.complete();
            await runner.close().catchError((Object error) {
              if (stopError == null) throw error;
            });
            if (stopping != null) await stopping;
            connection?.destroy();
            await fixture.close();
          }
        },
      );
    }
  }
  test('actual discovery failure remains failed rather than interrupted and leaves a sealed zero-item record', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final store = BenchmarkRunStore(
      directory: Directory(
        '${fixture.runtime.root.path}/startup-service-failure',
      ),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    await fixture.gateway.stop();
    await expectLater(
      runner.run(suite: suite, model: 'native-kev'),
      throwsStateError,
    );
    final record = (await store.list()).single;
    expect(record.status, BenchmarkRunStatus.failed);
    expect(record.items, isEmpty);
    expect(record.summary['accuracy'], isNull);
    expect(record.summary['error'], contains('HTTP 服务未运行'));
    expect(
      fixture.runtime.io.requests.where(
        (body) => body['state'] == suite.items.first.state,
      ),
      isEmpty,
    );
    expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
  });
  for (final stop in ['cancel', 'interrupt', 'close']) {
    test(
      '$stop during second batch queued registry lock seals a truthful plan and releases acquired locks',
      () async {
        final graph = await _StartupLockGraph.create();
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final firstArrived = Completer<void>(), firstHeld = Completer<void>();
        graph.runtime.io.requests.clear();
        graph.runtime.io.respond = (body, raw) async {
          if (!firstArrived.isCompleted) firstArrived.complete();
          await firstHeld.future;
          return raw;
        };
        final store = BenchmarkRunStore(
          directory: Directory('${graph.runtime.root.path}/lock-interruption'),
        );
        final runner = BenchmarkRunner(
          client: JevPlayground(gateway: graph.gateway, mcp: graph.mcp),
          store: store,
          models: graph.council.models,
        );
        Future<void>? writing;
        Future<BenchmarkRun>? second;
        Future<void>? stopping;
        StreamSubscription<BenchmarkRun>? watching;
        try {
          final first = runner.run(suite: suite, model: 'native-kev');
          await firstArrived.future.timeout(const Duration(seconds: 5));
          runner.cancel();
          final previous = await first;
          final previousBytes = jsonEncode(
            (await store.load(previous.id)).toJson(),
          );
          firstHeld.complete();
          graph.registry.hold = true;
          final definition = graph.council.models.definitions.singleWhere(
            (entry) => entry.name == 'native-kev',
          );
          writing = graph.council.models.save(
            definition,
            replacing: definition.name,
          );
          await graph.registry.entered.future.timeout(
            const Duration(seconds: 5),
          );
          final published = Completer<BenchmarkRun>();
          watching = runner.changes.listen((record) {
            if (record.id != previous.id && !published.isCompleted) {
              published.complete(record);
            }
          });
          second = runner.run(
            suite: suite,
            modelNames: ['native-kev', 'quick'],
            channels: JevPlaygroundMode.values,
          );
          final plan = await published.future.timeout(
            const Duration(seconds: 5),
          );
          expect(
            plan.evaluations.every(
              (entry) => entry.identity['selection_status'] == 'not_acquired',
            ),
            isTrue,
          );
          expect(
            graph.council.models.isEvaluationLocked('native-kev'),
            isFalse,
          );
          if (stop == 'cancel') {
            runner.cancel();
          } else {
            stopping = stop == 'close' ? runner.close() : runner.interrupt();
          }
          graph.registry.release.complete();
          await writing;
          final result = await second.timeout(const Duration(seconds: 5));
          if (stopping != null) await stopping;
          expect(
            result.status,
            stop == 'cancel'
                ? BenchmarkRunStatus.cancelled
                : BenchmarkRunStatus.interrupted,
          );
          expect(
            result.evaluations.every(
              (entry) =>
                  entry.items.isEmpty && entry.summary['accuracy'] == null,
            ),
            isTrue,
          );
          for (final entry in result.evaluations.where(
            (entry) => entry.model == 'native-kev',
          )) {
            expect(entry.identity['configuration'], definition.toJson());
          }
          expect(graph.runtime.io.requests, hasLength(1));
          expect(
            jsonEncode((await store.load(previous.id)).toJson()),
            previousBytes,
          );
          expect(
            graph.council.models.definitions.any(
              (entry) => graph.council.models.isEvaluationLocked(entry.name),
            ),
            isFalse,
          );
          final restarted = BenchmarkRunner(
            client: JevPlayground(gateway: graph.gateway, mcp: graph.mcp),
            store: store,
            models: graph.council.models,
          );
          expect(restarted.running, isFalse);
          expect(restarted.current, isNull);
          expect((await restarted.store.load(result.id)).status, result.status);
          await restarted.close();
        } finally {
          if (!firstHeld.isCompleted) firstHeld.complete();
          if (!graph.registry.release.isCompleted) {
            graph.registry.release.complete();
          }
          if (writing != null) await writing;
          await runner.close();
          if (second != null) await second;
          if (stopping != null) await stopping;
          await watching?.cancel();
          await graph.close();
        }
      },
    );
  }
  test('completed then cancelled and interrupted histories cannot filter later startup intents', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite);
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/consecutive-startup'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    try {
      var previous = await runner.run(suite: suite, model: 'native-kev');
      expect(previous.status, BenchmarkRunStatus.completed);
      final completedBytes = jsonEncode(previous.toJson());
      for (final stop in ['cancel', 'interrupt', 'close']) {
        final bytes = jsonEncode((await store.load(previous.id)).toJson());
        final entered = Completer<void>(), release = Completer<void>();
        final filesystem = Zone.current;
        final operation = IOOverrides.runZoned(
          () => runner.run(
            suite: suite,
            modelNames: ['native-kev', 'quick'],
            channels: JevPlaygroundMode.values,
          ),
          fseGetType: (path, followLinks) async {
            if (path.startsWith('${store.directory.path}/run-') &&
                path.endsWith('.json') &&
                !path.contains(previous.id) &&
                !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
            return filesystem.run(
              () => FileSystemEntity.type(path, followLinks: followLinks),
            );
          },
        );
        Future<void>? stopping;
        try {
          await entered.future.timeout(const Duration(seconds: 5));
          expect(runner.current!.id, previous.id);
          if (stop == 'cancel') {
            runner.cancel();
          } else {
            stopping = stop == 'close' ? runner.close() : runner.interrupt();
          }
        } finally {
          if (!release.isCompleted) release.complete();
        }
        final result = await operation.timeout(const Duration(seconds: 5));
        if (stopping != null) await stopping;
        expect(
          result.status,
          stop == 'cancel'
              ? BenchmarkRunStatus.cancelled
              : BenchmarkRunStatus.interrupted,
        );
        expect(result.id, isNot(previous.id));
        expect(
          result.evaluations.every(
            (entry) =>
                entry.items.isEmpty &&
                entry.summary['complete'] == false &&
                entry.identity['selection_status'] == 'not_acquired',
          ),
          isTrue,
        );
        expect(jsonEncode((await store.load(previous.id)).toJson()), bytes);
        previous = result;
      }
      expect(fixture.runtime.io.requests, hasLength(400));
      final records = await store.list();
      expect(records, hasLength(4));
      expect(
        jsonEncode(
          records
              .singleWhere(
                (entry) => entry.status == BenchmarkRunStatus.completed,
              )
              .toJson(),
        ),
        completedBytes,
      );
      final restarted = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      expect(restarted.current, isNull);
      expect(restarted.running, isFalse);
      await restarted.close();
    } finally {
      await runner.close();
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('batch cancellation closes only its normal public request and seals incomplete history', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final held = Completer<void>(), arrived = Completer<void>();
    final otherHeld = Completer<void>(), otherArrived = Completer<void>();
    fixture.runtime.io.requests.clear();
    fixture.runtime.io.respond = (body, raw) async {
      if (body['state'] == suite.items.first.state) {
        if (!arrived.isCompleted) arrived.complete();
        await held.future;
      } else if (body['state'] == suite.items[1].state) {
        if (!otherArrived.isCompleted) otherArrived.complete();
        await otherHeld.future;
      }
      return raw;
    };
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/batch-history'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    Future<BenchmarkRun>? pending;
    Future<JevPlaygroundResult>? independent;
    try {
      pending = runner.run(suite: suite, model: 'native-kev');
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isTrue);
      independent = fixture.playground.run(
        JevPlaygroundMode.http,
        jsonEncode(suite.items[1].request('native-kev')),
      );
      await otherArrived.future.timeout(const Duration(seconds: 5));
      runner.cancel();
      final cancelled = await pending.timeout(const Duration(seconds: 2));
      expect(cancelled.status, BenchmarkRunStatus.cancelled);
      expect(cancelled.items, hasLength(1));
      expect(cancelled.summary['complete'], isFalse);
      expect(cancelled.summary['accuracy'], isNull);
      expect(cancelled.summary['pair_accuracy'], isNull);
      expect(held.isCompleted, isFalse);
      expect(otherHeld.isCompleted, isFalse);
      expect(
        fixture.runtime.engine.state.instances.fold<int>(
          0,
          (sum, instance) => sum + instance.activeRequests,
        ),
        1,
      );
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
      otherHeld.complete();
      expect(
        (await independent.timeout(const Duration(seconds: 2))).status,
        JevPlaygroundStatus.success,
      );
      final saved = await store.load(cancelled.id);
      final frozen = saved.toJson();
      held.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect((await store.load(cancelled.id)).toJson(), frozen);
      expect(fixture.runtime.io.requests, hasLength(2));
      expect(fixture.gateway.activeOwnedRequests, 0);
    } finally {
      // Recover real owned I/O after a red without abandoning a live batch.
      await fixture.runtime.catalog.stopManaged();
      if (!held.isCompleted) held.complete();
      if (!otherHeld.isCompleted) otherHeld.complete();
      if (pending != null) await pending.timeout(const Duration(seconds: 5));
      if (independent != null) {
        await independent.timeout(const Duration(seconds: 5));
      }
      await runner.close();
      await fixture.close();
    }
  });
  for (final exitMethod in ['interrupt', 'close']) {
    test(
      'app $exitMethod flushes interrupted history and releases its public request before shutdown',
      () async {
        final fixture = await PlaygroundRuntime.create();
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final held = Completer<void>(), arrived = Completer<void>();
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await held.future;
          return raw;
        };
        final store = BenchmarkRunStore(
          directory: Directory('${fixture.runtime.root.path}/quit-history'),
        );
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        Future<BenchmarkRun>? pending;
        Future<void>? settled;
        Object? lateFailure;
        try {
          pending = runner.run(suite: suite, model: 'native-kev');
          settled = pending.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              lateFailure = error;
            },
          );
          await arrived.future.timeout(const Duration(seconds: 5));
          final id = runner.current!.id;
          final viewing = runner.changes.listen((_) {});
          await viewing.cancel();
          expect(runner.running, isTrue);
          expect((await store.load(id)).status, BenchmarkRunStatus.running);
          expect(held.isCompleted, isFalse);
          if (exitMethod == 'interrupt') {
            await runner.interrupt();
          } else {
            await runner.close();
          }
          expect((await store.load(id)).status, BenchmarkRunStatus.interrupted);
          final interrupted = await pending.timeout(const Duration(seconds: 2));
          expect(interrupted.status, BenchmarkRunStatus.interrupted);
          expect(interrupted.items, hasLength(1));
          expect(interrupted.summary['complete'], isFalse);
          expect(interrupted.summary['accuracy'], isNull);
          expect(held.isCompleted, isFalse);
          expect(
            fixture.council.models.isEvaluationLocked('native-kev'),
            isFalse,
          );
          expect(
            fixture.runtime.engine.state.instances.every(
              (instance) => instance.activeRequests == 0,
            ),
            isTrue,
          );
          await runner.close();
          await runner.close();
          expect(
            () => runner.run(suite: suite, model: 'native-kev'),
            throwsA(isA<StateError>()),
          );
          await expectLater(runner.targets(), throwsA(isA<StateError>()));
          final restarted = BenchmarkRunner(
            client: fixture.playground,
            store: BenchmarkRunStore(directory: store.directory),
            models: fixture.council.models,
          );
          expect(restarted.current, isNull);
          expect(restarted.running, isFalse);
          expect(
            (await restarted.store.list()).single.status,
            BenchmarkRunStatus.interrupted,
          );
          expect(fixture.runtime.io.requests, hasLength(1));
          await restarted.close();
          held.complete();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect((await store.load(id)).status, BenchmarkRunStatus.interrupted);
          expect(lateFailure, isNull);
        } finally {
          await fixture.runtime.catalog.stopManaged();
          if (!held.isCompleted) held.complete();
          if (settled != null) {
            await settled.timeout(const Duration(seconds: 5));
            if (lateFailure != null) {
              stderr.writeln(
                'Shutdown red cleanup also observed: $lateFailure',
              );
            }
          }
          await runner.close();
          await fixture.close();
        }
      },
    );
  }
  test('one ordinary upstream failure retains all original denominators and never retries', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite, failedId: suite.items.first.id);
    final store = BenchmarkRunStore(
      directory: Directory(
        '${fixture.runtime.root.path}/single-failure-history',
      ),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    final completed = await runner.run(suite: suite, model: 'native-kev');
    expect(completed.status, BenchmarkRunStatus.completed);
    expect(completed.items, hasLength(400));
    expect(completed.groups, hasLength(200));
    expect(completed.summary['attempted'], 400);
    expect(completed.summary['complete'], isTrue);
    expect(completed.summary['accuracy'], 0.9975);
    expect(completed.summary['pair_accuracy'], 0.995);
    expect(completed.summary['unusable'], 1);
    expect(completed.summary['failures'], 1);
    expect(completed.summary['valid'], 399);
    expect(fixture.runtime.io.requests, hasLength(400));
    final failed = completed.items.first;
    expect(failed['prediction'], isNull);
    expect(failed['status'], isNot('success'));
    expect((failed['result'] as Map)['http_status'], 502);
    expect((failed['result'] as Map)['raw_response'], contains('engine_error'));
    expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
    expect((await store.load(completed.id)).summary['failures'], 1);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('loss of the actual public HTTP listener stops the target even while model metadata stays ready', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final held = Completer<void>(), arrived = Completer<void>();
    fixture.runtime.io.requests.clear();
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/lost-http-history'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    final progress = Completer<BenchmarkRun>();
    var listenerStopped = false;
    final subscription = runner.changes.listen((record) {
      if (listenerStopped &&
          (record.status != BenchmarkRunStatus.running ||
              record.items.length > 1) &&
          !progress.isCompleted) {
        progress.complete(record);
      }
    });
    Future<BenchmarkRun>? pending;
    try {
      final publicUrl = fixture.gateway.baseUrl!;
      pending = runner.run(suite: suite, model: 'native-kev');
      await arrived.future.timeout(const Duration(seconds: 5));
      listenerStopped = true;
      await fixture.gateway.stop();
      expect(
        fixture.runtime.engine.state.instances.every(
          (instance) => instance.status.name == 'ready',
        ),
        isTrue,
      );
      final ordinary = HttpClient();
      try {
        await expectLater(
          ordinary.getUrl(publicUrl.resolve('/v1/models')),
          throwsA(isA<SocketException>()),
        );
      } finally {
        ordinary.close(force: true);
      }
      final observed = await progress.future.timeout(
        const Duration(seconds: 3),
      );
      expect(observed.status, BenchmarkRunStatus.targetUnavailable);
      expect(observed.items.length, lessThanOrEqualTo(1));
      final stopped = await pending.timeout(const Duration(seconds: 2));
      expect(stopped.summary['complete'], isFalse);
      expect(stopped.summary['accuracy'], isNull);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
      expect(
        (await store.load(stopped.id)).status,
        BenchmarkRunStatus.targetUnavailable,
      );
    } finally {
      await runner.interrupt();
      if (!held.isCompleted) held.complete();
      if (pending != null) await pending.timeout(const Duration(seconds: 5));
      await subscription.cancel();
      await runner.close();
      await fixture.close();
    }
  });
  test('manually stopping the owned engine stops this target without sending another original item', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final held = Completer<void>(), arrived = Completer<void>();
    fixture.runtime.io.requests.clear();
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/manual-stop-history'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    Future<BenchmarkRun>? pending;
    try {
      pending = runner.run(suite: suite, model: 'native-kev');
      await arrived.future.timeout(const Duration(seconds: 5));
      await fixture.runtime.catalog.stopManaged();
      final stopped = await pending.timeout(const Duration(seconds: 3));
      expect(stopped.status, BenchmarkRunStatus.targetUnavailable);
      expect(stopped.items, hasLength(1));
      expect(stopped.summary['complete'], isFalse);
      expect(stopped.summary['accuracy'], isNull);
      expect(stopped.summary['pair_accuracy'], isNull);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(fixture.gateway.activeOwnedRequests, 0);
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
      expect(
        (await store.load(stopped.id)).status,
        BenchmarkRunStatus.targetUnavailable,
      );
      expect(held.isCompleted, isFalse);
    } finally {
      if (!held.isCompleted) held.complete();
      await runner.interrupt();
      if (pending != null) await pending.timeout(const Duration(seconds: 5));
      await runner.close();
      await fixture.close();
    }
  });

  test('cancellation at the final original item cannot publish a full benchmark score', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    _originalGoldReplies(fixture, suite);
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/final-cancel-history'),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    addTearDown(runner.close);
    var sawComplete = false;
    final subscription = runner.changes.listen((record) {
      sawComplete |= record.summary['complete'] == true;
      if (record.status == BenchmarkRunStatus.running &&
          record.items.length == 400) {
        runner.cancel();
      }
    });
    addTearDown(subscription.cancel);
    final cancelled = await runner.run(suite: suite, model: 'native-kev');
    await Future<void>.delayed(Duration.zero);
    expect(sawComplete, isFalse);
    expect(cancelled.status, BenchmarkRunStatus.cancelled);
    expect(cancelled.items, hasLength(400));
    expect(cancelled.groups, hasLength(200));
    expect(cancelled.summary['attempted'], 400);
    expect(cancelled.summary['missing'], 0);
    expect(cancelled.summary['complete'], isFalse);
    expect(cancelled.summary['accuracy'], isNull);
    expect(cancelled.summary['pair_accuracy'], isNull);
    expect(cancelled.summary['brier'], isNull);
    expect(cancelled.summary['ece'], isNull);
    expect(fixture.runtime.io.requests, hasLength(400));
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
    expect(
      (await store.load(cancelled.id)).status,
      BenchmarkRunStatus.cancelled,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  for (final serverDeadline in [true, false]) {
    test(
      'a real ${serverDeadline ? 'server' : 'client'} deadline is counted without changing the service budget',
      () async {
        final fixture = await PlaygroundRuntime.create();
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final model = serverDeadline ? 'quick' : 'native-kev';
        final budget = fixture.council.models.definitions
            .singleWhere((definition) => definition.name == model)
            .timeout;
        final held = Completer<void>();
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          await held.future;
          return raw;
        };
        final store = BenchmarkRunStore(
          directory: Directory('${fixture.runtime.root.path}/deadline-history'),
        );
        final runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        final subscription = runner.changes.listen((record) {
          if (record.items.isNotEmpty) runner.cancel();
        });
        try {
          final result = await runner.run(
            suite: suite,
            model: model,
            timeout: serverDeadline
                ? const Duration(seconds: 30)
                : const Duration(milliseconds: 200),
          );
          expect(result.status, BenchmarkRunStatus.cancelled);
          expect(result.items, hasLength(1));
          final row = result.items.single;
          final response = row['result'] as Map;
          if (serverDeadline) {
            expect(row['status'], JevPlaygroundStatus.businessError.name);
            expect(response['http_status'], 504);
            expect(
              jsonDecode(response['raw_response'] as String)['error']['code'],
              'timed_out',
            );
          } else {
            expect(row['status'], JevPlaygroundStatus.timedOut.name);
            expect(response['http_status'], isNull);
          }
          expect(result.summary['client_timeouts'], serverDeadline ? 0 : 1);
          expect(result.summary['server_timeouts'], serverDeadline ? 1 : 0);
          expect(result.summary['timeouts'], 1);
          expect(result.summary['complete'], isFalse);
          expect(result.summary['accuracy'], isNull);
          expect(result.summary['failures'], 1);
          expect(fixture.runtime.io.requests, hasLength(1));
          expect(
            fixture.council.models.definitions
                .singleWhere((definition) => definition.name == model)
                .timeout,
            budget,
          );
          expect(
            (result.identity['configuration'] as Map)['timeout_us'],
            budget.inMicroseconds,
          );
          expect(fixture.council.models.isEvaluationLocked(model), isFalse);
          expect((await store.load(result.id)).summary['timeouts'], 1);
        } finally {
          await subscription.cancel();
          if (!held.isCompleted) held.complete();
          await runner.close();
          await fixture.close();
        }
      },
    );
  }

  test('a real history write failure keeps received results visible and cannot be hidden by app quit', () async {
    final fixture = await PlaygroundRuntime.create();
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final held = Completer<void>(), arrived = Completer<void>();
    fixture.runtime.io.requests.clear();
    fixture.runtime.io.respond = (body, raw) async {
      if (body['state'] == suite.items[1].state) {
        if (!arrived.isCompleted) arrived.complete();
        await held.future;
      }
      return raw;
    };
    final store = BenchmarkRunStore(
      directory: Directory(
        '${fixture.runtime.root.path}/write-failure-history',
      ),
    );
    final runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
    );
    Future<BenchmarkRun>? pending;
    Future<void>? settled;
    try {
      pending = runner.run(suite: suite, model: 'native-kev');
      settled = pending.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      );
      await arrived.future.timeout(const Duration(seconds: 5));
      final id = runner.current!.id;
      expect((await store.load(id)).items, hasLength(1));
      final originalFile = File('${store.directory.path}/$id.json');
      final originalBytes = await originalFile.readAsString();
      final previous = Directory('${fixture.runtime.root.path}/prior-history');
      await previous.create();
      await originalFile.rename('${previous.path}/$id.json');
      final userFile = await File(
        '${fixture.runtime.root.path}/user-owned.json',
      ).writeAsString('user bytes must survive');
      await Link(originalFile.path).create(userFile.path);
      held.complete();
      await expectLater(pending, throwsA(isA<FileSystemException>()));
      Object? quitError;
      try {
        await runner.close();
      } catch (error) {
        quitError = error;
      }
      expect(
        {
          'status': runner.current!.status.name,
          'quit_reports_storage_failure': quitError is FileSystemException,
        },
        {'status': 'failed', 'quit_reports_storage_failure': true},
      );
      expect(runner.current!.items, hasLength(2));
      expect(runner.current!.summary['complete'], isFalse);
      expect(runner.current!.summary['accuracy'], isNull);
      expect(runner.current!.summary['error'], contains('符号链接'));
      expect(fixture.runtime.io.requests, hasLength(2));
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
      expect(await userFile.readAsString(), 'user bytes must survive');
      expect(
        await File('${previous.path}/$id.json').readAsString(),
        originalBytes,
      );
      expect(
        (await BenchmarkRunStore(directory: previous).load(id)).items,
        hasLength(1),
      );
      expect(
        await FileSystemEntity.type(originalFile.path, followLinks: false),
        FileSystemEntityType.link,
      );
    } finally {
      if (!held.isCompleted) held.complete();
      await runner.interrupt().catchError((Object error) {
        if (error is! FileSystemException) throw error;
      });
      if (settled != null) await settled.timeout(const Duration(seconds: 5));
      await runner.close().catchError((Object error) {
        if (error is! FileSystemException) throw error;
      });
      await fixture.close();
    }
  });
}

void _originalGoldReplies(
  PlaygroundRuntime fixture,
  DecideBenchSuite suite, {
  String? failedId,
}) {
  final original = {
    for (final item in suite.items) '${item.state}\n${item.question}': item,
  };
  fixture.runtime.io.requests.clear();
  fixture.runtime.io.respond = (body, raw) async {
    final question = (body['questions'] as Map)['decision'] as Map;
    final item = original['${body['state']}\n${question['instructions']}']!;
    fixture.runtime.io.consultationStatus = item.id == failedId ? 503 : 200;
    final reply = jsonDecode(raw) as Map;
    reply['answers']['decision'] = {
      'type': 'choice',
      'choice': item.gold,
      'confidence': 1.0,
      'probabilities': {
        for (final key in item.options.keys) key: key == item.gold ? 1.0 : 0.0,
      },
    };
    return jsonEncode(reply);
  };
}

class _StartupRegistryIO extends NativeJevRegistryIO {
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> write(File file, String contents) async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.write(file, contents);
  }
}

class _StartupLockGraph {
  _StartupLockGraph(
    this.runtime,
    this.registry,
    this.council,
    this.routes,
    this.gateway,
    this.mcp,
  );
  final CouncilRuntime runtime;
  final _StartupRegistryIO registry;
  final CouncilController council;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;
  static Future<_StartupLockGraph> create() async {
    final runtime = await CouncilRuntime.create();
    final registry = _StartupRegistryIO();
    final council = CouncilController(
      catalog: runtime.catalog,
      modelRegistryFile: File('${runtime.root.path}/jev.json'),
      modelRegistryIO: registry,
    );
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.native(name: 'native-kev', binding: bindings.last),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [bindings.first],
        timeout: const Duration(seconds: 2),
      ),
    );
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: [runtime.engine],
    );
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    final mcp = CouncilMcpServer(controller: council, port: 0);
    await gateway.start();
    await mcp.start();
    return _StartupLockGraph(runtime, registry, council, routes, gateway, mcp);
  }

  Future<void> close() async {
    await mcp.close();
    await gateway.stop();
    gateway.close();
    routes.close();
    await council.close();
    await runtime.close();
  }
}
