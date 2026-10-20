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
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;
import 'fixtures/council_runtime.dart';

void main() {
  for (final observed in <int?>[4096, null]) {
    test(
      'applied context uses ${observed ?? 'successful configuration fallback'} and survives pending save and reopen',
      () async {
        final runtime = await CouncilRuntime.create(
          modelCount: 1,
          sourceSystemone: true,
        );
        addTearDown(runtime.close);
        if (observed != null) {
          runtime.io.capacityProperties = {
            'default_generation_settings': {'n_ctx': observed},
            'total_slots': 2,
          };
        }
        final store = LaunchInstances(
          catalog: runtime.catalog,
          file: File('${runtime.root.path}/observed-context.json'),
        );
        addTearDown(store.close);
        final definition = await store.save(
          name: 'Context source',
          artifactId: runtime.library.state.artifacts.single.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(
            formValues: {'--ctx-size': '16384'},
          ),
        );
        final run = await store.start(definition.id);
        expect(run.capacity?.contextPerSlot, observed);
        expect(store.contextLengthFor(definition.id), observed ?? 16384);
        await store.save(
          id: definition.id,
          name: definition.name,
          artifactId: definition.artifactId,
          engineId: definition.engineId,
          configuration: EngineLaunchConfiguration(
            formValues: {'--ctx-size': '32768'},
          ),
        );
        expect(store.find(definition.id)!.configuration.contextLength, 32768);
        expect(store.contextLengthFor(definition.id), observed ?? 16384);
        final reopened = LaunchInstances(
          catalog: runtime.catalog,
          file: store.file,
        );
        addTearDown(reopened.close);
        await reopened.load();
        expect(reopened.contextLengthFor(definition.id), observed ?? 16384);
        expect(
          reopened.find(definition.id)!.configuration.contextLength,
          32768,
        );
        expect(store.runsFor(definition.id).single.id, run.id);
        await store.stop(definition.id);
      },
    );
  }
  test('saved generation defaults apply to the next public request without restarting', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final cpp = LlamaEngine(
      library: fixture.library,
      installationDirectory: Directory('${fixture.root.path}/cpp'),
    );
    addTearDown(cpp.close);
    final catalog = EngineCatalog(
      library: fixture.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(fixture.library),
      registryFile: File('${fixture.root.path}/engines.json'),
      splashIO: fixture.io,
    );
    addTearDown(catalog.close);
    addTearDown(catalog.shutdown);
    final entry = await catalog.link(fixture.source.path);
    final store = LaunchInstances(
      catalog: catalog,
      file: File('${fixture.root.path}/instances.json'),
    );
    addTearDown(store.close);
    EngineLaunchConfiguration configuration(double temperature, int topK) =>
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          drafter: const DrafterConfiguration(enabled: false),
          generation: GenerationConfiguration({
            'temperature': temperature,
            'top_k': topK,
            'stop': ['END'],
          }),
        );
    final definition = await store.save(
      name: 'Generation defaults',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: configuration(0.6, 9),
    );
    final run = await store.start(definition.id);
    final routes = PublicModelRoutes(
      library: fixture.library,
      runtimes: catalog.runtimes.toList(),
      instances: store,
    );
    addTearDown(routes.close);
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    addTearDown(gateway.close);
    addTearDown(gateway.stop);
    await gateway.start();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<void> request([Map<String, Object?> overrides = const {}]) async {
      final http = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/chat/completions'),
      );
      http.headers.contentType = ContentType.json;
      http.write(
        jsonEncode({
          'model': definition.publicName,
          'messages': [
            {'role': 'user', 'content': 'Reply OK'},
          ],
          ...overrides,
        }),
      );
      final response = await http.close();
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200, reason: body);
    }

    await request();
    expect(fixture.io.chatBodies.last['temperature'], 0.6);
    expect(fixture.io.chatBodies.last['top_k'], 9);
    expect(fixture.io.chatBodies.last.containsKey('max_tokens'), isFalse);
    await request({'temperature': 0.9, 'top_k': 4});
    expect(fixture.io.chatBodies.last['temperature'], 0.9);
    expect(fixture.io.chatBodies.last['top_k'], 4);
    expect(fixture.io.chatBodies.last['stop'], ['END']);
    await store.save(
      id: definition.id,
      name: definition.name,
      artifactId: definition.artifactId,
      engineId: definition.engineId,
      configuration: configuration(0.3, 17),
    );
    await request({'stream': true});
    expect(fixture.io.chatBodies.last['temperature'], 0.3);
    expect(fixture.io.chatBodies.last['top_k'], 17);
    expect(store.runsFor(definition.id).single.id, run.id);
    expect(fixture.io.starts, 1);
    final restored = LaunchInstances(catalog: catalog, file: store.file);
    addTearDown(restored.close);
    await restored.load();
    expect(
      restored
          .find(definition.id)!
          .configuration
          .generation
          .values['temperature'],
      0.3,
    );
    await store.stop(definition.id);
  });

  test('disabled limits and output defaults persist per instance without changing admitted requests', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final cpp = LlamaEngine(
      library: fixture.library,
      installationDirectory: Directory('${fixture.root.path}/cpp'),
    );
    addTearDown(cpp.close);
    final catalog = EngineCatalog(
      library: fixture.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(fixture.library),
      registryFile: File('${fixture.root.path}/engines.json'),
      splashIO: fixture.io,
    );
    addTearDown(catalog.close);
    addTearDown(catalog.shutdown);
    final entry = await catalog.link(fixture.source.path);
    final store = LaunchInstances(
      catalog: catalog,
      file: File('${fixture.root.path}/instances.json'),
    );
    addTearDown(store.close);
    const format = {
      'type': 'json_schema',
      'json_schema': {
        'name': 'instance-answer',
        'strict': true,
        'description': 'Persist the selected contract',
        'schema': {'type': 'object'},
      },
    };
    EngineLaunchConfiguration configuration(Map<String, Object?> values) =>
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          drafter: const DrafterConfiguration(enabled: false),
          generation: GenerationConfiguration(values),
        );
    final first = await store.save(
      name: 'First defaults',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: configuration({
        'temperature': 0.6,
        'max_tokens': 13,
        'seed': 31,
        'stop': ['END'],
        'response_format': format,
      }),
    );
    final second = await store.save(
      name: 'Second defaults',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: configuration({'temperature': 0.8, 'max_tokens': 7}),
    );
    final firstRun = await store.start(first.id);
    final secondRun = await store.start(second.id);
    final routes = PublicModelRoutes(
      library: fixture.library,
      runtimes: catalog.runtimes.toList(),
      instances: store,
    );
    addTearDown(routes.close);
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    addTearDown(gateway.close);
    addTearDown(gateway.stop);
    await gateway.start();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<void> request(
      String model, {
      Map<String, Object?> overrides = const {},
      String prompt = 'Reply OK',
      int expectedStatus = 200,
    }) async {
      final http = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/chat/completions'),
      );
      http.headers.contentType = ContentType.json;
      http.write(
        jsonEncode({
          'model': model,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          ...overrides,
        }),
      );
      final response = await http.close();
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, expectedStatus, reason: body);
      if (expectedStatus == 200 && overrides['stream'] == true) {
        expect(body, contains('data: [DONE]'));
      }
    }

    for (final stream in [false, true]) {
      await request(
        first.publicName,
        overrides: {
          'stream': stream,
          'max_completion_tokens': null,
          'temperature': 0,
          'seed': -1,
          'stop': ['123'],
        },
      );
      expect(fixture.io.chatBodies.last.containsKey('max_tokens'), isFalse);
      expect(fixture.io.chatBodies.last['temperature'], 0);
      expect(fixture.io.chatBodies.last['seed'], -1);
      expect(fixture.io.chatBodies.last['stop'], ['123']);
      expect(fixture.io.chatBodies.last['response_format'], format);
    }
    final accepted = fixture.io.chatBodies.length;
    for (final stream in [false, true]) {
      await request(
        first.publicName,
        overrides: {'stream': stream, 'ignore_eos': true},
        expectedStatus: 400,
      );
      expect(fixture.io.chatBodies, hasLength(accepted));
    }
    final admitted = request(first.publicName, prompt: 'hold');
    await fixture.io.holdReached.future.timeout(const Duration(seconds: 5));
    final oldBody = Map<String, Object?>.from(fixture.io.chatBodies.last);
    await store.save(
      id: first.id,
      name: first.name,
      artifactId: first.artifactId,
      engineId: first.engineId,
      configuration: configuration({
        'temperature': 0.2,
        'max_tokens': null,
        'stop': <String>[],
        'response_format': {'type': 'text'},
      }),
    );
    await request(first.publicName, overrides: {'stream': true});
    expect(fixture.io.chatBodies.last.containsKey('max_tokens'), isFalse);
    expect(fixture.io.chatBodies.last['temperature'], 0.2);
    expect(fixture.io.chatBodies.last['stop'], isEmpty);
    expect(fixture.io.chatBodies.last['response_format'], {'type': 'text'});
    expect(oldBody['max_tokens'], 13);
    expect(oldBody['temperature'], 0.6);
    expect(oldBody['response_format'], format);
    fixture.io.releaseHeld.complete();
    await admitted;
    await request(second.publicName);
    expect(fixture.io.chatBodies.last['temperature'], 0.8);
    expect(fixture.io.chatBodies.last['max_tokens'], 7);
    final restored = LaunchInstances(catalog: catalog, file: store.file);
    addTearDown(restored.close);
    await restored.load();
    final saved = restored.find(first.id)!.configuration;
    expect(saved.generation.values.containsKey('max_tokens'), isTrue);
    expect(saved.generation.values['max_tokens'], isNull);
    expect(saved.generation.values['stop'], isEmpty);
    expect(saved.loadingIdentity, first.configuration.loadingIdentity);
    expect(
      restored.find(second.id)!.configuration.generation.values['max_tokens'],
      7,
    );
    expect(store.runsFor(first.id).single.id, firstRun.id);
    expect(store.runsFor(second.id).single.id, secondRun.id);
    expect(fixture.io.starts, 2);
    await store.stop(first.id);
    await store.stop(second.id);
  });

  test('Splash drafter choices persist per instance and rebuild bindings on directory and switch changes', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final cpp = LlamaEngine(
      library: fixture.library,
      installationDirectory: Directory('${fixture.root.path}/cpp'),
    );
    addTearDown(cpp.close);
    final catalog = EngineCatalog(
      library: fixture.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(fixture.library),
      registryFile: File('${fixture.root.path}/engines.json'),
      splashIO: fixture.io,
    );
    addTearDown(catalog.close);
    addTearDown(catalog.shutdown);
    final entry = await catalog.link(fixture.source.path);
    final runtime = catalog.runtimeFor(entry.id) as SplashEngine;
    final file = File('${fixture.root.path}/instances.json');
    final store = LaunchInstances(catalog: catalog, file: file);
    addTearDown(store.close);
    Future<EngineLaunchConfiguration> selection(String name) async {
      final directory = await Directory('${fixture.root.path}/$name').create();
      await File('${directory.path}/config.json')
          .writeAsString('{"architectures":["DFlashDraftModel"]}');
      await File('${directory.path}/model.safetensors')
          .writeAsString('external engine fixture weights');
      return EngineLaunchConfiguration(
        family: EngineFamily.splash,
        drafter: DrafterConfiguration(enabled: true, path: directory.path),
      );
    }

    final a = await selection('drafter-a');
    final b = await selection('drafter-b');
    final first = await store.save(
      name: 'A',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: a,
    );
    final second = await store.save(
      name: 'B',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: b,
    );
    expect(catalog.launchDefaultsFor(entry.id).drafter, isNull);
    await expectLater(
      catalog.saveLaunchDefaults(entry.id, a),
      throwsArgumentError,
    );
    await store.start(first.id);
    final assemblyA = runtime.bindingFor(fixture.asset.id)!.assembly.path;
    expect(
      runtime.bindingFor(fixture.asset.id)!.roles['draft/config.json'],
      '${a.drafter!.path}/config.json',
    );
    expect(runtime.actualDrafterFor(first.id)!.source, a.drafter!.path);
    // Saving a different next-start source cannot rewrite the active owner's observation.
    await store.save(
      id: first.id,
      name: first.name,
      artifactId: first.artifactId,
      engineId: first.engineId,
      configuration: b,
    );
    expect(runtime.actualDrafterFor(first.id)!.source, a.drafter!.path);
    await store.stop(first.id);
    expect(runtime.actualDrafterFor(first.id), isNull);
    fixture.io.nativeDrafter = 'none';
    await expectLater(
      store.start(first.id),
      throwsA(
        isA<SplashEngineException>().having(
          (e) => e.message,
          'native fallback',
          contains('原生未报告实际启用'),
        ),
      ),
    );
    fixture.io.nativeDrafter = null;
    await store.save(
      id: first.id,
      name: first.name,
      artifactId: first.artifactId,
      engineId: first.engineId,
      configuration: b,
    );
    await store.start(first.id);
    expect(
      runtime.bindingFor(fixture.asset.id)!.assembly.path,
      isNot(assemblyA),
    );
    expect(
      runtime.bindingFor(fixture.asset.id)!.roles['draft/config.json'],
      '${b.drafter!.path}/config.json',
    );
    await store.stop(first.id);
    final off = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      drafter: const DrafterConfiguration(
        enabled: false,
        path: '/deleted/worktree/drafter',
      ),
    );
    await store.save(
      id: first.id,
      name: first.name,
      artifactId: first.artifactId,
      engineId: first.engineId,
      configuration: off,
    );
    await store.start(first.id);
    expect(
      runtime
          .bindingFor(fixture.asset.id)!
          .roles
          .keys
          .any((key) => key.startsWith('draft/')),
      isFalse,
    );
    expect(runtime.drafterCheckFor(fixture.asset.id, off)!.active, isFalse);
    await store.stop(first.id);
    final restored = LaunchInstances(catalog: catalog, file: file);
    addTearDown(restored.close);
    await restored.load();
    expect(restored.find(first.id)!.configuration.drafter!.enabled, isFalse);
    expect(
      restored.find(first.id)!.configuration.drafter!.path,
      '/deleted/worktree/drafter',
    );
    expect(restored.find(second.id)!.configuration.drafter!.enabled, isTrue);
    expect(
      restored.find(second.id)!.configuration.drafter!.path,
      b.drafter!.path,
    );
  });

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
