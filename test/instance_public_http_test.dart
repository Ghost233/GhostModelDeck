import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test('public HTTP selects saved instances of the same model and invalidates old names', () async {
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
    final instances = LaunchInstances(
      catalog: catalog,
      file: File('${fixture.root.path}/instances.json'),
    );
    addTearDown(instances.close);
    final first = await instances.save(
      name: 'First',
      artifactId: fixture.asset.id,
      engineId: engine.id,
      configuration: EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--max-context': '1024'},
      ),
      splashAssembly: fixture.assembly.path,
    );
    final second = await instances.copy(first.id);
    final routes = PublicModelRoutes(
      library: fixture.library,
      runtimes: catalog.runtimes.toList(),
      instances: instances,
    );
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    await gateway.start();
    addTearDown(() async {
      await gateway.stop();
      gateway.close();
      routes.close();
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, Map)> post(String name) async {
      final request = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/chat/completions'),
      );
      final body = utf8.encode(
        jsonEncode({
          'model': name,
          'messages': [
            {'role': 'user', 'content': 'Reply OK.'},
          ],
          'max_tokens': 8,
          'stream': false,
        }),
      );
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      );
    }

    expect((await post(first.publicName)).$1, 503);
    expect(fixture.io.starts, 0);
    final firstRun = await instances.start(first.id);
    final secondRun = await instances.start(second.id);
    final reused = await instances.start(first.id);
    expect(reused.id, firstRun.id);
    expect(fixture.io.starts, 2);
    fixture.io.chatModels.clear();
    for (final definition in [first, second]) {
      final (status, response) = await post(definition.publicName);
      expect(status, 200);
      expect(response['model'], definition.publicName);
      expect(response['choices'].single['message']['content'], 'OK');
    }
    expect(fixture.io.chatModels, [firstRun.id, secondRun.id]);
    await instances.renamePublicName(first.id, 'fast');
    expect((await post(first.publicName)).$1, 404);
    expect(fixture.io.chatModels, [firstRun.id, secondRun.id]);
    expect((await post('fast')).$1, 200);
    expect(fixture.io.chatModels.last, firstRun.id);
    final third = await instances.copy(first.id);
    final release = Completer<void>();
    fixture.io.releaseStart = release;
    final starting = instances.start(third.id);
    expect(identical(starting, instances.start(third.id)), isTrue);
    final outcome = starting.then<Object>(
      (value) => value,
      onError: (Object error) => error,
    );
    while (fixture.io.starts < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final stopping = instances.stop(third.id);
    release.complete();
    await stopping;
    expect(await outcome, isA<Exception>());
    expect(
      instances.runsFor(third.id).any((run) => run.hasLiveProcess),
      isFalse,
    );
    expect(fixture.io.starts, 3);
  });
}
