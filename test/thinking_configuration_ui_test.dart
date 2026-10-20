import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_launch_editor.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llm_playground_page.dart';

import 'fixtures/generation_runtime.dart';
import 'fixtures/parameter_editor_navigation.dart';
import 'llm_playground_test.dart' show LlmTestRuntime, llmDocument;

void main() {
  testWidgets(
    'Splash thought and scheduling controls save, reopen and dispatch exact defaults',
    (tester) async {
      _viewport(tester);
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => GenerationTestRuntime.create(
            start: false,
            defaults: GenerationConfiguration({
              'thinking_token_budget': 8,
              'seed': 42,
              'timeout': 30,
              'cache_salt': 'old-domain',
              'chat_template_kwargs': {
                'metadata': {'keep': true},
                'enable_thinking': true,
                'preserve_thinking': true,
              },
            }),
          ),
          _Network(),
        ),
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }),
      );
      Future<void> edit() => tester.runAsync(() async {
        await tester.ensureVisible(find.text('编辑参数'));
        await tester.tap(find.text('编辑参数'));
        await _settle(tester);
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: InstancesPage(instances: fixture.store)),
          ),
        );
        await _settle(tester);
      });
      await edit();
      await _group(tester, '思考与模板');
      await _mode(tester, 'thinking_token_budget', '不限（-1）');
      expect(
        tester.widget<TextField>(_number('thinking_token_budget')).enabled,
        isFalse,
      );
      await _mode(tester, 'thinking_token_budget', '不分配思考 token（0）');
      await _mode(tester, 'thinking_token_budget', '指定预算');
      await tester.ensureVisible(_number('thinking_token_budget'));
      await tester.enterText(_number('thinking_token_budget'), '-');
      await tester.pumpAndSettle();
      await _mode(tester, 'thinking_token_budget', '不分配思考 token（0）');
      expect(
        tester
            .widget<TextField>(_number('thinking_token_budget'))
            .decoration!
            .errorText,
        isNull,
      );
      await _mode(tester, 'thinking_token_budget', '指定预算');
      await _emptyAndCorrect(tester, 'thinking_token_budget', '0');
      final template = find.byKey(
        const Key('parameter-object:generation:template'),
      );
      await tester.ensureVisible(template);
      await tester.enterText(
        template,
        '{"metadata":{"keep":true},"enable_thinking":true,"preserve_thinking":true}',
      );
      await tester.pumpAndSettle();
      await _choice(tester, 'generation:enable_thinking', '关闭');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(
                const Key('parameter-choice:generation:preserve_thinking'),
              ),
            )
            .value,
        'true',
      );
      await _choice(tester, 'generation:preserve_thinking', '关闭');
      expect(jsonDecode(tester.widget<TextField>(template).controller!.text), {
        'metadata': {'keep': true},
        'enable_thinking': false,
      });
      await tester.ensureVisible(template);
      await tester.enterText(template, '{');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(
                const Key('parameter-choice:generation:enable_thinking'),
              ),
            )
            .onChanged,
        isNull,
      );
      await tester.enterText(
        template,
        '{"metadata":{"keep":true},"enable_thinking":false}',
      );
      await tester.pumpAndSettle();
      await _group(tester, '请求与调度');
      await _choice(tester, 'generation:priority', 'background');
      await _mode(tester, 'timeout', '指定秒数');
      await _emptyAndCorrect(tester, 'timeout', '0.25');
      await _mode(tester, 'cache_salt', '共享缓存（不隔离）');
      await _mode(tester, 'cache_salt', '指定隔离标识');
      final salt = find.byKey(
        const Key('parameter-text:generation:cache_salt'),
      );
      await tester.ensureVisible(salt);
      await tester.enterText(salt, '');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(salt).enabled, isTrue);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.enterText(salt, 'new-domain');
      await tester.pumpAndSettle();
      await _group(tester, '基本生成');
      await _mode(tester, 'max_tokens', '指定数值');
      await _emptyAndCorrect(tester, 'max_tokens', '16');
      await _emptyAndCorrect(tester, 'seed', '18446744073709551615');
      await _group(tester, '采样与惩罚');
      await _mode(tester, 'top_p', '指定数值');
      await _emptyAndCorrect(tester, 'top_p', '0.75');
      await tester.enterText(_number('top_p'), '-');
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const Key('parameter-slider:generation:top_p')),
      );
      expect(
        tester.widget<TextField>(_number('top_p')).decoration!.errorText,
        isNull,
      );
      await tester.enterText(_number('top_p'), '0.75');
      await tester.pumpAndSettle();
      await _save(tester);
      final expected = fixture.store
          .find(fixture.definition.id)!
          .configuration
          .generation;
      expect(expected.values['thinking_token_budget'], 0);
      expect(expected.values['cache_salt'], 'new-domain');
      expect(expected.values['seed'].toString(), '18446744073709551615');
      await tester.runAsync(() async {
        final restored = LaunchInstances(
          catalog: fixture.catalog,
          file: fixture.store.file,
        );
        await restored.load();
        expect(
          jsonEncode(
            restored
                .find(fixture.definition.id)!
                .configuration
                .generation
                .toJson(),
          ),
          jsonEncode(expected.toJson()),
        );
        await restored.close();
      });
      await edit();
      await _group(tester, '思考与模板');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(
                const Key('parameter-choice:generation:thinking_token_budget'),
              ),
            )
            .value,
        'custom',
      );
      await _mode(tester, 'thinking_token_budget', '不限（-1）');
      await _group(tester, '请求与调度');
      await _mode(tester, 'cache_salt', '共享缓存（不隔离）');
      await _mode(tester, 'timeout', '使用服务时限');
      await _save(tester);
      final finalValues = fixture.store
          .find(fixture.definition.id)!
          .configuration
          .generation
          .values;
      expect(finalValues['thinking_token_budget'], -1);
      expect(finalValues.containsKey('cache_salt'), isTrue);
      expect(finalValues['cache_salt'], isNull);
      expect(finalValues['timeout'], isNull);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await fixture.store.start(fixture.definition.id);
          for (final stream in [false, true]) {
            final response = await fixture.post({'stream': stream});
            expect(response.status, 200, reason: response.body);
            final body = fixture.source.io.chatBodies.last;
            expect(body['thinking_token_budget'], -1);
            expect(body['priority'], 'background');
            expect(body['preserve_thinking'], false);
            expect(body.containsKey('timeout'), isFalse);
            expect(body.containsKey('cache_salt'), isFalse);
            expect(body['chat_template_kwargs'], {
              'metadata': {'keep': true},
              'enable_thinking': false,
            });
            expect(
              fixture.source.io.rawChatBodies.last,
              contains('"seed":18446744073709551615'),
            );
          }
        }, _Network()),
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
            ),
          );
          await _settle(
            tester,
            completed: () =>
                find.byKey(const Key('llm-discovery')).evaluate().isNotEmpty,
          );
        }, _Network()),
      );
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      await tester.enterText(
        find.byKey(const Key('llm-json')),
        jsonEncode({
          'model': fixture.definition.publicName,
          'messages': [
            {'role': 'user', 'content': 'OK'},
          ],
        }),
      );
      await _tap(tester, find.byKey(const Key('llm-form-mode')));
      await _tap(tester, find.text('思考与模板'));
      await _choice(tester, 'llm:enable_thinking', '开启');
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      final override = jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ) as Map;
      expect(override['chat_template_kwargs'], {
        'metadata': {'keep': true},
        'enable_thinking': true,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'llama service thought defaults use typed controls and exact launch preview',
    (tester) async {
      _viewport(tester);
      EngineLaunchConfiguration? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EngineLaunchEditor(
                  title: '服务参数',
                  initialConfiguration: EngineLaunchConfiguration(),
                  executable: '/verified/llama-server',
                  onSave: (configuration) async {
                    saved = configuration;
                  },
                ),
              ),
              child: const Text('打开服务参数'),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('打开服务参数'));
      await tester.pumpAndSettle();
      await _group(tester, '服务思考默认值');
      await _choice(tester, '--reasoning', '自动');
      await _choice(tester, '--reasoning-effort', 'high');
      final budget = find.byKey(
        const Key('parameter-number:--reasoning-budget'),
      );
      await tester.ensureVisible(budget);
      await tester.enterText(budget, '-1');
      await _choice(tester, '--reasoning-preserve', '关闭');
      await _group(tester, '参数文本与命令');
      final command = tester
          .widget<EngineLaunchCommandView>(find.byType(EngineLaunchCommandView))
          .command;
      expect(command.arguments, containsAllInOrder(['--reasoning', 'auto']));
      expect(
        command.arguments,
        containsAllInOrder(['--reasoning-effort', 'high']),
      );
      expect(
        command.arguments,
        containsAllInOrder(['--reasoning-budget', '-1']),
      );
      expect(command.arguments, contains('--no-reasoning-preserve'));
      await _tap(tester, find.widgetWithText(FilledButton, '保存'));
      expect(saved!.formValues['--reasoning-budget'], '-1');
      expect(saved!.formValues['--reasoning-preserve'], 'false');
      expect(saved!.generation.values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'llama thought controls preserve canonical aliases, template metadata and service budget meaning',
    (tester) async {
      _viewport(tester);
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          LlmTestRuntime.create,
          _Network(),
        ),
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }),
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
            ),
          );
          await _settle(
            tester,
            completed: () =>
                find.byKey(const Key('llm-discovery')).evaluate().isNotEmpty,
          );
        }, _Network()),
      );
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      final document = llmDocument(fixture.publicId)
        ..addAll({
          'thinking_budget_tokens': 12,
          'reasoning_budget_tokens': -1,
          'chat_template_kwargs': {
            'metadata': {'keep': true},
            'enable_thinking': true,
          },
        });
      await tester.enterText(
        find.byKey(const Key('llm-json')),
        jsonEncode(document),
      );
      await _tap(tester, find.byKey(const Key('llm-form-mode')));
      await _tap(tester, find.text('思考与模板'));
      final mode = find.byKey(
        const Key('parameter-choice:llm:reasoning_budget_tokens'),
      );
      expect(
        tester.widget<DropdownButton<String>>(mode).value,
        'nativeDefault',
      );
      expect(find.textContaining('继承已启动服务预算'), findsWidgets);
      await _choice(tester, 'llm:preserve_reasoning', '关闭');
      await _choice(tester, 'llm:enable_thinking', '关闭');
      await _choice(tester, 'llm:reasoning_budget_tokens', '指定预算');
      await _emptyAndCorrect(
        tester,
        'reasoning_budget_tokens',
        '0',
        prefix: 'llm',
        save: false,
      );
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      final current = jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ) as Map;
      expect(current['reasoning_budget_tokens'], 0);
      expect(current.containsKey('thinking_budget_tokens'), isFalse);
      expect(current['chat_template_kwargs'], {
        'metadata': {'keep': true},
        'enable_thinking': false,
        'preserve_reasoning': false,
      });
      current['chat_template_kwargs'] = {'enable_thinking': false};
      await tester.enterText(
        find.byKey(const Key('llm-json')),
        jsonEncode(current),
      );
      await _tap(tester, find.byKey(const Key('llm-form-mode')));
      await _tap(tester, find.text('思考与模板'));
      await _choice(tester, 'llm:enable_thinking', '继承服务模板默认');
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      final cleared = jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ) as Map;
      expect(cleared['chat_template_kwargs'], <String, Object?>{});
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _number(String key, {String prefix = 'generation'}) =>
    find.byKey(Key('parameter-number:$prefix:$key'));
