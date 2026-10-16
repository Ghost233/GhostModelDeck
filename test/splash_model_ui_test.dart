import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/model_run_dialog.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/llama_engine.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  testWidgets(
    'Splash instance editor saves model, engine and parameters without a directory or preparation',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
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
      var saved = false;
      await tester.runAsync(() async {
        final entry = await catalog.link(fixture.source.path);
        final variant = LocalModelVariant(
          id: fixture.asset.id,
          label: 'GGUF',
          artifacts: [fixture.asset],
        );
        late BuildContext host;
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
              onSaveInstance: (name, engine, model, configuration) async {
                expect(engine, entry.id);
                expect(model.id, fixture.asset.id);
                expect(configuration.family, EngineFamily.splash);
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
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('Splash editor did not finish reading engine files');
      });
      expect(find.byKey(const Key('splash-model-assembly')), findsNothing);
      expect(find.textContaining('包含 model.json'), findsNothing);
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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
