import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/manager_lifecycle.dart';
import 'package:ghost_model_deck/model_downloader.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  test('master off cancels its evaluation batch without consuming later questions or stopping HTTP/MCP', () async {
    late BenchmarkRunner runner;
    final fixture = await PlaygroundRuntime.create(
      onRuntimeClosing: () => runner.cancel(),
    );
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/history'),
    );
    runner = BenchmarkRunner(
      client: fixture.playground,
      store: store,
      models: fixture.council.models,
      requireRuntimeEnabled: fixture.runtime.catalog.requireRuntimeEnabled,
    );
    addTearDown(fixture.close);
    addTearDown(store.close);
    addTearDown(runner.close);
    final arrived = Completer<void>(), held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final operation = runner.run(suite: suite, model: 'native-kev');
    await arrived.future.timeout(const Duration(seconds: 5));
    await fixture.runtime.catalog
        .setRuntimeEnabled(false)
        .timeout(const Duration(seconds: 5));
    final result = await operation.timeout(const Duration(seconds: 5));
    expect(result.status, BenchmarkRunStatus.cancelled);
    expect(result.summary['complete'], isFalse);
    expect(fixture.runtime.io.requests, hasLength(1));
    expect(fixture.gateway.baseUrl, isNotNull);
    expect(fixture.mcp.endpoint, isNotNull);
    expect(
      () => runner.run(suite: suite, model: 'native-kev'),
      throwsStateError,
    );
    final persisted = await store.load(result.id);
    expect(persisted.status, BenchmarkRunStatus.cancelled);
    held.complete();
  });

  test('explicit application shutdown seals and flushes its benchmark before releasing services', () async {
    final fixture = await PlaygroundRuntime.create();
    final resources = BenchmarkResources(
      Directory('${fixture.runtime.root.path}/benchmark-cache'),
    );
    final store = BenchmarkRunStore(
      directory: Directory('${fixture.runtime.root.path}/history'),
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
      benchmarkResources: resources,
    );
    final arrived = Completer<void>(), held = Completer<void>();
    fixture.runtime.io.requests.clear();
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    Future<BenchmarkRun>? operation;
    Future<void>? settled;
    Object? operationError;
    try {
      final suite = await DecideBenchSuite.load(
        Directory('benchmarks/sources/decidebench'),
      );
      operation = runner.run(suite: suite, model: 'native-kev');
      settled = operation.then<void>(
        (_) {},
        onError: (Object error) {
          operationError = error;
        },
      );
      await arrived.future.timeout(const Duration(seconds: 5));
      final id = runner.current!.id;
      final first = manager.shutdown();
      expect(identical(first, manager.shutdown()), isTrue);
      await first.timeout(const Duration(seconds: 5));
      final reopened = BenchmarkRunStore(directory: store.directory);
      addTearDown(reopened.close);
      final record = await reopened.load(id);
      expect(record.status, BenchmarkRunStatus.interrupted);
      expect(record.summary['complete'], isFalse);
      expect(record.summary['accuracy'], isNull);
      expect((await operation).status, BenchmarkRunStatus.interrupted);
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
      expect(manager.state, ManagerLifecycleState.stopped);
      expect(fixture.gateway.activeOwnedRequests, 0);
      expect(fixture.runtime.io.requests, hasLength(1));
      await expectLater(runner.targets(), throwsStateError);
      await expectLater(
        resources.prepare(DecisionCancellation()),
        throwsStateError,
      );
      held.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await reopened.load(id)).status, BenchmarkRunStatus.interrupted);
      expect(operationError, isNull);
    } finally {
      await fixture.runtime.catalog.stopManaged();
      if (!held.isCompleted) held.complete();
      if (settled != null) await settled.timeout(const Duration(seconds: 5));
      await runner.close();
      await resources.close();
      await downloader.close();
      await fixture.close();
    }
  });
}
