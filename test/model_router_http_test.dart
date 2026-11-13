import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
import 'package:ghost_model_deck/prefill_operation_id.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_route.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import 'fixtures/native_text_api.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test(
    'model routing uses the current instance for each new text request',
    // All protocols use the same running instances and saved router.
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      fixture.io.prefillCapabilities = {
        'schema': 'splash-prefill/1',
        'operation_tracking': true,
        'chat_zero_budget': true,
        'systemone_state': false,
      };
      fixture.io.monitorStatus = {
        'maximum_context_tokens': 1024,
        'http': {
          'requests': {'capacity': 2},
        },
      };
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
      final prefillTarget = await prefill.resolve(
        SplashOperationPath.chat,
        alias,
      );
      expect(prefillTarget.nativeModel, secondRun.id);
      final models = await read(
        await (await client.getUrl(base.resolve('/api/v1/models'))).close(),
      );
      final aliasCapacity = (models['models'] as List).cast<Map>().singleWhere(
        (model) => model['key'] == alias,
      );
      expect(aliasCapacity['loaded_instances'], [
        {
          'id': alias,
          'config': {'context_length': 1024, 'max_concurrent_requests': 2},
        },
      ]);
      expect(
        aliasCapacity['capabilities']['prefill'],
        containsPair('supported', true),
      );
      const operationToken =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      String operationId(String token) =>
          'gmd1.${sha256.convert(utf8.encode(prefillTarget.generation))}.'
          '${ledger.timeBasisMs}.${PrefillOperationId.nonceForToken(token)}';
      final oldOperation = operationId(operationToken);
      const prefillBody = {
        'model': alias,
        'cache_salt': 'tracked-salt',
        'messages': [
          {'role': 'user', 'content': 'prefill input'},
        ],
        'max_tokens': 0,
      };
      final trackedModels = <String>[];
      fixture.io.trackedOperation = (request, nativeAlias, model, pid) async {
        if (request.method == 'POST') {
          expect(request.headers.value('x-splash-operation-id'), oldOperation);
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          trackedModels.add(body['model'] as String);
          expect(body['model'], nativeAlias);
          expect(body['max_tokens'], 0);
          request.response.write(
            jsonEncode({
              'object': 'chat.completion',
              'model': model,
              'choices': [
                {
                  'index': 0,
                  'finish_reason': 'length',
                  'message': {'role': 'assistant', 'content': null},
                },
              ],
              'usage': {
                'prompt_tokens': 4,
                'completion_tokens': 0,
                'total_tokens': 4,
              },
            }),
          );
        } else {
          expect(request.uri.path, '/v1/splash/operations/$oldOperation');
          request.response.write(
            jsonEncode({
              'operation_id': oldOperation,
              'service_instance': 'service-$pid',
              'state': 'completed',
              'terminal': true,
              'lease_released': true,
              'children': [
                {
                  'state': 'length',
                  'lease_released': true,
                  'native_request_id': 1,
                  'runtime_generation': 1,
                  'prompt_tokens': 4,
                  'completion_tokens': 0,
                },
              ],
            }),
          );
        }
        await request.response.close();
      };
      Future<HttpClientResponse> tracked(String id, String token) async {
        final request = await client.postUrl(
          base.resolve('/v1/chat/completions'),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('idempotency-key', id);
        request.headers.set('x-gmd-operation-token', token);
        request.headers.set(
          'x-gmd-runtime-generation',
          prefillTarget.generation,
        );
        request.write(jsonEncode(prefillBody));
        return request.close();
      }

      final submitted = await tracked(oldOperation, operationToken);
      expect(submitted.statusCode, 200);
      final prefilled = await read(submitted);
      expect(prefilled['model'], alias);
      expect(
        prefilled['prefill'],
        containsPair('runtime_generation', prefillTarget.generation),
      );
      expect(trackedModels, [secondRun.id]);

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
        final now = await prefill.resolve(SplashOperationPath.chat, alias);
        expect(now.nativeModel, firstRun.id);
        expect(now.generation, isNot(prefillTarget.generation));
        final replayed = await tracked(oldOperation, operationToken);
        expect(replayed.statusCode, 200);
        expect(await read(replayed), prefilled);
        const staleToken =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final stale = await tracked(operationId(staleToken), staleToken);
        expect(stale.statusCode, 409);
        expect(
          (await read(stale))['error'],
          containsPair('code', 'idempotency_conflict'),
        );
        expect(trackedModels, [secondRun.id]);
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

      final forwardedModels = <String>[];
      final responseBodies = <Map>[];
      fixture.io.nativeText = (request, nativeModel) async {
        final input =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(input['model'], nativeModel);
        forwardedModels.add(nativeModel);
        final path = request.uri.path;
        if (path == '/v1/responses') responseBodies.add(input);
        if (path == '/v1/chat/completions') {
          expect(input['tool_choice'], 'required');
          expect(input['tools'], isNotEmpty);
        }
        if (input['stream'] == true) {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          if (path == '/v1/chat/completions') {
            request.response.write(
              'data: {"model":"$nativeModel","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1"}]},"finish_reason":null}]}\n\n'
              'data: {"model":"$nativeModel","choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n'
              'data: [DONE]\n\n',
            );
          } else {
            request.response.write(
              'event: response.completed\n'
              'data: {"type":"response.completed","response":{"model":"$nativeModel","id":"resp-second","status":"completed","previous_response_id":null,"output":[{"type":"message","role":"assistant","content":"Second reply"}]}}\n\n',
            );
          }
        } else {
          request.response.write(
            jsonEncode(switch (path) {
              '/v1/responses' => {
                'object': 'response',
                'model': nativeModel,
                'temperature': input['temperature'],
                'id': input['store'] == false ? 'resp-private' : 'resp-first',
                'previous_response_id': null,
                'output': [
                  {
                    'type': 'message',
                    'role': 'assistant',
                    'content': 'First reply',
                  },
                ],
              },
              '/v1/messages' => {'type': 'message', 'model': nativeModel},
              '/v1/messages/count_tokens' => {'input_tokens': 4},
              '/v1/chat/completions' => {
                'object': 'chat.completion',
                'model': nativeModel,
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': null,
                      'tool_calls': [
                        {
                          'id': 'call_1',
                          'type': 'function',
                          'function': {'name': 'probe', 'arguments': '{}'},
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
              },
              _ => throw StateError('Unexpected protocol path: $path'),
            }),
          );
        }
        await request.response.close();
      };
      try {
        final responses = await postNativeText(base, '/v1/responses', {
          'model': alias,
          'input': 'hello',
        });
        expect(responses.status, 200);
        expect(
          jsonDecode(responses.body),
          allOf(
            containsPair('model', alias),
            containsPair('temperature', 0.2),
            containsPair('id', 'resp-first'),
          ),
        );
        await routers.select(alias, second.id);
        final sse = await postNativeText(base, '/v1/responses', {
          'model': alias,
          'input': 'continue',
          'previous_response_id': 'resp-first',
          'stream': true,
        });
        expect(sse.status, 200);
        expect(sse.mime, 'text/event-stream');
        expect(sse.body, contains('event: response.completed'));
        expect(sse.body, contains('"model":"$alias"'));
        expect(sse.body, contains('"previous_response_id":"resp-first"'));
        expect(sse.body, isNot(contains(secondRun.id)));
        expect(responseBodies.last['previous_response_id'], isNull);
        expect(responseBodies.last['input'], [
          {'type': 'message', 'role': 'user', 'content': 'hello'},
          {'type': 'message', 'role': 'assistant', 'content': 'First reply'},
          {'type': 'message', 'role': 'user', 'content': 'continue'},
        ]);

        const message = {
          'model': alias,
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
        };
        final messages = await postNativeText(base, '/v1/messages', message);
        expect(messages.status, 200);
        expect(jsonDecode(messages.body), {'type': 'message', 'model': alias});
        final count = await postNativeText(
          base,
          '/v1/messages/count_tokens',
          message,
        );
        expect(count.status, 200);
        expect(jsonDecode(count.body), {'input_tokens': 4});
        final toolRequest = {
          ...message,
          'tools': [
            {
              'type': 'function',
              'function': {'name': 'probe'},
            },
          ],
          'tool_choice': 'required',
        };
        final tools = await postNativeText(
          base,
          '/v1/chat/completions',
          toolRequest,
        );
        expect(tools.status, 200);
        expect(jsonDecode(tools.body)['model'], alias);
        expect(
          jsonDecode(tools.body)['choices'][0]['finish_reason'],
          'tool_calls',
        );
        final toolStream = await postNativeText(base, '/v1/chat/completions', {
          ...toolRequest,
          'stream': true,
        });
        expect(toolStream.status, 200);
        expect(
          toolStream.body,
          contains('"tool_calls":[{"index":0,"id":"call_1"}]'),
        );
        expect(toolStream.body, contains('"model":"$alias"'));
        expect(toolStream.body, endsWith('data: [DONE]\n\n'));
        await routers.select(alias, first.id);
        final resumed = await postNativeText(base, '/v1/responses', {
          'model': alias,
          'input': 'continue again',
          'previous_response_id': 'resp-second',
        });
        expect(resumed.status, 200);
        expect(responseBodies.last['input'], [
          {'type': 'message', 'role': 'user', 'content': 'hello'},
          {'type': 'message', 'role': 'assistant', 'content': 'First reply'},
          {'type': 'message', 'role': 'user', 'content': 'continue'},
          {'type': 'message', 'role': 'assistant', 'content': 'Second reply'},
          {'type': 'message', 'role': 'user', 'content': 'continue again'},
        ]);
        final private = await postNativeText(base, '/v1/responses', {
          'model': alias,
          'input': 'do not store',
          'store': false,
        });
        expect(private.status, 200);
        final unavailableHistory = await postNativeText(base, '/v1/responses', {
          'model': alias,
          'input': 'continue',
          'previous_response_id': 'resp-private',
        });
        expect(unavailableHistory.status, 404);
        expect(
          unavailableHistory.body,
          contains('previous_response_not_found'),
        );
        expect(forwardedModels, [
          firstRun.id,
          secondRun.id,
          secondRun.id,
          secondRun.id,
          secondRun.id,
          secondRun.id,
          firstRun.id,
          firstRun.id,
        ]);
      } finally {
        fixture.io.nativeText = null;
      }

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
