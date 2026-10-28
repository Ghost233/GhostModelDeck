import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/prefill_operation_id.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';
import 'package:ghost_model_deck/public_prefill_route.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import 'splash_engine_test.dart' as fixture;

void main() {
  test('old Splash without prefill endpoint keeps ordinary salt calls usable', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final environment = await fixture.SplashRuntimeFixture.create();
      environment.io.runtimeEndpointMissing = true;
      environment.io.monitorStatus = {
        'maximum_context_tokens': 8192,
        'http': {
          'requests': {'capacity': 1},
        },
      };
      final engine = environment.engine();
      final ledger = await PrefillOperationLedger.open(
        File('${environment.root.path}/old-ledger.json'),
        wallClock: () => 1000000,
      );
      await engine.bindModel(environment.asset.id, environment.assembly);
      final run = await engine.startRuntime(environment.asset.id);
      final routes = PublicModelRoutes(
        library: environment.library,
        runtimes: [engine],
        instanceIds: {run.id},
      );
      await routes.enable(environment.asset.id);
      final model = routes.publicIdFor(environment.asset.id);
      final resolver = PublicPrefillRouteResolver(
        routes: routes,
        ledger: ledger,
      );
      final service = PublicPrefillService(
        ledger: ledger,
        enabled: true,
        resolve: resolver.resolve,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillService: service,
      );
      final client = HttpClient();
      Future<int> ordinary() async {
        final request = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'model': model,
            'cache_salt': 'same',
            'max_tokens': 32,
            'messages': [
              {'role': 'user', 'content': 'hello'},
            ],
          }),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        await gateway.start();
        final discovery = await client.getUrl(
          gateway.baseUrl!.resolve('/api/v1/models'),
        );
        final discoveryResponse = await discovery.close();
        final models =
            (jsonDecode(await utf8.decoder.bind(discoveryResponse).join())
                    as Map)['models']
                as List;
        expect(models.single['capabilities']['prefill']['supported'], isFalse);
        expect(await ordinary(), 200);
        expect(await ordinary(), 200);
        environment.io.runtimeEndpointMissing = false;
        environment.io.prefillCapabilities = {
          'schema': 'splash-prefill/1',
          'operation_tracking': true,
          'chat_zero_budget': false,
          'systemone_state': false,
        };
        expect(await ordinary(), 200);
        expect(await ordinary(), 200);
        const token =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final generation = ledger.publicGeneration('prior-tracked');
        final id =
            'gmd1.${sha256.convert(utf8.encode(generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
        expect(
          (await ledger.admit(
            operationId: id,
            token: token,
            model: model,
            owner: SplashPublicPrefillRuntime.ownerFor(run),
            generation: generation,
            cacheSalt: 'same',
            request: {'text': 'A'},
            kind: PrefillOperationKind.prefill,
          )).created,
          isTrue,
        );
        expect(await ordinary(), 409);
      } finally {
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await engine.shutdown();
        await engine.close();
        await ledger.close();
        await environment.close();
      }
    }, _NetworkBoundary());
  });

  test(
    'disabled prefill leaves ordinary explicit-salt Splash requests unchanged',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final environment = await fixture.SplashRuntimeFixture.create();
        final engine = environment.engine();
        final ledger = await PrefillOperationLedger.open(
          File('${environment.root.path}/disabled-ledger.json'),
        );
        await engine.bindModel(environment.asset.id, environment.assembly);
        final run = await engine.startRuntime(environment.asset.id);
        final routes = PublicModelRoutes(
          library: environment.library,
          runtimes: [engine],
          instanceIds: {run.id},
        );
        await routes.enable(environment.asset.id);
        var resolutions = 0;
        final service = PublicPrefillService(
          ledger: ledger,
          resolve: (path, model) async {
            resolutions++;
            throw StateError('disabled service must not resolve');
          },
        );
        final gateway = PublicGatewayServer(
          routes: routes,
          port: 0,
          prefillService: service,
        );
        final client = HttpClient();
        try {
          await gateway.start();
          final request = await client.postUrl(
            gateway.baseUrl!.resolve('/v1/chat/completions'),
          );
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'model': routes.publicIdFor(environment.asset.id),
              'cache_salt': 'ordinary-scope',
              'max_tokens': 32,
              'messages': [
                {'role': 'user', 'content': 'hello'},
              ],
            }),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          await response.drain<void>();
          expect(resolutions, 0);
        } finally {
          client.close(force: true);
          await gateway.stop();
          await service.close();
          gateway.close();
          routes.close();
          await engine.shutdown();
          await engine.close();
          await ledger.close();
          await environment.close();
        }
      }, _NetworkBoundary());
    },
  );

  test('ordinary and tracked calls share only the same runtime and explicit salt', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final environment = await fixture.SplashRuntimeFixture.create();
      environment.io.prefillCapabilities = {
        'schema': 'splash-prefill/1',
        'operation_tracking': true,
        'chat_zero_budget': true,
        'systemone_state': false,
      };
      environment.io.monitorStatus = {
        'maximum_context_tokens': 8192,
        'http': {
          'requests': {'capacity': 1},
        },
      };
      final engine = environment.engine();
      final ledger = await PrefillOperationLedger.open(
        File('${environment.root.path}/ledger.json'),
        wallClock: () => 1000000,
      );
      await engine.bindModel(environment.asset.id, environment.assembly);
      final run = await engine.startRuntime(environment.asset.id);
      final target = await SplashPublicPrefillRuntime.create(
        engine: engine,
        instance: run,
        ledger: ledger,
      );
      final routes = PublicModelRoutes(
        library: environment.library,
        runtimes: [engine],
        instanceIds: {run.id},
      );
      await routes.enable(environment.asset.id);
      final publicName = routes.publicIdFor(environment.asset.id);
      final resolver = PublicPrefillRouteResolver(
        routes: routes,
        ledger: ledger,
      );
      final resolved = await resolver.resolve(
        SplashOperationPath.chat,
        publicName,
      );
      expect(resolved.generation, target.generation);
      expect(resolved.owner, target.owner);
      final service = PublicPrefillService(
        enabled: true,
        ledger: ledger,
        resolve: resolver.resolve,
      );
      final gateway = PublicGatewayServer(
        routes: routes,
        port: 0,
        prefillControl: service.control,
        prefillService: service,
      );
      final client = HttpClient();
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final id =
          'gmd1.${sha256.convert(utf8.encode(target.generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
      Future<(int, Map)> ordinary(String? salt, String text) async {
        final request = await client.postUrl(
          gateway.baseUrl!.resolve('/v1/chat/completions'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'model': publicName,
            'cache_salt': ?salt,
            'max_tokens': 32,
            'messages': [
              {'role': 'user', 'content': text},
            ],
          }),
        );
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      Future<PrefillAdmission> tracked() => ledger.admit(
        operationId: id,
        token: token,
        model: publicName,
        owner: target.owner,
        generation: target.generation,
        cacheSalt: 'same',
        request: {'text': 'tracked'},
        kind: PrefillOperationKind.prefill,
      );
      try {
        await gateway.start();
        final discovery = await client.getUrl(
          gateway.baseUrl!.resolve('/api/v1/models'),
        );
        final discoveryResponse = await discovery.close();
        final models =
            (jsonDecode(await utf8.decoder.bind(discoveryResponse).join())
                    as Map)['models']
                as List;
        final capability = models.single['capabilities']['prefill'] as Map;
        expect(capability['supported'], isTrue);
        expect(capability['mode'], 'chat_max_tokens_zero');
        expect(capability['runtime_generation'], target.generation);
        final pending = ordinary('same', 'hold');
        await environment.io.holdReached.future.timeout(
          const Duration(seconds: 5),
        );
        await expectLater(tracked(), throwsA(isA<PrefillCacheBusy>()));
        expect((await ordinary('different', 'hello')).$1, 200);
        environment.io.releaseHeld.complete();
        expect((await pending).$1, 200);
        expect((await tracked()).created, isTrue);
        expect((await ordinary('same', 'hello')).$1, 409);
        expect((await ordinary('different', 'hello')).$1, 200);
        expect((await ordinary(null, 'hello')).$1, 200);
        environment.io.emptyText = true;
        expect((await ordinary('unconfirmed', 'hello')).$1, 502);
        const failedToken =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final failedId =
            'gmd1.${sha256.convert(utf8.encode(target.generation))}.1000000.${PrefillOperationId.nonceForToken(failedToken)}';
        await expectLater(
          ledger.admit(
            operationId: failedId,
            token: failedToken,
            model: publicName,
            owner: target.owner,
            generation: target.generation,
            cacheSalt: 'unconfirmed',
            request: {'text': 'tracked'},
            kind: PrefillOperationKind.prefill,
          ),
          throwsA(isA<PrefillCacheBusy>()),
        );
      } finally {
        if (!environment.io.releaseHeld.isCompleted) {
          environment.io.releaseHeld.complete();
        }
        client.close(force: true);
        await gateway.stop();
        await service.close();
        gateway.close();
        routes.close();
        await engine.shutdown();
        await engine.close();
        await ledger.close();
        await environment.close();
      }
    }, _NetworkBoundary());
  });
}

class _NetworkBoundary extends HttpOverrides {}
