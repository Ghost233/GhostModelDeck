import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_page.dart';
import 'package:ghost_model_deck/jev_models.dart';

import 'fixtures/council_runtime.dart';

void main() {
  testWidgets(
    'editing preserves unavailable saved bindings until explicitly removed',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      late JevModelBinding remaining;
      late JevModelBinding removed;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(
            catalog: runtime.catalog,
            modelRegistryFile: File('${runtime.root.path}/models.json'),
          );
          final bindings = council.models.availableBindings;
          remaining = bindings.first;
          removed = bindings.last;
          await council.models.save(
            JevModelDefinition.council(
              name: 'quick',
              seats: bindings,
              timeout: const Duration(seconds: 2),
            ),
          );
          final instance = runtime.engine.state.instances.singleWhere(
            (instance) => instance.asset.id == removed.artifactId,
          );
          await runtime.engine.stop(instance.id);
          final plan = await runtime.library.prepareDeletion([
            removed.artifactId,
          ]);
          await runtime.library.delete(plan, confirmed: true);
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        await tester.runAsync(council.close);
        await tester.runAsync(runtime.close);
      });
      expect(council.models.availableBindings, hasLength(1));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CouncilPage(controller: council, onOpenLibrary: () {}),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('edit-model-quick')));
      await tester.tap(find.byKey(const Key('edit-model-quick')));
      await tester.pumpAndSettle();
      final checkboxes = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(CheckboxListTile),
      );
      expect(checkboxes, findsNWidgets(2));
      expect(
        tester
            .widgetList<CheckboxListTile>(checkboxes)
            .map((tile) => tile.value),
        everyElement(isTrue),
      );
      final unavailableLabel = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining(removed.artifactId),
      );
      expect(unavailableLabel, findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('jev-model-name')),
        'renamed',
      );
      await tester.enterText(find.byKey(const Key('jev-model-timeout')), '3');
      await tester.runAsync(() async {
        await tester.tap(find.text('保存'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('席位必须绑定已登记的本机 JEV 模型与兼容引擎'), findsOneWidget);
      await tester.runAsync(() async {
        final restored = CouncilController(
          catalog: runtime.catalog,
          modelRegistryFile: File('${runtime.root.path}/models.json'),
        );
        try {
          await restored.models.load();
          final saved = restored.models.definitions.single;
          expect(saved.name, 'quick');
          expect(saved.timeout, const Duration(seconds: 2));
          expect(saved.bindings.map((binding) => binding.id), [
            remaining.id,
            removed.id,
          ]);
        } finally {
          await restored.close();
        }
      });
      final unavailableCheckbox = find.ancestor(
        of: unavailableLabel,
        matching: find.byType(CheckboxListTile),
      );
      await tester.ensureVisible(unavailableCheckbox);
      await tester.tap(unavailableCheckbox);
      await tester.runAsync(() async {
        final done = council.models.changes.first;
        await tester.tap(find.text('保存'));
        await done.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final saved = council.models.definitions.single;
      expect(saved.name, 'renamed');
      expect(saved.timeout, const Duration(seconds: 3));
      expect(saved.bindings.map((binding) => binding.id), [remaining.id]);
    },
  );
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
        await tester.runAsync(council.close);
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
