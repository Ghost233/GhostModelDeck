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
        greaterThanOrEqualTo(3),
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
