import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/prefill_operation_id.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_control.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('HTTP status and cancellation protect credentials and native release', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      final routes = PublicModelRoutes(library: runtime.library, runtimes: []);
      final ledger = await PrefillOperationLedger.open(
        File('${runtime.root.path}/prefill-operations.json'),
        wallClock: () => 1000000,
      );
      final generation = ledger.publicGeneration('trusted-running-instance');
      var cancels = 0;
      var resolverFails = false;
      var cancelFails = false;
      final control = PublicPrefillControl(
        ledger: ledger,
        resolveCurrentGeneration: (_) async {
          if (resolverFails) throw StateError('private engine detail');
          return generation;
        },
        cancelNative: (id, token) async {
          cancels++;
          if (cancelFails) throw StateError('native cancellation unavailable');
        },
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillControl: control,
      );
      final client = HttpClient();
      const first =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const second =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const third =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      const fourth =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      String operationId(String token, [int issued = 1000000]) =>
          'gmd1.${sha256.convert(utf8.encode(generation))}.$issued.${PrefillOperationId.nonceForToken(token)}';
      Future<(int, Map)> request(
        String method,
        String id,
        String token, {
        bool cancel = false,
      }) async {
        final url = gateway.baseUrl!.resolve(
          '/api/v1/inference/requests/$id${cancel ? '/cancel' : ''}',
        );
        final request = await client.openUrl(method, url);
        request.headers.set('X-GMD-Operation-Token', token);
        if (method == 'POST') request.contentLength = 0;
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      try {
        await gateway.start();
        final firstId = operationId(first);
        await ledger.admit(
          operationId: firstId,
          token: first,
          model: 'model',
          owner: 'owner',
          generation: generation,
          cacheSalt: 'private-salt',
          request: {'text': 'private'},
          kind: PrefillOperationKind.prefill,
        );
        await ledger.bindNative(
          firstId,
          first,
          const SplashOperationIdentity('service', 1),
        );
        final status = await request('GET', firstId, first);
        expect(status.$1, 200);
        expect(status.$2['state'], 'running');
        expect(status.$2['runtime_generation'], generation);
        expect(status.$2.toString(), isNot(contains('private-salt')));
        final forbidden = await request('GET', firstId, second);
        expect(forbidden.$1, 403);
        expect(forbidden.$2['error']['code'], 'operation_forbidden');
        expect(forbidden.$2.toString(), isNot(contains('model')));
        final cancelled = await request('POST', firstId, first, cancel: true);
        expect(cancelled.$1, 202);
        expect(cancelled.$2['state'], 'cancel_requested');
        expect(cancelled.$2['lease_released'], isFalse);
        expect(cancels, 1);
        cancelFails = true;
        final pending = await request('POST', firstId, first, cancel: true);
        expect(pending.$1, 202);
        expect(pending.$2['state'], 'cancel_requested');
        expect(pending.$2['lease_released'], isFalse);
        final late = operationId(second);
        final stopped = await request('POST', late, second, cancel: true);
        expect(stopped.$1, 200);
        expect(stopped.$2['proof_scope'], 'identity_only');
        expect(stopped.$2['native_dispatch'], 'not_started');
        expect(stopped.$2['runtime_generation'], generation);
        expect(stopped.$2.containsKey('model'), isFalse);
        expect(stopped.$2.containsKey('cache_salt_sha256'), isFalse);
        final recovered = await request('GET', late, second);
        expect(recovered.$2['proof_scope'], 'identity_only');
        final queuedId = operationId(fourth, ledger.timeBasisMs);
        await ledger.admit(
          operationId: queuedId,
          token: fourth,
          model: 'model',
          owner: 'owner',
          generation: generation,
          cacheSalt: 'queued-scope',
          request: {'text': 'pending'},
          kind: PrefillOperationKind.prefill,
        );
        final cancelledBeforeDispatch = await request(
          'POST',
          queuedId,
          fourth,
          cancel: true,
        );
        expect(cancelledBeforeDispatch.$2['state'], 'cancelled');
        expect(cancelledBeforeDispatch.$2['terminal'], isTrue);
        expect(cancelledBeforeDispatch.$2['children'], isEmpty);
        final native = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        try {
          final completedId = operationId(third, ledger.timeBasisMs);
          await ledger.admit(
            operationId: completedId,
            token: third,
            model: 'model',
            owner: 'owner',
            generation: generation,
            cacheSalt: 'third-scope',
            request: {'text': 'private'},
            kind: PrefillOperationKind.prefill,
          );
          await ledger.bindNative(
            completedId,
            third,
            const SplashOperationIdentity('service', 1),
          );
          native.listen((incoming) async {
            incoming.response.write(
              jsonEncode({
                'operation_id': completedId,
                'service_instance': 'service',
                'state': 'completed',
                'terminal': true,
                'lease_released': true,
                'children': [
                  {
                    'question_id': null,
                    'native_request_id': 42,
                    'runtime_generation': 1,
                    'state': 'length',
                    'lease_released': true,
                    'prompt_tokens': 12,
                    'completion_tokens': 0,
                    'matched_prompt_tokens': 7,
                  },
                ],
              }),
            );
            await incoming.response.close();
          });
          final nativeClient = SplashOperationClient(
            endpoint: Uri.parse('http://127.0.0.1:${native.port}'),
          );
          final evidence = await nativeClient.query(
            operationId: completedId,
            token: third,
            expected: const SplashOperationIdentity('service', 1),
          );
          await ledger.recordTerminal(
            completedId,
            third,
            evidence,
            response: 'private result',
          );
          final completed = await request('GET', completedId, third);
          expect(completed.$2['state'], 'completed');
          expect(completed.$2['lease_released'], isTrue);
          expect(completed.$2['children'][0]['matched_prompt_tokens'], 7);
          expect(completed.$2.toString(), isNot(contains('private result')));
          expect(completed.$2.toString(), isNot(contains('service_instance')));
        } finally {
          await native.close(force: true);
        }
        resolverFails = true;
        final unavailable = await request(
          'GET',
          operationId('c' * 64),
          'c' * 64,
        );
        expect(unavailable.$1, 503);
        expect(
          unavailable.$2['error']['code'],
          'prefill_capability_unconfirmed',
        );
        expect(
          unavailable.$2.toString(),
          isNot(contains('private engine detail')),
        );
        await expectLater(
          ledger.admit(
            operationId: late,
            token: second,
            model: 'model',
            owner: 'owner',
            generation: generation,
            cacheSalt: 'salt',
            request: {'text': 'new'},
            kind: PrefillOperationKind.prefill,
          ),
          throwsA(isA<PrefillAdmissionNotAdmitted>()),
        );
      } finally {
        client.close(force: true);
        await gateway.stop();
        gateway.close();
        routes.close();
        await ledger.close();
        await runtime.close();
      }
    }, _NetworkBoundary());
  });
}

class _NetworkBoundary extends HttpOverrides {}
