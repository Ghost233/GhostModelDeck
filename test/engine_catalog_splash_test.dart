import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/splash_engine.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test('Splash automatically prepares and persists a model without a manual binding', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    final first = await engine.startRuntime(fixture.asset.id);
    final binding = engine.bindingFor(fixture.asset.id)!;
    expect(binding.assembly.path, startsWith('${engine.modelDirectory.path}/'));
    expect(binding.assembly.path, isNot(fixture.assembly.path));
    expect(first.status, RuntimeInstanceStatus.ready);
    await engine.stop(first.id);
    final second = await engine.startRuntime(fixture.asset.id);
    expect(
      engine.bindingFor(fixture.asset.id)!.assembly.path,
      binding.assembly.path,
    );
    await engine.stop(second.id);
    expect(await File('${binding.assembly.path}/model.json').exists(), isTrue);
  });
  test('Splash catalog persists bindings and config, routes public HTTP and preserves external files on unlink', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final cppProviders = <LlamaEngine>[];
    addTearDown(() {
      for (final cpp in cppProviders) {
        cpp.close();
      }
    });
    EngineCatalog catalog() {
      final cpp = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/cpp'),
      );
      cppProviders.add(cpp);
      return EngineCatalog(
        library: fixture.library,
        officialEngine: cpp,
        useRegistry: ModelUseRegistry(fixture.library),
        registryFile: File('${fixture.root.path}/engines.json'),
        splashIO: fixture.io,
      );
    }

    final first = catalog();
    final registration = await first.link(fixture.source.path);
    expect(registration.family, EngineFamily.splash);
    expect(registration.path, fixture.source.path);
    await expectLater(
      first.link(fixture.source.path),
      throwsA(isA<SplashEngineException>()),
    );
    await first.saveModelLaunchOverrides(
      registration.id,
      fixture.asset.id,
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--max-context 1K',
      ),
    );
    await first.bindSplashModel(
      registration.id,
      fixture.asset.id,
      fixture.assembly,
    );
    await first.shutdown();
    first.close();
    final reopened = catalog();
    addTearDown(reopened.close);
    await reopened.refresh();
    final engine = reopened.runtimeFor(registration.id) as SplashEngine;
    expect(engine.bindingFor(fixture.asset.id), isNotNull);
    expect(
      reopened
          .launchConfigurationFor(registration.id, fixture.asset.id)
          .argumentText,
      '--max-context 1K',
    );
    final routes = PublicModelRoutes(
      library: fixture.library,
      runtimes: [],
      runtimeSources: () => reopened.runtimes.toList(),
    );
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    await routes.enable(fixture.asset.id);
    addTearDown(routes.close);
    await gateway.start();
    addTearDown(() async {
      await gateway.stop();
      await reopened.shutdown();
    });
    final run = await engine.startRuntime(fixture.asset.id);
    expect(
      reopened.runsFor([fixture.asset.id]).single.engine.id,
      registration.id,
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/chat/completions'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': routes.publicIdFor(fixture.asset.id),
          'messages': [
            {'role': 'user', 'content': 'Reply OK'},
          ],
        }),
      );
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200, reason: text);
      expect((jsonDecode(text) as Map)['choices'], isNotEmpty);
    } finally {
      client.close(force: true);
    }
    await expectLater(
      reopened.prepareRemoval(registration.id),
      throwsA(isA<SplashEngineException>()),
    );
    await engine.stop(run.id);
    await reopened.remove(
      await reopened.prepareRemoval(registration.id),
      confirmed: true,
    );
    expect(reopened.state.entries.any((e) => e.id == registration.id), isFalse);
    final saved = jsonDecode(await reopened.registryFile.readAsString()) as Map;
    expect(saved.containsKey('unlinkedConfigurations'), isFalse);
    expect(
      (saved['launchDefaults'] as Map?)?.containsKey(registration.id) ?? false,
      isFalse,
    );
    expect(
      (saved['modelLaunchOverrides'] as Map?)?.containsKey(registration.id) ??
          false,
      isFalse,
    );
    expect(await fixture.source.exists(), isTrue);
    expect(await fixture.assembly.exists(), isTrue);
    final again = catalog();
    addTearDown(again.close);
    await again.refresh();
    expect(
      (jsonDecode(await again.registryFile.readAsString()) as Map).containsKey(
        'unlinkedConfigurations',
      ),
      isFalse,
    );
    expect(
      again.state.entries.any((e) => e.family == EngineFamily.splash),
      isFalse,
    );
  });
}
