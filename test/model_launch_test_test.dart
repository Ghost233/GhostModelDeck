import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_launch_test.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test('master off cancels a running draft HTTP test, stops all owned instances and preserves saved configuration', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final cpp = LlamaEngine(
      library: fixture.library,
      installationDirectory: Directory('${fixture.root.path}/cpp'),
    );
    final catalog = EngineCatalog(
      library: fixture.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(fixture.library),
      registryFile: File('${fixture.root.path}/engines.json'),
      splashIO: fixture.io,
    );
    addTearDown(() async {
      await catalog.shutdown();
      catalog.close();
      cpp.close();
    });
    final registration = await catalog.link(fixture.source.path);
    await catalog.bindSplashModel(
      registration.id,
      fixture.asset.id,
      fixture.assembly,
    );
    final saved = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--max-context': '1024'},
    );
    await catalog.saveLaunchDefaults(registration.id, saved);
    final runtime = catalog.runtimeFor(registration.id) as SplashEngine;
    final peer = await runtime.startRuntime(fixture.asset.id);
    final before = await catalog.registryFile.readAsBytes();
    fixture.io.holdChatResponses = true;
    final token = DecisionCancellation();
    final pending = testModelLaunch(
      catalog: catalog,
      engineId: registration.id,
      artifact: fixture.asset,
      configuration: EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--max-context': '2048'},
      ),
      cancellation: token,
    ).then<Object>((result) => result, onError: (Object error) => error);
    try {
      await fixture.io.holdReached.future.timeout(const Duration(seconds: 5));
      expect(
        runtime.runtimeInstances.where(
          (run) =>
              run.temporaryTest &&
              run.hasLiveProcess &&
              run.activeRequests == 1,
        ),
        hasLength(1),
      );
      await catalog
          .setRuntimeEnabled(false)
          .timeout(const Duration(seconds: 5));
      final result = await pending.timeout(const Duration(seconds: 5));
      expect(
        result,
        isA<StateError>().having(
          (error) => error.message,
          'HTTP cancellation',
          contains('HTTP 499'),
        ),
      );
      expect(
        token.isCancelled,
        isFalse,
        reason: 'Cancellation must come from the master switch, not the draft button token',
      );
      expect(
        runtime.runtimeInstances.every(
          (run) => !run.hasLiveProcess && run.activeRequests == 0,
        ),
        isTrue,
      );
      expect(
        runtime.runtimeInstances.singleWhere((run) => run.id == peer.id).status,
        RuntimeInstanceStatus.stopped,
      );
      expect(await catalog.registryFile.readAsBytes(), before);
      expect(await File(fixture.asset.files.first.path).exists(), isTrue);
    } finally {
      if (!fixture.io.releaseHeld.isCompleted) {
        fixture.io.releaseHeld.complete();
      }
    }
  });

  test(
    'unsaved launch uses public HTTP and preserves peer and saved parameters',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final cpp = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/cpp'),
      );
      final catalog = EngineCatalog(
        library: fixture.library,
        officialEngine: cpp,
        useRegistry: ModelUseRegistry(fixture.library),
        registryFile: File('${fixture.root.path}/engines.json'),
        splashIO: fixture.io,
      );
      addTearDown(() async {
        await catalog.shutdown();
        catalog.close();
        cpp.close();
      });
      final registration = await catalog.link(fixture.source.path);
      await catalog.bindSplashModel(
        registration.id,
        fixture.asset.id,
        fixture.assembly,
      );
      final saved = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--max-context': '1024'},
        argumentText: '--disable-ane',
      );
      await catalog.saveModelLaunchOverrides(
        registration.id,
        fixture.asset.id,
        saved,
      );
      final before = await catalog.registryFile.readAsBytes();
      final runtime = catalog.runtimeFor(registration.id) as SplashEngine;
      final peer = await runtime.startRuntime(fixture.asset.id);
      expect(
        fixture.io.httpPaths.where((p) => p == '/v1/chat/completions'),
        isEmpty,
      );
      final routes = PublicModelRoutes(
        library: fixture.library,
        runtimes: [runtime],
      );
      await routes.enable(fixture.asset.id);
      addTearDown(routes.close);
      var observedTemporary = false;
      final observation = catalog.changes.listen((_) {
        if (runtime.runtimeInstances.any(
          (v) => v.temporaryTest && v.status == RuntimeInstanceStatus.ready,
        )) {
          observedTemporary = true;
          expect(
            routes.resolve(routes.publicIdFor(fixture.asset.id)).instance.id,
            peer.id,
          );
        }
      });
      addTearDown(observation.cancel);
      final result = await testModelLaunch(
        catalog: catalog,
        engineId: registration.id,
        artifact: fixture.asset,
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--max-context': '2048'},
          argumentText: '--disable-ane',
        ),
        cancellation: DecisionCancellation(),
      );
      expect(result, contains('HTTP 200'));
      expect(observedTemporary, isTrue);
      expect(await catalog.registryFile.readAsBytes(), before);
      expect(
        runtime.runtimeInstances.singleWhere((v) => v.id == peer.id).status,
        RuntimeInstanceStatus.ready,
      );
      expect(
        runtime.runtimeInstances
            .where((v) => v.id != peer.id)
            .every((v) => !v.hasLiveProcess),
        isTrue,
      );
      expect(
        runtime.actualCommandFor(runtime.runtimeInstances.last.id)!.arguments,
        containsAllInOrder(['--max-context', '2048']),
      );
      expect(
        fixture.io.httpPaths.where((p) => p == '/v1/chat/completions').length,
        1,
      );
      // Cancellation during real cold startup must leave the peer intact.
      fixture.io.identityEntered = Completer<void>();
      fixture.io.identityRelease = Completer<void>();
      final token = DecisionCancellation();
      final pending = testModelLaunch(
        catalog: catalog,
        engineId: registration.id,
        artifact: fixture.asset,
        configuration: saved,
        cancellation: token,
        splashAssembly: fixture.assembly,
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<SplashEngineException>()),
      );
      await fixture.io.identityEntered!.future;
      token.cancel();
      fixture.io.identityRelease!.complete();
      await rejected;
      expect(await catalog.registryFile.readAsBytes(), before);
      expect(
        runtime.runtimeInstances
            .where((v) => v.id != peer.id)
            .every((v) => !v.hasLiveProcess),
        isTrue,
      );
      expect(
        routes.resolve(routes.publicIdFor(fixture.asset.id)).instance.id,
        peer.id,
      );
      final cancelled = DecisionCancellation()..cancel();
      final starts = fixture.io.starts;
      await expectLater(
        testModelLaunch(
          catalog: catalog,
          engineId: registration.id,
          artifact: fixture.asset,
          configuration: saved,
          cancellation: cancelled,
        ),
        throwsA(isA<StateError>()),
      );
      expect(fixture.io.starts, starts);
      expect(
        runtime.runtimeInstances
            .singleWhere((v) => v.id == peer.id)
            .hasLiveProcess,
        isTrue,
      );
    },
  );
}
