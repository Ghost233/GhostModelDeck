import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_page.dart';

import 'fixtures/council_runtime.dart';

void main() {
  testWidgets(
    'software creates and selects persistent named council and native models with standard output',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(
            catalog: runtime.catalog,
            modelRegistryFile: File('${runtime.root.path}/models.json'),
          );
          await council.models.load();
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        council.close();
        await tester.runAsync(runtime.close);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CouncilPage(controller: council, onOpenLibrary: () {}),
          ),
        ),
      );
      await tester.tap(find.text('创建模型'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('jev-model-name')), 'quick');
      await tester.enterText(find.byKey(const Key('jev-model-timeout')), '2');
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(CheckboxListTile),
            )
            .first,
      );
      await tester.runAsync(() async {
        final done = council.models.changes.first;
        await tester.tap(find.text('保存'));
        await done.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(council.models.definitions.single.name, 'quick');
      expect(find.textContaining('quick'), findsWidgets);
      await tester.enterText(find.byKey(const Key('council-option-1')), 'A');
      await tester.enterText(find.byKey(const Key('council-option-2')), 'B');
      await tester.pump();
      await tester.ensureVisible(find.text('咨询'));
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final done = council.changes.firstWhere(
            (s) => s.lastBatchResult != null && !s.busy,
          );
          await tester.tap(find.text('咨询'));
          await done.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(Duration.zero);
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      final output = tester
          .widget<SelectableText>(find.byKey(const Key('jev-standard-output')))
          .data!;
      final decoded = jsonDecode(output) as Map;
      expect(decoded.keys, ['model', 'answers', 'usage']);
      expect(decoded['model'], 'quick');
      expect(decoded['answers']['council_choice']['confidence'], 0.5);
      await tester.ensureVisible(find.byKey(const Key('edit-model-quick')));
      await tester.tap(find.byKey(const Key('edit-model-quick')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('jev-model-name')),
        'native-kev',
      );
      await tester.tap(find.byKey(const Key('jev-model-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原生 JEV').last);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final done = council.models.changes.first;
        await tester.tap(find.text('保存'));
        await done.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(council.models.definitions.single.name, 'native-kev');
      expect(council.models.definitions.single.source.name, 'native');
      await tester.ensureVisible(
        find.byKey(const Key('delete-model-native-kev')),
      );
      await tester.runAsync(() async {
        final done = council.models.changes.first;
        await tester.tap(find.byKey(const Key('delete-model-native-kev')));
        await done.timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(council.models.definitions, isEmpty);
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
