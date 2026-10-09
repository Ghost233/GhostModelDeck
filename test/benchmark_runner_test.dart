import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

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
