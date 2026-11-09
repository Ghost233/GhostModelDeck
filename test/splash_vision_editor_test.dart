import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/parameter_editor.dart';

import 'fixtures/parameter_editor_navigation.dart';

void main() {
  testWidgets(
    'Splash vision editor switches from automatic to a picked GGUF and back',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('com.ghost233.ghostmodeldeck/native');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickParameterFile');
        expect(call.arguments, {
          'extensions': ['gguf'],
        });
        return '/models/vision/model-mmproj.gguf';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      SplashVision vision = (enabled: false, projector: null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ParameterEditor(
                family: EngineFamily.splash,
                formValues: const {},
                onFormChanged: (_) {},
                generationValues: const {},
                onGenerationChanged: (_) {},
                onDrafterChanged: (_) {},
                showGeneration: false,
                showDrafter: false,
                splashVision: vision,
                initialSplashVision: (enabled: false, projector: null),
                splashVisionUsesProjector: true,
                onSplashVisionChanged: (value) =>
                    setState(() => vision = value),
              ),
            ),
          ),
        ),
      );
      await selectParameterGroup(tester, '视觉输入');
      final toggle = find.byKey(const Key('splash-vision-enabled'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(vision, (enabled: true, projector: null));

      final field = find.byKey(const Key('splash-vision-projector'));
      await tester.tap(
        find.descendant(
          of: field,
          matching: find.widgetWithText(OutlinedButton, '选择…'),
        ),
      );
      await tester.pumpAndSettle();
      expect(vision, (
        enabled: true,
        projector: '/models/vision/model-mmproj.gguf',
      ));
      await tester.enterText(
        find.descendant(of: field, matching: find.byType(TextField)),
        '',
      );
      await tester.pumpAndSettle();
      expect(vision, (enabled: true, projector: null));
    },
  );
}
