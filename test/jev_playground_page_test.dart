import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/jev_playground_page.dart';

import 'fixtures/playground_runtime.dart';
import 'fixtures/test_environment.dart';

void main() {
  setUp(() {
    // Production notifications can refresh the public endpoint asynchronously.
    // These tests retain real loopback HTTP rather than Flutter's default 400.
    final previous = HttpOverrides.current;
    HttpOverrides.global = _Network();
    addTearDown(() => HttpOverrides.global = previous);
  });
  for (final action in ['cancel', 'confirm', 'open']) {
    testWidgets(
      'JEV rapid export dialog $action preserves the page and actual result',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final fixture = (await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              PlaygroundRuntime.create,
              _Network(),
            ),
          ))!;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(fixture.close);
          });
          tester.view.physicalSize = const Size(1000, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final observer = _ExportRouteObserver();
          final screen = MaterialApp(
            navigatorObservers: [observer],
            home: Scaffold(
              body: JevPlaygroundPage(
                gateway: fixture.gateway,
                mcp: fixture.mcp,
              ),
            ),
          );
          await tester.pumpWidget(screen);
          await _discoverPublicModels(tester);
          await tester.ensureVisible(
            find.byKey(const Key('playground-json-mode')),
          );
          await tester.tap(find.byKey(const Key('playground-json-mode')));
          await tester.pump();
          final document = playgroundDocument(
            'quick',
            state: 'retained dialog input',
          );
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            jsonEncode(document),
          );
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              await tester.tap(find.byKey(const Key('playground-submit')));
              final until = DateTime.now().add(const Duration(seconds: 5));
              while (find
                  .byKey(const Key('playground-output'))
                  .evaluate()
                  .isEmpty) {
                if (DateTime.now().isAfter(until)) {
                  fail('Actual public dialog input request did not complete');
                }
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await tester.pump();
              }
            }, _Network()),
          );
          await tester.pumpAndSettle();
          final originalResult = tester
              .widget<SelectableText>(
                find.byKey(const Key('playground-output')),
              )
              .data;
          await tester.ensureVisible(
            find.byKey(const Key('playground-export')),
          );
          await tester.pumpAndSettle();
          tester.semantics.tap(find.semantics.byLabel('导出 JSON'));
          if (action == 'open') {
            // Native accessibility may deliver two activations before a frame.
            tester.semantics.tap(find.semantics.byLabel('导出 JSON'));
          }
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
          final destination = File(
            '${fixture.runtime.root.path}/rapid-dialog.json',
          );
          if (action == 'confirm') {
            await tester.enterText(
              find.byKey(const Key('playground-export-path')),
              destination.path,
            );
          }
          await tester.runAsync(() async {
            final dismiss = find.semantics.byLabel(
              action == 'confirm' ? '保存' : '取消',
            );
            tester.semantics.tap(dismiss);
            if (action != 'open') {
              tester.semantics.tap(dismiss);
            }
          });
          await tester.pumpAndSettle();
          expect(
            observer.popped.length,
            1,
            reason: 'Only the export dialog route may close once.',
          );
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(JevPlaygroundPage), findsOneWidget);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('playground-json')))
                .controller!
                .text,
            jsonEncode(document),
          );
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('playground-output')),
                )
                .data,
            originalResult,
          );
          expect(tester.takeException(), isNull);
          if (action == 'confirm') {
            await tester.runAsync(() async {
              final until = DateTime.now().add(const Duration(seconds: 5));
              while (find
                  .byKey(const Key('playground-export-status'))
                  .evaluate()
                  .isEmpty) {
                if (DateTime.now().isAfter(until)) {
                  fail('Export write did not complete');
                }
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await tester.pump();
              }
            });
            final saved = (await tester.runAsync(destination.readAsString))!;
            expect(jsonDecode(saved)['request'], document);
          }
          // Cancellation must release the dialog lock for a later deliberate open.
          await tester.ensureVisible(
            find.byKey(const Key('playground-export')),
          );
          await tester.tap(find.byKey(const Key('playground-export')));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('取消'),
            ),
          );
          await tester.pumpAndSettle();
          expect(observer.popped.length, 2);
          expect(find.byType(JevPlaygroundPage), findsOneWidget);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  testWidgets(
    'the form adds all three JEV primitives and submits a public mixed batch',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          PlaygroundRuntime.create,
          _Network(),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JevPlaygroundPage(gateway: fixture.gateway, mcp: fixture.mcp),
          ),
        ),
      );
      await _discoverPublicModels(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('playground-model-http')),
      );
      await tester.tap(find.byKey(const ValueKey('playground-model-http')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('quick').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('playground-add-noul')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('playground-add-noul')));
      await tester.tap(find.byKey(const Key('playground-add-noul')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('playground-add-score')));
      await tester.tap(find.byKey(const Key('playground-add-score')));
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(TextFormField, '低'));
      await tester.enterText(find.widgetWithText(TextFormField, '低'), 'Low');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('playground-json-mode')));
      await tester.tap(find.byKey(const Key('playground-json-mode')));
      await tester.pump();
      final document = jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('playground-json')))
            .controller!
            .text,
      ) as Map;
      final questions = document['questions'] as Map;
      expect(questions.values.map((q) => q['type']), [
        'choice',
        'noul',
        'score',
      ]);
      final noulId = questions.keys.singleWhere(
        (id) => questions[id]['type'] == 'noul',
      );
      final scoreId = questions.keys.singleWhere(
        (id) => questions[id]['type'] == 'score',
      );
      expect(questions[scoreId]['criteria'], ['Low', '高']);
      await tester.ensureVisible(find.byKey(const Key('playground-submit')));
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.byKey(const Key('playground-submit')));
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (find
              .byKey(const Key('playground-status'))
              .evaluate()
              .isEmpty) {
            if (DateTime.now().isAfter(until)) {
              fail('mixed form request did not finish');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        }, _Network()),
      );
      await tester.pumpAndSettle();
      final output = jsonDecode(
        tester
            .widget<SelectableText>(find.byKey(const Key('playground-output')))
            .data!,
      );
      expect(output['model'], 'quick');
      expect(output['answers'][noulId], {'type': 'noul', 'noul': 0.8});
      expect(output['answers'][scoreId]['legend'], {'0': 'Low', '1': '高'});
      expect(output['answers']['route']['choice'], 'b');
      expect(fixture.runtime.io.requests.last['questions'], questions);
      await tester.runAsync(() async {
        for (final instance
            in fixture.runtime.engine.state.instances.toList()) {
          await fixture.runtime.engine.stop(instance.id);
        }
      });
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('playground-submit')))
            .onPressed,
        isNull,
      );
      expect(
        jsonDecode(
          tester
              .widget<TextField>(find.byKey(const Key('playground-json')))
              .controller!
              .text,
        ),
        document,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'public call evidence keeps the edited deadline and exports the actual request snapshot',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          PlaygroundRuntime.create,
          _Network(),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JevPlaygroundPage(gateway: fixture.gateway, mcp: fixture.mcp),
          ),
        ),
      );
      await _discoverPublicModels(tester);
      await tester.tap(find.byKey(const Key('playground-json-mode')));
      await tester.pump();
      final original = playgroundDocument(
        'quick',
        state: {
          'payload': ['保留', 4],
        },
      );
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode(original),
      );
      expect(find.byKey(const Key('playground-timeout')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('playground-timeout')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('playground-timeout')))
            .controller!
            .text,
        '30',
      );
      await tester.enterText(
        find.byKey(const Key('playground-timeout')),
        '1.5',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('playground-submit')));
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.byKey(const Key('playground-submit')));
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (find
              .byKey(const Key('playground-status'))
              .evaluate()
              .isEmpty) {
            if (DateTime.now().isAfter(until)) {
              fail('public call did not finish');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        }, _Network()),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playground-result-meta')))
            .data,
        contains('1500 ms'),
      );
      final raw = tester
          .widget<SelectableText>(
            find.byKey(const Key('playground-raw-response')),
          )
          .data!;
      expect(jsonDecode(raw)['model'], 'quick');
      await tester.ensureVisible(find.byKey(const Key('playground-json')));
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode({...original, 'state': 'edited after call'}),
      );
      await tester.pump();
      final destination = File('${fixture.runtime.root.path}/page-export.json');
      await tester.ensureVisible(find.byKey(const Key('playground-export')));
      await tester.tap(find.byKey(const Key('playground-export')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('playground-export-path')),
        destination.path,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('playground-export-save')));
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (find
            .byKey(const Key('playground-export-status'))
            .evaluate()
            .isEmpty) {
          if (DateTime.now().isAfter(until)) fail('export did not finish');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      final exported = (await tester.runAsync(
        () => destination.readAsString(),
      ))!;
      final record = jsonDecode(exported) as Map;
      expect(record['request'], original);
      expect(record['result']['timeout_us'], 1500000);
      expect(record['result']['raw_response'], raw);
      expect(record['result']['diagnostic'], false);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'public discovery supplies the JEV selector and exposes only HTTP and MCP',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          PlaygroundRuntime.create,
          _Network(),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => fixture.runtime.engine.start(
            fixture.council.models.availableBindings.last.artifactId,
          ),
          _Network(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JevPlaygroundPage(gateway: fixture.gateway, mcp: fixture.mcp),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('playground-mode')));
      await tester.pumpAndSettle();
      expect(find.text('原生 JEV · 受管实例'), findsNothing);
      expect(find.text('Jev HTTP · 本机服务'), findsWidgets);
      expect(find.text('MCP · 本机服务'), findsOneWidget);
      await tester.tap(find.text('Jev HTTP · 本机服务').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('playground-discover')));
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.byKey(const Key('playground-discover')));
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (find
              .byKey(const Key('playground-discovery'))
              .evaluate()
              .isEmpty) {
            if (DateTime.now().isAfter(until)) {
              fail('public discovery did not complete');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        }, _Network()),
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('playground-model-http')),
      );
      await tester.tap(find.byKey(const ValueKey('playground-model-http')));
      await tester.pumpAndSettle();
      expect(find.text('quick'), findsOneWidget);
      expect(find.text('hard'), findsOneWidget);
      expect(find.text('native-kev'), findsNothing);
    },
  );
  testWidgets(
    'JSON edits update the model selector and form edits preserve mixed complex fields',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          PlaygroundRuntime.create,
          _Network(),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JevPlaygroundPage(gateway: fixture.gateway, mcp: fixture.mcp),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('playground-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jev HTTP · 本机服务').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('playground-json-mode')));
      await _discoverPublicModels(tester);
      await tester.tap(find.byKey(const Key('playground-json-mode')));
      await tester.pump();
      final document = playgroundDocument('quick', state: 'first');
      document['images'] = null;
      ((document['questions'] as Map)['valid'] as Map)['criteria'] = null;
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode(document),
      );
      await tester.pump();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('playground-model-http')),
            )
            .initialValue,
        'quick',
      );
      document['model'] = 'hard';
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode(document),
      );
      await tester.pump();
      final selector = find.descendant(
        of: find.byKey(const ValueKey('playground-model-http')),
        matching: find.byType(DropdownButton<String>),
      );
      expect(tester.widget<DropdownButton<String>>(selector).value, 'hard');
      await tester.tap(find.byKey(const Key('playground-form-mode')));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'first'),
        'edited',
      );
      await tester.pump();
      await _discoverPublicModels(tester);
      await tester.tap(find.byKey(const Key('playground-json-mode')));
      await tester.pump();
      final text = tester
          .widget<TextField>(find.byKey(const Key('playground-json')))
          .controller!
          .text;
      expect(jsonDecode(text), {...document, 'state': 'edited'});
      expect((jsonDecode(text)['questions'] as Map).keys.toList(), [
        'route',
        'rank',
        'valid',
      ]);
      document.remove('model');
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode(document),
      );
      await tester.pump();
      expect(tester.widget<DropdownButton<String>>(selector).value, isNull);
      expect(find.textContaining('model 需要是非空字符串'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  const fontFamily = 'Playground Noto CJK';
  setUpAll(() async {
    final file = layoutFontFile;
    final loader = FontLoader(fontFamily)
      ..addFont(Future.value(ByteData.sublistView(await file.readAsBytes())));
    await loader.load();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'production playground fits 900x560 $brightness $scale with long JSON, actual result, copy and error',
        (tester) async {
          final fixture = (await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              PlaygroundRuntime.create,
              _Network(),
            ),
          ))!;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(fixture.close);
          });
          tester.view.physicalSize = const Size(900, 560);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
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
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final theme = buildJevTheme(brightness);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: fontFamily),
                primaryTextTheme: theme.primaryTextTheme.apply(
                  fontFamily: fontFamily,
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Row(
                  children: [
                    const SizedBox(width: 188),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(32, 30, 32, 28),
                        child: JevPlaygroundPage(
                          gateway: fixture.gateway,
                          mcp: fixture.mcp,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.ensureVisible(
            find.byKey(const Key('playground-json-mode')),
          );
          await _discoverPublicModels(tester);
          await tester.tap(find.byKey(const Key('playground-json-mode')));
          await tester.pump();
          const alias = 'native-kev';
          final document = playgroundDocument(
            alias,
            debug: true,
            state: {'long': List.generate(20, (i) => '长上下文 $i 保留字段内容')},
          );
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            jsonEncode(document),
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-form-mode')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('playground-form-mode')));
          await tester.pump();
          expect(find.textContaining('State：结构化值'), findsOneWidget);
          await _discoverPublicModels(tester);
          await tester.tap(find.byKey(const Key('playground-json-mode')));
          await tester.pump();
          expect(
            jsonDecode(
              tester
                  .widget<TextField>(find.byKey(const Key('playground-json')))
                  .controller!
                  .text,
            ),
            document,
          );
          await tester.ensureVisible(
            find.byKey(const Key('playground-preview-expand')),
          );
          await tester.tap(find.byKey(const Key('playground-preview-expand')));
          await tester.pumpAndSettle();
          expect(
            jsonDecode(
              tester
                  .widget<SelectableText>(
                    find.byKey(const Key('playground-preview')),
                  )
                  .data!,
            ),
            document,
          );
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              expect(
                tester
                    .widget<FilledButton>(
                      find.byKey(const Key('playground-submit')),
                    )
                    .onPressed,
                isNotNull,
                reason:
                    find
                        .byKey(const Key('playground-validation'))
                        .evaluate()
                        .isEmpty
                    ? 'no validation shown'
                    : tester
                          .widget<Text>(
                            find.byKey(const Key('playground-validation')),
                          )
                          .data,
              );
              await tester.tap(find.byKey(const Key('playground-submit')));
              final until = DateTime.now().add(const Duration(seconds: 5));
              while (find
                  .byKey(const Key('playground-status'))
                  .evaluate()
                  .isEmpty) {
                if (DateTime.now().isAfter(until)) {
                  fail('page result did not complete');
                }
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await tester.pump();
              }
            }, _Network()),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-output-copy')),
          );
          final copyRect = tester.getRect(
            find.byKey(const Key('playground-output-copy')),
          );
          expect(copyRect.top >= 0 && copyRect.bottom <= 560, true);
          await tester.tap(find.byKey(const Key('playground-output-copy')));
          await tester.pump();
          final output = tester
              .widget<SelectableText>(
                find.byKey(const Key('playground-output')),
              )
              .data!;
          expect(copied, output);
          expect((jsonDecode(output) as Map)['model'], alias);
          await tester.ensureVisible(
            find.byKey(const Key('playground-debug-expand')),
          );
          await tester.tap(find.byKey(const Key('playground-debug-expand')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-debug-output-copy')),
          );
          await tester.tap(
            find.byKey(const Key('playground-debug-output-copy')),
          );
          await tester.pump();
          final debug = jsonDecode(copied!) as Map;
          final publicInput = {...document}..remove('debug');
          expect(debug['input'], publicInput);
          expect(debug['native']['request'], {
            ...publicInput,
            'model': debug['native']['instance_id'],
          });
          await tester.ensureVisible(find.byKey(const Key('playground-json')));
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            '{broken',
          );
          await tester.pump();
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.tap(find.byKey(const Key('playground-submit')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('playground-output')), findsOneWidget);
          await tester.ensureVisible(
            find.byKey(const Key('playground-validation')),
          );
          expect(find.textContaining('FormatException'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(fixture.runtime.io.killedChildren, 0);
        },
      );
    }
  }

  for (final mode in JevPlaygroundMode.values) {
    testWidgets(
      'actual $mode page clears success before cancel, preserves late isolation and copies this call',
      (tester) async {
        final fixture = (await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(
            PlaygroundRuntime.create,
            _Network(),
          ),
        ))!;
        late Completer<void> arrived, held;
        await tester.runAsync(() async {
          arrived = Completer<void>();
          held = Completer<void>();
        });
        addTearDown(() async {
          if (!held.isCompleted) held.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.close);
        });
        fixture.runtime.io.respond = (body, raw) async {
          if (body['state'] == 'B') {
            if (!arrived.isCompleted) arrived.complete();
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
        tester.view.physicalSize = const Size(900, 560);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: JevPlaygroundPage(
                gateway: fixture.gateway,
                mcp: fixture.mcp,
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('playground-mode')));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(
                mode == JevPlaygroundMode.http
                    ? 'Jev HTTP · 本机服务'
                    : 'MCP · 本机服务',
              )
              .last,
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('playground-json-mode')),
        );
        await _discoverPublicModels(tester);
        await tester.tap(find.byKey(const Key('playground-json-mode')));
        await tester.pump();
        final name = 'hard';
        Future<void> edit(String state, bool debug) async {
          await tester.ensureVisible(find.byKey(const Key('playground-json')));
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            jsonEncode(playgroundDocument(name, state: state, debug: debug)),
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.pumpAndSettle();
          await _waitForSubmit(tester);
        }

        Future<void> waitResult() async {
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (find
              .byKey(const Key('playground-status'))
              .evaluate()
              .isEmpty) {
            if (DateTime.now().isAfter(until)) {
              fail('page result did not complete');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        }

        Future<void> submit() async {
          // Public discovery may change the content height while we await it.
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.pumpAndSettle();

          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              await tester.tap(find.byKey(const Key('playground-submit')));
              await tester.pump();
              await waitResult();
            }, _Network()),
          );
          await tester.pumpAndSettle();
        }

        await edit('A', true);
        await submit();
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const Key('playground-output')),
              )
              .data!,
          isNot(contains('gui-secret')),
        );
        await tester.ensureVisible(
          find.byKey(const Key('playground-debug-expand')),
        );
        await tester.tap(find.byKey(const Key('playground-debug-expand')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('playground-debug-output-copy')),
        );
        await tester.tap(find.byKey(const Key('playground-debug-output-copy')));
        await tester.pump();
        expect(jsonDecode(copied!)['input']['state'], 'A');
        expect(copied, isNot(contains('gui-secret')));
        await edit('B', true);
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await tester.tap(find.byKey(const Key('playground-submit')));
            await arrived.future.timeout(const Duration(seconds: 5));
          }, _Network()),
        );
        await tester.pump();
        expect(find.byKey(const Key('playground-output')), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('playground-cancel')));
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await tester.tap(find.byKey(const Key('playground-cancel')));
            await waitResult();
          }, _Network()),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('playground-output')), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const Key('playground-status'))).data,
          contains('未收到业务结果'),
        );

        held.complete();
        await edit('C', false);
        final stillCallable = (await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(
            () => fixture.playground.discover(mode),
            _Network(),
          ),
        ))!;
        expect(
          (stillCallable['data'] as List).map((row) => row['id']),
          contains(name),
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('playground-submit')))
              .onPressed,
          isNotNull,
          reason: 'The same target remains callable through the normal public discovery entry after cancellation.',
        );

        await submit();
        expect(
          (jsonDecode(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('playground-output')),
                )
                .data!,
          ) as Map)['model'],
          name,
        );
        expect(find.byKey(const Key('playground-debug-expand')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(fixture.gateway.state, PublicGatewayState.running);
        expect(fixture.mcp.state.status, CouncilMcpStatus.running);
        expect(fixture.runtime.io.killedChildren, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in JevPlaygroundMode.values) {
    for (final disposePage in [false, true]) {
      testWidgets(
        'leaving the production $mode playground ($disposePage) cancels only its request',
        (tester) async {
          late PlaygroundRuntime fixture;
          late Completer<void> held, arrived;
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              fixture = await PlaygroundRuntime.create();
              held = Completer<void>();
              arrived = Completer<void>();
            }, _Network()),
          );
          addTearDown(() async {
            if (!held.isCompleted) held.complete();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(fixture.close);
          });
          fixture.runtime.io.respond = (body, raw) async {
            if (!arrived.isCompleted) arrived.complete();
            await held.future;
            return raw;
          };
          tester.view.physicalSize = const Size(1000, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          Widget screen(bool active) => MaterialApp(
            home: Scaffold(
              body: JevPlaygroundPage(
                gateway: fixture.gateway,
                mcp: fixture.mcp,
                active: active,
              ),
            ),
          );
          await tester.pumpWidget(screen(true));

          await tester.tap(find.byKey(const Key('playground-mode')));
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .text(
                  mode == JevPlaygroundMode.http
                      ? 'Jev HTTP · 本机服务'
                      : 'MCP · 本机服务',
                )
                .last,
          );
          await tester.pumpAndSettle();

          await _discoverPublicModels(tester);
          await tester.tap(find.byKey(const Key('playground-json-mode')));
          await tester.pump();
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            jsonEncode(playgroundDocument('hard', debug: true)),
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              await tester.tap(find.byKey(const Key('playground-submit')));
              await arrived.future.timeout(const Duration(seconds: 5));
            }, _Network()),
          );
          await tester.runAsync(() async {
            await tester.pumpWidget(
              disposePage ? const SizedBox.shrink() : screen(false),
            );
            final until = DateTime.now().add(const Duration(seconds: 5));
            while (fixture.runtime.engine.state.instances.any(
              (i) => i.activeRequests != 0,
            )) {
              if (DateTime.now().isAfter(until)) {
                fail('leaving page did not drain its permit before IO release');
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          await tester.pumpAndSettle();
          expect(fixture.gateway.activeOwnedRequests, 0);
          expect(fixture.gateway.state, PublicGatewayState.running);
          expect(fixture.mcp.state.status, CouncilMcpStatus.running);
          expect(fixture.runtime.io.killedChildren, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final mode in JevPlaygroundMode.values) {
    testWidgets(
      'actual $mode page copies header-looking discovery IDs and calls the copied name',
      (tester) async {
        final fixture = (await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(
            PlaygroundRuntime.create,
            _Network(),
          ),
        ))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.close);
        });
        await tester.runAsync(() => saveHeaderNamedJevModels(fixture));
        fixture.runtime.io.respond = (body, raw) async => jsonEncode({
          ...jsonDecode(raw) as Map,
          'diagnostic': {'API_KEY': 'page-identity-private-token'},
        });
        tester.view.physicalSize = const Size(1000, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: JevPlaygroundPage(
                gateway: fixture.gateway,
                mcp: fixture.mcp,
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('playground-mode')));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(
                mode == JevPlaygroundMode.http
                    ? 'Jev HTTP · 本机服务'
                    : 'MCP · 本机服务',
              )
              .last,
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('playground-discover')),
        );
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await tester.tap(find.byKey(const Key('playground-discover')));
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (find
                .byKey(const Key('playground-discovery'))
                .evaluate()
                .isEmpty) {
              if (DateTime.now().isAfter(deadline)) {
                fail('actual discovery did not finish');
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          }, _Network()),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('playground-discovery-copy')),
        );
        await tester.tap(find.byKey(const Key('playground-discovery-copy')));
        await tester.pump();
        final discovery = jsonDecode(copied!) as Map;
        final ids = (discovery['data'] as List)
            .map((row) => row['id'] as String)
            .toList();
        final names = [...headerNamedNativeModels, ...headerNamedCouncilModels];
        expect(ids, containsAll(names));
        await tester.ensureVisible(
          find.byKey(const Key('playground-json-mode')),
        );
        await _discoverPublicModels(tester);
        await tester.tap(find.byKey(const Key('playground-json-mode')));
        await tester.pump();
        for (final name in ids.where(names.contains)) {
          final document = headerNamedJevDocument(name);
          await tester.ensureVisible(find.byKey(const Key('playground-json')));
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            jsonEncode(document),
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await _waitForSubmit(tester);
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              await tester.tap(find.byKey(const Key('playground-submit')));
              await tester.pump();
              final deadline = DateTime.now().add(const Duration(seconds: 5));
              while (find
                  .byKey(const Key('playground-status'))
                  .evaluate()
                  .isEmpty) {
                if (DateTime.now().isAfter(deadline)) {
                  fail('copied discovery name did not complete');
                }
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await tester.pump();
              }
            }, _Network()),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('playground-output-copy')),
          );
          await tester.tap(find.byKey(const Key('playground-output-copy')));
          await tester.pump();
          final output = jsonDecode(copied!) as Map;
          expect(output['model'], name);
          expect(output['answers'], headerNamedJevAnswers);
          await tester.ensureVisible(
            find.byKey(const Key('playground-debug-expand')),
          );
          if (find
              .byKey(const Key('playground-debug-output'))
              .evaluate()
              .isEmpty) {
            await tester.tap(find.byKey(const Key('playground-debug-expand')));
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(
            find.byKey(const Key('playground-debug-output-copy')),
          );
          await tester.tap(
            find.byKey(const Key('playground-debug-output-copy')),
          );
          await tester.pump();
          final debug = jsonDecode(copied!) as Map;
          expect(debug['input']['state'], document['state']);
          expect(debug['input']['questions'], document['questions']);
          expect(debug['converted_result'], output);

          expect(debug['configuration']['name'], name);

          expect(copied, isNot(contains('page-identity-private-token')));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final mode in JevPlaygroundMode.values) {
    testWidgets(
      'actual $mode page preview and copied result preserve legal task data and hide response credential extras and nested response shapes',
      (tester) async {
        final fixture = (await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(
            PlaygroundRuntime.create,
            _Network(),
          ),
        ))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.close);
        });
        tester.view.physicalSize = const Size(1000, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: JevPlaygroundPage(
                gateway: fixture.gateway,
                mcp: fixture.mcp,
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('playground-mode')));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(
                mode == JevPlaygroundMode.http
                    ? 'Jev HTTP · 本机服务'
                    : 'MCP · 本机服务',
              )
              .last,
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('playground-json-mode')),
        );
        await _discoverPublicModels(tester);
        await tester.tap(find.byKey(const Key('playground-json-mode')));
        await tester.pump();
        final name = 'quick';
        for (final extraKind in [0, 1, 2]) {
          final extras = extraKind == 1;
          final nested = extraKind == 2;
          fixture.runtime.io.respond = nested
              ? (body, raw) async =>
                    jsonEncode(nestedCredentialJevResponse(raw))
              : extras
              ? (body, raw) async => jsonEncode(credentialExtraJevResponse(raw))
              : null;
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            await tester.ensureVisible(
              find.byKey(const Key('playground-json')),
            );
            await tester.enterText(
              find.byKey(const Key('playground-json')),
              jsonEncode(document),
            );
            FocusManager.instance.primaryFocus?.unfocus();
            await tester.pumpAndSettle();
            if (find
                .byKey(const Key('playground-preview'))
                .evaluate()
                .isEmpty) {
              await tester.ensureVisible(
                find.byKey(const Key('playground-preview-expand')),
              );
              await tester.tap(
                find.byKey(const Key('playground-preview-expand')),
              );
              await tester.pumpAndSettle();
            }
            await tester.ensureVisible(
              find.byKey(const Key('playground-preview-copy')),
            );
            await tester.tap(find.byKey(const Key('playground-preview-copy')));
            await tester.pump();
            expect(jsonDecode(copied!), document);
            await tester.ensureVisible(
              find.byKey(const Key('playground-submit')),
            );
            await _waitForSubmit(tester);
            final sentBefore = fixture.runtime.io.requests.length;
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(() async {
                await tester.tap(find.byKey(const Key('playground-submit')));
                await tester.pump();
                final deadline = DateTime.now().add(const Duration(seconds: 5));
                while (find
                    .byKey(const Key('playground-status'))
                    .evaluate()
                    .isEmpty) {
                  if (DateTime.now().isAfter(deadline)) {
                    fail('public page call did not finish');
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                  await tester.pump();
                }
              }, _Network()),
            );
            await tester.pumpAndSettle();
            expect(
              fixture.runtime.io.requests.length,
              sentBefore + 1,
              reason: 'Every edited request must traverse the real public shell; a previous result cannot satisfy this call.',
            );
            await tester.ensureVisible(
              find.byKey(const Key('playground-output-copy')),
            );
            await tester.tap(find.byKey(const Key('playground-output-copy')));
            await tester.pump();
            expect(jsonDecode(copied!), {
              'model': name,
              'answers': credentialNamedJevAnswers,
              'usage': {'input_tokens': 10, 'output_tokens': 0},
            });
            for (final secret in [
              'answer-extra-secret',
              'unknown-header-token',
              'unlisted-cookie-token',
              'typed-object-secret',
              'shape-secret',
              'response-legend-token',
              'unique-secret',
              'encoded-question-token',
              'encoded-answer-token',
            ]) {
              expect(copied, isNot(contains(secret)));
            }
            if (debug) {
              await tester.ensureVisible(
                find.byKey(const Key('playground-debug-expand')),
              );
              await tester.tap(
                find.byKey(const Key('playground-debug-expand')),
              );
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.byKey(const Key('playground-debug-output-copy')),
              );
              await tester.tap(
                find.byKey(const Key('playground-debug-output-copy')),
              );
              await tester.pump();
              expect(
                jsonDecode(copied!)['input']['questions'],
                document['questions'],
              );
              for (final secret in [
                'answer-extra-secret',
                'unknown-header-token',
                'unlisted-cookie-token',
                'typed-object-secret',
                'shape-secret',
                'response-legend-token',
                'unique-secret',
                'encoded-question-token',
                'encoded-answer-token',
              ]) {
                expect(copied, isNot(contains(secret)));
              }
            }
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _waitForSubmit(WidgetTester tester) async {
  await tester.runAsync(() async {
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (tester
            .widget<FilledButton>(find.byKey(const Key('playground-submit')))
            .onPressed ==
        null) {
      if (DateTime.now().isAfter(until)) {
        fail('public Ready selection did not become submit-ready');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.ensureVisible(find.byKey(const Key('playground-submit')));
  await tester.pumpAndSettle();
}

Future<void> _discoverPublicModels(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('playground-discover')));
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('playground-discover')));
      // Commit the cleared discovery view before waiting for this new call;
      // a previous mounted result must not satisfy the completion condition.
      await tester.pump();
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (find.byKey(const Key('playground-discovery')).evaluate().isEmpty) {
        if (DateTime.now().isAfter(until)) {
          fail('public model discovery did not finish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    }, _Network()),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('playground-json-mode')));
}

class _Network extends HttpOverrides {}

class _ExportRouteObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
    super.didPop(route, previousRoute);
  }
}
