import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test(
    'optional prefill setup failure does not prevent ordinary gateway start',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixture = await CouncilRuntime.create(modelCount: 1);
        final routes = PublicModelRoutes(
          library: fixture.library,
          runtimes: [],
        );
        final gateway = PublicGatewayServer(
          routes: routes,
          port: 0,
          prefillServiceFactory: () async =>
              throw StateError('optional setup failed'),
        );
        final client = HttpClient();
        try {
          await gateway.start();
          final request = await client.getUrl(
            gateway.baseUrl!.resolve('/v1/models'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          await response.drain<void>();
          final tracked = await client.postUrl(
            gateway.baseUrl!.resolve('/v1/chat/completions'),
          );
          tracked.headers.contentType = ContentType.json;
          tracked.headers.set('Idempotency-Key', 'gmd1.example');
          tracked.headers.set('X-GMD-Operation-Token', 'a' * 64);
          tracked.headers.set('X-GMD-Runtime-Generation', 'generation');
          tracked.write(
            jsonEncode({
              'model': 'missing',
              'messages': [
                {'role': 'user', 'content': 'A'},
              ],
              'max_tokens': 32,
            }),
          );
          final refusal = await tracked.close();
          expect(refusal.statusCode, 503);
          final body =
              jsonDecode(await utf8.decoder.bind(refusal).join()) as Map;
          expect(body['error']['code'], 'prefill_capability_unconfirmed');
          final ordinary = await client.postUrl(
            gateway.baseUrl!.resolve('/v1/chat/completions'),
          );
          ordinary.headers.contentType = ContentType.json;
          ordinary.headers.set('Idempotency-Key', 'ordinary-client-key');
          ordinary.write(
            jsonEncode({
              'model': 'missing',
              'messages': [
                {'role': 'user', 'content': 'A'},
              ],
              'max_tokens': 32,
            }),
          );
          final ordinaryReply = await ordinary.close();
          expect(ordinaryReply.statusCode, 404);
          await ordinaryReply.drain<void>();
        } finally {
          client.close(force: true);
          await gateway.stop();
          gateway.close();
          routes.close();
          await fixture.close();
        }
      }, _NetworkBoundary());
    },
  );

  test(
    'stopping during optional setup waits for cleanup and never starts late',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixture = await CouncilRuntime.create(modelCount: 1);
        final routes = PublicModelRoutes(
          library: fixture.library,
          runtimes: [],
        );
        final file = File('${fixture.root.path}/pending-prefill.json');
        final entered = Completer<void>();
        final release = Completer<void>();
        final gateway = PublicGatewayServer(
          routes: routes,
          port: 0,
          prefillServiceFactory: () async {
            final ledger = await PrefillOperationLedger.open(file);
            entered.complete();
            await release.future;
            return PublicPrefillService(
              ledger: ledger,
              resolve: (path, model) async => throw StateError('disabled'),
            );
          },
        );
        try {
          final starting = gateway.start().then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
          await entered.future.timeout(const Duration(seconds: 5));
          final stopping = gateway.stop();
          release.complete();
          await stopping.timeout(const Duration(seconds: 5));
          expect(await starting, isA<StateError>());
          expect(gateway.state, PublicGatewayState.stopped);
          expect(gateway.baseUrl, isNull);
          final reopened = await PrefillOperationLedger.open(file);
          await reopened.close();
        } finally {
          if (!release.isCompleted) release.complete();
          await gateway.stop();
          gateway.close();
          routes.close();
          await fixture.close();
        }
      }, _NetworkBoundary());
    },
  );

  test(
    'owned disabled prefill service closes its ledger without runtime access',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixture = await CouncilRuntime.create(modelCount: 1);
        final routes = PublicModelRoutes(
          library: fixture.library,
          runtimes: [],
        );
        final file = File('${fixture.root.path}/owned-prefill.json');
        var resolutions = 0;
        final gateway = PublicGatewayServer(
          routes: routes,
          port: 0,
          prefillServiceFactory: () async {
            final ledger = await PrefillOperationLedger.open(file);
            return PublicPrefillService(
              ledger: ledger,
              resolve: (path, model) async {
                resolutions++;
                throw StateError('must not resolve');
              },
            );
          },
        );
        final client = HttpClient();
        try {
          await gateway.start();
          final request = await client.getUrl(
            gateway.baseUrl!.resolve('/v1/models'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          await utf8.decoder.bind(response).join();
          expect(resolutions, 0);
          await gateway.stop();
          final reopened = await PrefillOperationLedger.open(file);
          await reopened.close();
        } finally {
          client.close(force: true);
          await gateway.stop();
          gateway.close();
          routes.close();
          await fixture.close();
        }
      }, _NetworkBoundary());
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
