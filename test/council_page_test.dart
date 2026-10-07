import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_page.dart';
import 'package:ghost_model_deck/jev_models.dart';

import 'fixtures/council_runtime.dart';

void main() {
  const layoutFont = 'Council Noto CJK';
  setUpAll(() async {
    final font = File(
      Platform.environment['JEV_LAYOUT_FONT'] ??
          '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    expect(await font.exists(), isTrue, reason: 'Noto CJK font is required');
    final loader = FontLoader(layoutFont)
      ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
    await loader.load();
  });
  for (final width in [400.0, 647.0, 880.0]) {
    for (final primitive in ['choice', 'score', 'noul']) {
      testWidgets('named $primitive standard result fits $width at 2x text', (
        tester,
      ) async {
        late CouncilRuntime runtime;
        late CouncilController council;
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            runtime = await CouncilRuntime.create();
            council = CouncilController(catalog: runtime.catalog);
            await council.models.save(
              JevModelDefinition.council(
                name: 'quick',
                seats: council.models.availableBindings,
                timeout: const Duration(seconds: 3),
              ),
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
        tester.view.physicalSize = Size(width, 900);
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
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: CouncilPage(controller: council, onOpenLibrary: () {}),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('council-model')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('quick').last);
        await tester.pumpAndSettle();
        if (primitive != 'choice') {
          await tester.ensureVisible(
            find.byKey(const Key('council-primitive')),
          );
          await tester.tap(find.byKey(const Key('council-primitive')));
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .text(
                  primitive == 'score' ? 'Score · 有序评分' : 'Noul · true-head',
                )
                .last,
          );
          await tester.pumpAndSettle();
        }
        await tester.enterText(
          find.byKey(const Key('council-option-1')),
          '低 / 不成立',
        );
        await tester.enterText(
          find.byKey(const Key('council-option-2')),
          '高 / 成立',
        );
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
            .widget<SelectableText>(
              find.byKey(const Key('jev-standard-output')),
            )
            .data!;
        final value = jsonDecode(output) as Map;
        expect(value.keys, ['model', 'answers', 'usage']);
        expect(value['model'], 'quick');
        expect(value['answers']['council_choice']['type'], primitive);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _NetworkBoundary extends HttpOverrides {}
