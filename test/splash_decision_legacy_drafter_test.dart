import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/model_run_dialog.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/parameter_editor.dart';

import 'fixtures/parameter_editor_navigation.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  testWidgets('decision model can disable an unconfirmed old drafter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var drafter = const DrafterConfiguration(
      enabled: true,
      path: '/old/drafter/source',
    );
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
              drafter: drafter,
              onDrafterChanged: (value) => setState(() => drafter = value),
              decisionModel: true,
              legacyDrafter: true,
              showGeneration: false,
            ),
          ),
        ),
      ),
    );
    await selectParameterGroup(tester, '草稿模型');
    expect(find.textContaining('旧草稿绑定待确认'), findsOneWidget);
    final toggle = find.byKey(const Key('splash-drafter-enabled'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(drafter.enabled, isFalse);
    expect(drafter.path, isNull);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
  });

  testWidgets('old Splash decision instance can save with drafter disabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (fixture, cpp, catalog) = (await tester.runAsync(() async {
      final fixture = await SplashRuntimeFixture.create();
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
    EngineLaunchConfiguration? saved;
    await tester.runAsync(() async {
      final manifest = File('${fixture.assembly.path}/model.json');
      final data =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      data['sources'] = {
        'draft': {'repo': '/old/drafter/source'},
      };
      await manifest.writeAsString(jsonEncode(data));
      final entry = await catalog.link(fixture.source.path);
      final variant = LocalModelVariant(
        id: fixture.asset.id,
        label: 'GGUF',
        artifacts: [fixture.asset],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (_) => ModelRunDialog(
                      catalog: catalog,
                      library: fixture.library,
                      modelPackage: LocalModelPackage(
                        directoryPath: fixture.source.path,
                        name: 'Decision',
                        variants: [variant],
                        details: [],
                      ),
                      variant: variant,
                      initialEngineId: entry.id,
                      initialConfiguration: EngineLaunchConfiguration(
                        family: EngineFamily.splash,
                      ),
                      initialSplashAssembly: fixture.assembly,
                      onSaveInstance: (
                        name,
                        engine,
                        model,
                        configuration,
                      ) async => saved = configuration,
                    ),
                  ),
                ),
                child: const Text('编辑'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find
                .byKey(const Key('parameter-group-navigation'))
                .evaluate()
                .isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      throw StateError('Splash editor did not finish loading');
    });
    await selectParameterGroup(tester, '草稿模型');
    expect(find.textContaining('旧草稿绑定待确认'), findsOneWidget);
    final toggle = find.byKey(const Key('splash-drafter-enabled'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
    });
    expect(saved?.drafter?.enabled, isFalse);
    expect(saved?.drafter?.path, isNull);
    expect(fixture.io.starts, 0);
  });
}
