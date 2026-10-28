import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/prefill_operation_id.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_request.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('invalid instance defaults are rejected before native binding', () async {
    final root = await Directory.systemTemp.createTemp('gmd-prefill-defaults-');
    addTearDown(() => root.delete(recursive: true));
    final ledger = await PrefillOperationLedger.open(
      File('${root.path}/ledger.json'),
      wallClock: () => 1000000,
    );
    final runtime = _FakeRuntime(
      ledger.publicGeneration('fixture-instance'),
      SplashOperationClient(endpoint: Uri.parse('http://127.0.0.1:9')),
    );
    runtime.defaultsOverride = GenerationConfiguration({
      'reasoning_budget_tokens': 1,
    });
    final service = PublicPrefillService(
      ledger: ledger,
      enabled: true,
      resolve: (path, model) async => runtime,
    );
    const token =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final id =
        'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
    final request = PublicPrefillRequest.parse(SplashOperationPath.chat, {
      'model': 'model',
      'cache_salt': 'scope',
      'messages': [
        {'role': 'user', 'content': 'A'},
      ],
      'max_tokens': 0,
    });
    try {
      expect(await service.registerRuntime(runtime), isTrue);
      await expectLater(
        service.submit(
          operationId: id,
          token: token,
          generation: runtime.generation,
          request: request,
        ),
        throwsFormatException,
      );
      final proof = await service.refuseUnadmitted(
        id,
        token,
        runtime.generation,
      );
      expect(proof.identityOnly, isTrue);
      expect(proof.nativeDispatchNotStarted, isTrue);
    } finally {
      await service.close();
      await ledger.close();
    }
  });

  test(
    'application-default prefill gate stays disabled without touching runtimes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-prefill-disabled-',
      );
      addTearDown(() => root.delete(recursive: true));
      final ledger = await PrefillOperationLedger.open(
        File('${root.path}/ledger.json'),
      );
      var resolutions = 0;
      final service = PublicPrefillService(
        ledger: ledger,
        resolve: (path, model) async {
          resolutions++;
          throw StateError('must not resolve');
        },
      );
      try {
        final capability = await service.capability(
          SplashOperationPath.chat,
          'model',
        );
        expect(capability['supported'], isFalse);
        final request = PublicPrefillRequest.parse(SplashOperationPath.chat, {
          'model': 'model',
          'cache_salt': 'scope',
          'messages': [
            {'role': 'user', 'content': 'A'},
          ],
          'max_tokens': 0,
        });
        await expectLater(
          service.submit(
            operationId: 'unused',
            token: 'a' * 64,
            generation: 'unused',
            request: request,
          ),
          throwsA(isA<StateError>()),
        );
        expect(resolutions, 0);
      } finally {
        await service.close();
        await ledger.close();
      }
    },
  );

  test('gateway shutdown cancels local I/O and leaves native state unknown', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await CouncilRuntime.create(modelCount: 1);
      final routes = PublicModelRoutes(library: fixture.library, runtimes: []);
      final ledger = await PrefillOperationLedger.open(
        File('${fixture.root.path}/shutdown.json'),
        wallClock: () => 1000000,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final runtime = _FakeRuntime(
        ledger.publicGeneration('fixture-instance'),
        SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        ),
      );
      final service = PublicPrefillService(
        enabled: true,
        ledger: ledger,
        resolve: (path, model) async => runtime,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillService: service,
      );
      final client = HttpClient();
      final entered = Completer<void>();
      final release = Completer<void>();
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final id =
          'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
      server.listen((request) async {
        if (request.uri.path == '/v1/splash/runtime') {
          request.response.write(
            jsonEncode({
              'service_instance': 'service',
              'runtime_generation': 1,
            }),
          );
        } else {
          await request.drain<void>();
          entered.complete();
          await release.future;
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      try {
        await gateway.start();
        final request = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('Idempotency-Key', id);
        request.headers.set('X-GMD-Operation-Token', token);
        request.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        request.write(
          jsonEncode({
            'model': 'public-model',
            'cache_salt': 'scope',
            'messages': [
              {'role': 'user', 'content': 'A'},
            ],
            'max_tokens': 0,
          }),
        );
        final pending = request.close().then<void>((response) async {
          await response.drain<void>();
        }, onError: (Object _) {});
        await entered.future.timeout(const Duration(seconds: 5));
        await gateway.stop().timeout(const Duration(seconds: 5));
        final state = await ledger.query(id, token);
        expect(state.state, PrefillOperationState.unknown);
        expect(state.leaseReleased, isFalse);
        await service.close();
        await expectLater(
          service.submit(
            operationId: id,
            token: token,
            generation: runtime.generation,
            request: PublicPrefillRequest.parse(SplashOperationPath.chat, {
              'model': 'public-model',
              'cache_salt': 'scope',
              'messages': [
                {'role': 'user', 'content': 'A'},
              ],
              'max_tokens': 0,
            }),
          ),
          throwsA(isA<StateError>()),
        );
        await pending;
      } finally {
        if (!release.isCompleted) release.complete();
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await ledger.close();
        await server.close(force: true);
        await fixture.close();
      }
    }, _NetworkBoundary());
  });

  test('capacity refusal distinguishes bound and identity-only proofs', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await CouncilRuntime.create(modelCount: 1);
      final routes = PublicModelRoutes(library: fixture.library, runtimes: []);
      final ledger = await PrefillOperationLedger.open(
        File('${fixture.root.path}/quota.json'),
        maxOperations: 2,
        maxPrefills: 1,
        maxRejections: 1,
        wallClock: () => 1000000,
      );
      final nativeServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final runtime = _FakeRuntime(
        ledger.publicGeneration('fixture-instance'),
        SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${nativeServer.port}'),
        ),
      );
      final service = PublicPrefillService(
        enabled: true,
        ledger: ledger,
        resolve: (path, model) async => runtime,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillService: service,
      );
      final client = HttpClient();
      const a =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const b =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const c =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      const d =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      String id(String token, int issued) =>
          'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.$issued.${PrefillOperationId.nonceForToken(token)}';
      Future<(int, Map)> reject(String token) async {
        final request = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('Idempotency-Key', id(token, 1000000));
        request.headers.set('X-GMD-Operation-Token', token);
        request.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        request.write(
          jsonEncode({
            'model': 'public-model',
            'cache_salt': token,
            'messages': [
              {'role': 'user', 'content': 'A'},
            ],
            'max_tokens': 0,
          }),
        );
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      try {
        await service.registerRuntime(runtime);
        await gateway.start();
        await ledger.admit(
          operationId: id(a, 1000000),
          token: a,
          model: 'public-model',
          owner: runtime.owner,
          generation: runtime.generation,
          cacheSalt: a,
          request: {'text': 'occupied'},
          kind: PrefillOperationKind.prefill,
        );
        final bound = await reject(b);
        expect(bound.$1, 503);
        expect(bound.$2['proof_scope'], 'bound');
        expect(bound.$2['native_dispatch'], 'not_started');
        expect(bound.$2['model'], 'public-model');
        expect(
          bound.$2['cache_salt_sha256'],
          sha256.convert(utf8.encode(b)).toString(),
        );
        final identity = await reject(c);
        expect(identity.$1, 503);
        expect(identity.$2['proof_scope'], 'identity_only');
        expect(identity.$2['native_dispatch'], 'not_started');
        expect(identity.$2['error']['code'], 'capacity_unavailable');
        expect(identity.$2.containsKey('model'), isFalse);
        expect(identity.$2.containsKey('cache_salt_sha256'), isFalse);
        final query = await client.getUrl(
          gateway.baseUrl!.resolve(
            '/api/v1/inference/requests/${id(c, 1000000)}',
          ),
        );
        query.headers.set('X-GMD-Operation-Token', c);
        final queryReply = await query.close();
        final queryBody =
            jsonDecode(await utf8.decoder.bind(queryReply).join()) as Map;
        expect(queryBody['proof_scope'], 'identity_only');
        expect(queryBody['error']['code'], 'not_admitted');
        final capability = await service.capability(
          SplashOperationPath.chat,
          'public-model',
        );
        expect(capability['supported'], isTrue);
        expect(capability['runtime_generation'], runtime.generation);
        expect(
          (capability['operation_policy'] as Map)['time_basis_ms'],
          greaterThan(1000000),
        );
        expect(
          (capability['operation_policy'] as Map)['past_window_ms'],
          600000,
        );
        final next = await ledger.admit(
          operationId: id(d, ledger.timeBasisMs),
          token: d,
          model: 'public-model',
          owner: runtime.owner,
          generation: runtime.generation,
          cacheSalt: d,
          request: {'text': 'consume'},
          kind: PrefillOperationKind.consume,
        );
        expect(next.created, isTrue);
      } finally {
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await ledger.close();
        await nativeServer.close(force: true);
        await fixture.close();
      }
    }, _NetworkBoundary());
  });

  test('cancel before POST fences the identity and permits a fresh consume', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await CouncilRuntime.create(modelCount: 1);
      final routes = PublicModelRoutes(library: fixture.library, runtimes: []);
      final ledger = await PrefillOperationLedger.open(
        File('${fixture.root.path}/fence.json'),
        wallClock: () => 1000000,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final native = SplashOperationClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final runtime = _FakeRuntime(
        ledger.publicGeneration('fixture-instance'),
        native,
      );
      final service = PublicPrefillService(
        enabled: true,
        ledger: ledger,
        resolve: (path, model) async => runtime,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillService: service,
      );
      final client = HttpClient();
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const invalidToken =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final id =
          'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
      try {
        expect(await service.registerRuntime(runtime), isTrue);
        await gateway.start();
        final invalidId =
            'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(invalidToken)}';
        final invalid = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        invalid.headers.contentType = ContentType.json;
        invalid.headers.set('Idempotency-Key', invalidId);
        invalid.headers.set('X-GMD-Operation-Token', invalidToken);
        invalid.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        invalid.write('{');
        final invalidReply = await invalid.close();
        final invalidBody =
            jsonDecode(await utf8.decoder.bind(invalidReply).join()) as Map;
        expect(invalidReply.statusCode, 400);
        expect(invalidBody['proof_scope'], 'identity_only');
        expect(invalidBody['native_dispatch'], 'not_started');
        final cancel = await client.postUrl(
          gateway.baseUrl!.resolve('/api/v1/inference/requests/$id/cancel'),
        );
        cancel.headers.set('X-GMD-Operation-Token', token);
        cancel.contentLength = 0;
        final cancelled = await cancel.close();
        final proof =
            jsonDecode(await utf8.decoder.bind(cancelled).join()) as Map;
        expect(cancelled.statusCode, 200);
        expect(proof['proof_scope'], 'identity_only');
        expect(proof['native_dispatch'], 'not_started');
        final late = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        late.headers.contentType = ContentType.json;
        late.headers.set('Idempotency-Key', id);
        late.headers.set('X-GMD-Operation-Token', token);
        late.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        late.write(
          jsonEncode({
            'model': 'public-model',
            'cache_salt': 'scope',
            'messages': [
              {'role': 'user', 'content': 'A'},
            ],
            'max_tokens': 0,
          }),
        );
        final rejected = await late.close().timeout(const Duration(seconds: 5));
        final rejectedBody =
            jsonDecode(await utf8.decoder.bind(rejected).join()) as Map;
        expect(rejected.statusCode, 409);
        expect(rejectedBody['proof_scope'], 'identity_only');
        expect(ledger.timeBasisMs, greaterThan(1000000));
        const nextToken =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final nextId =
            'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.${ledger.timeBasisMs}.${PrefillOperationId.nonceForToken(nextToken)}';
        final next = await ledger.admit(
          operationId: nextId,
          token: nextToken,
          model: 'public-model',
          owner: runtime.owner,
          generation: runtime.generation,
          cacheSalt: 'scope',
          request: {'text': 'A+B'},
          kind: PrefillOperationKind.consume,
        );
        expect(next.created, isTrue);
      } finally {
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await ledger.close();
        await server.close(force: true);
        await fixture.close();
      }
    }, _NetworkBoundary());
  });

  test('cancel retries until the native operation exists and seals late output', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await CouncilRuntime.create(modelCount: 1);
      final routes = PublicModelRoutes(library: fixture.library, runtimes: []);
      final ledger = await PrefillOperationLedger.open(
        File('${fixture.root.path}/cancel.json'),
        wallClock: () => 1000000,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final native = SplashOperationClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final runtime = _FakeRuntime(
        ledger.publicGeneration('fixture-instance'),
        native,
      );
      final service = PublicPrefillService(
        enabled: true,
        ledger: ledger,
        resolve: (path, model) async => runtime,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillControl: service.control,
        prefillService: service,
      );
      final client = HttpClient();
      final entered = Completer<void>();
      final cancelled = Completer<void>();
      final release = Completer<void>();
      var cancelCalls = 0;
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const busyToken =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final id =
          'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/v1/splash/runtime') {
          request.response.write(
            jsonEncode({
              'service_instance': 'service',
              'runtime_generation': 1,
            }),
          );
        } else if (request.uri.path == '/v1/chat/completions') {
          await request.drain<void>();
          entered.complete();
          await release.future;
          request.response.write(
            jsonEncode({
              'object': 'chat.completion',
              'model': 'native-response',
              'choices': [
                {
                  'index': 0,
                  'finish_reason': 'length',
                  'message': {'role': 'assistant', 'content': null},
                },
              ],
              'usage': {
                'prompt_tokens': 12,
                'completion_tokens': 0,
                'total_tokens': 12,
              },
            }),
          );
        } else if (request.uri.path.endsWith('/cancel')) {
          cancelCalls++;
          if (cancelCalls == 1) {
            request.response.statusCode = 404;
            request.response.write('{}');
          } else {
            if (!cancelled.isCompleted) cancelled.complete();
            request.response.write(
              jsonEncode({
                'operation_id': id,
                'service_instance': 'service',
                'state': 'cancel_requested',
                'terminal': false,
                'lease_released': false,
                'children': [],
              }),
            );
          }
        } else {
          request.response.write(
            jsonEncode({
              'operation_id': id,
              'service_instance': 'service',
              'state': 'cancelled',
              'terminal': true,
              'lease_released': true,
              'children': [
                {
                  'question_id': null,
                  'native_request_id': 1,
                  'runtime_generation': 1,
                  'state': 'cancelled',
                  'lease_released': true,
                  'prompt_tokens': 12,
                  'completion_tokens': 0,
                },
              ],
            }),
          );
        }
        await request.response.close();
      });
      Future<(int, Map)> submit() async {
        final req = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        req.headers.contentType = ContentType.json;
        req.headers.set('Idempotency-Key', id);
        req.headers.set('X-GMD-Operation-Token', token);
        req.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        req.write(
          jsonEncode({
            'model': 'public-model',
            'cache_salt': 'scope',
            'messages': [
              {'role': 'user', 'content': 'A'},
            ],
            'max_tokens': 0,
          }),
        );
        final response = await req.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      try {
        await gateway.start();
        final pending = submit();
        await entered.future.timeout(const Duration(seconds: 5));
        final busyId =
            'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(busyToken)}';
        final busy = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        busy.headers.contentType = ContentType.json;
        busy.headers.set('Idempotency-Key', busyId);
        busy.headers.set('X-GMD-Operation-Token', busyToken);
        busy.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        busy.write(
          jsonEncode({
            'model': 'another-alias',
            'cache_salt': 'scope',
            'messages': [
              {'role': 'user', 'content': 'A+B'},
            ],
            'max_tokens': 32,
          }),
        );
        final busyResponse = await busy.close();
        final busyBody =
            jsonDecode(await utf8.decoder.bind(busyResponse).join()) as Map;
        expect(busyResponse.statusCode, 409);
        expect(busyBody['proof_scope'], 'identity_only');
        expect(busyBody['error']['code'], 'prefill_context_busy');
        final req = await client.postUrl(
          gateway.baseUrl!.resolve('/api/v1/inference/requests/$id/cancel'),
        );
        req.headers.set('X-GMD-Operation-Token', token);
        req.contentLength = 0;
        final cancelResponse = await req.close();
        final cancelBody =
            jsonDecode(await utf8.decoder.bind(cancelResponse).join()) as Map;
        expect(cancelResponse.statusCode, 202);
        expect(cancelBody['lease_released'], isFalse);
        await cancelled.future.timeout(const Duration(seconds: 5));
        expect(cancelCalls, greaterThanOrEqualTo(2));
        release.complete();
        final finalResult = await pending;
        expect(finalResult.$1, 409);
        expect(finalResult.$2['state'], 'cancelled');
        expect(finalResult.$2['lease_released'], isTrue);
        expect(finalResult.$2.containsKey('prefill'), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await ledger.close();
        await server.close(force: true);
        await fixture.close();
      }
    }, _NetworkBoundary());
  });

  test('tracked HTTP prefill, consume and replay use one native operation each', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await CouncilRuntime.create(modelCount: 1);
      final routes = PublicModelRoutes(library: fixture.library, runtimes: []);
      final ledger = await PrefillOperationLedger.open(
        File('${fixture.root.path}/prefill.json'),
        wallClock: () => 1000000,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final native = SplashOperationClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final runtime = _FakeRuntime(
        ledger.publicGeneration('fixture-instance'),
        native,
      );
      var available = true;
      final service = PublicPrefillService(
        enabled: true,
        ledger: ledger,
        resolve: (path, model) async {
          if (!available) throw StateError('runtime unavailable');
          return runtime;
        },
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillControl: service.control,
        prefillService: service,
      );
      final client = HttpClient();
      final jobs = <String, Map<String, Object?>>{};
      var submissions = 0;
      var failNextStatus = false;
      var loseNextReply = false;
      var corruptNextReply = false;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/v1/splash/runtime') {
          request.response.write(
            jsonEncode({
              'service_instance': 'service',
              'runtime_generation': 1,
            }),
          );
        } else if (request.uri.path == '/v1/chat/completions') {
          submissions++;
          final id = request.headers.value('x-splash-operation-id')!;
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final zero = body['max_tokens'] == 0;
          jobs[id] = {'zero': zero};
          final corrupt = corruptNextReply;
          corruptNextReply = false;
          if (loseNextReply) {
            loseNextReply = false;
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
            return;
          }
          request.response.write(
            jsonEncode({
              'object': 'chat.completion',
              'model': 'native-response',
              'choices': [
                {
                  'index': 0,
                  'finish_reason': zero ? 'length' : 'stop',
                  'message': {
                    'role': 'assistant',
                    'content': zero ? null : '回答',
                  },
                },
              ],
              'usage': {
                'prompt_tokens': 12,
                'completion_tokens': corrupt
                    ? 1
                    : zero
                    ? 0
                    : 2,
                'total_tokens': corrupt
                    ? 13
                    : zero
                    ? 12
                    : 14,
              },
            }),
          );
        } else if (request.uri.path == '/v1/systemone') {
          submissions++;
          final id = request.headers.value('x-splash-operation-id')!;
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final zero = body['prefill_only'] == true;
          jobs[id] = {'zero': zero, 'decision': true};
          request.response.write(
            jsonEncode({
              'model': 'native-response',
              'usage': {'input_tokens': 12, 'output_tokens': 0},
              'answers': zero
                  ? {}
                  : {
                      'q': {
                        'type': 'choice',
                        'choice': 'a',
                        'confidence': 0.6,
                        'probabilities': {'a': 0.6, 'b': 0.4},
                      },
                    },
              if (zero) 'prefill_only': true,
            }),
          );
        } else if (request.uri.path.startsWith('/v1/splash/operations/')) {
          final id = request.uri.pathSegments.last;
          final job = jobs[id];
          if (job == null || failNextStatus) {
            failNextStatus = false;
            request.response.statusCode = 404;
            request.response.write('{}');
          } else {
            final zero = job['zero'] == true;
            final decision = job['decision'] == true;
            request.response.write(
              jsonEncode({
                'operation_id': id,
                'service_instance': 'service',
                'state': 'completed',
                'terminal': true,
                'lease_released': true,
                'children': [
                  {
                    'question_id': decision && !zero ? 'q' : null,
                    'native_request_id': submissions,
                    'runtime_generation': 1,
                    'state': zero ? 'length' : 'stop',
                    'lease_released': true,
                    'prompt_tokens': 12,
                    'completion_tokens': zero || decision ? 0 : 2,
                    'matched_prompt_tokens': 4,
                  },
                ],
              }),
            );
          }
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      const tokenA =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const tokenB =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const tokenC =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      const tokenD =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      const tokenE =
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      const tokenF =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
      const tokenG =
          '1111111111111111111111111111111111111111111111111111111111111111';
      const tokenH =
          '2222222222222222222222222222222222222222222222222222222222222222';
      const tokenI =
          '3333333333333333333333333333333333333333333333333333333333333333';
      String id(String token) =>
          'gmd1.${sha256.convert(utf8.encode(runtime.generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
      Future<(int, Map)> post(
        String token,
        int budget, {
        String? operationId,
      }) async {
        final req = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        req.headers.contentType = ContentType.json;
        req.headers.set('Idempotency-Key', operationId ?? id(token));
        req.headers.set('X-GMD-Operation-Token', token);
        req.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        req.write(
          jsonEncode({
            'model': 'public-model',
            'cache_salt': 'same-scope',
            'messages': [
              {'role': 'user', 'content': '累计材料'},
            ],
            'max_tokens': budget,
          }),
        );
        final response = await req.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      Future<(int, Map)> postDecision(
        String token, {
        required bool prefill,
      }) async {
        final req = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/systemone'),
        );
        req.headers.contentType = ContentType.json;
        req.headers.set('Idempotency-Key', id(token));
        req.headers.set('X-GMD-Operation-Token', token);
        req.headers.set('X-GMD-Runtime-Generation', runtime.generation);
        req.write(
          jsonEncode({
            'model': 'public-model',
            'cache_salt': 'decision-scope',
            'state': {'text': '累计材料'},
            'prefill_only': prefill,
            if (!prefill)
              'questions': {
                'q': {
                  'type': 'choice',
                  'instructions': '选择',
                  'criteria': {'a': 'A', 'b': 'B'},
                },
              },
          }),
        );
        final response = await req.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      try {
        await gateway.start();
        final first = await post(tokenA, 0);
        expect(first.$1, 200);
        expect(first.$2['choices'], isEmpty);
        expect(first.$2['prefill']['lease_released'], isTrue);
        available = false;
        final replay = await post(tokenA, 0);
        expect(replay.$1, 200);
        expect(replay.$2, first.$2);
        expect(submissions, 1);
        expect((await post(tokenA, 32)).$1, 409);
        expect((await post(tokenB, 0, operationId: id(tokenA))).$1, 403);
        expect(submissions, 1);
        available = true;
        final finalResult = await post(tokenB, 32);
        expect(finalResult.$1, 200);
        expect(finalResult.$2['choices'][0]['message']['content'], '回答');
        expect(
          finalResult.$2['cache']['children'][0]['matched_prompt_tokens'],
          4,
        );
        expect(submissions, 2);
        final decisionPrefill = await postDecision(tokenD, prefill: true);
        expect(decisionPrefill.$1, 200);
        expect(decisionPrefill.$2['object'], 'systemone.prefill');
        expect(decisionPrefill.$2.containsKey('answers'), isFalse);
        final decisionFinal = await postDecision(tokenE, prefill: false);
        expect(decisionFinal.$1, 200);
        expect(decisionFinal.$2['answers']['q']['choice'], 'a');
        expect(decisionFinal.$2['cache']['children'][0]['question_id'], 'q');
        expect(submissions, 4);
        failNextStatus = true;
        final temporarilyUnknown = await post(tokenF, 0);
        expect(temporarilyUnknown.$1, 202);
        expect(temporarilyUnknown.$2['state'], 'unknown');
        final statusRequest = await client.getUrl(
          gateway.baseUrl!.resolve('/api/v1/inference/requests/${id(tokenF)}'),
        );
        statusRequest.headers.set('X-GMD-Operation-Token', tokenF);
        final statusResponse = await statusRequest.close();
        final recovered =
            jsonDecode(await utf8.decoder.bind(statusResponse).join()) as Map;
        expect(recovered['state'], 'completed');
        expect(recovered['lease_released'], isTrue);
        expect((await post(tokenF, 0)).$1, 200);
        expect(submissions, 5);
        failNextStatus = true;
        expect((await post(tokenG, 0)).$2['state'], 'unknown');
        final cancelUnknown = await client.postUrl(
          gateway.baseUrl!.resolve(
            '/api/v1/inference/requests/${id(tokenG)}/cancel',
          ),
        );
        cancelUnknown.headers.set('X-GMD-Operation-Token', tokenG);
        cancelUnknown.contentLength = 0;
        final cancelUnknownResponse = await cancelUnknown.close();
        final cancelUnknownBody = jsonDecode(
          await utf8.decoder.bind(cancelUnknownResponse).join(),
        ) as Map;
        expect(cancelUnknownResponse.statusCode, 202);
        expect(cancelUnknownBody['cancel_requested'], isTrue);
        expect(cancelUnknownBody['lease_released'], isFalse);
        final recoveredCancelRequest = await client.getUrl(
          gateway.baseUrl!.resolve('/api/v1/inference/requests/${id(tokenG)}'),
        );
        recoveredCancelRequest.headers.set('X-GMD-Operation-Token', tokenG);
        final recoveredCancelResponse = await recoveredCancelRequest.close();
        final recoveredCancel = jsonDecode(
          await utf8.decoder.bind(recoveredCancelResponse).join(),
        ) as Map;
        expect(recoveredCancel['state'], 'cancelled');
        expect(recoveredCancel['lease_released'], isTrue);
        expect((await post(tokenG, 0)).$1, 409);
        expect(submissions, 6);
        loseNextReply = true;
        final lostReply = await post(tokenH, 0);
        expect(lostReply.$1, 202);
        expect(lostReply.$2['state'], 'unknown');
        final lostStatus = await client.getUrl(
          gateway.baseUrl!.resolve('/api/v1/inference/requests/${id(tokenH)}'),
        );
        lostStatus.headers.set('X-GMD-Operation-Token', tokenH);
        final recoveredLost = await lostStatus.close();
        final recoveredLostBody =
            jsonDecode(await utf8.decoder.bind(recoveredLost).join()) as Map;
        expect(recoveredLostBody['state'], 'failed');
        expect(recoveredLostBody['lease_released'], isTrue);
        expect(recoveredLostBody['error']['code'], 'result_unavailable');
        expect((await post(tokenH, 0)).$1, 409);
        expect(submissions, 7);
        corruptNextReply = true;
        final invalid = await post(tokenI, 0);
        expect(invalid.$1, 202);
        final invalidStatus = await client.getUrl(
          gateway.baseUrl!.resolve('/api/v1/inference/requests/${id(tokenI)}'),
        );
        invalidStatus.headers.set('X-GMD-Operation-Token', tokenI);
        final invalidResponse = await invalidStatus.close();
        final invalidBody =
            jsonDecode(await utf8.decoder.bind(invalidResponse).join()) as Map;
        expect(invalidBody['state'], 'failed');
        expect(invalidBody['lease_released'], isTrue);
        expect(invalidBody['error']['code'], 'invalid_response');
        expect(submissions, 8);
        runtime.failAfterWork = true;
        final unconfirmed = await post(tokenC, 0);
        expect(unconfirmed.$1, 202);
        expect(unconfirmed.$2['state'], 'unknown');
        expect(unconfirmed.$2['lease_released'], isFalse);
        expect(submissions, 9);
      } finally {
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await ledger.close();
        await server.close(force: true);
        await fixture.close();
      }
    }, _NetworkBoundary());
  });
}

class _FakeRuntime implements PublicPrefillRuntime {
  _FakeRuntime(this.generation, this.client);
  @override
  final String generation;
  final SplashOperationClient client;
  bool failAfterWork = false;
  bool active = true;
  GenerationConfiguration? defaultsOverride;
  @override
  String get owner => 'fixture-owner';
  @override
  String get nativeModel => 'native-request';
  @override
  GenerationConfiguration get defaults =>
      defaultsOverride ?? const GenerationConfiguration.empty();
  @override
  bool supportsPrefill(SplashOperationPath path) => true;
  @override
  Future<bool> isCurrent() async => active;
  @override
  Future<T> withClient<T>(
    Future<T> Function(
      SplashOperationClient client,
      String nativeModel,
      String responseModel,
      DecisionCancellation cancellation,
    )
    work, {
    DecisionCancellation? cancellation,
  }) async {
    final result = await work(
      client,
      'native-request',
      'native-response',
      cancellation ?? DecisionCancellation(),
    );
    if (failAfterWork) throw StateError('identity changed');
    return result;
  }
}

class _NetworkBoundary extends HttpOverrides {}
