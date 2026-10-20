import 'fixtures/parameter_editor_navigation.dart';
import 'fixtures/splash_help.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_launch_editor.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';

void main() {
  testWidgets(
    'A editor path middle edits and consecutive paste preserve cursor, cancel and save',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var persisted = EngineLaunchConfiguration(
        formValues: {'--lora': '/models/base/adapter.gguf'},
      );
      var saves = 0;
      final recognition = EngineParameterRecognition.fromHelp(
        '--lora FNAME  path to LoRA adapter\n',
        version: 'b11457 FILE option',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EngineLaunchEditor(
                  title: 'A 启动参数',
                  initialConfiguration: persisted,
                  executable: '/verified/llama-server',
                  recognition: recognition,
                  onSave: (value) async {
                    persisted = value;
                    saves++;
                  },
                ),
              ),
              child: const Text('编辑A参数'),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('编辑A参数'));
        await tester.pumpAndSettle();
        await selectParameterGroup(tester, '其他引擎参数');
      }

      final path = find.byKey(const Key('parameter-path:--lora'));
      Future<void> send(String text, int cursor) async {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: cursor),
          ),
        );
        await tester.pump();
        expect(tester.widget<TextField>(path).controller!.text, text);
        expect(
          tester.widget<TextField>(path).controller!.selection.baseOffset,
          cursor,
        );
        expect(tester.testTextInput.hasAnyClients, isTrue);
      }

      await open();
      await tester.ensureVisible(path);
      await tester.tap(path);
      await tester.pump();
      await send('/models/new-base/adapter.gguf', 12);
      await send('/models/new-base/pasted adapter.gguf', 23);
      await send('/models/new-base/pasted copy adapter.gguf', 28);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(persisted.formValues['--lora'], '/models/base/adapter.gguf');
      await open();
      expect(
        tester.widget<TextField>(path).controller!.text,
        '/models/base/adapter.gguf',
      );
      await tester.ensureVisible(path);
      await tester.tap(path);
      await tester.pump();
      await send('/models/saved-base/adapter.gguf', 14);
      await send('/models/saved-base/pasted adapter.gguf', 25);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(
        persisted.formValues['--lora'],
        '/models/saved-base/pasted adapter.gguf',
      );
      await open();
      expect(
        tester.widget<TextField>(path).controller!.text,
        '/models/saved-base/pasted adapter.gguf',
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('context capacity uses the selected installation option metadata', () {
    final splash = EngineParameterRecognition.fromHelp(
      splashCurrentHelp,
      family: EngineFamily.splash,
      version: 'context consumer observed help',
    );
    for (final text in ['--max-con=8192', '--max-con 8192']) {
      final configuration = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--max-context': '2048'},
        argumentText: text,
      );
      expect(configuration.contextLengthFor(recognition: splash), 8192);
      expect(configuration.contextLength, 2048);
      expect(configuration.argumentText, text);
    }
  });

  test('context capacity does not invent option prefixes', () {
    final observedSplash = EngineParameterRecognition.fromHelp(
      splashCurrentHelp,
      family: EngineFamily.splash,
      version: 'current custom Splash',
    );
    final unobservedContext = EngineParameterRecognition.fromHelp(
      '--max-memory SIZE  memory budget\n',
      family: EngineFamily.splash,
      version: 'context option not observed',
    );
    for (final input in [
      (EngineFamily.splash, '--max-c=8192', observedSplash),
      (EngineFamily.splash, '--max-con 8192', unobservedContext),
      (
        EngineFamily.splash,
        '--max-con=8192',
        EngineParameterRecognition.builtIn(family: EngineFamily.splash),
      ),
      (
        EngineFamily.llamaCpp,
        '--ctx-s=8192',
        EngineParameterRecognition.fromHelp(
          '-c, --ctx-size N  context capacity\n',
          version: 'llama exact options',
        ),
      ),
    ]) {
      final field = input.$1 == EngineFamily.splash
          ? '--max-context'
          : '--ctx-size';
      final configuration = EngineLaunchConfiguration(
        family: input.$1,
        formValues: {field: '2048'},
        argumentText: input.$2,
      );
      expect(configuration.contextLengthFor(recognition: input.$3), 2048);
      expect(configuration.argumentText, input.$2);
    }
  });

  test('context capacity retains exact alias and token unit handling', () {
    final llama = EngineParameterRecognition.fromHelp(
      '-c, --ctx-size N  context capacity\n',
      version: 'llama exact aliases',
    );
    for (final text in ['-c=8192', '-c 8192', '--ctx_size 8192']) {
      final configuration = EngineLaunchConfiguration(
        formValues: {'--ctx-size': '2048'},
        argumentText: text,
      );
      expect(configuration.contextLengthFor(recognition: llama), 8192);
      expect(configuration.contextLength, 8192);
      expect(configuration.argumentText, text);
    }
    final splash = EngineParameterRecognition.fromHelp(
      splashCurrentHelp,
      family: EngineFamily.splash,
      version: 'current custom Splash',
    );
    expect(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--max-con 8K',
      ).contextLengthFor(recognition: splash),
      8192,
    );
  });

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
      await selectParameterGroup(tester, '参数文本与命令');
      final raw = find.byKey(const Key('engine-argument-text'));

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
      expect(
        tester
            .widget<EngineLaunchCommandView>(
              find.byType(EngineLaunchCommandView),
            )
            .command
            .overriddenForm,
        contains('--ctx-size'),
      );
      expect(
        tester.widget<EditableText>(rawEditable()).focusNode.hasFocus,
        isTrue,
      );
      expect(activeClient(), client);
      tester.testTextInput.enterText('--threads 2');
      await tester.pump();
      expect(
        tester
            .widget<EngineLaunchCommandView>(
              find.byType(EngineLaunchCommandView),
            )
            .command
            .overriddenForm,
        isNot(contains('--ctx-size')),
      );
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
