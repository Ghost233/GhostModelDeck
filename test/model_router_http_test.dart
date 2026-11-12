import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/llm_playground.dart';
import 'package:ghost_model_deck/model_routers.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_route.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test(
    'chat alias switches only new requests and follows the selected instance',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      fixture.io.runtimeEndpointMissing = true;
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
      Future<LaunchInstance> saveInstance(String name, double temperature) =>
          instances.save(
            name: name,
            artifactId: fixture.asset.id,
            engineId: engine.id,
            configuration: EngineLaunchConfiguration(
              family: EngineFamily.splash,
              formValues: {'--max-context': '1024'},
              generation: GenerationConfiguration({'temperature': temperature}),
            ),
            splashAssembly: fixture.assembly.path,
          );
      final first = await saveInstance('First', 0.2);
      final second = await saveInstance('Second', 0.7);
      final file = File('${fixture.root.path}/model-routers.json');
      final initial = ModelRouters(file: file, instances: instances);
      addTearDown(initial.close);
      const alias = 'model_router';
      final candidates = [first.id, second.id];
      ModelRouter config(String name) => ModelRouter(
        name: name,
        candidateIds: candidates,
        currentInstanceId: first.id,
      );
      await expectLater(
        initial.create(config(first.publicName)),
        throwsStateError,
      );
      await initial.create(config(alias));
      await initial.select(alias, second.id);
      await initial.close();

      final routers = ModelRouters(file: file, instances: instances);
      addTearDown(routers.close);
      final routes = PublicModelRoutes(
        library: fixture.library,
        runtimes: catalog.runtimes.toList(),
        instances: instances,
        modelRouters: routers,
      );
      final ledger = await PrefillOperationLedger.open(
        File('${fixture.root.path}/prefill-operations.json'),
      );
      addTearDown(ledger.close);
      final prefill = PublicPrefillRouteResolver(
        routes: routes,
        ledger: ledger,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillService: PublicPrefillService(
          ledger: ledger,
          enabled: true,
          resolve: prefill.resolve,
        ),
      );
      addTearDown(() async {
        await gateway.stop();
        gateway.close();
        routes.close();
      });
      await gateway.start();
      expect(routers.find(alias)?.candidateIds, candidates);
      expect(routers.find(alias)?.currentInstanceId, second.id);
      final base = gateway.baseUrl!;
      final playground = LlmPlayground(baseUrl: () => base);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<HttpClientResponse> post({
        String model = alias,
        bool stream = false,
        double? temperature,
        String prompt = 'Reply OK.',
      }) async {
        final request = await client.postUrl(
          base.resolve('/v1/chat/completions'),
        );
        final body = utf8.encode(
          jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'stream': stream,
            'max_tokens': 8,
            'cache_salt': 'router-test-salt',
            'temperature': ?temperature,
          }),
        );
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
        return request.close();
      }

      Future<Map<String, Object?>> read(HttpClientResponse response) async =>
          (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
              .cast<String, Object?>();

      final firstRun = await instances.start(first.id);
      final unavailable = await post();
      expect(unavailable.statusCode, 503);
      expect(
        (await read(unavailable))['error'],
        containsPair('type', 'model_not_ready'),
      );
      expect(fixture.io.chatModels, isEmpty);
      expect(await playground.discover(), [first.publicName]);
      expect(fixture.io.starts, 1);

      final secondRun = await instances.start(second.id);
      await expectLater(
        prefill.resolve(SplashOperationPath.chat, alias),
        throwsA(
          isA<PublicRequestException>().having(
            (error) => error.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(
        await playground.discover(),
        unorderedEquals([first.publicName, second.publicName, alias]),
      );
      final response = await post();
      expect(response.statusCode, 200);
      expect((await read(response))['model'], alias);
      expect(fixture.io.chatModels.last, secondRun.id);
      expect(fixture.io.chatBodies.last['temperature'], 0.7);

      final streaming = await post(stream: true, prompt: 'streamhold');
      expect(streaming.statusCode, 200);
      final body = utf8.decoder.bind(streaming).join();
      try {
        await routers.select(alias, first.id);
        final next = await post(temperature: 0.4);
        expect(next.statusCode, 200);
        expect((await read(next))['model'], alias);
        expect(fixture.io.chatModels, [
          secondRun.id,
          secondRun.id,
          firstRun.id,
        ]);
        expect(fixture.io.chatBodies.last['temperature'], 0.4);
      } finally {
        fixture.io.releaseHeld.complete();
      }
      final events = (await body)
          .split('\n')
          .where((line) => line.startsWith('data: '))
          .toList();
      expect(events.last, 'data: [DONE]');
      expect(
        events
            .take(events.length - 1)
            .map((event) => (jsonDecode(event.substring(6)) as Map)['model']),
        everyElement(alias),
      );

      await instances.stop(first.id);
      await instances.delete(first.id);
      expect(routers.find(alias)?.currentInstanceId, first.id);
      expect(await playground.discover(), [second.publicName]);
      final missing = await post();
      expect(missing.statusCode, 503);
      await read(missing);
      expect(fixture.io.chatModels, hasLength(3));
      await routers.select(alias, second.id);
      final recovered = await post();
      expect(recovered.statusCode, 200);
      await read(recovered);
      expect(fixture.io.chatModels.last, secondRun.id);

      await routers.delete(alias);
      final removed = await post();
      expect(removed.statusCode, 404);
      await read(removed);
      final direct = await post(model: second.publicName);
      expect(direct.statusCode, 200);
      expect((await read(direct))['model'], second.publicName);
    },
  );
}
