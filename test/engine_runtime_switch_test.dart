import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime_switch.dart';

import 'fixtures/council_runtime.dart';

void main() {
  testWidgets(
    'master switch observes business changes and never hides configuration children',
    (tester) async {
      final runtime = (await tester.runAsync(
        () => CouncilRuntime.create(modelCount: 0),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                EngineRuntimeSwitch(catalog: runtime.catalog),
                const Text('配置管理'),
              ],
            ),
          ),
        ),
      );
      try {
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('engine-master-switch')));
        });
        await tester.pumpAndSettle();
        expect(runtime.catalog.runtimeEnabled, isFalse);
        expect(find.text('配置管理'), findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse,
        );
        await tester.runAsync(() => runtime.catalog.setRuntimeEnabled(true));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        await tester.runAsync(() async {
          await runtime.close();
          closed = true;
        });
        expect(closed, isTrue);
      }
    },
  );
}
