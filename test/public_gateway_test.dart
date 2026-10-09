import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/manager_lifecycle.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';
import 'fixtures/typed_answers.dart';

void main() {
  group('TextRequest 公开协议扩展', () {
    test('legacy prompt constructor keeps its exact upstream shape', () {
      final request = TextRequest(prompt: 'Hi', maxTokens: 8);
      expect(request.messages, hasLength(1));
      expect(request.messages.single.role, 'user');
      expect(request.messages.single.content, 'Hi');
      expect(
        request.toChat(model: 'native-alias'),
        equals({
          'model': 'native-alias',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
          'stream': false,
          'temperature': 0,
          'max_tokens': 8,
        }),
      );
    });

    test(
      'messages constructor carries roles, temperature and top_p verbatim',
      () {
        final request = TextRequest.messages(
          messages: [
            TextMessage(role: 'system', content: 'Be brief.'),
            TextMessage(role: 'user', content: 'Hi'),
            TextMessage(role: 'assistant', content: 'Hello'),
            TextMessage(role: 'user', content: 'Again'),
          ],
          maxTokens: 64,
          temperature: 0.7,
          topP: 0.9,
        );
        expect(request.maxTokens, 64);
        expect(request.temperature, 0.7);
        expect(request.topP, 0.9);
        final chat = request.toChat(model: 'native-alias', stream: true);
        expect(chat['model'], 'native-alias');
        expect(
          chat['messages'],
          equals([
            {'role': 'system', 'content': 'Be brief.'},
            {'role': 'user', 'content': 'Hi'},
            {'role': 'assistant', 'content': 'Hello'},
            {'role': 'user', 'content': 'Again'},
          ]),
        );
        expect(chat['stream'], true);
        expect(chat['stream_options'], {'include_usage': true});
        expect(chat['temperature'], 0.7);
        expect(chat['top_p'], 0.9);
        expect(chat['max_tokens'], 64);
        expect(chat.keys, isNot(contains('rawResponse')));
      },
    );

    test('messages constructor omits unset sampling fields', () {
      final chat = TextRequest.messages(
        messages: [TextMessage(role: 'user', content: 'Hi')],
      ).toChat(model: 'm');
      expect(chat.containsKey('temperature'), isFalse);
      expect(chat.containsKey('top_p'), isFalse);
    });

    test('messages constructor rejects invalid inputs explicitly', () {
      expect(
        () => TextRequest.messages(messages: const []),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextMessage(role: 'tool', content: 'x'),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextMessage(role: 'user', content: '  '),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          maxTokens: 0,
        ),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          maxTokens: 4097,
        ),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          temperature: 2.5,
        ),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          temperature: -0.1,
        ),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          temperature: double.nan,
        ),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          topP: 0,
        ),
        throwsA(isA<TextProtocolException>()),
      );
      expect(
        () => TextRequest.messages(
          messages: [TextMessage(role: 'user', content: 'x')],
          topP: 1.5,
        ),
        throwsA(isA<TextProtocolException>()),
      );
    });

    test('legacy constructor keeps its original rejection message', () {
      expect(
        () => TextRequest(prompt: ' '),
        throwsA(
          isA<TextProtocolException>().having(
            (e) => e.message,
            'message',
            '需要非空文本与 1–4096 个生成 token 上限',
          ),
        ),
      );
    });
  });

  group('EngineRuntime 流式接口', () {
    test(
      'EngineRuntime exposes streamText with timeout and cancellation',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        final instance = await fixture.engine.start(fixture.asset.id);
        final EngineRuntime runtime = fixture.engine;
        final events = <TextStreamEvent>[];
        fixture.io.streamResponse = _defaultStream;
        await runtime
            .streamText(instance.id, TextRequest(prompt: 'stream'))
            .forEach(events.add);
        expect(events.map((e) => e.delta).join(), 'Hello.');
        expect(events.last.result?.finishReason, 'stop');
        expect(events.last.result?.outputTokens, 2);
      },
    );
  });

  group('PublicModelRoutes 公开路由身份', () {
    test('public IDs derive from the stable artifact identity with a gmd- prefix', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      final routes = fixture.routes;
      expect(routes.publicIdFor(fixture.asset.id), 'gmd-${fixture.asset.id}');
      // Same artifact, rebuilt routes: identity survives restart of the layer.
      final rebuilt = PublicModelRoutes(
        library: fixture.library,
        runtimes: [fixture.engine],
      );
      addTearDown(rebuilt.close);
      await rebuilt.load();
      expect(rebuilt.publicIdFor(fixture.asset.id), 'gmd-${fixture.asset.id}');
    });

    test('enable persists across route-layer restarts', () async {
      final fixture = await _GatewayFixture.create(withRegistry: true);
      addTearDown(fixture.close);
      await fixture.routes.enable(fixture.asset.id);
      final rebuilt = PublicModelRoutes(
        library: fixture.library,
        runtimes: [fixture.engine],
        registryFile: fixture.registryFile,
      );
      addTearDown(rebuilt.close);
      await rebuilt.load();
      expect(rebuilt.isEnabled(fixture.asset.id), isTrue);
    });

    test(
      'a corrupt registry file fails explicitly instead of guessing',
      () async {
        final fixture = await _GatewayFixture.create(withRegistry: true);
        addTearDown(fixture.close);
        await fixture.registryFile!.parent.create(recursive: true);
        await fixture.registryFile!.writeAsString('{not json');
        final rebuilt = PublicModelRoutes(
          library: fixture.library,
          runtimes: [fixture.engine],
          registryFile: fixture.registryFile,
        );
        addTearDown(rebuilt.close);
        await expectLater(
          rebuilt.load(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('公开模型登记文件无效'),
            ),
          ),
        );
      },
    );

    test(
      'decision-only artifacts cannot be enabled for public text chat',
      () async {
        final fixture = await _GatewayFixture.create(ordinaryChat: false);
        addTearDown(fixture.close);
        expect(fixture.asset.kind, AssetKind.decision);
        await expectLater(
          fixture.routes.enable(fixture.asset.id),
          throwsStateError,
        );
        expect(fixture.routes.isEnabled(fixture.asset.id), isFalse);
      },
    );

    test('unknown artifacts cannot be enabled', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await expectLater(fixture.routes.enable('f' * 64), throwsStateError);
    });

    test(
      'listModels only exposes enabled artifacts with a ready text instance',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        expect(fixture.routes.listModels(), isEmpty);
        await fixture.routes.enable(fixture.asset.id);
        // Enabled but cold: not listed, zero upstream contact.
        expect(fixture.routes.listModels(), isEmpty);
        final instance = await fixture.engine.start(fixture.asset.id);
        fixture.io.textRequests = 0;
        final models = fixture.routes.listModels();
        expect(models.single.publicId, 'gmd-${fixture.asset.id}');
        expect(models.single.artifactId, fixture.asset.id);
        expect(fixture.io.textRequests, 0);
        await fixture.engine.stop(instance.id);
        expect(fixture.routes.listModels(), isEmpty);
      },
    );

    test('resolution rejects unknown, disabled and not-ready routes with zero upstream', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      final instance = await fixture.engine.start(fixture.asset.id);
      fixture.io.textRequests = 0;
      expect(
        () => fixture.routes.resolve('not-a-public-id'),
        throwsA(
          isA<PublicRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(
        () => fixture.routes.resolve('gmd-${'f' * 64}'),
        throwsA(
          isA<PublicRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      // Disabled artifact: explicit refusal even while a ready instance exists.
      expect(
        () => fixture.routes.resolve('gmd-${fixture.asset.id}'),
        throwsA(
          isA<PublicRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      await fixture.routes.enable(fixture.asset.id);
      await fixture.engine.stop(instance.id);
      expect(
        () => fixture.routes.resolve('gmd-${fixture.asset.id}'),
        throwsA(
          isA<PublicRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      expect(fixture.io.textRequests, 0);
    });

    test(
      'duplicate ready instances for one artifact fail as an explicit conflict',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        await fixture.routes.enable(fixture.asset.id);
        await fixture.engine.start(fixture.asset.id);
        await fixture.engine.start(fixture.asset.id);
        expect(
          () => fixture.routes.resolve('gmd-${fixture.asset.id}'),
          throwsA(
            isA<PublicRequestException>()
                .having((e) => e.statusCode, 'statusCode', 409)
                .having((e) => e.type, 'type', 'route_conflict'),
          ),
        );
      },
    );

    test(
      'a restarted instance keeps the public ID and revokes the old generation',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        await fixture.routes.enable(fixture.asset.id);
        final first = await fixture.engine.start(fixture.asset.id);
        final target = fixture.routes.resolve('gmd-${fixture.asset.id}');
        expect(target.instance.id, first.id);
        await fixture.engine.stop(first.id);
        await expectLater(
          fixture.engine.generateText(first.id, TextRequest(prompt: 'late')),
          throwsA(isA<LlamaRequestException>()),
        );
        final second = await fixture.engine.start(fixture.asset.id);
        expect(second.id, isNot(first.id));
        final rerouted = fixture.routes.resolve('gmd-${fixture.asset.id}');
        expect(rerouted.publicId, 'gmd-${fixture.asset.id}');
        expect(rerouted.instance.id, second.id);
        expect(
          (await fixture.engine.generateText(
            second.id,
            TextRequest(prompt: 'peer'),
          )).text,
          'Hello.',
        );
      },
    );
  });

  group('PublicGatewayServer HTTP 网关', () {
    test('repeated start and stop releases each real listener and shares concurrent stop', () async {
      final library = ModelLibrary();
      final routes = PublicModelRoutes(library: library, runtimes: const []);
      final gateway = PublicGatewayServer(routes: routes, port: 0);
      addTearDown(() async {
        await gateway.stop();
        gateway.close();
        routes.close();
        library.close();
      });
      await gateway.stop();
      for (var cycle = 0; cycle < 2; cycle++) {
        await gateway.start();
        final address = gateway.baseUrl!;
        final response = await _get('$address/v1/models');
        expect(
          response.status,
          HttpStatus.ok,
          reason: 'cycle $cycle serves an actual HTTP listener',
        );
        expect((jsonDecode(response.body) as Map)['data'], isEmpty);
        final firstStop = gateway.stop();
        final concurrentStop = gateway.stop();
        expect(identical(firstStop, concurrentStop), isTrue);
        await Future.wait([firstStop, concurrentStop]);
        await expectLater(
          Socket.connect(
            InternetAddress.loopbackIPv4,
            address.port,
            timeout: const Duration(seconds: 1),
          ).then((socket) => socket.destroy()),
          throwsA(isA<SocketException>()),
          reason: 'cycle $cycle must close its actual listening port',
        );
        final replacement = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          address.port,
        );
        await replacement.close();
        expect(gateway.state, PublicGatewayState.stopped);
        expect(gateway.baseUrl, isNull);
        await gateway.stop();
      }
    });
    test(
      'a port conflict fails explicitly without fallback or drift',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => blocker.close(force: true));
        final gateway = PublicGatewayServer(
          routes: fixture.routes,
          port: blocker.port,
        );
        addTearDown(gateway.close);
        await expectLater(
          gateway.start(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('${blocker.port}'),
            ),
          ),
        );
        expect(gateway.state, PublicGatewayState.failed);
        expect(gateway.baseUrl, isNull);
        // No retry drift: a second attempt fails the same way on the same port.
        await expectLater(gateway.start(), throwsStateError);
        expect(gateway.state, PublicGatewayState.failed);
      },
    );

    test('GET /v1/models lists only enabled and ready public models', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.gateway.start();
      var listed = await _get('${fixture.gateway.baseUrl}/v1/models');
      expect(listed.status, 200);
      expect(jsonDecode(listed.body), {'object': 'list', 'data': []});

      await fixture.routes.enable(fixture.asset.id);
      listed = await _get('${fixture.gateway.baseUrl}/v1/models');
      expect(jsonDecode(listed.body)['data'], isEmpty);

      await fixture.engine.start(fixture.asset.id);
      listed = await _get('${fixture.gateway.baseUrl}/v1/models');
      final data = jsonDecode(listed.body)['data'] as List;
      expect(data, hasLength(1));
      expect(data.single['id'], 'gmd-${fixture.asset.id}');
      expect(data.single['object'], 'model');
      expect(listed.body, isNot(contains(fixture.instanceId)));
    });

    test('ordinary public chat protects credential metadata while retaining actual usage', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.textUsage = {
        'prompt_tokens': 4,
        'completion_tokens': 2,
        'total_tokens': 6,
        'prompt_tokens_details': {'cached_tokens': 3},
        'api_key': 'upstream-private-credential',
      };
      final response = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Say hello'},
          ],
        },
      );
      expect(response.status, 200);
      expect(response.body, isNot(contains('upstream-private-credential')));
      final body = jsonDecode(response.body) as Map;
      expect(body['choices'].single['message']['content'], 'Hello.');
      expect(body['usage'], {
        'prompt_tokens': 4,
        'completion_tokens': 2,
        'total_tokens': 6,
        'prompt_tokens_details': {'cached_tokens': 3},
        'api_key': '[redacted]',
      });
    });

    test('non-stream chat completion passes real messages through and binds the public ID', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.textRequests = 0;
      final response = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'system', 'content': 'Be brief.'},
            {'role': 'user', 'content': 'Say hello'},
          ],
          'max_tokens': 16,
          'temperature': 0.5,
          'top_p': 0.8,
        },
      );
      expect(response.status, 200);
      final body = jsonDecode(response.body) as Map;
      expect(body['model'], 'gmd-${fixture.asset.id}');
      expect(body['object'], 'chat.completion');
      expect(body['choices'], hasLength(1));
      final choice = body['choices'].single as Map;
      expect(choice['index'], 0);
      expect(choice['message'], {'role': 'assistant', 'content': 'Hello.'});
      expect(choice['finish_reason'], 'stop');
      expect(body['usage'], {
        'prompt_tokens': 4,
        'completion_tokens': 2,
        'total_tokens': 6,
      });
      // No upstream identity, internals or raw frames leak into the public reply.
      expect(response.body, isNot(contains(fixture.instanceId)));
      expect(response.body, isNot(contains('rawResponse')));
      // The upstream saw the real request, not a reconstructed prompt.
      expect(fixture.io.textRequests, 1);
      final upstream = fixture.io.textBodies.single;
      expect(upstream['model'], fixture.instanceId);
      expect(
        upstream['messages'],
        equals([
          {'role': 'system', 'content': 'Be brief.'},
          {'role': 'user', 'content': 'Say hello'},
        ]),
      );
      expect(upstream['max_tokens'], 16);
      expect(upstream['temperature'], 0.5);
      expect(upstream['top_p'], 0.8);
      expect(upstream['stream'], false);
    });

    test('ordinary public SSE protects credential metadata and preserves task text', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.streamResponse = (response, alias, body) async {
        for (final frame in [
          {
            'model': alias,
            'choices': [
              {
                'index': 0,
                'delta': {
                  'role': 'assistant',
                  'content': 'Authorization: allow',
                },
                'finish_reason': null,
              },
            ],
          },
          {
            'model': alias,
            'choices': [
              {
                'index': 0,
                'delta': <String, Object?>{},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 4,
              'completion_tokens': 2,
              'total_tokens': 6,
              'api_key': 'upstream-sse-private',
            },
          },
        ]) {
          response.write('data: ${jsonEncode(frame)}\n\n');
          await response.flush();
        }
        response.write('data: [DONE]\n\n');
      };
      final client = _SseClient();
      addTearDown(client.destroy);
      expect(
        await client.open('${fixture.gateway.baseUrl}/v1/chat/completions', {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Say hello'},
          ],
          'stream': true,
        }),
        200,
      );
      final raw = await client.body();
      expect(raw, contains('Authorization: allow'));
      expect(raw, contains('data: [DONE]'));
      expect(raw, isNot(contains('upstream-sse-private')));
      final frames = raw
          .split('\n\n')
          .where((frame) => frame.startsWith('data: {'))
          .map((frame) => jsonDecode(frame.substring(6)) as Map)
          .toList();
      expect(frames.last['usage'], {
        'prompt_tokens': 4,
        'completion_tokens': 2,
        'total_tokens': 6,
        'api_key': '[redacted]',
      });
    });

    test('SSE chat preserves framing, usage, finish reason and DONE with public ID parity', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.streamResponse = _defaultStream;
      final client = _SseClient();
      addTearDown(client.destroy);
      final status = await client.open(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Stream please'},
          ],
          'stream': true,
        },
      );
      expect(status, 200);
      final raw = await client.body();
      final frames = raw
          .split('\n\n')
          .map((f) => f.trim())
          .where((f) => f.isNotEmpty)
          .toList();
      expect(frames.last, 'data: [DONE]');
      final chunks = frames
          .sublist(0, frames.length - 1)
          .map((f) => jsonDecode(f.substring('data: '.length)) as Map)
          .toList();
      expect(chunks.length, 3);
      for (final chunk in chunks) {
        expect(chunk['model'], 'gmd-${fixture.asset.id}');
        expect(chunk['object'], 'chat.completion.chunk');
      }
      expect(chunks[0]['choices'].single['delta'], {
        'role': 'assistant',
        'content': 'Hel',
      });
      expect(chunks[1]['choices'].single['delta'], {'content': 'lo.'});
      final terminal = chunks[2]['choices'].single as Map;
      expect(terminal['delta'], isEmpty);
      expect(terminal['finish_reason'], 'stop');
      expect(chunks[2]['usage'], {
        'prompt_tokens': 4,
        'completion_tokens': 2,
        'total_tokens': 6,
      });
      expect(raw, isNot(contains(fixture.instanceId)));
      // The upstream SSE request carried the identity-bound stream options.
      final upstream = fixture.io.textBodies.single;
      expect(upstream['stream'], true);
      expect(upstream['stream_options'], {'include_usage': true});
    });

    test(
      'non-stream chat preserves the full upstream usage verbatim',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        await fixture.enableReady();
        fixture.io.textUsage = {
          'prompt_tokens': 10,
          'completion_tokens': 5,
          'total_tokens': 15,
        };
        final response = await _post(
          '${fixture.gateway.baseUrl}/v1/chat/completions',
          {
            'model': 'gmd-${fixture.asset.id}',
            'messages': [
              {'role': 'user', 'content': 'Say hello'},
            ],
          },
        );
        expect(response.status, 200);
        final body = jsonDecode(response.body) as Map;
        expect(body['usage'], {
          'prompt_tokens': 10,
          'completion_tokens': 5,
          'total_tokens': 15,
        });
      },
    );

    test('SSE chat preserves the full upstream usage verbatim in the terminal frame', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.streamResponse = (response, alias, body) async {
        for (final frame in [
          {
            'model': alias,
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'Hi'},
                'finish_reason': null,
              },
            ],
          },
          {
            'model': alias,
            'choices': [
              {
                'index': 0,
                'delta': <String, Object?>{},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 10,
              'completion_tokens': 5,
              'total_tokens': 15,
            },
          },
        ]) {
          response.write('data: ${jsonEncode(frame)}\n\n');
          await response.flush();
        }
        response.write('data: [DONE]\n\n');
      };
      final client = _SseClient();
      addTearDown(client.destroy);
      final status = await client.open(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Stream please'},
          ],
          'stream': true,
        },
      );
      expect(status, 200);
      final raw = await client.body();
      final frames = raw
          .split('\n\n')
          .map((f) => f.trim())
          .where((f) => f.isNotEmpty)
          .toList();
      expect(frames.last, 'data: [DONE]');
      final chunks = frames
          .sublist(0, frames.length - 1)
          .map((f) => jsonDecode(f.substring('data: '.length)) as Map)
          .toList();
      final terminal = chunks.last;
      expect(terminal['choices'].single['finish_reason'], 'stop');
      expect(terminal['usage'], {
        'prompt_tokens': 10,
        'completion_tokens': 5,
        'total_tokens': 15,
      });
    });

    test('unsupported fields and invalid values are rejected with zero upstream forwarding', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.textRequests = 0;
      final valid = {
        'model': 'gmd-${fixture.asset.id}',
        'messages': [
          {'role': 'user', 'content': 'Hi'},
        ],
      };
      final cases = <Map<String, Object?>>[
        {
          ...valid,
          'response_format': {'type': 'json_object'},
        },
        {...valid, 'tools': []},
        {...valid, 'n': 2},
        {...valid, 'stream': 'yes'},
        {...valid, 'max_tokens': 0},
        {...valid, 'max_tokens': 4097},
        {...valid, 'max_tokens': true},
        {...valid, 'temperature': 2.5},
        {...valid, 'temperature': 'hot'},
        {...valid, 'top_p': 0},
        {...valid, 'messages': <Object?>[]},
        {...valid, 'messages': 'Hi'},
        {
          ...valid,
          'messages': [
            {'role': 'tool', 'content': 'x'},
          ],
        },
        {
          ...valid,
          'messages': [
            {'role': 'user', 'content': ''},
          ],
        },
        {
          ...valid,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Hi'},
              ],
            },
          ],
        },
        {
          ...valid,
          'messages': [
            {'role': 'user', 'content': 'Hi', 'name': 'extra'},
          ],
        },
        {'messages': valid['messages']},
        {...valid, 'model': 42},
        {...valid, 'model': ''},
      ];
      for (final body in cases) {
        final response = await _post(
          '${fixture.gateway.baseUrl}/v1/chat/completions',
          body,
        );
        expect(
          response.status,
          400,
          reason: 'expected explicit rejection for $body',
        );
        final error = jsonDecode(response.body)['error'] as Map;
        expect(error['type'], 'invalid_request_error');
        expect(error['message'], isA<String>());
      }
      expect(fixture.io.textRequests, 0);
      expect(fixture.engine.runtimeInstances.single.activeRequests, 0);
    });

    test('unknown, disabled and not-ready models are refused without any upstream call', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.gateway.start();
      Map<String, Object?> chat(String model) => {
        'model': model,
        'messages': [
          {'role': 'user', 'content': 'Hi'},
        ],
      };
      final missing = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        chat('gmd-${'f' * 64}'),
      );
      expect(missing.status, 404);
      expect(jsonDecode(missing.body)['error']['type'], 'model_not_found');

      // Enabled and resolvable-ready, then cold again: explicit 503, zero load.
      await fixture.routes.enable(fixture.asset.id);
      final cold = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        chat('gmd-${fixture.asset.id}'),
      );
      expect(cold.status, 503);
      expect(jsonDecode(cold.body)['error']['type'], 'model_not_ready');
      expect(fixture.io.children, isEmpty);

      await fixture.engine.start(fixture.asset.id);
      await fixture.routes.disable(fixture.asset.id);
      final disabled = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        chat('gmd-${fixture.asset.id}'),
      );
      expect(disabled.status, 404);
      expect(fixture.io.textRequests, 1); // only the start readiness proof
      expect(fixture.io.children, hasLength(1));
    });

    test('an upstream refusal surfaces as a truthful 502, never as a fake completion', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.textStatus = 500;
      final response = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
        },
      );
      expect(response.status, 502);
      expect(jsonDecode(response.body)['error']['type'], 'upstream_error');
      expect(response.body, isNot(contains('Hello.')));
      expect(fixture.engine.runtimeInstances.single.activeRequests, 0);
    });

    test('an upstream failure before the first SSE frame is an error, not a stream', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.streamResponse = (response, alias, body) async {
        response.statusCode = 500;
        response.write('upstream refused');
      };
      final client = _SseClient();
      addTearDown(client.destroy);
      final status = await client.open(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
          'stream': true,
        },
      );
      expect(status, 502);
      final body = await client.body();
      expect(jsonDecode(body)['error']['type'], 'upstream_error');
      expect(body, isNot(contains('[DONE]')));
    });

    test('a mid-stream upstream failure closes the stream without a fabricated DONE', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      await fixture.enableReady();
      fixture.io.streamResponse = (response, alias, body) async {
        response.write(
          'data: ${jsonEncode({
            'model': alias,
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'partial'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        await response.flush();
        // Upstream dies mid-stream: close without terminal frames.
        await response.close();
      };
      final client = _SseClient();
      addTearDown(client.destroy);
      final status = await client.open(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
          'stream': true,
        },
      );
      expect(status, 200);
      final raw = await client.body();
      expect(raw, contains('partial'));
      expect(raw, isNot(contains('[DONE]')));
      expect(fixture.engine.runtimeInstances.single.activeRequests, 0);
    });

    test('client disconnect cancels the upstream stream and releases the permit', () async {
      // dart:io surfaces a dead SSE client only on the next write, so this
      // test injects a short heartbeat; the gateway then notices the dead
      // client within one cadence and cancels the upstream.
      final fixture = await _GatewayFixture.create(
        heartbeatInterval: const Duration(milliseconds: 100),
      );
      addTearDown(fixture.close);
      await fixture.enableReady();
      final upstreamOpen = Completer<void>();
      final upstreamClosed = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.io.streamResponse = (response, alias, body) async {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (!upstreamClosed.isCompleted) upstreamClosed.complete();
          },
          onError: (Object _) {
            if (!upstreamClosed.isCompleted) upstreamClosed.complete();
          },
        );
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ${jsonEncode({
              'model': alias,
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'held'},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          ),
        );
        await socket.flush();
        upstreamOpen.complete();
        await release.future;
        socket.destroy();
      };
      final client = _SseClient();
      addTearDown(client.destroy);
      final status = await client.open(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
          'stream': true,
        },
      );
      expect(status, 200);
      await upstreamOpen.future;
      await client.firstFrame();
      expect(fixture.engine.runtimeInstances.single.activeRequests, 1);
      client.destroy();
      await upstreamClosed.future.timeout(const Duration(seconds: 5));
      await fixture.drain();
      expect(fixture.engine.runtimeInstances.single.activeRequests, 0);
      expect(fixture.io.children.every((c) => !c.exited.isCompleted), isTrue);
      // A follow-up request still works: the permit was really released.
      fixture.io.streamResponse = _defaultStream;
      final again = await _post(
        '${fixture.gateway.baseUrl}/v1/chat/completions',
        {
          'model': 'gmd-${fixture.asset.id}',
          'messages': [
            {'role': 'user', 'content': 'again'},
          ],
        },
      );
      expect(again.status, 200);
    });

    test(
      'oversized bodies and foreign hosts are bounded before any parsing',
      () async {
        final fixture = await _GatewayFixture.create();
        addTearDown(fixture.close);
        await fixture.gateway.start();
        final big = await _postRaw(
          '${fixture.gateway.baseUrl}/v1/chat/completions',
          List.filled(1024 * 1024 + 8, 65),
        );
        expect(big, 413);
        final foreign = await _post(
          '${fixture.gateway.baseUrl}/v1/chat/completions',
          {
            'model': 'gmd-x',
            'messages': [
              {'role': 'user', 'content': 'Hi'},
            ],
          },
          host: 'evil.example.com',
        );
        expect(foreign.status, 403);
      },
    );

    test('shutdown seals admission, cancels in-flight streams and stops before engines drain', () async {
      final fixture = await _GatewayFixture.create();
      addTearDown(fixture.close);
      final council = CouncilController(catalog: fixture.catalog);
      addTearDown(council.close);
      final mcp = CouncilMcpServer(controller: council, port: 0);
      addTearDown(mcp.close);
      final lifecycle = ManagerLifecycle(
        council: council,
        mcp: mcp,
        engines: fixture.catalog,
        downloader: ModelDownloader(),
        gateway: fixture.gateway,
      );
      await fixture.enableReady();
      final upstreamOpen = Completer<void>();
      final release = Completer<void>();
      fixture.io.streamResponse = (response, alias, body) async {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.listen((_) {}, onDone: () {}, onError: (Object _) {});
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ${jsonEncode({
              'model': alias,
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'held'},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          ),
        );
        await socket.flush();
        upstreamOpen.complete();
        await release.future;
        socket.destroy();
      };
      final client = _SseClient();
      addTearDown(client.destroy);
      await client.open('${fixture.gateway.baseUrl}/v1/chat/completions', {
        'model': 'gmd-${fixture.asset.id}',
        'messages': [
          {'role': 'user', 'content': 'Hi'},
        ],
        'stream': true,
      });
      await upstreamOpen.future;
      await client.firstFrame();
      expect(fixture.engine.runtimeInstances.single.activeRequests, 1);

      await lifecycle.shutdown();

      // Gateway stopped before the engine was drained, and the in-flight
      // stream was cancelled rather than completed.
      expect(fixture.gateway.state, PublicGatewayState.stopped);
      expect(
        fixture.events.indexOf('gateway-stopped'),
        lessThan(fixture.events.indexOf('engine-killed')),
      );
      final remaining = fixture.engine.runtimeInstances;
      expect(
        remaining.every(
          (instance) =>
              instance.status == RuntimeInstanceStatus.stopped &&
              !instance.hasLiveProcess &&
              instance.activeRequests == 0,
        ),
        isTrue,
      );
      expect(fixture.io.children.single.exited.isCompleted, isTrue);
      expect(lifecycle.state, ManagerLifecycleState.stopped);
      // The listener is gone: no admission after shutdown.
      final refused = _SseClient();
      addTearDown(refused.destroy);
      expect(
        await refused.openOrNull(
          'http://127.0.0.1:${fixture.gateway.port}/v1/models',
          null,
          get: true,
        ),
        isNull,
      );
      final raw = await client.body();
      expect(raw, contains('held'));
      expect(raw, isNot(contains('[DONE]')));
    });
  });
}

