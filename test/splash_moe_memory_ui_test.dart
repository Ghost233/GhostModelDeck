import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_launch_editor.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';

import 'fixtures/parameter_editor_navigation.dart';

void main() {
  testWidgets('Splash MoE settings save and produce the selected arguments', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    EngineLaunchConfiguration? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => EngineLaunchEditor(
                title: 'Splash 参数',
                initialConfiguration: EngineLaunchConfiguration(
                  family: EngineFamily.splash,
                ),
                onSave: (value) async => saved = value,
              ),
            ),
            child: const Text('编辑'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await selectParameterGroup(tester, '上下文与内存');

    Future<void> choose(String name, String label) async {
      final field = find.byKey(Key('parameter-choice:$name'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('--expert-memory', '加载全部专家');
    await choose('--expert-memory', '自动');
    await choose('--moe-memory-pressure', '开启');
    await choose('--host-memory-reserve', '指定数值');
    final amount = find.byKey(
      const Key('parameter-quantity:--host-memory-reserve'),
    );
    await tester.ensureVisible(amount);
    await tester.enterText(amount, '4');
    // The unit dropdown has the same key as the mode dropdown.
    final reserveChoices = find.byKey(
      const Key('parameter-choice:--host-memory-reserve'),
    );
    await tester.tap(reserveChoices.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('G').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(saved!.formValues['--expert-memory'], 'auto');
    expect(saved!.formValues['--moe-memory-pressure'], 'on');
    expect(saved!.formValues['--host-memory-reserve'], '4G');
    final command = saved!.command(executable: 'splash', modelPath: 'model');
    expect(
      command.arguments,
      containsAll([
        '--expert-memory',
        'auto',
        '--moe-memory-pressure',
        'on',
        '--host-memory-reserve',
        '4G',
      ]),
    );
  });

  test('defaults stay omitted and text overrides the new form fields', () {
    final defaults = EngineLaunchConfiguration(family: EngineFamily.splash)
        .command(executable: 'splash', modelPath: 'model');
    expect(defaults.arguments, isNot(contains('--moe-memory-pressure')));
    expect(defaults.arguments, isNot(contains('--expert-memory')));
    final config = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--expert-memory': 'auto', '--moe-memory-pressure': 'on'},
      argumentText: '--expert-memory 16G --moe-memory-pressure off',
    );
    final oldHelp = EngineParameterRecognition.fromHelp(
      '--max-context TOKENS  context\n',
      family: EngineFamily.splash,
      version: 'older Splash',
    );
    final command = config.command(executable: 'splash', modelPath: 'model');
    expect(
      command.overriddenForm,
      containsAll(['--expert-memory', '--moe-memory-pressure']),
    );
    expect(
      command.arguments.where((value) => value == '--expert-memory'),
      hasLength(1),
    );
    expect(command.arguments, containsAll(['16G', 'off']));
    final unsupported = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--moe-memory-pressure': 'on'},
    ).command(executable: 'splash', modelPath: 'model', recognition: oldHelp);
    expect(unsupported.notices, contains(contains('支持情况尚未')));
  });
}
