import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';

import 'splash_engine_test.dart' as fixture;

void main() {
  test('public generation binds the actual Splash service and run', () async {
    final environment = await fixture.SplashRuntimeFixture.create();
    addTearDown(environment.close);
    final engine = environment.engine();
    addTearDown(engine.close);
    final ledger = await PrefillOperationLedger.open(
      File('${environment.root.path}/prefill.json'),
    );
    addTearDown(ledger.close);
    await engine.bindModel(environment.asset.id, environment.assembly);
    try {
      final run = await engine.startRuntime(environment.asset.id);
      final target = await SplashPublicPrefillRuntime.create(
        engine: engine,
        instance: run,
        ledger: ledger,
      );
      expect(target.supportsPrefill(SplashOperationPath.chat), isFalse);
      expect(await target.isCurrent(), isTrue);
      expect(
        target.generation,
        matches(RegExp(r'^gmd1b-[0-9a-f]{32}-[0-9a-f]{64}$')),
      );
      expect(target.owner, isNotEmpty);
      final changedDefaults = await SplashPublicPrefillRuntime.create(
        engine: engine,
        instance: run,
        ledger: ledger,
        defaults: GenerationConfiguration({'temperature': 0.5}),
      );
      expect(changedDefaults.generation, isNot(target.generation));
      expect(changedDefaults.owner, target.owner);
      expect(
        await target.withClient((
          client,
          nativeModel,
          responseModel,
          cancellation,
        ) async {
          final identity = await client.identity(cancellation: cancellation);
          expect(identity.runtimeGeneration, 1);
          return nativeModel;
        }),
        run.id,
      );
      environment.io.prefillCapabilities = {
        'schema': 'splash-prefill/1',
        'operation_tracking': true,
        'chat_zero_budget': true,
        'systemone_state': false,
      };
      expect(await target.isCurrent(), isFalse);
      final enabled = await SplashPublicPrefillRuntime.create(
        engine: engine,
        instance: run,
        ledger: ledger,
      );
      expect(enabled.supportsPrefill(SplashOperationPath.chat), isTrue);
      expect(enabled.supportsPrefill(SplashOperationPath.systemone), isFalse);
      expect(enabled.generation, isNot(target.generation));
      expect(await enabled.isCurrent(), isTrue);
      environment.io.transportRestarts = 1;
      expect(await enabled.isCurrent(), isFalse);
    } finally {
      await engine.shutdown();
    }
  });

  test(
    'tracked operation owns the ready Splash instance and its permit',
    () async {
      final environment = await fixture.SplashRuntimeFixture.create();
      addTearDown(environment.close);
      final engine = environment.engine();
      addTearDown(engine.close);
      await engine.bindModel(environment.asset.id, environment.assembly);
      try {
        final run = await engine.startRuntime(environment.asset.id);
        var called = false;
        final result = await engine.withTrackedClient(
          run.id,
          expectedGeneration: run.generation,
          work: (client, nativeModel, responseModel, cancellation) async {
            called = true;
            expect(nativeModel, run.id);
            expect(responseModel, isNotEmpty);
            expect(cancellation.isCancelled, isFalse);
            expect(engine.runtimeInstances.single.activeRequests, 1);
            expect(client.endpoint, engine.endpointFor(run.id));
            return 'ok';
          },
        );
        expect(result, 'ok');
        expect(called, isTrue);
        expect(engine.runtimeInstances.single.activeRequests, 0);
        called = false;
        await expectLater(
          engine.withTrackedClient(
            run.id,
            expectedGeneration: run.generation + 1,
            work: (client, nativeModel, responseModel, cancellation) async {
              called = true;
            },
          ),
          throwsA(isA<SplashRequestException>()),
        );
        expect(called, isFalse);
        final cancellation = DecisionCancellation();
        final entered = Completer<void>();
        final pending = expectLater(
          engine.withTrackedClient(
            run.id,
            expectedGeneration: run.generation,
            cancellation: cancellation,
            work: (client, nativeModel, responseModel, requested) async {
              entered.complete();
              await requested.whenCancelled;
              throw const SplashOperationUnavailable(
                'native outcome unconfirmed',
              );
            },
          ),
          throwsA(isA<SplashOperationUnavailable>()),
        );
        await entered.future;
        expect(engine.runtimeInstances.single.activeRequests, 1);
        cancellation.cancel();
        await pending;
        expect(engine.runtimeInstances.single.activeRequests, 0);
      } finally {
        await engine.shutdown();
      }
    },
  );
}
