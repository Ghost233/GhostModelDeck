import 'dart:convert';
import 'dart:io';

import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import '../splash_engine_test.dart' show SplashRuntimeFixture;

/// Production configuration/runtime/gateway graph with only external native IO replaced.
class GenerationTestRuntime {
  GenerationTestRuntime(
    this.source,
    this.cpp,
    this.catalog,
    this.store,
    this.definition,
    this.routes,
    this.gateway,
  );
  final SplashRuntimeFixture source;
  final LlamaEngine cpp;
  final EngineCatalog catalog;
  final LaunchInstances store;
  final LaunchInstance definition;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;

  static Future<GenerationTestRuntime> create({
    GenerationConfiguration defaults = const GenerationConfiguration.empty(),
    bool start = true,
    Map<String, String> formValues = const {},
  }) async {
    final source = await SplashRuntimeFixture.create();
    final cpp = LlamaEngine(
      library: source.library,
      installationDirectory: Directory('${source.root.path}/cpp'),
    );
    final catalog = EngineCatalog(
      library: source.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(source.library),
      registryFile: File('${source.root.path}/engines.json'),
      splashIO: source.io,
    );
    final entry = await catalog.link(source.source.path);
    final store = LaunchInstances(
      catalog: catalog,
      file: File('${source.root.path}/instances.json'),
    );
    final definition = await store.save(
      name: 'Generation settings',
      artifactId: source.asset.id,
      engineId: entry.id,
      configuration: EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: formValues,
        drafter: const DrafterConfiguration(enabled: false),
        generation: defaults,
      ),
    );
    if (start) await store.start(definition.id);
    final routes = PublicModelRoutes(
      library: source.library,
      runtimes: catalog.runtimes.toList(),
      instances: store,
    );
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    await gateway.start();
    return GenerationTestRuntime(
      source,
      cpp,
      catalog,
      store,
      definition,
      routes,
      gateway,
    );
  }

  Future<void> saveDefaults(GenerationConfiguration defaults) async {
    final old = store.find(definition.id)!;
    await store.save(
      id: old.id,
      name: old.name,
      artifactId: old.artifactId,
      engineId: old.engineId,
      configuration: EngineLaunchConfiguration(
        family: old.configuration.family,
        formValues: old.configuration.formValues,
        argumentText: old.configuration.argumentText,
        drafter: old.configuration.drafter,
        generation: defaults,
      ),
    );
  }

  Future<({int status, String body})> post(
    Map<String, Object?> overrides, {
    String prompt = 'Reply OK',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/chat/completions'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': definition.publicName,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          ...overrides,
        }),
      );
      final response = await request.close();
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await gateway.stop();
    gateway.close();
    routes.close();
    await catalog.shutdown();
    await store.close();
    catalog.close();
    cpp.close();
    await source.close();
  }
}
