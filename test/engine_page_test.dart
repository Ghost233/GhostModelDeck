import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

void main() {
  testWidgets(
    'engine management contains install and association but no model execution or LM Studio connection form',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine official;
      late EngineCatalog catalog;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jev-engine-page-');
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        official = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/engines'),
          useRegistry: use,
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: official,
          useRegistry: use,
          registryFile: File('${root.path}/registry.json'),
        );
      });
      addTearDown(() async {
        catalog.close();
        official.close();
        library.close();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(28),
                child: EnginePage(
                  catalog: catalog,
                  pickEngineDirectory: () async => null,
                ),
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      expect(find.text('关联引擎'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget);
      expect(find.text('运行'), findsNothing);
      expect(find.text('启动模型'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
