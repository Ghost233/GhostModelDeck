import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/council_runtime.dart';

void main() {
  for (final separateEngines in [true, false]) {
    test(
      'saved instances start independently on ${separateEngines ? 'different engines' : 'one engine installation'}',
      () async {
        final fixture = await CouncilRuntime.create(
          modelCount: 2,
          sourceSystemone: true,
        );
        final peer = LlamaEngine(
          library: fixture.library,
          installationDirectory: Directory('${fixture.root.path}/peer'),
          release: fixture.engine.release,
          io: fixture.io,
        );
        final catalog = EngineCatalog(
          library: fixture.library,
          officialEngine: fixture.engine,
          standardEngine: peer,
          useRegistry: ModelUseRegistry(fixture.library),
          registryFile: File('${fixture.root.path}/independent-engines.json'),
        );
        final store = LaunchInstances(
          catalog: catalog,
          file: File('${fixture.root.path}/instances.json'),
        );
        Future<Object?>? first;
        Future<Object?>? second;
        try {
          await fixture.engine.stopManaged();
          if (separateEngines) {
            await peer.install(
              verifiedArchive: File('${fixture.root.path}/release.tar.gz'),
            );
          }
          final assets = fixture.library.state.artifacts;
          final a = await store.save(
            name: 'First',
            artifactId: assets[0].id,
            engineId: EngineCatalog.officialId,
            configuration: EngineLaunchConfiguration(),
          );
          final b = await store.save(
            name: 'Second',
            artifactId: assets[1].id,
            engineId: separateEngines
                ? EngineCatalog.standardId
                : EngineCatalog.officialId,
            configuration: EngineLaunchConfiguration(),
          );
          fixture.io.holdIdentity(expected: 2);
          final operation = store.start(a.id);
          expect(identical(operation, store.start(a.id)), isTrue);
          first = operation.then<Object?>(
            (value) => value,
            onError: (Object error) => error,
          );
          second = store
              .start(b.id)
              .then<Object?>(
                (value) => value,
                onError: (Object error) => error,
              );
          await fixture.io.identityArrived!.future.timeout(
            const Duration(seconds: 2),
          );
          expect(store.isStarting(a.id), isTrue);
          expect(store.isStarting(b.id), isTrue);
          expect(fixture.library.state.scanning, isFalse);
          fixture.io.identityRelease!.complete();
          expect(await first, isNot(isA<Exception>()));
          expect(await second, isNot(isA<Exception>()));
          expect(store.runsFor(a.id).single.hasLiveProcess, isTrue);
          expect(store.runsFor(b.id).single.hasLiveProcess, isTrue);
          await store.stop(a.id);
          expect(store.runsFor(b.id).single.hasLiveProcess, isTrue);
        } finally {
          if (fixture.io.identityRelease != null &&
              !fixture.io.identityRelease!.isCompleted) {
            fixture.io.identityRelease!.complete();
          }
          if (first != null) await first;
          if (second != null) await second;
          await store.close();
          await catalog.shutdown();
          catalog.close();
          peer.close();
          await fixture.close();
        }
      },
    );
  }
}
