import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/jeval.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'complete original JEVal cache enters ordinary HTTP and cancellation retains original evidence in history',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await PlaygroundRuntime.create();
      final resources = BenchmarkResources(
        Directory('${fixture.runtime.root.path}/benchmark-cache'),
      );
      final store = BenchmarkRunStore(
        directory: Directory('${fixture.runtime.root.path}/benchmark-history'),
      );
      final runner = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      final arrived = Completer<void>(), release = Completer<void>();
      Future<BenchmarkRun>? pending;
      fixture.runtime.io.respond = (request, response) async {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
        return response;
      };
      try {
        // All three full pinned resources are real upstream files, not a
        // reduced product suite. Only this lifecycle test cancels its batch.
        final manifest = jsonDecode(
          await File('benchmarks/manifests/jeval.json').readAsString(),
        ) as Map;
        final cache = Directory(
          '${resources.cacheRoot.path}/jeval/${JevalSuite.pin}',
        );
        for (final entry in manifest['files'] as List) {
          final path = (entry as Map)['path'] as String;
          final destination = File('${cache.path}/$path');
          await destination.parent.create(recursive: true);
          await File('benchmarks/sources/jeval/$path').copy(destination.path);
        }
        final suite = await resources.prepareQuestions(
          'jeval',
          DecisionCancellation(),
        );
        expect(suite.tasks, hasLength(11257));
        expect(resources.status, BenchmarkResourceStatus.ready);
        expect(suite.identity['pin'], JevalSuite.pin);
        expect(
          suite.identity['canonicalOriginalFieldsSha256'],
          '8daba7b00874d3e0a83ca51cf580fb238dc2a6e28a6ee9f19d8678b9fd3a33a3',
        );
        final executing = runner.runQuestions(
          suite: suite,
          model: 'native-kev',
        );
        pending = executing;
        await arrived.future.timeout(const Duration(seconds: 20));
        expect(fixture.council.models.isEvaluationLocked('native-kev'), isTrue);
        runner.cancel();
        final cancelled = await executing.timeout(const Duration(seconds: 10));
        expect(cancelled.status, BenchmarkRunStatus.cancelled);
        expect(cancelled.toJson()['schema_version'], 3);
        expect(cancelled.summary['expected'], 11257);
        expect(cancelled.summary['attempted'], 1);
        expect(cancelled.summary['complete'], isFalse);
        expect(
          cancelled.toJson()['source_summary'],
          containsPair('accuracy', null),
        );
        expect(
          fixture.council.models.isEvaluationLocked('native-kev'),
          isFalse,
        );
        expect(fixture.gateway.activeOwnedRequests, 0);
        final restarted = BenchmarkRunStore(directory: store.directory);
        final history = await restarted.list();
        expect(history, hasLength(1));
        final restored = await restarted.load(cancelled.id);
        expect(restored.status, BenchmarkRunStatus.cancelled);
        expect(restored.items, hasLength(1));
        final item = restored.items.single;
        expect(item['id'], suite.tasks.first.id);
        expect(item['metadata'], suite.tasks.first.metadata);
        expect(item['request'], suite.tasks.first.request('native-kev'));
        expect(
          item['request_json'],
          suite.tasks.first.requestDocument('native-kev'),
        );
        expect((item['result'] as Map)['channel'], 'http');
        expect(item['status'], JevPlaygroundStatus.cancelled.name);
        expect(restored.summary['failures'], 1);
        expect(
          restored.toJson()['source_summary'],
          containsPair('accuracy', null),
        );
        final export = File(
          '${fixture.runtime.root.path}/original-evidence.json',
        );
        await restarted.exportTo(cancelled.id, export);
        final exported = BenchmarkRun.fromJson(
          Map<String, Object?>.from(
            jsonDecode(await export.readAsString()) as Map,
          ),
        );
        expect(exported.toJson(), restored.toJson());
        // A history-only store never invokes the still-running public graph.
        expect(fixture.runtime.io.requests, hasLength(1));
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
        await resources.close();
        await fixture.close();
      }
    }, _NetworkBoundary()),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

// Same real loopback boundary as sdk_service_test.dart; no public HTTP mock.
class _NetworkBoundary extends HttpOverrides {}
