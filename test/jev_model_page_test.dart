import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_page.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/jev_playground_page.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/council_mcp.dart';

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
      late PublicModelRoutes routes;
      late PublicGatewayServer gateway;
      late CouncilMcpServer mcp;

      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(
            catalog: runtime.catalog,
            modelRegistryFile: File('${runtime.root.path}/models.json'),
          );
          await council.models.load();
          routes = PublicModelRoutes(
            library: runtime.library,
            runtimes: [runtime.engine],
          );
          gateway = PublicGatewayServer(
            routes: routes,
            jevModels: council.models,
            port: 0,
          );
          mcp = CouncilMcpServer(controller: council, port: 0);
          await gateway.start();
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await mcp.close();
          await gateway.stop();
          gateway.close();
          routes.close();
        });

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
      // The configuration page creates the persistent identity; manual
      // inference then traverses the actual playground's ordinary public HTTP.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JevPlaygroundPage(gateway: gateway, mcp: mcp),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('playground-discover')));
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.byKey(const Key('playground-discover')));
          await tester.pump();
          await _waitForPage(
            tester,
            find.byKey(const Key('playground-discovery')),
          );
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      final discovered = jsonDecode(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('playground-discovery')),
            )
            .data!,
      ) as Map;
      expect(
        (discovered['data'] as List).map((entry) => entry['id']),
        contains('quick'),
      );
      await tester.ensureVisible(find.byKey(const Key('playground-json-mode')));
      await tester.tap(find.byKey(const Key('playground-json-mode')));
      await tester.pump();
      final document = {
        'model': 'quick',
        'state': 'Check the saved council model through its public identity.',
        'questions': {
          'council_choice': {
            'type': 'choice',
            'instructions': 'Choose the best option.',
            'criteria': {'accept': 'A', 'reject': 'B'},
          },
        },
      };
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode(document),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('playground-submit')));
      await tester.pumpAndSettle();
      final engineRequestsBefore = runtime.io.requests.length;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.byKey(const Key('playground-submit')));
          await tester.pump();
          await _waitForPage(
            tester,
            find.byKey(const Key('playground-output')),
          );
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      final output = tester
          .widget<SelectableText>(find.byKey(const Key('playground-output')))
          .data!;
      final decoded = jsonDecode(output) as Map;
      expect(decoded.keys, ['model', 'answers', 'usage']);
      expect(decoded['model'], 'quick');
      expect(decoded['answers']['council_choice']['confidence'], 0.5);
      expect(decoded['answers'].keys, ['council_choice']);
      expect(decoded['usage'], {'input_tokens': 10, 'output_tokens': 0});
      expect(runtime.io.requests.length, engineRequestsBefore + 1);
      expect(runtime.io.requests.last['questions'], document['questions']);
      expect(runtime.io.requests.last['state'], document['state']);
      final nativeInstance = runtime.engine.state.instances.singleWhere(
        (instance) =>
            instance.asset.id ==
            council.models.definitions.single.bindings.single.artifactId,
      );
      expect(runtime.io.requests.last['model'], nativeInstance.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CouncilPage(controller: council, onOpenLibrary: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
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

Future<void> _waitForPage(WidgetTester tester, Finder finder) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(until)) {
      fail('The actual public JEV playground action did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

class _NetworkBoundary extends HttpOverrides {}
