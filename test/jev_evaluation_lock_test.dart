import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_page.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/jev_models.dart';

import 'fixtures/council_runtime.dart';

void main() {
  testWidgets(
    'participating configuration controls stay disabled until release',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(catalog: runtime.catalog);
          await council.models.save(
            JevModelDefinition.council(
              name: 'quick',
              seats: [council.models.availableBindings.first],
              timeout: const Duration(seconds: 9),
            ),
          );
        }, _RealNetwork()),
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
      final selection = await tester.runAsync(
        () => council.models.lockForEvaluation('quick'),
      );
      addTearDown(selection!.release);
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('edit-model-quick')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('delete-model-quick')))
            .onPressed,
        isNull,
      );
      selection.release();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('edit-model-quick')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('delete-model-quick')))
            .onPressed,
        isNotNull,
      );
    },
  );
  test(
    'evaluation locks only its named configuration and permits manual stop',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final runtime = await CouncilRuntime.create();
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      final binding = council.models.availableBindings.first;
      final definition = JevModelDefinition.council(
        name: 'quick',
        seats: [binding],
        timeout: const Duration(seconds: 9),
      );
      await council.models.save(definition);
      runtime.io.requests.clear();
      final selection = await council.models.lockForEvaluation('quick');
      expect(selection.isCurrent, isTrue);
      expect(selection.identity['model'], 'quick');
      expect(selection.identity['configuration'], definition.toJson());
      expect(council.models.isEvaluationLocked('quick'), isTrue);
      await expectLater(
        council.models.save(definition, replacing: 'quick'),
        throwsA(isA<DecisionProtocolException>()),
      );
      await expectLater(
        council.models.save(
          JevModelDefinition.council(
            name: 'renamed',
            seats: [binding],
            timeout: const Duration(seconds: 9),
          ),
          replacing: 'quick',
        ),
        throwsA(isA<DecisionProtocolException>()),
      );
      await expectLater(
        council.models.delete('quick'),
        throwsA(isA<DecisionProtocolException>()),
      );
      await council.models.save(
        JevModelDefinition.council(
          name: 'other',
          seats: [binding],
          timeout: const Duration(seconds: 9),
        ),
      );
      await council.models.delete('other');
      expect(selection.isCurrent, isTrue);
      final instance = runtime.engine.state.instances.singleWhere(
        (instance) => instance.asset.id == binding.artifactId,
      );
      await runtime.engine.stop(instance.id);
      expect(selection.isCurrent, isFalse);
      expect(runtime.io.requests, isEmpty);
      selection.release();
      selection.release();
      expect(council.models.isEvaluationLocked('quick'), isFalse);
      await council.models.delete('quick');
      expect(council.models.definitions, isEmpty);
    }, _RealNetwork()),
  );
}

class _RealNetwork extends HttpOverrides {}
