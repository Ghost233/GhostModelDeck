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

void main() {
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
            body: JevPlaygroundPage(
              controller: fixture.council,
              gateway: fixture.gateway,
              mcp: fixture.mcp,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('playground-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jev HTTP · 本机服务').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('playground-json-mode')));
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
  testWidgets(
    'native JSON selects its actual alias and keeps keyboard focus while editing a field',
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
            body: JevPlaygroundPage(
              controller: fixture.council,
              gateway: fixture.gateway,
              mcp: fixture.mcp,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('playground-json-mode')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jsonEncode(
          playgroundDocument(
            fixture.runtime.engine.state.instances.last.id,
            state: 'typed',
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('playground-validation')), findsNothing);
      await tester.tap(find.byKey(const Key('playground-form-mode')));
      await tester.pump();
      final field = find.widgetWithText(TextFormField, 'typed');
      await tester.tap(field);
      await tester.enterText(field, 'typing');
      await tester.pump();
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'typing'),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, true);
      expect(tester.takeException(), isNull);
    },
  );

  const fontFamily = 'Playground Noto CJK';
  setUpAll(() async {
    final file = File(
      Platform.environment['JEV_LAYOUT_FONT'] ??
          '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
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
                          controller: fixture.council,
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
          await tester.tap(find.byKey(const Key('playground-json-mode')));
          await tester.pump();
          final alias = fixture.runtime.engine.state.instances.first.id;
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
            {...document}..remove('debug'),
          );
          await tester.ensureVisible(
            find.byKey(const Key('playground-submit')),
          );
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
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
          expect(
            jsonDecode(copied!)['native']['request'],
            {...document}..remove('debug'),
          );
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
          expect(find.byKey(const Key('playground-output')), findsNothing);
          await tester.ensureVisible(
            find.byKey(const Key('playground-status')),
          );
          expect(find.textContaining('JSON 格式错误'), findsOneWidget);
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
                controller: fixture.council,
                gateway: fixture.gateway,
                mcp: fixture.mcp,
              ),
            ),
          ),
        );
        if (mode != JevPlaygroundMode.native) {
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
        }
        await tester.ensureVisible(
          find.byKey(const Key('playground-json-mode')),
        );
        await tester.tap(find.byKey(const Key('playground-json-mode')));
        await tester.pump();
        final name = mode == JevPlaygroundMode.native
            ? fixture.runtime.engine.state.instances.first.id
            : 'hard';
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
        if (mode == JevPlaygroundMode.native) {
          final output = jsonDecode(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('playground-output')),
                )
                .data!,
          ) as Map;
          expect(output['error']['code'], 'cancelled');
          expect(output.containsKey('answers'), false);
        } else {
          expect(find.byKey(const Key('playground-output')), findsNothing);
          expect(
            tester
                .widget<Text>(find.byKey(const Key('playground-status')))
                .data,
            contains('未收到业务结果'),
          );
        }
        held.complete();
        await edit('C', false);
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
                controller: fixture.council,
                gateway: fixture.gateway,
                mcp: fixture.mcp,
                active: active,
              ),
            ),
          );
          await tester.pumpWidget(screen(true));
          if (mode != JevPlaygroundMode.native) {
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
          }
          await tester.tap(find.byKey(const Key('playground-json-mode')));
          await tester.pump();
          await tester.enterText(
            find.byKey(const Key('playground-json')),
            jsonEncode(
              playgroundDocument(
                mode == JevPlaygroundMode.native
                    ? fixture.runtime.engine.state.instances.first.id
                    : 'hard',
                debug: true,
              ),
            ),
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
}

class _Network extends HttpOverrides {}
