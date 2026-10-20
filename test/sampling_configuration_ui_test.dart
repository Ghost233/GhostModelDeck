import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/launch_instances.dart';

import 'fixtures/generation_runtime.dart';
import 'fixtures/parameter_editor_navigation.dart';

void main() {
  testWidgets(
    'sampling controls preserve inherited, disabled and explicit neutral values',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => GenerationTestRuntime.create(
            start: false,
            defaults: GenerationConfiguration({
              'top_k': 20,
              'top_p': 0.7,
              'min_p': 0.1,
              'repeat_penalty': 1.2,
              'presence_penalty': 0.2,
              'frequency_penalty': -0.3,
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
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: InstancesPage(instances: fixture.store)),
          ),
        );
        await _settle(tester);
        await tester.ensureVisible(find.text('编辑参数'));
        await tester.tap(find.text('编辑参数'));
        await _settle(tester);
      });
      await selectParameterGroup(tester, '采样与惩罚');
      final neutral = {
        'top_k': 0,
        'top_p': 1,
        'min_p': 0,
        'repeat_penalty': 1,
        'presence_penalty': 0,
        'frequency_penalty': 0,
      };
      for (final entry in neutral.entries) {
        await _mode(tester, entry.key, '关闭');
        final input = find.byKey(
          Key('parameter-number:generation:${entry.key}'),
        );
        expect(tester.widget<TextField>(input).enabled, isFalse);
        expect(
          num.parse(tester.widget<TextField>(input).controller!.text),
          entry.value,
        );
        if (entry.key != 'top_k') {
          expect(
            tester
                .getSemantics(
                  find.byKey(Key('parameter-slider:generation:${entry.key}')),
                )
                .getSemanticsData()
                .hasAction(SemanticsAction.increase),
            isFalse,
          );
        }
      }
      for (final key in [
        'top_p',
        'min_p',
        'repeat_penalty',
        'presence_penalty',
        'frequency_penalty',
      ]) {
        await _mode(tester, key, '指定数值');
        final input = find.byKey(Key('parameter-number:generation:$key'));
        await tester.ensureVisible(input);
        await tester.enterText(input, '${neutral[key]}');
        await tester.runAsync(() => _settle(tester));
        expect(tester.widget<TextField>(input).enabled, isTrue);
      }
      final topP = find.byKey(const Key('parameter-slider:generation:top_p'));
      await tester.ensureVisible(topP);
      final sliderBounds = tester.getRect(topP);
      await tester.tapAt(
        Offset(sliderBounds.right - 1, sliderBounds.center.dy),
      );
      await tester.runAsync(() => _settle(tester));
      expect(
        num.parse(
          tester
              .widget<TextField>(
                find.byKey(const Key('parameter-number:generation:top_p')),
              )
              .controller!
              .text,
        ),
        1,
      );
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await _settle(
          tester,
          completed: () => find
              .byKey(const Key('parameter-group-navigation'))
              .evaluate()
              .isEmpty,
        );
      });
      final saved = fixture.store.find(fixture.definition.id)!.configuration;
      expect(saved.generation.values, {
        'top_k': null,
        'top_p': 1,
        'min_p': 0,
        'repeat_penalty': 1,
        'presence_penalty': 0,
        'frequency_penalty': 0,
      });
      expect(fixture.source.io.starts, 0);
      await tester.runAsync(() async {
        final restored = LaunchInstances(
          catalog: fixture.catalog,
          file: fixture.store.file,
        );
        await restored.load();
        expect(
          restored.find(fixture.definition.id)!.configuration.generation.values,
          saved.generation.values,
        );
        await restored.close();
        await tester.ensureVisible(find.text('编辑参数'));
        await tester.tap(find.text('编辑参数'));
        await _settle(tester);
      });
      await selectParameterGroup(tester, '采样与惩罚');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('parameter-choice:generation:top_k')),
            )
            .value,
        'off',
      );
      for (final key in [
        'top_p',
        'min_p',
        'repeat_penalty',
        'presence_penalty',
        'frequency_penalty',
      ]) {
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.byKey(Key('parameter-choice:generation:$key')),
              )
              .value,
          'custom',
        );
      }
      await _mode(tester, 'min_p', '继承引擎默认');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await _settle(
          tester,
          completed: () => find
              .byKey(const Key('parameter-group-navigation'))
              .evaluate()
              .isEmpty,
        );
      });
      expect(
        fixture.store
            .find(fixture.definition.id)!
            .configuration
            .generation
            .values
            .containsKey('min_p'),
        isFalse,
      );
      await tester.runAsync(() async {
        await tester.ensureVisible(find.text('编辑参数'));
        await tester.tap(find.text('编辑参数'));
        await _settle(tester);
      });
      await selectParameterGroup(tester, '推测与采样优化');
      final minimum = find.byKey(
        const Key('parameter-choice:--prompt-lookup-min-match'),
      );
      await tester.ensureVisible(minimum);
      await tester.tap(minimum);
      await tester.pumpAndSettle();
      await tester.tap(find.text('4').last);
      await tester.pumpAndSettle();
      await tester.runAsync(() => _settle(tester));
      expect(find.textContaining('提示查找关闭，本项当前不适用'), findsOneWidget);
      for (final key in ['--prompt-lookup', '--fast-topk']) {
        final field = find.byKey(Key('parameter-choice:$key'));
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text('开启').last);
        await tester.pumpAndSettle();
        await tester.runAsync(() => _settle(tester));
      }
      expect(find.textContaining('未选择草稿验证路径'), findsOneWidget);
      expect(find.textContaining('实例默认不满足快速路径条件'), findsOneWidget);
      expect(find.textContaining('实际命中未知'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await _settle(
          tester,
          completed: () => find
              .byKey(const Key('parameter-group-navigation'))
              .evaluate()
              .isEmpty,
        );
      });
      expect(fixture.source.io.starts, 0);
      final loading = fixture.store
          .find(fixture.definition.id)!
          .configuration
          .formValues;
      expect(loading['--prompt-lookup'], 'on');
      expect(loading['--prompt-lookup-min-match'], '4');
      expect(loading['--fast-topk'], 'on');
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await fixture.store.start(fixture.definition.id);
          final arguments = fixture.source.io.launchArguments.last;
          expect(arguments, containsAllInOrder(['--prompt-lookup', 'on']));
          expect(
            arguments,
            containsAllInOrder(['--prompt-lookup-min-match', '4']),
          );
          expect(arguments, containsAllInOrder(['--fast-topk', 'on']));
          for (final stream in [false, true]) {
            final response = await fixture.post({'stream': stream, 'min_p': 0});
            expect(response.status, 200, reason: response.body);
            final body = fixture.source.io.chatBodies.last;
            expect(body['top_k'], 0);
            expect(body['top_p'], 1);
            expect(body['min_p'], 0);
            expect(body['presence_penalty'], 0);
            expect(body['frequency_penalty'], 0);
          }
        }, _Network()),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _mode(WidgetTester tester, String key, String mode) async {
  final field = find.byKey(Key('parameter-choice:generation:$key'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(mode).last);
  await tester.pumpAndSettle();
  await tester.runAsync(() => _settle(tester));
}

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
  fail('Sampling configuration GUI did not settle');
}

class _Network extends HttpOverrides {}
