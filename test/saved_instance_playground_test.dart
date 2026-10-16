import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/playground_runtime.dart' show playgroundDocument;

void main() {
  for (final firstChannel in JevPlaygroundMode.values) {
    test(
      'saved instance and committee use public ${firstChannel.name} in the existing full batch and cancellation',
      () async {
        final runtime = await CouncilRuntime.create(
          modelCount: 1,
          sourceSystemone: true,
        );
        final instances = LaunchInstances(
          catalog: runtime.catalog,
          file: File('${runtime.root.path}/instances.json'),
        );
        final council = CouncilController(
          catalog: runtime.catalog,
          launchInstances: instances,
        );
        final routes = PublicModelRoutes(
          library: runtime.library,
          runtimes: runtime.catalog.runtimes.toList(),
          instances: instances,
        );
        final gateway = PublicGatewayServer(
          routes: routes,
          jevModels: council.models,
          port: 0,
        );
        final mcp = CouncilMcpServer(controller: council, port: 0);
        final runner = BenchmarkRunner(
          client: JevPlayground(gateway: gateway, mcp: mcp),
          models: council.models,
          store: BenchmarkRunStore(
            directory: Directory('${runtime.root.path}/history'),
          ),
        );
        final arrived = Completer<void>(), held = Completer<void>();
        Future<BenchmarkRun>? pending;
        try {
          final definition = await instances.save(
            name: 'Saved',
            artifactId: runtime.library.state.artifacts.single.id,
            engineId: EngineCatalog.officialId,
            configuration: EngineLaunchConfiguration(),
          );
          final run = await instances.start(definition.id);
          await council.models.save(
            JevModelDefinition.council(
              name: 'committee',
              seats: council.models.availableBindings,
              timeout: const Duration(seconds: 2),
            ),
          );
          await gateway.start();
          await mcp.start();
          expect(
            council.models.definitionFor(definition.publicName)!.timeout,
            const Duration(seconds: 60),
          );
          for (final name in [definition.publicName, 'committee']) {
            final response = await runner.client.run(
              firstChannel,
              jsonEncode({...playgroundDocument(name), 'debug': true}),
            );
            expect(response.status, JevPlaygroundStatus.success);
            expect(response.output!['model'], name);
            expect(runtime.io.requests.last['model'], run.id);
            expect(
              (response.debug!['configuration'] as Map)['timeout_us'],
              name == 'committee' ? 2000000 : 60000000,
            );
          }
          await instances.save(
            id: definition.id,
            name: definition.name,
            artifactId: definition.artifactId,
            engineId: definition.engineId,
            configuration: definition.configuration,
            jevRequestTimeoutSeconds: 17,
          );
          final changed = await runner.client.run(
            firstChannel,
            jsonEncode({
              ...playgroundDocument(definition.publicName),
              'debug': true,
            }),
          );
          expect(changed.status, JevPlaygroundStatus.success);
          expect(
            (changed.debug!['configuration'] as Map)['timeout_us'],
            17000000,
          );
          expect(instances.runsFor(definition.id).single.id, run.id);
          final suite = await DecideBenchSuite.load(
            Directory('benchmarks/sources/decidebench'),
          );
          expect(suite.items, hasLength(400));
          runtime.io.requests.clear();
          runtime.io.respond = (body, raw) async {
            if (!arrived.isCompleted) arrived.complete();
            await held.future;
            return raw;
          };
          pending = runner.run(
            suite: suite,
            modelNames: [definition.publicName, 'committee'],
            channels: [
              firstChannel,
              ...JevPlaygroundMode.values.where((mode) => mode != firstChannel),
            ],
          );
          await arrived.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw StateError(
                'planned request did not reach engine; requests=${runtime.io.requests.length}; '
                'status=${runner.current?.status}; evaluations=${runner.current?.evaluations.map((e) => '${e.model}/${e.channel}/${e.status}').toList()}',
              );
            },
          );
          expect(
            council.models.isEvaluationLocked(definition.publicName),
            isTrue,
          );
          expect(council.models.isEvaluationLocked('committee'), isTrue);
          runner.cancel();
          final result = await pending.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw StateError(
                'cancel did not complete; status=${runner.current?.status}',
              );
            },
          );
          expect(result.status, BenchmarkRunStatus.cancelled);
          expect(result.evaluations, hasLength(4));
          expect(result.evaluations.map((entry) => entry.model).toSet(), {
            definition.publicName,
            'committee',
          });
          expect(
            result.evaluations.every(
              (entry) => entry.summary['complete'] == false,
            ),
            isTrue,
          );
          expect(runtime.io.requests, hasLength(1));
          expect(runtime.io.requests.single['model'], run.id);
          for (final entry in result.evaluations) {
            final binding = (entry.identity['bindings'] as List).single as Map;
            expect((binding['binding'] as Map)['instance_id'], definition.id);
            expect((binding['instance'] as Map)['id'], run.id);
          }
          expect(
            (await runner.store.load(result.id)).toJson(),
            result.toJson(),
          );
          expect(
            council.models.isEvaluationLocked(definition.publicName),
            isFalse,
          );
          expect(council.models.isEvaluationLocked('committee'), isFalse);
          expect(
            instances.runsFor(definition.id).single.hasLiveProcess,
            isTrue,
          );
        } finally {
          if (!held.isCompleted) held.complete();
          await runner.close();
          if (pending != null) await pending;
          await mcp.close();
          await gateway.stop();
          gateway.close();
          routes.close();
          await council.close();
          await instances.close();
          await runtime.close();
        }
      },
    );
  }
}
