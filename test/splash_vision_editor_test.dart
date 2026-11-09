import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  testWidgets(
    'Splash vision editor switches from automatic to a picked GGUF and back',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('com.ghost233.ghostmodeldeck/native');
      final path =
          '/models/${List.filled(14, 'a-long-model-directory').join('/')}/model-mmproj.gguf';
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickParameterFile');
        expect(call.arguments, {
          'extensions': ['gguf'],
        });
        return path;
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
      expect(vision, (enabled: true, projector: path));
      final editable = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      final RenderEditable render = editable.renderEditable;
      expect(editable.widget.controller.text, path);
      expect(
        render.getLocalRectForCaret(TextPosition(offset: path.length)).top,
        greaterThan(
          render.getLocalRectForCaret(const TextPosition(offset: 0)).top,
        ),
      );
      await tester.enterText(
        find.descendant(of: field, matching: find.byType(TextField)),
        '',
      );
      await tester.pumpAndSettle();
      expect(vision, (enabled: true, projector: null));
    },
  );

  testWidgets(
    'Splash selects and saves the detected projector and respects a manual choice during a probe',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (fixture, catalog, cpp, entry, automatic) = (await tester.runAsync(
        () async {
          final fixture = await SplashRuntimeFixture.create();
          final cpp = LlamaEngine(
            library: fixture.library,
            installationDirectory: Directory('${fixture.root.path}/cpp'),
          );
          final catalog = EngineCatalog(
            library: fixture.library,
            officialEngine: cpp,
            useRegistry: ModelUseRegistry(fixture.library),
            splashIO: fixture.io,
            registryFile: File('${fixture.root.path}/engines.json'),
          );
          final entry = await catalog.link(fixture.source.path);
          final folder = File(fixture.asset.files.single.path).parent;
          final file = await File('${folder.path}/model-mmproj-BF16.gguf')
              .writeAsString('test projector');
          return (fixture, catalog, cpp, entry, file.path);
        },
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await catalog.shutdown();
          catalog.close();
          cpp.close();
          await fixture.close();
        }),
      );
      const manual = '/models/selected-mmproj.gguf';
      const channel = MethodChannel('com.ghost233.ghostmodeldeck/native');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => manual);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final heldProbe = Completer<void>();
      var probes = 0;
      fixture.io.beforePreparation = (request) async {
        expect(request['probe_projector'], fixture.asset.files.single.path);
        if (++probes == 2) await heldProbe.future;
      };
      EngineLaunchConfiguration? saved;
      final variant = LocalModelVariant(
        id: fixture.asset.id,
        label: 'GGUF',
        artifacts: [fixture.asset],
      );
      final save = find.widgetWithText(FilledButton, '保存');
      final path = find.byKey(
        const Key('parameter-path:splash-vision-projector'),
      );
      String pathValue() => tester.widget<TextField>(path).controller!.text;
      Future<void> waitFor(bool Function() condition) async {
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('Vision editor did not reach the expected state');
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ModelRunDialog(
              catalog: catalog,
              library: fixture.library,
              modelPackage: LocalModelPackage(
                directoryPath: fixture.source.path,
                name: 'Vision target',
                variants: [variant],
                details: [],
              ),
              variant: variant,
              initialEngineId: entry.id,
              initialConfiguration: EngineLaunchConfiguration(
                family: EngineFamily.splash,
                drafter: const DrafterConfiguration(enabled: false),
              ),
              onSaveInstance: (_, _, _, configuration) async =>
                  saved = configuration,
            ),
          ),
        );
        await waitFor(
          () => tester.widget<FilledButton>(save).onPressed != null,
        );
      });
      await selectParameterGroup(tester, '视觉输入');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('splash-vision-enabled')));
        await waitFor(() => pathValue() == automatic);
        await tester.enterText(path, '');
        await waitFor(() => probes == 2);
      });
      final field = find.byKey(const Key('splash-vision-projector'));
      await tester.tap(
        find.descendant(
          of: field,
          matching: find.widgetWithText(OutlinedButton, '选择…'),
        ),
      );
      await tester.pumpAndSettle();
      expect(pathValue(), manual);
      heldProbe.complete();
      await tester.pumpAndSettle();
      expect(pathValue(), manual);
      await tester.runAsync(() async {
        await tester.enterText(path, '');
        await waitFor(() => pathValue() == automatic);
        await tester.tap(save);
        await waitFor(() => saved != null);
      });
      expect(EngineLaunchConfiguration.fromJson(saved!.toJson()).splashVision, (
        enabled: true,
        projector: automatic,
      ));
    },
  );
}