Future<void> _defaultStream(
  HttpResponse response,
  String alias,
  Map body,
) async {
  for (final frame in [
    {
      'model': alias,
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'Hel'},
          'finish_reason': null,
        },
      ],
    },
    {
      'model': alias,
      'choices': [
        {
          'index': 0,
          'delta': {'content': 'lo.'},
          'finish_reason': null,
        },
      ],
    },
    {
      'model': alias,
      'choices': [
        {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
      ],
      'usage': {'prompt_tokens': 4, 'completion_tokens': 2, 'total_tokens': 6},
    },
  ]) {
    response.write('data: ${jsonEncode(frame)}\n\n');
    await response.flush();
  }
  response.write('data: [DONE]\n\n');
}

Future<({int status, String body})> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close();
  }
}

Future<({int status, String body})> _post(
  String url,
  Object? body, {
  String? host,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close();
  }
}

Future<int> _postRaw(String url, List<int> bytes) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    request.add(bytes);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

class _SseClient {
  final HttpClient _client = HttpClient();
  final _received = StringBuffer();
  final _signals = StreamController<void>.broadcast();
  final _done = Completer<void>();
  String? _error;

  Future<int> open(String url, Object? body) async {
    final request = await _client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    utf8.decoder
        .bind(response)
        .listen(
          (chunk) {
            _received.write(chunk);
            _signals.add(null);
          },
          onError: (Object error) {
            _error = '$error';
            if (!_done.isCompleted) _done.complete();
            _signals.add(null);
          },
          onDone: () {
            if (!_done.isCompleted) _done.complete();
            _signals.add(null);
          },
        );
    return response.statusCode;
  }

