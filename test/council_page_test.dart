import 'dart:async';
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
          await tester.runAsync(council.close);
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
  for (final model in ['quick', 'native']) {
    testWidgets(
      '$model software uses single-call debug and clears old output before cancellation',
      (tester) async {
        late CouncilRuntime runtime;
        late CouncilController council;
        late Completer<void> held, arrived;
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            held = Completer<void>();
            arrived = Completer<void>();
            runtime = await CouncilRuntime.create(modelCount: 1);
            council = CouncilController(catalog: runtime.catalog);
            final binding = council.models.availableBindings.single;
            await council.models.save(
              JevModelDefinition.council(
                name: 'quick',
                seats: [binding],
                timeout: const Duration(seconds: 3),
              ),
            );
            await council.models.save(
              JevModelDefinition.native(name: 'native', binding: binding),
            );
          }, _NetworkBoundary()),
        );
        addTearDown(() async {
          if (!held.isCompleted) held.complete();
          await tester.runAsync(council.close);
          await tester.runAsync(runtime.close);
        });
        runtime.io.respond = (body, raw) async {
          if (body['state'] == 'cancelled') {
            arrived.complete();
            await held.future;
          }
          return jsonEncode({
            ...jsonDecode(raw) as Map,
            'marker': body['state'],
            'diagnostic': {'API_KEY': 'gui-secret'},
          });
        };
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 1200);
        final theme = buildJevTheme(Brightness.light);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: layoutFont),
            ),
            home: Scaffold(
              body: CouncilPage(controller: council, onOpenLibrary: () {}),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('council-model')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(model).last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('council-id-1')), 'accept');
        await tester.enterText(find.byKey(const Key('council-id-2')), 'reject');
        await tester.enterText(
          find.byKey(const Key('council-option-1')),
          'Accept',
        );
        await tester.enterText(
          find.byKey(const Key('council-option-2')),
          'Reject',
        );
        expect(
          tester
              .widget<CheckboxListTile>(find.byKey(const Key('jev-debug')))
              .value,
          false,
        );
        Future<void> completedCall(String marker) async {
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              final idle = runtime.engine.changes.firstWhere(
                (state) =>
                    runtime.io.requests.any((r) => r['state'] == marker) &&
                    state.instances.single.activeRequests == 0,
              );
              await tester.tap(find.text('咨询'));
              await idle.timeout(const Duration(seconds: 4));
              await Future<void>.value();
              await Future<void>.value();
            }, _NetworkBoundary()),
          );
          await tester.pumpAndSettle();
        }

        String output() => tester
            .widget<SelectableText>(
              find.byKey(const Key('jev-standard-output')),
            )
            .data!;
        await tester.enterText(
          find.byKey(const Key('council-context')),
          'first',
        );
        await tester.ensureVisible(find.byKey(const Key('jev-debug')));
        await tester.tap(find.byKey(const Key('jev-debug')));
        await tester.pump();
        await tester.ensureVisible(find.text('咨询'));
        await completedCall('first');
        final first = jsonDecode(output()) as Map;
        expect(first['model'], model);
        expect(first['debug']['input']['state'], 'first');
        expect(output(), isNot(contains('gui-secret')));
        await tester.ensureVisible(find.byTooltip('复制结果'));
        await tester.tap(find.byTooltip('复制结果'));
        await tester.pump();
        expect(copied, output());
        expect(
          tester
              .widget<CheckboxListTile>(find.byKey(const Key('jev-debug')))
              .value,
          false,
        );
        await tester.enterText(
          find.byKey(const Key('council-context')),
          'cancelled',
        );
        await tester.ensureVisible(find.byKey(const Key('jev-debug')));
        await tester.tap(find.byKey(const Key('jev-debug')));
        await tester.pump();
        await tester.ensureVisible(find.text('咨询'));
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await tester.tap(find.text('咨询'));
            await arrived.future.timeout(const Duration(seconds: 3));
          }, _NetworkBoundary()),
        );
        await tester.pump();
        expect(find.byKey(const Key('jev-standard-output')), findsNothing);
        expect(find.text('咨询中'), findsOneWidget);
        await tester.ensureVisible(find.text('取消'));
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final idle = runtime.engine.changes.firstWhere(
              (state) => state.instances.single.activeRequests == 0,
            );
            await tester.tap(find.text('取消'));
            await idle.timeout(const Duration(seconds: 3));
            await Future<void>.value();
            await Future<void>.value();
          }, _NetworkBoundary()),
        );
        await tester.pumpAndSettle();
        final cancelled = jsonDecode(output()) as Map;
        expect(cancelled['error']['code'], 'cancelled');
        expect(cancelled.containsKey('answers'), false);
        expect(cancelled['debug']['input']['state'], 'cancelled');
        final io = model == 'native'
            ? cancelled['debug']['native']
            : (cancelled['debug']['seats'] as List).single;
        expect(io['raw_response'], isNull);
        await tester.ensureVisible(find.byTooltip('复制结果'));
        await tester.tap(find.byTooltip('复制结果'));
        await tester.pump();
        expect(copied, output());
        expect(copied, isNot(contains('"first"')));
        held.complete();
        await tester.enterText(
          find.byKey(const Key('council-context')),
          'third',
        );
        await tester.ensureVisible(find.text('咨询'));
        await completedCall('third');
        expect((jsonDecode(output()) as Map).keys, [
          'model',
          'answers',
          'usage',
        ]);
        expect(runtime.io.killedChildren, 0);
        expect(runtime.engine.state.instances.single.activeRequests, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _NetworkBoundary extends HttpOverrides {}
