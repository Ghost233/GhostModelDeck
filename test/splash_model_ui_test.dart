import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/model_run_dialog.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/llama_engine.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;
import 'fixtures/parameter_editor_navigation.dart';

void main() {
  testWidgets(
    'Splash instance editor saves model, engine and parameters without a directory or preparation',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var rankingPicks = 0;
      const native = MethodChannel('com.ghost233.ghostmodeldeck/native');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        if (call.method == 'pickParameterFile') {
          rankingPicks++;
          return rankingPicks == 1
              ? null
              : '/model-library/public-ranking.splash';
        }
        expect(call.method, 'pickLibraryDirectory');
        return '/model-library/explicit-drafter';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        ),
      );
      final (fixture, cpp, catalog) = (await tester.runAsync(() async {
        final fixture = await SplashRuntimeFixture.create(compactHelp: true);
        final cpp = LlamaEngine(
          library: fixture.library,
          installationDirectory: fixture.source,
        );
        final catalog = EngineCatalog(
          library: fixture.library,
          officialEngine: cpp,
          useRegistry: ModelUseRegistry(fixture.library),
          registryFile: File('${fixture.root.path}/engines.json'),
          splashIO: fixture.io,
        );
        return (fixture, cpp, catalog);
      }))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await catalog.shutdown();
          catalog.close();
          cpp.close();
          await fixture.close();
        }),
      );
      var saved = false;
      EngineLaunchConfiguration? savedConfiguration;
      late BuildContext host;
      late LocalModelVariant variant;
      await tester.runAsync(() async {
        final entry = await catalog.link(fixture.source.path);
        variant = LocalModelVariant(
          id: fixture.asset.id,
          label: 'GGUF',
          artifacts: [fixture.asset],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                host = context;
                return const Scaffold();
              },
            ),
          ),
        );
        unawaited(
          showDialog<void>(
            context: host,
            builder: (_) => ModelRunDialog(
              catalog: catalog,
              library: fixture.library,
              modelPackage: LocalModelPackage(
                directoryPath: fixture.source.path,
                name: 'Selected model',
                variants: [variant],
                details: [],
              ),
              variant: variant,
              initialEngineId: entry.id,
              initialConfiguration: EngineLaunchConfiguration(
                family: EngineFamily.splash,
                formValues: {
                  '--compact-draft-head': 'off',
                  '--compact-draft-ranking':
                      '/model-library/kept-ranking.splash',
                  '--compact-draft-capacity': '32768',
                },
              ),
              onSaveInstance: (name, engine, model, configuration) async {
                expect(engine, entry.id);
                expect(model.id, fixture.asset.id);
                expect(configuration.family, EngineFamily.splash);
                expect(configuration.drafter!.enabled, isTrue);
                expect(configuration.formValues['--kv-format'], 'q4h');
                expect(
                  configuration.drafter!.path,
                  '/model-library/explicit-drafter',
                );
                expect(
                  configuration.formValues.containsKey('--compact-draft-head'),
                  isFalse,
                );
                expect(
                  configuration.formValues['--compact-draft-ranking'],
                  '/model-library/public-ranking.splash',
                );
                expect(
                  configuration.formValues['--compact-draft-capacity'],
                  '33024',
                );
                savedConfiguration = configuration;
                saved = true;
              },
            ),
          ),
        );
        await tester.pump();
      });
      await tester.runAsync(() async {
        for (var n = 0; n < 100; n++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('Splash editor did not finish reading engine files');
      });
      expect(find.byKey(const Key('splash-model-assembly')), findsNothing);
      expect(
        find.byKey(const Key('parameter-group-navigation')),
        findsOneWidget,
      );
      expect(find.textContaining('包含 model.json'), findsNothing);
      await tester.tap(find.text('缓存与磁盘').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('parameter-choice:--max-cache-disk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('parameter-choice:--persistent-cache')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('持久缓存需要启用磁盘缓存'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('parameter-choice:--max-cache-disk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('持久缓存需要启用磁盘缓存'), findsNothing);
      await tester.tap(find.text('计算与 ANE').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('parameter-number:--ane-ffn-minimum-rows')),
        '512',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('ANE 最小提交行数需要固定 FFN 分担比例'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('parameter-choice:--ane-ffn-share')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('0.25').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('ANE 最小提交行数需要固定 FFN 分担比例'), findsNothing);
      await tester.ensureVisible(find.text('更多参数').first);
      await tester.tap(find.text('更多参数').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('parameter-choice:--ane-power-recovery')),
      );
      await tester.tap(
        find.byKey(const Key('parameter-choice:--ane-power-recovery')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(
          const Key('parameter-number:--ane-recovery-max-power-percent'),
        ),
      );
      await tester.enterText(
        find.byKey(
          const Key('parameter-number:--ane-recovery-max-power-percent'),
        ),
        '10',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('功耗百分比需要有效功耗参考'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('parameter-choice:--ane-power-reference')),
      );
      await tester.tap(
        find.byKey(const Key('parameter-choice:--ane-power-reference')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('功耗百分比需要有效功耗参考'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('parameter-search')),
        'encoder-option-queries',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('仅适用于 ModernBERT 决策编码器'), findsOneWidget);
      await tester.tap(find.text('草稿模型').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('splash-drafter-enabled')), findsOneWidget);
      expect(
        find.byKey(const Key('parameter-path:drafter-path')),
        findsOneWidget,
      );
      expect(find.text('启动检查列表'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('splash-drafter-enabled')),
      );
      await tester.tap(find.byKey(const Key('splash-drafter-enabled')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(OutlinedButton, '选择…')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多参数').first);
      await tester.pumpAndSettle();
      final ranking = find.byKey(
        const Key('parameter-path:--compact-draft-ranking'),
      );
      final capacity = find.byKey(
        const Key('parameter-number:--compact-draft-capacity'),
      );
      expect(tester.widget<TextField>(ranking).enabled, isFalse);
      expect(tester.widget<TextField>(capacity).enabled, isFalse);
      expect(find.textContaining('compact 已关闭'), findsOneWidget);
      final compact = find.byKey(
        const Key('parameter-choice:--compact-draft-head'),
      );
      await tester.ensureVisible(compact);
      await tester.tap(compact);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(ranking).enabled, isTrue);
      expect(tester.widget<TextField>(capacity).enabled, isTrue);
      final chooseRanking = find.descendant(
        of: find.byKey(const Key('parameter-field:--compact-draft-ranking')),
        matching: find.widgetWithText(OutlinedButton, '选择…'),
      );
      await tester.ensureVisible(chooseRanking);
      await tester.runAsync(() => tester.tap(chooseRanking));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(ranking).controller!.text,
        '/model-library/kept-ranking.splash',
      );
      await tester.runAsync(() => tester.tap(chooseRanking));
      await tester.pumpAndSettle();
      await tester.ensureVisible(capacity);
      await tester.enterText(capacity, '33024');
      await tester.pumpAndSettle();
      final capacityField = find.byKey(
        const Key('parameter-field:--compact-draft-capacity'),
      );
      await tester.tap(
        find.descendant(of: capacityField, matching: find.byTooltip('增加')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(capacity).controller!.text, '33280');
      await tester.tap(
        find.descendant(of: capacityField, matching: find.byTooltip('减少')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(compact);
      await tester.tap(compact);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继承引擎默认').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(ranking).enabled, isFalse);
      expect(tester.widget<TextField>(capacity).controller!.text, '33024');
      await tester.tap(find.text('上下文与内存').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('parameter-choice:--kv-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('q4h').last);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(FilledButton, '保存')),
      );
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      expect(fixture.io.starts, 0);
      expect(
        fixture.io.calls.any(
          (args) => args.any(
            (arg) => arg.contains('# Ghost Model Deck Splash preparation'),
          ),
        ),
        isFalse,
      );
      final savedBeforeCancel = jsonEncode(savedConfiguration!.toJson());
      var unexpectedSave = false;
      await tester.runAsync(() async {
        unawaited(
          showDialog<void>(
            context: host,
            builder: (_) => ModelRunDialog(
              catalog: catalog,
              library: fixture.library,
              modelPackage: LocalModelPackage(
                directoryPath: fixture.source.path,
                name: 'Selected model',
                variants: [variant],
                details: [],
              ),
              variant: variant,
              initialEngineId: catalog.state.entries
                  .singleWhere((entry) => entry.family == EngineFamily.splash)
                  .id,
              initialConfiguration: EngineLaunchConfiguration.fromJson(
                jsonDecode(savedBeforeCancel),
              ),
              onSaveInstance: (name, engine, model, configuration) async {
                unexpectedSave = true;
              },
            ),
          ),
        );
        for (var n = 0; n < 100; n++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await selectParameterGroup(tester, '草稿模型');
      await tester.tap(find.text('更多参数').first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(ranking).controller!.text,
        '/model-library/public-ranking.splash',
      );
      expect(tester.widget<TextField>(capacity).controller!.text, '33024');
      expect(tester.widget<TextField>(ranking).enabled, isFalse);
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.enterText(
        find.byKey(const Key('engine-argument-text')),
        '--compact-draft-h=on',
      );
      await tester.runAsync(() async {
        for (var n = 0; n < 100; n++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .any(
                (text) => text.data?.contains('--compact-draft-h=on') ?? false,
              )) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError(
          'Compact text preview did not finish reading engine identity',
        );
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '草稿模型');
      if (ranking.evaluate().isEmpty) {
        await tester.tap(find.text('更多参数').first);
        await tester.pumpAndSettle();
      }
      expect(tester.widget<TextField>(ranking).enabled, isTrue);
      await tester.ensureVisible(compact);
      await tester.tap(compact);
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭').last);
      await tester.runAsync(() async {
        for (var n = 0; n < 100; n++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (find
                  .descendant(
                    of: find.byKey(
                      const Key('parameter-field:--compact-draft-head'),
                    ),
                    matching: find.text('文本优先'),
                  )
                  .evaluate()
                  .length ==
              1) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('Compact prefix override preview did not finish');
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(ranking).enabled,
        isTrue,
        reason: 'Text on overrides form off',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('parameter-field:--compact-draft-head')),
          matching: find.text('文本优先'),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const Key('splash-drafter-enabled')),
      );
      await tester.tap(find.byKey(const Key('splash-drafter-enabled')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(ranking).enabled, isFalse);
      expect(find.textContaining('保留 compact 设置，不读取 ranking'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(unexpectedSave, isFalse);
      expect(jsonEncode(savedConfiguration!.toJson()), savedBeforeCancel);
      expect(fixture.io.starts, 0);
      expect(
        fixture.io.calls.any(
          (args) => args.any(
            (arg) => arg.contains('# Ghost Model Deck Splash preparation'),
          ),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