  Future<int?> openOrNull(String url, Object? body, {bool get = false}) async {
    try {
      final request = get
          ? await _client.getUrl(Uri.parse(url))
          : await _client.postUrl(Uri.parse(url));
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } on SocketException {
      return null;
    }
  }

  Future<void> firstFrame() async {
    if (_received.toString().contains('\n\n')) return;
    await for (final _ in _signals.stream) {
      if (_received.toString().contains('\n\n')) return;
      if (_done.isCompleted) break;
    }
    throw StateError('stream closed before the first frame: $_error');
  }

  Future<String> body() async {
    await _done.future;
    return _received.toString();
  }

  void destroy() {
    _client.close(force: true);
  }
}

class _GatewayFixture {
  _GatewayFixture(
    this.root,
    this.library,
    this.asset,
    this.io,
    this.engine,
    this.catalog,
    this.routes,
    this.gateway,
    this.registryFile,
    this.events,
  );
  final Directory root;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final _GatewayIO io;
  final LlamaEngine engine;
  final EngineCatalog catalog;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  final File? registryFile;
  final List<String> events;

  String get instanceId => engine.runtimeInstances.single.id;

  static Future<_GatewayFixture> create({
    bool ordinaryChat = true,
    bool withRegistry = false,
    Duration? heartbeatInterval,
  }) async {
    final root = await Directory.systemTemp.createTemp('gmd-public-gateway-');
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: ordinaryChat);
    final library = ModelLibrary();
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final bytes = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(bytes);
    final events = <String>[];
    final io = _GatewayIO(events);
    final use = ModelUseRegistry(library);
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      useRegistry: use,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
      ),
      loadTimeout: const Duration(seconds: 3),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
      io: io,
    );
    await catalog.installOfficial(verifiedArchive: archive);
    final registry = withRegistry
        ? File('${root.path}/private/public_models.json')
        : null;
    final routes = PublicModelRoutes(
      library: library,
      runtimes: [engine],
      registryFile: registry,
    );
    await routes.load();
    final gateway = PublicGatewayServer(
      routes: routes,
      port: 0,
      heartbeatInterval: heartbeatInterval ?? const Duration(seconds: 15),
    );
    gateway.changes.listen((state) {
      if (state == PublicGatewayState.stopped) events.add('gateway-stopped');
    });
    return _GatewayFixture(
      root,
      library,
      asset,
      io,
      engine,
      catalog,
      routes,
      gateway,
      registry,
      events,
    );
  }

  Future<void> enableReady() async {
    await routes.enable(asset.id);
    await engine.start(asset.id);
    await gateway.start();
    io.textRequests = 0;
    io.textBodies.clear();
  }

  Future<void> drain() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (engine.runtimeInstances.isNotEmpty &&
        engine.runtimeInstances.single.activeRequests != 0) {
      if (DateTime.now().isAfter(deadline)) {
        fail('engine request permits were not released in time');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    gateway.close();
    routes.close();
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    for (final child in io.children) {
      await child.server.close(force: true);
    }
    await root.delete(recursive: true);
  }
}

