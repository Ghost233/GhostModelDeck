import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_page.dart';

import 'fixtures/council_runtime.dart';

void main() {
  const layoutFont = 'Council Noto CJK';
  setUpAll(() async {
    final font = File(
      Platform.environment['JEV_LAYOUT_FONT'] ??
          '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    // These geometry regressions must not silently fall back to Ahem.
    expect(await font.exists(), isTrue, reason: 'Noto CJK font is required');
    final loader = FontLoader(layoutFont)
      ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
    await loader.load();
  });

  for (final rejectId in [
    'reject',
    'reject_with_a_long_public_choice_identifier',
  ]) {
    for (final geometry in [
      for (final width in [647.0, 879.0, 880.0])
        for (final scale in [1.0, 1.5, 2.0]) (width: width, scale: scale),
      (width: 400.0, scale: 2.0),
    ]) {
      testWidgets(
        'public tied Choice fits page ${geometry.width} at ${geometry.scale}x with $rejectId',
        (tester) async {
          late CouncilRuntime runtime;
          late CouncilController council;
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              runtime = await CouncilRuntime.create();
              // Adapt only the external HTTP response to the submitted ID.
              runtime.io.respond = (request, response) async {
                final body = jsonDecode(response) as Map<String, dynamic>;
                final answer = body['answers']['council_choice'] as Map;
                if (answer['choice'] == 'reject') answer['choice'] = rejectId;
                final probabilities = answer['probabilities'] as Map;
                probabilities[rejectId] = probabilities.remove('reject');
                return jsonEncode(body);
              };
              council = CouncilController(catalog: runtime.catalog);
              council.selectSeats(
                council.availableSeats.map((seat) => seat.id),
              );
            }, _NetworkBoundary()),
          );
          addTearDown(() async {
            council.close();
            await tester.runAsync(runtime.close);
          });
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(geometry.width, 900);
          final theme = buildJevTheme(Brightness.light);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: layoutFont),
                primaryTextTheme: theme.primaryTextTheme.apply(
                  fontFamily: layoutFont,
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(geometry.scale)),
                child: child!,
              ),
              home: Scaffold(
                body: CouncilPage(controller: council, onOpenLibrary: () {}),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'input before result');
          await tester.enterText(
            find.byKey(const Key('council-id-1')),
            'accept',
          );
          await tester.enterText(
            find.byKey(const Key('council-id-2')),
            rejectId,
          );
          await tester.enterText(
            find.byKey(const Key('council-option-1')),
            '低 / 不成立',
          );
          await tester.enterText(
            find.byKey(const Key('council-option-2')),
            '高 / 成立',
          );
          await tester.pump();
          final button = find.widgetWithText(FilledButton, '咨询');
          await tester.ensureVisible(button);
          expect(
            tester.takeException(),
            isNull,
            reason: 'input before request',
          );
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              final done = council.changes.firstWhere(
                (state) => state.lastResult != null,
              );
              await tester.tap(button);
              await done.timeout(const Duration(seconds: 3));
            }, _NetworkBoundary()),
          );
          await tester.pumpAndSettle();
          expect(council.state.lastResult!.aggregateScores, {
            'accept': 0.5,
            rejectId: 0.5,
          });
          expect(council.state.lastResult!.topChoices, ['accept', rejectId]);
          expect(runtime.io.requests, hasLength(2));
          expect(find.text('综合评分'), findsOneWidget);
          expect(find.text('并列最高'), findsNWidgets(2));
          expect(find.text('50.0%'), findsNWidgets(2));
          expect(find.text('accept · 1 票'), findsOneWidget);
          expect(find.text('$rejectId · 1 票'), findsOneWidget);
          for (final label in ['低 / 不成立', '高 / 成立']) {
            expect(
              find.byWidgetPredicate(
                (widget) => widget is Text && widget.data == label,
              ),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull, reason: 'published result');
          expect(runtime.io.killedChildren, 0);
        },
      );
    }
  }

  testWidgets(
    'existing Council controls display the latest Score Choice Noul Choice publication',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(catalog: runtime.catalog);
          council.selectSeats(council.availableSeats.map((s) => s.id));
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        council.close();
        await tester.runAsync(runtime.close);
      });
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: CouncilPage(controller: council, onOpenLibrary: () {}),
          ),
        ),
      );
      for (final primitive in [
        'Score · 有序评分',
        'Choice · 候选选择',
        'Noul · true-head',
        'Choice · 候选选择',
      ]) {
        await tester.tap(find.byKey(const Key('council-primitive')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(primitive).last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('council-option-1')),
          '低 / 不成立',
        );
        await tester.enterText(
          find.byKey(const Key('council-option-2')),
          '高 / 成立',
        );
        if (primitive.startsWith('Choice')) {
          await tester.enterText(
            find.byKey(const Key('council-id-1')),
            'accept',
          );
          await tester.enterText(
            find.byKey(const Key('council-id-2')),
            'reject',
          );
          await tester.enterText(
            find.byKey(const Key('council-context')),
            'latest choice',
          );
        }
        await tester.pump();
        final button = find.widgetWithText(FilledButton, '咨询');
        await tester.ensureVisible(button);
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final previous = council.state;
            final done = council.changes.firstWhere(
              (s) => primitive.startsWith('Choice')
                  ? s.lastResult != null &&
                        !identical(previous.lastResult, s.lastResult)
                  : s.lastBatchResult != null &&
                        !identical(previous.lastBatchResult, s.lastBatchResult),
            );
            await tester.tap(button);
            await done.timeout(const Duration(seconds: 3));
          }, _NetworkBoundary()),
        );
        await tester.pumpAndSettle();
        if (primitive.startsWith('Choice')) {
          expect(council.state.lastResult!.aggregateScores, {
            'accept': 0.5,
            'reject': 0.5,
          });
          expect(council.state.lastResult!.request.state, 'latest choice');
          expect(
            council.state.lastBatchResult,
            isNotNull,
            reason: 'typed history is retained',
          );
          expect(find.text('综合评分'), findsOneWidget);
          expect(find.textContaining('期望索引'), findsNothing);
          expect(find.textContaining('true-head scalar'), findsNothing);
        } else {
          expect(council.state.lastBatchResult!.scope, CouncilScope.ensemble);
          final expected = primitive.startsWith('Score')
              ? '期望索引 0.7500'
              : 'true-head scalar 0.8000';
          expect(find.textContaining(expected), findsOneWidget);
          expect(find.text('综合评分'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = primitive.startsWith('Choice')
            ? const Size(1200, 900)
            : const Size(400, 800);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(1200, 900);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('council-primitive')));
      }
      expect(runtime.io.killedChildren, 0);
    },
  );

  testWidgets(
    'desktop cancellation returns every seat status and keeps the resident models',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(catalog: runtime.catalog);
          council.selectSeats(council.availableSeats.map((seat) => seat.id));
          runtime.io.holdConsultation();
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        council.close();
        await tester.runAsync(runtime.close);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(28),
              child: CouncilPage(controller: council, onOpenLibrary: () {}),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const Key('council-id-1')), 'accept');
      await tester.enterText(find.byKey(const Key('council-option-1')), '接受');
      await tester.enterText(find.byKey(const Key('council-id-2')), 'reject');
      await tester.enterText(find.byKey(const Key('council-option-2')), '拒绝');
      await tester.pump();
      final consultButton = find.widgetWithText(FilledButton, '咨询');
      await tester.ensureVisible(consultButton);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(consultButton);
          await runtime.io.bothArrived!.future.timeout(
            const Duration(seconds: 2),
          );
        }, _NetworkBoundary()),
      );
      await tester.pump();
      expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
      await tester.runAsync(() async {
        final done = council.changes.firstWhere(
          (state) => state.lastResult != null,
        );
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await done.timeout(const Duration(seconds: 2));
        runtime.io.release!.complete();
      });
      await tester.pumpAndSettle();
      expect(find.text('咨询失败'), findsOneWidget);
      expect(find.text('已取消'), findsNWidgets(2));
      expect(find.text('综合评分'), findsNothing);
      expect(runtime.io.killedChildren, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'an empty council offers the model library without inventing seats or results',
    (tester) async {
      late CouncilRuntime runtime;
      await tester.runAsync(() async {
        runtime = await CouncilRuntime.create(modelCount: 0);
      });
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(() async {
        council.close();
        await tester.runAsync(runtime.close);
      });
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(28),
              child: CouncilPage(
                controller: council,
                onOpenLibrary: () {
                  opened = true;
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('暂无运行中模型'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('综合评分'), findsNothing);
      await tester.tap(find.text('打开模型库'));
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the desktop consultation uses selected running seats and shows a real tied result',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(catalog: runtime.catalog);
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        council.close();
        await tester.runAsync(runtime.close);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(28),
              child: CouncilPage(controller: council, onOpenLibrary: () {}),
            ),
          ),
        ),
      );
      expect(find.byType(FilterChip), findsNWidgets(2));
      expect(find.text('综合评分'), findsNothing);
      for (final chip in find.byType(FilterChip).evaluate().toList()) {
        await tester.tap(find.byWidget(chip.widget));
        await tester.pump();
      }
      await tester.enterText(find.byKey(const Key('council-context')), '允许接受');
      await tester.enterText(find.byKey(const Key('council-id-1')), 'accept');
      await tester.enterText(find.byKey(const Key('council-option-1')), '接受');
      await tester.enterText(find.byKey(const Key('council-id-2')), 'reject');
      await tester.enterText(find.byKey(const Key('council-option-2')), '拒绝');
      await tester.pump();
      expect(council.selectedSeatIds, hasLength(2));
      final consultButton = find.widgetWithText(FilledButton, '咨询');
      expect(tester.widget<FilledButton>(consultButton).onPressed, isNotNull);
      await tester.ensureVisible(consultButton);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final done = council.changes.firstWhere(
            (state) => state.lastResult != null,
          );
          await tester.tap(consultButton);
          await done.timeout(const Duration(seconds: 5));
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      expect(council.state.lastResult!.aggregateScores, {
        'accept': 0.5,
        'reject': 0.5,
      });
      expect(find.text('综合评分'), findsOneWidget);
      expect(find.text('并列最高'), findsNWidgets(2));
      expect(find.text('50.0%'), findsNWidgets(2));
      expect(find.textContaining('分歧 50.0%'), findsOneWidget);
      expect(find.text('原始响应'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stopped selected seat stays visible until the user removes it',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          runtime = await CouncilRuntime.create();
          council = CouncilController(catalog: runtime.catalog);
          council.selectSeats(council.availableSeats.map((seat) => seat.id));
          await runtime.engine.stop(council.availableSeats.first.instance.id);
        }, _NetworkBoundary()),
      );
      addTearDown(() async {
        council.close();
        await tester.runAsync(runtime.close);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(28),
              child: CouncilPage(controller: council, onOpenLibrary: () {}),
            ),
          ),
        ),
      );
      expect(find.byType(FilterChip), findsNWidgets(2));
      await tester.runAsync(() async {
        final changed = council.changes.firstWhere(
          (_) => council.selectedSeatIds.length == 1,
        );
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is FilterChip &&
                widget.label is Text &&
                ((widget.label as Text).data?.endsWith(' · 未就绪') ?? false),
          ),
        );
        await changed.timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(council.selectedSeatIds, hasLength(1));
      expect(find.textContaining('未就绪'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
