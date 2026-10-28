import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_prefill_route.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import 'splash_decision_routes_test.dart' as fixture;

void main() {
  test(
    'resolves a ready native JEV instance with its declared capabilities',
    () async {
      final environment = await fixture.DecisionRouteFixture.create();
      addTearDown(environment.close);
      environment.native.io.prefillCapabilities = {
        'schema': 'splash-prefill/1',
        'operation_tracking': true,
        'chat_zero_budget': false,
        'systemone_state': true,
      };
      final saved = await environment.save('prefill-jev');
      await environment.instances.start(saved.id);
      final ledger = await PrefillOperationLedger.open(
        File('${environment.native.root.path}/route-ledger.json'),
      );
      addTearDown(ledger.close);
      final resolver = PublicPrefillRouteResolver(
        routes: environment.routes,
        ledger: ledger,
        jevModels: environment.council.models,
      );
      final runtime = await resolver.resolve(
        SplashOperationPath.systemone,
        saved.publicName,
      );
      expect(runtime.supportsPrefill(SplashOperationPath.systemone), isTrue);
      expect(runtime.supportsPrefill(SplashOperationPath.chat), isFalse);
      expect(await runtime.isCurrent(), isTrue);
    },
  );
}
