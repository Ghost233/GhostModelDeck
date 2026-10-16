import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_launch_test.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/playground_runtime.dart';

void main() {
  test('master off closes every start entry while keeping configuration and installation management usable', () async {
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      sourceSystemone: true,
    );
    addTearDown(runtime.close);
    final store = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(store.close);
    final asset = runtime.library.state.artifacts.single;
    final saved = await store.save(
      name: 'Saved',
      artifactId: asset.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final original = await store.start(saved.id);
    await runtime.catalog.saveLaunchDefaults(
      saved.engineId,
      EngineLaunchConfiguration(),
    );
    final config = await store.file.readAsBytes();
    final registry = await runtime.catalog.registryFile.readAsBytes();
    await runtime.catalog.setRuntimeEnabled(false);
    expect(runtime.catalog.runtimeEnabled, isFalse);
    expect(
      runtime.engine.runtimeInstances.any((run) => run.hasLiveProcess),
      isFalse,
    );
    await expectLater(
      runtime.engine.start(asset.id),
      throwsA(isA<LlamaEngineException>()),
    );
    await expectLater(store.start(saved.id), throwsA(isA<StateError>()));
    await expectLater(
      testModelLaunch(
        catalog: runtime.catalog,
        engineId: saved.engineId,
        artifact: asset,
        configuration: saved.configuration,
        cancellation: DecisionCancellation(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await store.file.readAsBytes(), config);
    expect(await runtime.catalog.registryFile.readAsBytes(), registry);
    expect(await File(asset.files.single.path).exists(), isTrue);
    await runtime.catalog.saveLaunchDefaults(
      saved.engineId,
      EngineLaunchConfiguration(argumentText: '--threads 3'),
    );
    await runtime.catalog.refresh();
    expect(
      runtime.catalog.launchDefaultsFor(saved.engineId).argumentText,
      '--threads 3',
    );
    await runtime.catalog.setRuntimeEnabled(false);
    await runtime.catalog.setRuntimeEnabled(true);
    expect(
      runtime.engine.runtimeInstances.any((run) => run.hasLiveProcess),
      isFalse,
    );
    final restarted = await store.start(saved.id);
    expect(restarted.id, isNot(original.id));
    await store.stop(saved.id);
  });

  test('off cancels a start in identity readiness and never publishes its late response', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    await runtime.catalog.stopManaged();
    runtime.io.holdIdentity(expected: 1);
    final start = runtime.engine.start(
      runtime.library.state.artifacts.single.id,
    );
    final failed = expectLater(start, throwsA(isA<LlamaEngineException>()));
    await runtime.io.identityArrived!.future.timeout(
      const Duration(seconds: 5),
    );
    await runtime.catalog
        .setRuntimeEnabled(false)
        .timeout(const Duration(seconds: 5));
    await failed;
    runtime.io.identityRelease!.complete();
    expect(
      runtime.engine.runtimeInstances.where((run) => run.hasLiveProcess),
      isEmpty,
    );
    expect(
      runtime.engine.runtimeInstances.where(
        (run) => run.status == RuntimeInstanceStatus.ready,
      ),
      isEmpty,
    );
    await runtime.catalog.setRuntimeEnabled(true);
    final next = await runtime.engine.start(
      runtime.library.state.artifacts.single.id,
    );
    expect(next.status, LlamaInstanceStatus.ready);
  });

  test('close open close supersedes the pending open and old cleanup cannot stop the reopened generation', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final old = runtime.engine.runtimeInstances.single;
    runtime.io.heldExitAliases.add(old.id);
    runtime.io.exitRelease = Completer<void>();
    runtime.io.childKilled = Completer<void>();
    final closing = runtime.catalog.setRuntimeEnabled(false);
    await runtime.io.childKilled!.future.timeout(const Duration(seconds: 5));
    final superseded = runtime.catalog.setRuntimeEnabled(true);
    final repeated = runtime.catalog.setRuntimeEnabled(false);
    expect(identical(closing, repeated), isTrue);
    expect(runtime.catalog.runtimeEnabled, isFalse);
    runtime.io.exitRelease!.complete();
    await Future.wait([closing, superseded, repeated]);
    expect(runtime.catalog.runtimeEnabled, isFalse);
    await runtime.catalog.setRuntimeEnabled(true);
    final next = await runtime.engine.start(
      runtime.library.state.artifacts.single.id,
    );
    expect(next.id, isNot(old.id));
    await closing;
    expect(
      runtime.engine.runtimeInstances
          .singleWhere((run) => run.id == next.id)
          .hasLiveProcess,
      isTrue,
    );
    await runtime.catalog.setRuntimeEnabled(false);
  });

  test('master off cancels public HTTP and MCP work without stopping their listeners or implicitly reloading', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    fixture.runtime.io.holdConsultation();
    final first = fixture.playground.run(
      JevPlaygroundMode.http,
      jsonEncode(playgroundDocument('hard')),
    );
    final second = fixture.playground.run(
      JevPlaygroundMode.mcp,
      jsonEncode(playgroundDocument('hard')),
    );
    await fixture.runtime.io.bothArrived!.future.timeout(
      const Duration(seconds: 5),
    );
    await fixture.runtime.catalog
        .setRuntimeEnabled(false)
        .timeout(const Duration(seconds: 5));
    final results = await Future.wait([first, second])
        .timeout(const Duration(seconds: 5));
    expect(
      results.every((result) => result.status != JevPlaygroundStatus.success),
      isTrue,
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        fixture.gateway.baseUrl!.resolve('/v1/models'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(
        (jsonDecode(await utf8.decoder.bind(response).join()) as Map)['data'],
        isEmpty,
      );
      expect(await fixture.playground.discover(JevPlaygroundMode.mcp), {
        'object': 'list',
        'data': [],
      });
      final unavailable = await fixture.playground.run(
        JevPlaygroundMode.http,
        jsonEncode(playgroundDocument('native-kev')),
      );
      expect(unavailable.status, JevPlaygroundStatus.businessError);
      expect(
        fixture.runtime.engine.runtimeInstances.any(
          (run) => run.hasLiveProcess,
        ),
        isFalse,
      );
      expect(fixture.gateway.baseUrl, isNotNull);
      expect(fixture.mcp.endpoint, isNotNull);
    } finally {
      client.close(force: true);
    }
  });
}
