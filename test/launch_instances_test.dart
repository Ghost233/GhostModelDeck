import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/chat_protocol.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;
import 'fixtures/council_runtime.dart';

void main() {
  test('successful startup reports capacity persistence failure and a later save repairs it', () async {
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
    final initial = await store.save(
      name: 'Capacity',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '8192'},
      ),
    );
    final pending = await store.save(
      id: initial.id,
      name: initial.name,
      artifactId: initial.artifactId,
      engineId: initial.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '16384'},
      ),
    );
    final obstruction = await Directory('${store.file.path}.tmp').create();
    addTearDown(() async {
      if (await obstruction.exists()) await obstruction.delete();
    });
    final run = await store.start(initial.id);
    expect(run.status, RuntimeInstanceStatus.ready);
    expect(store.contextLengthFor(initial.id), 16384);
    expect(store.persistenceError, contains('生效容量保存失败'));
    expect(
      (jsonDecode(await store.file.readAsString())['instances'] as List)
          .single['applied_context_length'],
      8192,
    );
    await obstruction.delete();
    await store.save(
      id: pending.id,
      name: pending.name,
      artifactId: pending.artifactId,
      engineId: pending.engineId,
      configuration: pending.configuration,
    );
    expect(store.persistenceError, isNull);
    expect(
      (jsonDecode(await store.file.readAsString())['instances'] as List)
          .single['applied_context_length'],
      16384,
    );
    expect(store.runsFor(initial.id).single.id, run.id);
    await store.stop(initial.id);
  });
  test('cancelled startup never applies pending capacity even when identity arrives late', () async {
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
    final initial = await store.save(
      name: 'Capacity',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '8192'},
      ),
    );
    await store.save(
      id: initial.id,
      name: initial.name,
      artifactId: initial.artifactId,
      engineId: initial.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '16384'},
      ),
    );
    runtime.io.holdIdentity(expected: 1);
    final starting = store
        .start(initial.id)
        .then<Object>((run) => run, onError: (Object error) => error);
    await runtime.io.identityArrived!.future.timeout(
      const Duration(seconds: 5),
    );
    final stopping = store.stop(initial.id);
    runtime.io.identityRelease!.complete();
    await starting;
    await stopping;
    expect(store.contextLengthFor(initial.id), 8192);
    expect(store.runsFor(initial.id).any((run) => run.hasLiveProcess), isFalse);
    expect(
      (jsonDecode(await store.file.readAsString())['instances'] as List)
          .single['applied_context_length'],
      8192,
    );
  });
  test('cold edits preserve applied capacity through reopen without starting the instance', () async {
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      sourceSystemone: true,
    );
    addTearDown(runtime.close);
    final file = File('${runtime.root.path}/instances.json');
    var store = LaunchInstances(catalog: runtime.catalog, file: file);
    addTearDown(() => store.close());
    final original = await store.save(
      name: 'Cold configuration',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '8192'},
      ),
    );
    expect(store.contextLengthFor(original.id), 8192);
    await store.save(
      id: original.id,
      name: original.name,
      artifactId: original.artifactId,
      engineId: original.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '16384'},
      ),
    );
    expect(store.find(original.id)!.configuration.contextLength, 16384);
    expect(store.contextLengthFor(original.id), 8192);
    expect(store.runsFor(original.id), isEmpty);
    await store.close();
    store = LaunchInstances(catalog: runtime.catalog, file: file);
    await store.load();
    expect(store.find(original.id)!.configuration.contextLength, 16384);
    expect(store.contextLengthFor(original.id), 8192);
    final copied = await store.copy(original.id);
    expect(store.contextLengthFor(copied.id), 16384);
    expect(store.runsFor(copied.id), isEmpty);
  });
  test('configured context follows text overrides and changes only after a successful restart', () async {
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
    final definition = await store.save(
      name: 'Context instance',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '4096'},
        argumentText: '-c 8192',
      ),
    );
    expect(store.contextLengthFor(definition.id), 8192);
    final first = await store.start(definition.id);
    await store.save(
      id: definition.id,
      name: definition.name,
      artifactId: definition.artifactId,
      engineId: definition.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '32768'},
        argumentText: '--ctx-size=16384',
      ),
    );
    expect(store.contextLengthFor(definition.id), 8192);
    expect((await store.start(definition.id)).id, first.id);
    await store.stop(definition.id);
    expect(store.contextLengthFor(definition.id), 8192);
    final restarted = await store.start(definition.id);
    expect(restarted.id, isNot(first.id));
    expect(store.contextLengthFor(definition.id), 16384);
    final copy = await store.copy(definition.id);
    expect(store.contextLengthFor(copy.id), 16384);
    expect(store.runsFor(copy.id), isEmpty);
    await store.stop(definition.id);
    await store.delete(definition.id);
    expect(store.contextLengthFor(definition.id), isNull);
  });
  test(
    'per-instance JEV budget persists independently and rejects invalid values',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      addTearDown(runtime.close);
      final file = File('${runtime.root.path}/instances.json');
      final store = LaunchInstances(catalog: runtime.catalog, file: file);
      addTearDown(store.close);
      final definition = await store.save(
        name: 'Saved',
        artifactId: runtime.library.state.artifacts.single.id,
        engineId: EngineCatalog.officialId,
        configuration: EngineLaunchConfiguration(),
        jevRequestTimeoutSeconds: 60,
      );
      final copied = await store.copy(definition.id);
      final renamed = await store.renamePublicName(definition.id, 'renamed');
      expect(copied.jevRequestTimeoutSeconds, 60);
      expect(renamed.jevRequestTimeoutSeconds, 60);
      final reopened = LaunchInstances(catalog: runtime.catalog, file: file);
      addTearDown(reopened.close);
      await reopened.load();
      expect(reopened.find(definition.id)!.jevRequestTimeoutSeconds, 60);
      final json = definition.toJson()..remove('jev_request_timeout_seconds');
      expect(LaunchInstance.fromJson(json).jevRequestTimeoutSeconds, 60);
      for (final value in [0, -1, 1.5, '60']) {
        expect(
          () => LaunchInstance.fromJson({
            ...json,
            'jev_request_timeout_seconds': value,
          }),
          throwsFormatException,
        );
      }
      await expectLater(
        store.save(
          id: definition.id,
          name: definition.name,
          artifactId: definition.artifactId,
          engineId: definition.engineId,
          configuration: definition.configuration,
          jevRequestTimeoutSeconds: 0,
        ),
        throwsArgumentError,
      );
      expect(store.find(definition.id)!.jevRequestTimeoutSeconds, 60);
    },
  );

  test('engine resource failure preserves the already loaded run and actual command until explicit stop', () async {
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
    final definition = await store.save(
      name: 'Saved',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final run = await store.start(definition.id);
    final actual = runtime.engine.state.instances
        .singleWhere((instance) => instance.id == run.id)
        .launchCommand;
    await File(runtime.engine.executablePath!).delete();
    await runtime.catalog.refresh();
    expect(store.missingReason(definition), contains('引擎缺失'));
    final retained = store.runsFor(definition.id).single;
    expect(retained.status, RuntimeInstanceStatus.ready);
    expect(retained.hasLiveProcess, isTrue);
    expect(
      runtime.engine.state.instances
          .singleWhere((instance) => instance.id == run.id)
          .launchCommand,
      same(actual),
    );
    expect(
      (await runtime.engine.generateText(
        run.id,
        TextRequest(prompt: 'Hi'),
      )).text,
      isNotEmpty,
    );
    await store.stop(definition.id);
    await expectLater(store.start(definition.id), throwsStateError);
  });
  test('unlinked roots preserve an owned run and references while blocking new starts until recovery', () async {
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
    final roots = runtime.library.state.rootPaths.map(Directory.new).toList();
    final definition = await store.save(
      name: 'Saved',
      artifactId: asset.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final first = await store.start(definition.id);
    await runtime.library.scanDirectories([]);
    expect(store.missingReason(definition), '模型缺失');
    expect(store.runsFor(definition.id).single.id, first.id);
    expect(store.runsFor(definition.id).single.hasLiveProcess, isTrue);
    expect(store.definitions.single.publicName, definition.publicName);
    await store.stop(definition.id);
    await expectLater(store.start(definition.id), throwsStateError);
    expect(
      store.runsFor(definition.id).where((run) => run.hasLiveProcess),
      isEmpty,
    );
    await runtime.library.scanDirectories(roots);
    expect(store.missingReason(definition), isNull);
    final restarted = await store.start(definition.id);
    expect(restarted.id, isNot(first.id));
    expect(store.definitions.single.id, definition.id);
    expect(store.definitions.single.publicName, definition.publicName);
    await store.stop(definition.id);
  });
  test(
    'saved copies keep independent parameter snapshots across reopen',
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
      final engine = await catalog.link(fixture.source.path);
      final file = File('${fixture.root.path}/launch-instances.json');
      final instances = LaunchInstances(catalog: catalog, file: file);
      addTearDown(instances.close);
      final configuration = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--max-context': '65536'},
        argumentText: '--disable-ane',
      );
      final original = await instances.save(
        name: 'Fast',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: configuration,
      );
      final copy = await instances.copy(original.id);
      expect(copy.id, isNot(original.id));
      expect(original.publicName, 'kev-q8-0');
      expect(copy.publicName, 'kev-q8-0-2');
      await catalog.saveLaunchDefaults(
        engine.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--max-context': '1024'},
        ),
      );
      await instances.save(
        id: original.id,
        name: 'Fast renamed',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--max-context': '2048'},
        ),
      );
      final reopened = LaunchInstances(catalog: catalog, file: file);
      addTearDown(reopened.close);
      await reopened.load();
      expect(reopened.find(original.id)!.publicName, 'kev-q8-0');
      expect(reopened.find(copy.id)!.publicName, 'kev-q8-0-2');
      expect(
        reopened.find(original.id)!.configuration.formValues['--max-context'],
        '2048',
      );
      expect(
        reopened.find(copy.id)!.configuration.formValues['--max-context'],
        '65536',
      );
      expect(
        reopened.find(copy.id)!.configuration.argumentText,
        '--disable-ane',
      );
      expect(
        catalog.runtimes.expand((runtime) => runtime.runtimeInstances),
        isEmpty,
      );
      final validConfiguration = instances.find(original.id)!.configuration;
      final invalidDraft = await instances.save(
        id: original.id,
        name: 'Fast renamed',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          argumentText: "--note 'unterminated",
        ),
      );
      expect(invalidDraft.configuration.argumentText, "--note 'unterminated");
      final restoredDraft = LaunchInstances(catalog: catalog, file: file);
      await restoredDraft.load();
      expect(
        restoredDraft.find(original.id)!.configuration.argumentText,
        "--note 'unterminated",
      );
      await restoredDraft.close();
      await expectLater(
        instances.start(original.id),
        throwsA(isA<LaunchArgumentTextException>()),
      );
      expect(fixture.io.starts, 0);
      await instances.save(
        id: original.id,
        name: 'Fast renamed',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: validConfiguration,
      );
      final savedBytes = await file.readAsBytes();
      expect(instances.find(original.id)!.name, 'Fast renamed');
      await expectLater(
        instances.save(
          id: original.id,
          name: 'Wrong engine parameters',
          artifactId: fixture.asset.id,
          engineId: engine.id,
          configuration: EngineLaunchConfiguration(),
        ),
        throwsArgumentError,
      );
      expect(await file.readAsBytes(), savedBytes);
      await instances.renamePublicName(original.id, 'FAST Test');
      expect(instances.find(original.id)!.publicName, 'fast-test');
      expect(instances.find(original.id)!.name, 'Fast renamed');
      final renamedBytes = await file.readAsBytes();
      await expectLater(
        instances.renamePublicName(copy.id, 'fast-test'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'suggestion',
            contains('fast-test-2'),
          ),
        ),
      );
      expect(await file.readAsBytes(), renamedBytes);
      expect(instances.find(copy.id)!.publicName, 'kev-q8-0-2');
    },
  );

  test(
    'new instance registry does not import model launch overrides',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-fresh-instances-',
      );
      addTearDown(() => root.delete(recursive: true));
      final library = ModelLibrary();
      addTearDown(library.close);
      final usage = ModelUseRegistry(library);
      final engine = LlamaEngine(
        library: library,
        useRegistry: usage,
        installationDirectory: Directory('${root.path}/engine'),
      );
      final registry = File('${root.path}/engines.json');
      await registry.writeAsString(
        jsonEncode({
          'schema': 4,
          'linked': [],
          'launchDefaults': {},
          'modelLaunchOverrides': {
            EngineCatalog.officialId: {
              'old-model': {
                'enabled': true,
                'configuration': EngineLaunchConfiguration(
                  argumentText: '--reasoning off',
                ).toJson(),
              },
            },
          },
        }),
      );
      final catalog = EngineCatalog(
        library: library,
        officialEngine: engine,
        useRegistry: usage,
        registryFile: registry,
      );
      addTearDown(catalog.close);
      await catalog.refresh();
      final file = File('${root.path}/launch-instances.json');
      final instances = LaunchInstances(catalog: catalog, file: file);
      addTearDown(instances.close);
      await instances.load();
      expect(instances.definitions, isEmpty);
      final reopened = LaunchInstances(catalog: catalog, file: file);
      addTearDown(reopened.close);
      await reopened.load();
      expect(reopened.definitions, isEmpty);
      expect(jsonDecode(await file.readAsString()), {
        'schema': 1,
        'instances': [],
      });
    },
  );
}