void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _emptyAndCorrect(
  WidgetTester tester,
  String key,
  String text, {
  String prefix = 'generation',
  bool save = true,
}) async {
  final field = _number(key, prefix: prefix);
  await tester.ensureVisible(field);
  await tester.enterText(field, '');
  await tester.pumpAndSettle();
  expect(
    tester.widget<TextField>(field).enabled,
    isTrue,
    reason: '$key must remain editable while empty',
  );
  if (save) {
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
  }
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '-',
      selection: TextSelection.collapsed(offset: 1),
    ),
  );
  await tester.pump();
  expect(tester.widget<TextField>(field).enabled, isTrue);
  expect(tester.widget<TextField>(field).controller!.text, '-');
  for (var i = 1; i <= text.length; i++) {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text.substring(0, i),
        selection: TextSelection.collapsed(offset: i),
      ),
    );
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.text, text.substring(0, i));
    expect(controller.selection.baseOffset, i);
  }
  final middle = text.length ~/ 2;
  final intermediate = text.replaceRange(middle, middle, '0');
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: intermediate,
      selection: TextSelection.collapsed(offset: middle + 1),
    ),
  );
  await tester.pump();
  expect(tester.widget<TextField>(field).controller!.text, intermediate);
  expect(
    tester.widget<TextField>(field).controller!.selection.baseOffset,
    middle + 1,
  );
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: middle),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.widget<TextField>(field).controller!.selection.baseOffset,
    middle,
  );
}

Future<void> _group(WidgetTester tester, String label) async {
  await tester.drag(
    find.byKey(const Key('parameter-group-navigation')),
    const Offset(0, 1600),
  );
  await tester.pumpAndSettle();
  await selectParameterGroup(tester, label);
}

Future<void> _mode(WidgetTester tester, String key, String label) =>
    _choice(tester, 'generation:$key', label);
Future<void> _choice(WidgetTester tester, String id, String label) async {
  await _tap(tester, find.byKey(Key('parameter-choice:$id')));
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.runAsync(() => _settle(tester));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) => tester.runAsync(() async {
  await tester.tap(find.widgetWithText(FilledButton, '保存'));
  await _settle(
    tester,
    completed: () =>
        find.byKey(const Key('parameter-group-navigation')).evaluate().isEmpty,
  );
});
Future<void> _settle(WidgetTester tester, {bool Function()? completed}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  do {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        (completed?.call() ?? true)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  } while (DateTime.now().isBefore(deadline));
  fail('Thinking configuration GUI did not settle');
}

class _Network extends HttpOverrides {}
