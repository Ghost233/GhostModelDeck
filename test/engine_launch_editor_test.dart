import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_launch_editor.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';

void main() {
  testWidgets(
    'raw typing keeps its input client through partial-help syntax and override transitions',
    (tester) async {
      final rules = EngineParameterRecognition.fromHelp(
        '--ctx-size N  current context limit\n',
        version: 'public partial help fixture',
      );
      expect(rules.notices, isNotEmpty);
      await tester.pumpWidget(
        MaterialApp(
          home: EngineLaunchEditor(
            title: '引擎启动参数',
            initialConfiguration: EngineLaunchConfiguration(),
            executable: '/verified/llama-server',
            recognition: rules,
            onSave: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final raw = find.widgetWithText(TextField, '启动参数文本');
      final context = find.widgetWithText(TextField, '上下文大小');
      Finder rawEditable() =>
          find.descendant(of: raw, matching: find.byType(EditableText));
      int activeClient() =>
          (tester.testTextInput.log
                          .lastWhere(
                            (call) => call.method == 'TextInput.setClient',
                          )
                          .arguments
                      as List)
                  .first
              as int;
      await tester.ensureVisible(raw);
      await tester.tap(raw);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final client = activeClient();
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      // Send platform editing events to the existing client, without enterText's
      // showKeyboard/focus repair between individual changes.
      tester.testTextInput.enterText('--ctx-size "u');
      await tester.pump();
      expect(
        tester.widget<TextField>(raw).decoration!.errorText,
        contains('引号未闭合'),
      );
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(activeClient(), client);
      tester.testTextInput.enterText('--ctx-size "unfinished');
      await tester.pump();
      expect(
        tester.widget<TextField>(raw).controller!.text,
        '--ctx-size "unfinished',
      );
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      expect(activeClient(), client);
      tester.testTextInput.enterText('--ctx-size "8192"');
      await tester.pump();
      expect(tester.widget<TextField>(raw).decoration!.errorText, isNull);
      expect(tester.widget<TextField>(context).decoration!.errorText, '已被文本覆盖');
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      expect(activeClient(), client);
      tester.testTextInput.enterText('--threads 2');
      await tester.pump();
      expect(tester.widget<TextField>(context).decoration!.errorText, isNull);
      expect(tester.widget<TextField>(context).controller!.text, '4096');
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      expect(activeClient(), client);
      tester.testTextInput.enterText('--threads 23');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(raw).controller!.text, '--threads 23');
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      expect(activeClient(), client);
      expect(tester.takeException(), isNull);
    },
  );
}
