import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/parameter_editor.dart';

import 'fixtures/parameter_editor_navigation.dart';
import 'fixtures/splash_help.dart';

const _option = '--experimental-quantized-ffn';
const _help =
    '$splashCurrentHelp\n  $_option {on,off}  experimental FFN (default: off)\n';
EngineParameterRecognition _recognition(String help) =>
    EngineParameterRecognition.fromHelp(
      help,
      family: EngineFamily.splash,
      version: 'quantized FFN contract fixture',
    );

void main() {
  for (final supported in [true, false]) {
    testWidgets(
      'FFN visual control reports support=$supported and native status without guessing',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var values = <String, String>{};
        var text = '';
        ({bool? enabled, int? cacheBytes})? actual;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  EngineLaunchCommand? command;
                  try {
                    command =
                        EngineLaunchConfiguration(
                          family: EngineFamily.splash,
                          formValues: values,
                          argumentText: text,
                        ).command(
                          executable: 'splash',
                          modelPath: '/model',
                          recognition: _recognition(
                            supported ? _help : splashCurrentHelp,
                          ),
                        );
                  } on FormatException {
                    // The full editor displays the unsupported request error.
                  }
                  return ParameterEditor(
                    family: EngineFamily.splash,
                    formValues: values,
                    onFormChanged: (v) => setState(() => values = v),
                    generationValues: const {},
                    onGenerationChanged: (_) {},
                    onDrafterChanged: (_) {},
                    recognition: _recognition(
                      supported ? _help : splashCurrentHelp,
                    ),
                    actualQuantizedFfn: actual,
                    command: command,
                    showGeneration: false,
                    showDrafter: false,
                  );
                },
              ),
            ),
          ),
        );
        await selectParameterGroup(tester, '计算与 ANE');
        final choice = find.byKey(
          const Key('parameter-choice:--experimental-quantized-ffn'),
        );
        await tester.ensureVisible(choice);
        await tester.pumpAndSettle();
        final dropdown = tester.widget<DropdownButton<String>>(choice);
        expect(find.text('实验性量化 FFN（不保留全量 FP16 缓存）'), findsOneWidget);
        expect(dropdown.value, '');
        expect(find.text('未知'), findsNWidgets(2));
        if (supported) {
          await tester.tap(choice);
          await tester.pumpAndSettle();
          await tester.tap(find.text('开启').last);
          await tester.pumpAndSettle();
          expect(values[_option], 'on');
          expect(find.text('未知'), findsNWidgets(2));
          update(() => actual = (enabled: true, cacheBytes: 0));
          await tester.pumpAndSettle();
          expect(find.text('0 字节'), findsOneWidget);
          update(() => actual = (enabled: true, cacheBytes: 1024));
          await tester.pumpAndSettle();
          expect(find.textContaining('未确认 FP16 缓存为 0'), findsOneWidget);
        } else {
          expect(dropdown.onChanged, isNull);
          expect(find.textContaining('当前引擎不支持或尚未确认支持'), findsOneWidget);
          update(() => values = {_option: 'on'});
          await tester.pumpAndSettle();
          update(() => text = '$_option on $_option off');
          await tester.pumpAndSettle();
          expect(find.text('off'), findsOneWidget);
          await tester.ensureVisible(find.text('关闭实验性量化 FFN'));
          await tester.tap(find.text('关闭实验性量化 FFN'));
          await tester.pumpAndSettle();
          expect(values[_option], 'off');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
