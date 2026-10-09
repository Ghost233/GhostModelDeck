import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/council_page.dart';
import 'package:ghost_model_deck/jev_playground_page.dart';

import 'fixtures/playground_runtime.dart';
import 'fixtures/test_environment.dart';

void main() {
  testWidgets('委员会配置只保留创建编辑删除，配置操作不发起内部咨询', (tester) async {
    final fixture = (await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(
        PlaygroundRuntime.create,
        _NetworkBoundary(),
      ),
    ))!;
    fixture.runtime.io.requests.clear();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CouncilPage(controller: fixture.council, onOpenLibrary: () {}),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('委员会配置'), findsOneWidget);
    expect(find.text('咨询'), findsNothing);
    expect(find.byKey(const Key('council-context')), findsNothing);
    expect(find.byKey(const Key('council-primitive')), findsNothing);
    expect(find.byKey(const Key('jev-standard-output')), findsNothing);
    await tester.tap(find.text('创建模型'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('jev-model-name')),
      'new-council',
    );
    final bindings = find.byType(CheckboxListTile);
    await tester.ensureVisible(bindings.first);
    await tester.tap(bindings.first);
    await tester.pump();
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        await tester.tap(find.text('保存'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }, _NetworkBoundary()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-model-new-council')), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-model-new-council')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('jev-model-name')),
      'renamed-council',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-model-renamed-council')), findsOneWidget);
    expect(find.byKey(const Key('edit-model-new-council')), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('delete-model-renamed-council')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.byKey(const Key('edit-model-renamed-council')), findsNothing);
    expect(fixture.runtime.io.requests, isEmpty);
  });

  const layoutFont = 'Council Noto CJK';
  setUpAll(() async {
    final font = layoutFontFile;
    expect(await font.exists(), isTrue, reason: 'Noto CJK font is required');
    final loader = FontLoader(layoutFont)
      ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
    await loader.load();
  });
  for (final width in [400.0, 647.0, 880.0]) {
    for (final primitive in ['choice', 'score', 'noul']) {
      testWidgets(
        'public named $primitive result fits $width at 2x text after consultation migration',
        (tester) async {
          final fixture = (await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              PlaygroundRuntime.create,
              _NetworkBoundary(),
            ),
          ))!;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(fixture.close);
          });
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          await _openPublicPlayground(tester, fixture, layoutFont, scale: 2);
          await _editPublicRequest(
            tester,
            _consultationDocument('quick', primitive),
          );
          await _submitPublic(tester);
          final output = tester
              .widget<SelectableText>(
                find.byKey(const Key('playground-output')),
              )
              .data!;
          final value = jsonDecode(output) as Map;
          expect(value.keys, ['model', 'answers', 'usage']);
          expect(value['model'], 'quick');
          expect(value['answers']['council_choice']['type'], primitive);
          final bounds = tester.getRect(
            find.byKey(const Key('playground-output')),
          );
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final model in ['quick', 'native-kev']) {
    testWidgets(
      '$model public debug copy, cancellation clears old output and late response stays isolated',
      (tester) async {
        final fixture = (await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(
            PlaygroundRuntime.create,
            _NetworkBoundary(),
          ),
        ))!;
        final signals = (await tester.runAsync(
          () async => (Completer<void>(), Completer<void>()),
        ))!;
        final held = signals.$1, arrived = signals.$2;
        addTearDown(() async {
          if (!held.isCompleted) held.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.close);
        });
        fixture.runtime.io.respond = (body, raw) async {
          if (body['state'] == 'cancelled') {
            if (!arrived.isCompleted) arrived.complete();
            await held.future;
          }
          return jsonEncode({
            ...jsonDecode(raw) as Map,
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
        await _openPublicPlayground(tester, fixture, layoutFont);
        await _editPublicRequest(
          tester,
          _consultationDocument(model, 'choice', state: 'first', debug: true),
        );
        await _submitPublic(tester);
        await tester.ensureVisible(
          find.byKey(const Key('playground-debug-expand')),
        );
        await tester.tap(find.byKey(const Key('playground-debug-expand')));
        await tester.pumpAndSettle();
        final debug = tester
            .widget<SelectableText>(
              find.byKey(const Key('playground-debug-output')),
            )
            .data!;
        expect(jsonDecode(debug)['input']['state'], 'first');
        expect(debug, isNot(contains('gui-secret')));
        await tester.ensureVisible(
          find.byKey(const Key('playground-debug-output-copy')),
        );
        await tester.tap(find.byKey(const Key('playground-debug-output-copy')));
        await tester.pump();
        expect(copied, debug);
        await _editPublicRequest(
          tester,
          _consultationDocument(
            model,
            'choice',
            state: 'cancelled',
            debug: true,
          ),
        );
        await tester.ensureVisible(find.byKey(const Key('playground-submit')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await _waitPublicSubmit(tester);
            await tester.tap(find.byKey(const Key('playground-submit')));
            await arrived.future.timeout(const Duration(seconds: 5));
          }, _NetworkBoundary()),
        );
        await tester.pump();
        expect(find.byKey(const Key('playground-output')), findsNothing);
        expect(find.text('测试中'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('playground-cancel')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('playground-cancel')));
          await _waitPublicWidget(
            tester,
            find.byKey(const Key('playground-status')),
          );
          final until = DateTime.now().add(const Duration(seconds: 3));
          while (fixture.runtime.engine.state.instances.any(
            (instance) => instance.activeRequests != 0,
          )) {
            if (DateTime.now().isAfter(until)) {
              fail('public cancellation must release each admitted permit');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('playground-status'))).data,
          contains('客户端已取消'),
        );
        expect(find.byKey(const Key('playground-output')), findsNothing);
        expect(find.byKey(const Key('playground-debug-output')), findsNothing);
        held.complete();
        await _editPublicRequest(
          tester,
          _consultationDocument(model, 'choice', state: 'third', debug: false),
        );
        await _submitPublic(tester);
        final third = jsonDecode(
          tester
              .widget<SelectableText>(
                find.byKey(const Key('playground-output')),
              )
              .data!,
        ) as Map;
        expect(third.keys, ['model', 'answers', 'usage']);
        expect(third['model'], model);
        expect(find.byKey(const Key('playground-debug-output')), findsNothing);
        expect(fixture.runtime.io.killedChildren, 0);
        expect(
          fixture.runtime.engine.state.instances.every(
            (instance) => instance.activeRequests == 0,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _NetworkBoundary extends HttpOverrides {}

Map<String, Object?> _consultationDocument(
  String model,
  String primitive, {
  String state = '',
  bool debug = false,
}) => {
  'model': model,
  'state': state,
  'debug': debug,
  'questions': {
    'council_choice': {
      'type': primitive,
      'instructions': '根据上下文判断：低 / 不成立，高 / 成立。',
      if (primitive == 'choice')
        'criteria': {'accept': '低 / 不成立', 'reject': '高 / 成立'},
      if (primitive == 'score') 'criteria': ['低 / 不成立', '高 / 成立'],
    },
  },
};

Future<void> _openPublicPlayground(
  WidgetTester tester,
  PlaygroundRuntime fixture,
  String font, {
  double scale = 1,
}) async {
  final theme = buildJevTheme(Brightness.light);
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: font),
            primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: font),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: JevPlaygroundPage(gateway: fixture.gateway, mcp: fixture.mcp),
          ),
        ),
      );
    }, _NetworkBoundary()),
  );
  await tester.ensureVisible(find.byKey(const Key('playground-discover')));
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('playground-discover')));
      await _waitPublicWidget(
        tester,
        find.byKey(const Key('playground-discovery')),
      );
    }, _NetworkBoundary()),
  );
  await tester.pump();
  await tester.ensureVisible(find.byKey(const Key('playground-json-mode')));
  await tester.tap(find.byKey(const Key('playground-json-mode')));
  await tester.pump();
}

Future<void> _editPublicRequest(
  WidgetTester tester,
  Map<String, Object?> document,
) async {
  await tester.enterText(
    find.byKey(const Key('playground-json')),
    jsonEncode(document),
  );
  await tester.pump();
}

Future<void> _submitPublic(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('playground-submit')));
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await _waitPublicSubmit(tester);
      await tester.tap(find.byKey(const Key('playground-submit')));
      await _waitPublicWidget(
        tester,
        find.byKey(const Key('playground-output')),
      );
    }, _NetworkBoundary()),
  );
  await tester.pump();
}

Future<void> _waitPublicWidget(WidgetTester tester, Finder finder) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(until)) {
      fail('public playground result did not arrive');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

Future<void> _waitPublicSubmit(WidgetTester tester) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (tester
          .widget<FilledButton>(find.byKey(const Key('playground-submit')))
          .onPressed ==
      null) {
    if (DateTime.now().isAfter(until)) {
      fail('public discovery did not restore a callable model before submit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}