class _GatewayIO implements EngineProcessIO {
  _GatewayIO(this.events);
  final List<String> events;
  int textRequests = 0;
  final textBodies = <Map>[];
  int textStatus = 200;
  Map<String, Object?> textUsage = {
    'prompt_tokens': 4,
    'completion_tokens': 2,
    'total_tokens': 6,
  };
  Future<void> Function(HttpResponse response, String alias, Map body)?
  streamResponse;
  final children = <_GatewayChild>[];

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    final child = _GatewayChild(server, events);
    children.add(child);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': arg('--alias'),
            'model_path': arg('--model'),
          }),
        );
      } else if (request.uri.path == '/v1/chat/completions') {
        textRequests++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        textBodies.add(body);
        expect(body['model'], arg('--alias'));
        if (body['stream'] == true) {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.bufferOutput = false;
          try {
            await streamResponse!(request.response, arg('--alias'), body);
            await request.response.close();
          } on HttpException {
            // A consumer may disconnect while this real server is still held.
          }
          return;
        }
        if (textStatus != 200) {
          request.response.statusCode = textStatus;
          request.response.write('upstream refused');
        } else {
          request.response.write(
            jsonEncode({
              'model': arg('--alias'),
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': 'Hello.'},
                  'finish_reason': 'stop',
                },
              ],
              'usage': textUsage,
            }),
          );
        }
      } else {
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        final questions = body['questions'] as Map;
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'answers': typedAnswers(questions),
            'usage': {'input_tokens': 10, 'output_tokens': 0},
          }),
        );
      }
      await request.response.close();
    });
    return child;
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
        '',
      );
    }
    final result = await Process.run(executable, arguments);
    return EngineCommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }
}

class _GatewayChild implements EngineChild {
  _GatewayChild(this.server, this.events) : pid = server.port;
  final HttpServer server;
  final List<String> events;
  final exited = Completer<int>();
  @override
  final int pid;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    events.add('engine-killed');
    server.close(force: true).then((_) {
      if (!exited.isCompleted) exited.complete(0);
    });
    return true;
  }
}
