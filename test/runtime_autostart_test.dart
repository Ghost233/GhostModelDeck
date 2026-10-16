import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/runtime_autostart.dart';
import 'package:ghost_model_deck/sdk_service.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('autostart choices persist independently, preserve old selections and roll back failed writes', () async {
    final root = await Directory.systemTemp.createTemp('gmd-autostart-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/startup.json');
    final settings = StartupModelSet(file: file);
    addTearDown(settings.close);
    await settings.load();
    expect(settings.autoOpenEngines, isFalse);
    expect(settings.entries, isEmpty);
    await settings.add('saved');
    await settings.saveAutoOpenEngines(true);
    final reopened = StartupModelSet(file: file);
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.autoOpenEngines, isTrue);
    expect(reopened.entries.single.instanceId, 'saved');
    await settings.saveAutoOpenEngines(false);
    expect(settings.contains('saved'), isTrue);
    final json = jsonDecode(await file.readAsString()) as Map;
    expect(
      json.keys,
      unorderedEquals(['schema', 'entries', 'auto_open_engines']),
    );
    await file.delete();
    await Directory(file.path).create();
    await expectLater(
      settings.saveAutoOpenEngines(true),
      throwsA(isA<FileSystemException>()),
    );
    expect(settings.autoOpenEngines, isFalse);
    expect(settings.contains('saved'), isTrue);
    await Directory(file.path).delete();
    await file.writeAsString(
      jsonEncode({
        'schema': 1,
        'entries': [
          {'instance': 'old-selection'},
        ],
      }),
    );
    final old = StartupModelSet(file: file);
    addTearDown(old.close);
    await old.load();
    expect(old.autoOpenEngines, isFalse);
    expect(old.contains('old-selection'), isTrue);
  });

  test('off-to-on starts selected instances concurrently, isolates failure and does not restore last switch state', () async {
    late RuntimeAutostart autostart;
    final runtime = await CouncilRuntime.create(
      modelCount: 3,
      onRuntimeOpened: () => autostart.startSelected(),
    );
    addTearDown(runtime.close);
    await runtime.catalog.setRuntimeEnabled(false);
    final store = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(store.close);
    final settings = StartupModelSet(
      file: File('${runtime.root.path}/startup.json'),
    );
    addTearDown(settings.close);
    final saved = [
      for (final asset in runtime.library.state.artifacts)
        await store.save(
          name: asset.name,
          artifactId: asset.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        ),
    ];
    await settings.add(saved[0].id);
    await settings.add(saved[1].id);
    await settings.add('missing');
    autostart = RuntimeAutostart(instances: store, settings: settings);
    await autostart.initialize();
    expect(runtime.catalog.runtimeEnabled, isFalse);
    expect(runtime.engine.hasLiveInstances, isFalse);
    runtime.io.holdIdentity(expected: 2);
    final opened = runtime.catalog.setRuntimeEnabled(true);
    await runtime.io.identityArrived!.future.timeout(
      const Duration(seconds: 5),
    );
    expect(store.isStarting(saved[0].id), isTrue);
    expect(store.isStarting(saved[1].id), isTrue);
    expect(store.isStarting(saved[2].id), isFalse);
    runtime.io.identityRelease!.complete();
    await opened;
    expect(
      store.runsFor(saved[0].id).single.status,
      RuntimeInstanceStatus.ready,
    );
    expect(
      store.runsFor(saved[1].id).single.status,
      RuntimeInstanceStatus.ready,
    );
    expect(store.runsFor(saved[2].id), isEmpty);
    expect(autostart.failures['missing'], contains('已删除'));
    final starts = runtime.engine.runtimeInstances.length;
    await runtime.catalog.setRuntimeEnabled(true);
    expect(runtime.engine.runtimeInstances.length, starts);
    await settings.remove(saved[0].id);
    expect(store.runsFor(saved[0].id).single.hasLiveProcess, isTrue);
    await settings.add(saved[0].id);
    final before = await settings.file.readAsBytes();
    await runtime.catalog.setRuntimeEnabled(false);
    expect(await settings.file.readAsBytes(), before);
    await autostart.initialize();
    expect(runtime.catalog.runtimeEnabled, isFalse);
    await settings.saveAutoOpenEngines(true);
    await autostart.initialize();
    expect(runtime.catalog.runtimeEnabled, isTrue);
    expect(
      store.runsFor(saved[0].id).where((run) => run.hasLiveProcess),
      hasLength(1),
    );
    expect(store.runsFor(saved[2].id), isEmpty);
  });

  test(
    'one unavailable library directory does not block valid selected instances',
    () async {
      late RuntimeAutostart autostart;
      final runtime = await CouncilRuntime.create(
        modelCount: 2,
        onRuntimeOpened: () => autostart.startSelected(),
      );
      addTearDown(runtime.close);
      await runtime.catalog.setRuntimeEnabled(false);
      final store = LaunchInstances(
        catalog: runtime.catalog,
        file: File('${runtime.root.path}/instances.json'),
      );
      addTearDown(store.close);
      final settings = StartupModelSet(
        file: File('${runtime.root.path}/startup.json'),
      );
      addTearDown(settings.close);
      final assets = runtime.library.state.artifacts;
      final saved = [
        for (final asset in assets)
          await store.save(
            name: asset.name,
            artifactId: asset.id,
            engineId: EngineCatalog.officialId,
            configuration: EngineLaunchConfiguration(),
          ),
      ];
      for (final definition in saved) {
        await settings.add(definition.id);
      }
      await runtime.library.scanDirectories([]);
      autostart = RuntimeAutostart(
        instances: store,
        settings: settings,
        prepare: () => store.prepareResources([
          File(assets.first.files.first.path).parent,
          Directory('${runtime.root.path}/unavailable-library'),
        ]),
      );
      await runtime.catalog.setRuntimeEnabled(true);
      expect(runtime.library.state.error, contains('无法读取'));
      expect(
        store.runsFor(saved.first.id).single.status,
        RuntimeInstanceStatus.ready,
      );
      expect(autostart.failures[saved.last.id], contains('模型缺失'));
      expect(store.runsFor(saved.last.id), isEmpty);
      expect(runtime.catalog.runtimeEnabled, isTrue);
    },
  );

  test('one native start failure does not block its peer and only manual retry clears it', () async {
    late RuntimeAutostart autostart;
    final io = _FailOneStartIO();
    final runtime = await CouncilRuntime.create(
      modelCount: 2,
      processIO: io,
      onRuntimeOpened: () => autostart.startSelected(),
    );
    addTearDown(runtime.close);
    await runtime.catalog.setRuntimeEnabled(false);
    final store = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(store.close);
    final settings = StartupModelSet(
      file: File('${runtime.root.path}/startup.json'),
    );
    addTearDown(settings.close);
    final saved = [
      for (final asset in runtime.library.state.artifacts)
        await store.save(
          name: asset.name,
          artifactId: asset.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        ),
    ];
    for (final definition in saved) {
      await settings.add(definition.id);
    }
    io.failingModel = runtime.library.state.artifacts.last.files.single.path;
    autostart = RuntimeAutostart(instances: store, settings: settings);
    await runtime.catalog.setRuntimeEnabled(true);
    expect(
      store.runsFor(saved.first.id).single.status,
      RuntimeInstanceStatus.ready,
    );
    expect(autostart.failures[saved.last.id], contains('native start refused'));
    expect(
      store.startErrorFor(saved.last.id),
      contains('native start refused'),
    );
    final attempts = io.failures;
    await runtime.catalog.setRuntimeEnabled(true);
    expect(io.failures, attempts);
    io.failingModel = null;
    await store.start(saved.last.id);
    expect(store.startErrorFor(saved.last.id), isNull);
    expect(
      store.runsFor(saved.last.id).where((run) => run.hasLiveProcess),
      hasLength(1),
    );
  });

  test('closing during selected identity loading cancels both instances without a late ready state', () async {
    late RuntimeAutostart autostart;
    final runtime = await CouncilRuntime.create(
      modelCount: 2,
      onRuntimeOpened: () => autostart.startSelected(),
    );
    addTearDown(runtime.close);
    await runtime.catalog.setRuntimeEnabled(false);
    final store = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(store.close);
    final settings = StartupModelSet(
      file: File('${runtime.root.path}/startup.json'),
    );
    addTearDown(settings.close);
    for (final asset in runtime.library.state.artifacts) {
      final definition = await store.save(
        name: asset.name,
        artifactId: asset.id,
        engineId: EngineCatalog.officialId,
        configuration: EngineLaunchConfiguration(),
      );
      await settings.add(definition.id);
    }
    autostart = RuntimeAutostart(instances: store, settings: settings);
    runtime.io.holdIdentity(expected: 2);
    final opening = runtime.catalog.setRuntimeEnabled(true);
    await runtime.io.identityArrived!.future.timeout(
      const Duration(seconds: 5),
    );
    await runtime.catalog
        .setRuntimeEnabled(false)
        .timeout(const Duration(seconds: 5));
    await opening;
    runtime.io.identityRelease!.complete();
    expect(runtime.engine.hasLiveInstances, isFalse);
    expect(autostart.failures, isEmpty);
    expect(
      store.definitions.every(
        (definition) => store.startErrorFor(definition.id) == null,
      ),
      isTrue,
    );
  });

  test('closing during autostart preparation prevents late loading, and the next open takes current choices', () async {
    late RuntimeAutostart autostart;
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      onRuntimeOpened: () => autostart.startSelected(),
    );
    addTearDown(runtime.close);
    await runtime.catalog.setRuntimeEnabled(false);
    final store = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(store.close);
    final settings = StartupModelSet(
      file: File('${runtime.root.path}/startup.json'),
    );
    addTearDown(settings.close);
    final saved = await store.save(
      name: 'Selected',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    await settings.add(saved.id);
    final arrived = Completer<void>();
    final release = Completer<void>();
    autostart = RuntimeAutostart(
      instances: store,
      settings: settings,
      prepare: () async {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
      },
    );
    final opened = runtime.catalog.setRuntimeEnabled(true);
    await arrived.future.timeout(const Duration(seconds: 5));
    await runtime.catalog.setRuntimeEnabled(false);
    await settings.remove(saved.id);
    final next = runtime.catalog.setRuntimeEnabled(true);
    release.complete();
    await Future.wait([opened, next]);
    expect(runtime.catalog.runtimeEnabled, isTrue);
    expect(runtime.engine.hasLiveInstances, isFalse);
    expect(autostart.failures, isEmpty);
  });
}

class _FailOneStartIO extends CouncilRuntimeIO {
  String? failingModel;
  int failures = 0;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) {
    if (failingModel != null && arguments.contains(failingModel)) {
      failures++;
      return Future.error(StateError('native start refused'));
    }
    return super.start(executable, arguments);
  }
}
