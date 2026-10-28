import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/generation_seed.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

void main() {
  test(
    'native prefill capabilities are explicit, versioned and fail closed',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        Object? capabilities;
        server.listen((request) async {
          request.response.write(
            jsonEncode({
              'service_instance': 'service',
              'runtime_generation': 1,
              'prefill_capabilities': ?capabilities,
            }),
          );
          await request.response.close();
        });
        final client = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        expect(
          (await client.identity()).supportsPrefill(SplashOperationPath.chat),
          isFalse,
        );
        capabilities = {
          'schema': 'splash-prefill/1',
          'operation_tracking': true,
          'chat_zero_budget': true,
          'systemone_state': false,
        };
        final identity = await client.identity();
        expect(identity.supportsPrefill(SplashOperationPath.chat), isTrue);
        expect(
          identity.supportsPrefill(SplashOperationPath.systemone),
          isFalse,
        );
        capabilities = {
          'schema': 'splash-prefill/1',
          'operation_tracking': false,
          'chat_zero_budget': true,
          'systemone_state': true,
        };
        expect(
          (await client.identity()).supportsPrefill(SplashOperationPath.chat),
          isFalse,
        );
        capabilities = {
          'schema': 'splash-prefill/1',
          'operation_tracking': true,
          'chat_zero_budget': true,
        };
        expect(
          (await client.identity()).supportsPrefill(SplashOperationPath.chat),
          isFalse,
        );
        capabilities = {
          'schema': 'future',
          'operation_tracking': true,
          'chat_zero_budget': true,
          'systemone_state': true,
        };
        expect(
          (await client.identity()).supportsPrefill(
            SplashOperationPath.systemone,
          ),
          isFalse,
        );
      }, _NetworkBoundary());
    },
  );

  test(
    'cancelling a pending identity query never proves a runtime identity',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final received = Completer<void>();
        final release = Completer<void>();
        server.listen((request) async {
          received.complete();
          await release.future;
          try {
            await request.response.close();
          } catch (_) {}
        });
        final client = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final cancellation = DecisionCancellation();
        final pending = expectLater(
          client.identity(cancellation: cancellation),
          throwsA(isA<SplashOperationUnavailable>()),
        );
        try {
          await received.future.timeout(const Duration(seconds: 5));
          cancellation.cancel();
          await pending.timeout(const Duration(seconds: 5));
        } finally {
          release.complete();
        }
      }, _NetworkBoundary());
    },
  );

  test(
    'cancelling local submission keeps the native outcome unconfirmed',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final received = Completer<void>();
        final release = Completer<void>();
        server.listen((request) async {
          await request.drain<void>();
          received.complete();
          await release.future;
          try {
            await request.response.close();
          } catch (_) {}
        });
        final client = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final cancellation = DecisionCancellation();
        final pending = expectLater(
          client.submit(
            path: SplashOperationPath.chat,
            kind: SplashOperationKind.prefill,
            operationId: 'op',
            token: 'a' * 64,
            expected: const SplashOperationIdentity('service', 1),
            body: {'model': 'model', 'max_tokens': 0},
            cancellation: cancellation,
          ),
          throwsA(isA<SplashOperationUnavailable>()),
        );
        try {
          await received.future.timeout(const Duration(seconds: 5));
          cancellation.cancel();
          await pending.timeout(const Duration(seconds: 5));
        } finally {
          release.complete();
        }
      }, _NetworkBoundary());
    },
  );

  test(
    'systemone prefill rejects questions and dispatches an empty state request',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var calls = 0;
        server.listen((request) async {
          calls++;
          expect(request.uri.path, '/v1/systemone');
          expect(request.headers.value('x-splash-operation-kind'), 'prefill');
          await request.drain<void>();
          request.response.write('{"prefill_only":true,"answers":{}}');
          await request.response.close();
        });
        final client = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        const token =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        Future<SplashOperationSubmission> send(Map<String, Object?> body) =>
            client.submit(
              path: SplashOperationPath.systemone,
              kind: SplashOperationKind.prefill,
              operationId: 'op',
              token: token,
              expected: const SplashOperationIdentity('service', 1),
              body: body,
            );
        await expectLater(
          send({
            'model': 'm',
            'prefill_only': true,
            'questions': {'q': {}},
          }),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          send({'model': 'm', 'prefill_only': true, 'stream': 'false'}),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 0);
        final result = await send({
          'model': 'm',
          'prefill_only': true,
          'state': {'text': '测试'},
        });
        expect(result.statusCode, 200);
        expect(jsonDecode(result.body)['prefill_only'], isTrue);
        expect(calls, 1);
      }, _NetworkBoundary());
    },
  );

  test(
    'tracked submission sends bounded UTF-8 body and native identity',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        const token =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        var calls = 0;
        server.listen((request) async {
          calls++;
          expect(request.uri.path, '/v1/chat/completions');
          expect(request.headers.value('authorization'), 'Bearer engine-key');
          expect(request.headers.value('x-splash-operation-id'), 'op-1');
          expect(request.headers.value('x-splash-operation-token'), token);
          expect(
            request.headers.value('x-splash-service-instance'),
            'service-a',
          );
          expect(request.headers.value('x-splash-runtime-generation'), '7');
          expect(request.headers.value('x-splash-operation-kind'), 'prefill');
          final bytes = await request.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          expect(request.contentLength, bytes.length);
          expect(utf8.decode(bytes), contains('"seed":18446744073709551615'));
          expect(
            jsonDecode(utf8.decode(bytes))['messages'][0]['content'],
            '中文',
          );
          request.response.statusCode = 409;
          request.response.write('{"error":"conflict"}');
          await request.response.close();
        });
        final client = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          headers: {'Authorization': 'Bearer engine-key'},
        );
        final result = await client.submit(
          path: SplashOperationPath.chat,
          kind: SplashOperationKind.prefill,
          operationId: 'op-1',
          token: token,
          expected: const SplashOperationIdentity('service-a', 7),
          body: {
            'model': 'model',
            'max_tokens': 0,
            'seed': parseGenerationSeed('18446744073709551615'),
            'messages': [
              {'role': 'user', 'content': '中文'},
            ],
          },
        );
        expect(result.statusCode, 409);
        expect(result.body, '{"error":"conflict"}');
        expect(calls, 1);
        await expectLater(
          client.submit(
            path: SplashOperationPath.chat,
            kind: SplashOperationKind.prefill,
            operationId: 'op-2',
            token: token,
            expected: const SplashOperationIdentity('service-a', 7),
            body: {'model': 'model', 'max_tokens': 1},
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          client.submit(
            path: SplashOperationPath.chat,
            kind: SplashOperationKind.prefill,
            operationId: 'op-3',
            token: token,
            expected: const SplashOperationIdentity('service-a', 7),
            body: {
              'model': 'model',
              'max_tokens': null,
              'max_completion_tokens': 0,
            },
          ),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 1);
      }, _NetworkBoundary());
    },
  );

  test('control client binds native evidence to the expected service and generation', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      var released = false;
      var cancelCalls = 0;
      var acknowledgements = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/v1/splash/runtime') {
          request.response.write(
            jsonEncode({
              'service_instance': 'service-a',
              'runtime_generation': 7,
            }),
          );
        } else if (request.headers.value('authorization') !=
                'Bearer engine-key' ||
            request.headers.value('x-splash-operation-token') != token) {
          request.response.statusCode = 404;
        } else {
          if (request.method == 'POST') cancelCalls++;
          if (request.method == 'DELETE') {
            acknowledgements++;
            request.response.write(jsonEncode({'acknowledged': true}));
          } else {
            request.response.write(
              jsonEncode({
                'operation_id': 'op-1',
                'service_instance': 'service-a',
                'state': released ? 'cancelled' : 'cancel_requested',
                'terminal': released,
                'lease_released': released,
                'children': [
                  {
                    'question_id': 'first',
                    'native_request_id': 42,
                    'runtime_generation': 7,
                    'state': released ? 'cancelled' : 'running',
                    'lease_released': released,
                    if (released) ...{
                      'prompt_tokens': 100,
                      'completion_tokens': 0,
                      'matched_prompt_tokens': 72,
                      'deduplicated_tokens': 3,
                    },
                  },
                ],
              }),
            );
          }
        }
        await request.response.close();
      });
      final client = SplashOperationClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        headers: {'Authorization': 'Bearer engine-key'},
      );
      final identity = await client.identity();
      expect(identity.serviceInstance, 'service-a');
      expect(identity.runtimeGeneration, 7);
      final pending = await client.cancel(
        operationId: 'op-1',
        token: token,
        expected: identity,
      );
      expect(cancelCalls, 1);
      expect(pending.terminal, isFalse);
      expect(pending.leaseReleased, isFalse);
      await expectLater(
        client.acknowledge(snapshot: pending, token: token),
        throwsA(isA<SplashOperationUnavailable>()),
      );
      expect(acknowledgements, 0);
      released = true;
      final finished = await client.query(
        operationId: 'op-1',
        token: token,
        expected: identity,
      );
      expect(finished.terminal, isTrue);
      expect(finished.leaseReleased, isTrue);
      expect(finished.children.single.questionId, 'first');
      expect(finished.children.single.nativeRequestId, 42);
      expect(finished.children.single.matchedPromptTokens, 72);
      expect(finished.children.single.deduplicatedTokens, 3);
      expect(
        () => finished.requirePrefillEvidence(),
        throwsA(isA<SplashOperationUnavailable>()),
      );
      await client.acknowledge(snapshot: finished, token: token);
      expect(acknowledgements, 1);
      await expectLater(
        client.query(operationId: 'op-1', token: 'b' * 64, expected: identity),
        throwsA(isA<SplashOperationUnavailable>()),
      );
      await expectLater(
        client.query(
          operationId: 'op-1',
          token: token,
          expected: const SplashOperationIdentity('service-other', 7),
        ),
        throwsA(isA<SplashOperationUnavailable>()),
      );
      await expectLater(
        client.query(
          operationId: 'op-1',
          token: token,
          expected: const SplashOperationIdentity('service-a', 8),
        ),
        throwsA(isA<SplashOperationUnavailable>()),
      );
    }, _NetworkBoundary());
  });

  test(
    'missing, conflicting or incomplete state never proves release',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        Object? payload;
        server.listen((request) async {
          if (payload == null) {
            request.response.statusCode = 404;
          } else {
            request.response.write(jsonEncode(payload));
          }
          await request.response.close();
        });
        final client = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        const identity = SplashOperationIdentity('service-a', 1);
        const token =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        Future<SplashOperationSnapshot> query() =>
            client.query(operationId: 'op', token: token, expected: identity);
        await expectLater(query(), throwsA(isA<SplashOperationUnavailable>()));
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'unknown',
          'terminal': false,
          'lease_released': false,
          'children': [
            {'state': 'unknown', 'lease_released': false},
          ],
        };
        final unknown = await query();
        expect(unknown.terminal, isFalse);
        expect(unknown.leaseReleased, isFalse);
        expect(
          () => unknown.requirePrefillEvidence(),
          throwsA(isA<SplashOperationUnavailable>()),
        );
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'completed',
          'terminal': true,
          'lease_released': true,
          'children': <Object>[],
        };
        final noNative = await query();
        expect(
          () => noNative.requirePrefillEvidence(),
          throwsA(isA<SplashOperationUnavailable>()),
        );
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'completed',
          'terminal': true,
          'lease_released': true,
          'children': [
            {
              'state': 'length',
              'lease_released': true,
              'native_request_id': 12,
              'runtime_generation': 1,
              'prompt_tokens': 30,
              'completion_tokens': 0,
              'matched_prompt_tokens': 20,
            },
          ],
        };
        final evidence = (await query()).requirePrefillEvidence();
        expect(evidence.promptTokens, 30);
        expect(evidence.matchedPromptTokens, 20);
        expect(evidence.deduplicatedTokens, isNull);
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'completed',
          'terminal': true,
          'lease_released': true,
          'children': [
            {'state': 'running', 'lease_released': false},
          ],
        };
        await expectLater(query(), throwsA(isA<SplashOperationUnavailable>()));
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'completed',
          'terminal': true,
          'lease_released': true,
          'children': [
            {'state': 'running', 'lease_released': true},
          ],
        };
        await expectLater(query(), throwsA(isA<SplashOperationUnavailable>()));
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'completed',
          'terminal': true,
          'lease_released': true,
          'children': [
            {
              'state': 'length',
              'lease_released': true,
              'prompt_tokens': 10,
              'matched_prompt_tokens': 11,
            },
          ],
        };
        await expectLater(query(), throwsA(isA<SplashOperationUnavailable>()));
        payload = {
          'operation_id': 'op',
          'service_instance': 'service-a',
          'state': 'unknown',
          'terminal': true,
          'lease_released': true,
          'children': [],
        };
        await expectLater(query(), throwsA(isA<SplashOperationUnavailable>()));
        await expectLater(
          client.query(
            operationId: '../wrong',
            token: token,
            expected: identity,
          ),
          throwsA(isA<SplashOperationUnavailable>()),
        );
      }, _NetworkBoundary());
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
