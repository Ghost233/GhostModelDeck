import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/runtime_monitor_controller.dart';
import 'package:ghost_model_deck/runtime_monitor_page.dart';
import 'package:ghost_model_deck/runtime_monitor.dart';

import 'fixtures/test_environment.dart';
import 'runtime_monitor_test.dart' show target, TestMonitorSource;

void main() {
  setUpAll(() async {
    expect(await layoutFontFile.exists(), isTrue);
    await (FontLoader('Layout Noto CJK')..addFont(
          Future.value(
            ByteData.sublistView(await layoutFontFile.readAsBytes()),
          ),
        ))
        .load();
    expect(await materialIconsFontFile.exists(), isTrue);
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(await materialIconsFontFile.readAsBytes()),
          ),
        ))
        .load();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'monitor is paged and scrollable at $brightness/$scale with real fonts',
        (tester) async {
          tester.view.physicalSize = const Size(900, 560);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final resources = (await tester.runAsync(() async {
            final root = await Directory.systemTemp.createTemp('monitor-ui-');
            final library = ModelLibrary();
            final cpp = LlamaEngine(
              library: library,
              installationDirectory: root,
            );
            final catalog = EngineCatalog(
              library: library,
              officialEngine: cpp,
              useRegistry: ModelUseRegistry(library),
              registryFile: File('${root.path}/engines.json'),
            );
            final instances = LaunchInstances(
              catalog: catalog,
              file: File('${root.path}/instances.json'),
            );
            return (
              root: root,
              library: library,
              cpp: cpp,
              catalog: catalog,
              instances: instances,
            );
          }))!;
          final instances = resources.instances;
          final source = TestMonitorSource();
          var now = DateTime.utc(2026, 10, 17);
          final controller = RuntimeMonitorController(
            targets: () => [for (var i = 0; i < 25; i++) target('$i', source)],
            interval: const Duration(hours: 1),
            now: () => now,
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
            await tester.runAsync(() async {
              await instances.close();
              resources.catalog.close();
              resources.cpp.close();
              resources.library.close();
              await resources.root.delete(recursive: true);
            });
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: brightness,
                fontFamily: 'Layout Noto CJK',
              ),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(24),
                    child: RuntimeMonitorPage(
                      instances: instances,
                      active: true,
                      controller: controller,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));
          expect(find.text('运行监控'), findsOneWidget);
          expect(find.text('运行实例 25'), findsOneWidget);
          expect(find.text('instance-24'), findsNothing);
          expect(find.byType(ExpansionTile), findsNothing);
          expect(find.textContaining('平均速度变化'), findsNothing);
          final slots = find.byKey(const Key('monitor-slots:0'));
          expect(slots, findsOneWidget);
          for (var slot = 0; slot < 4; slot++) {
            expect(find.byKey(Key('monitor-slot:0:$slot')), findsOneWidget);
          }
          expect(
            find.descendant(of: slots, matching: find.text('prefill')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('32 / 100')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('decode')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('6 token')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('空闲')),
            findsNWidgets(2),
          );
          expect(find.byKey(const Key('monitor-summary:0')), findsOneWidget);
          expect(find.text('decode 50.0'), findsNothing);
          now = now.add(const Duration(seconds: 1));
          source.response = RuntimeTelemetry(
            capacity: 4,
            running: 0,
            queued: 0,
            promptTokens: 1400,
            generatedTokens: 650,
            prefillSeconds: 7,
            decodeSeconds: 13,
            prefillPerSecond: 9999,
            decodePerSecond: 8888,
          );
          await controller.refresh();
          await tester.pump();
          final summary = find.byKey(const Key('monitor-summary:0'));
          expect(
            find.descendant(of: summary, matching: find.text('prefill 200.0')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: summary, matching: find.text('decode 50.0')),
            findsOneWidget,
          );
          source.response = RuntimeTelemetry(
            capacity: 4,
            running: 4,
            queued: 3,
            requests: [
              const RequestProgress(
                id: 'a',
                phase: RequestPhase.prefill,
                promptTokens: 100,
                processedTokens: 32,
                slotIndex: 0,
              ),
              const RequestProgress(
                id: 'b',
                phase: RequestPhase.decode,
                generatedTokens: 6,
                slotIndex: 1,
              ),
              const RequestProgress(
                id: 'c',
                phase: RequestPhase.prefill,
                processedTokens: 2,
                slotIndex: 2,
              ),
              const RequestProgress(
                id: 'd',
                phase: RequestPhase.decode,
                generatedTokens: 7,
                slotIndex: 3,
              ),
              const RequestProgress(id: 'q1', phase: RequestPhase.queued),
              const RequestProgress(id: 'q2', phase: RequestPhase.queued),
              const RequestProgress(id: 'q3', phase: RequestPhase.queued),
            ],
          );
          await controller.refresh();
          await tester.pump();
          expect(
            find.descendant(of: slots, matching: find.text('排队 3')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('prefill')),
            findsNWidgets(2),
          );
          expect(
            find.descendant(of: slots, matching: find.text('decode')),
            findsNWidgets(2),
          );
          source.response = RuntimeTelemetry(
            capacity: 4,
            requests: [
              const RequestProgress(id: 'unknown', phase: RequestPhase.running),
            ],
          );
          await controller.refresh();
          await tester.pump();
          expect(
            find.descendant(of: slots, matching: find.text('排队 —')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('空闲')),
            findsNothing,
          );
          expect(
            find.descendant(of: slots, matching: find.text('运行中')),
            findsNWidgets(4),
          );
          source.response = RuntimeTelemetry(
            capacity: 4,
            running: 0,
            queued: 0,
            promptTokens: 0,
            generatedTokens: 0,
          );
          await controller.refresh();
          await tester.pump();
          expect(
            find.descendant(of: slots, matching: find.text('空闲')),
            findsNWidgets(4),
          );
          expect(
            find.descendant(
              of: find.byKey(const Key('monitor-summary:0')),
              matching: find.text('输入 0'),
            ),
            findsOneWidget,
          );
          source.response = RuntimeTelemetry(
            capacity: 4,
            running: 1,
            queued: 0,
            requests: [
              const RequestProgress(
                id: 'reused',
                phase: RequestPhase.decode,
                generatedTokens: 9,
                slotIndex: 0,
              ),
            ],
          );
          await controller.refresh();
          await tester.pump();
          expect(
            find.descendant(
              of: find.byKey(const Key('monitor-slot:0:0')),
              matching: find.text('9 token'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: slots, matching: find.text('空闲')),
            findsNWidgets(3),
          );
          source.response = RuntimeTelemetry(
            capacity: 10000,
            running: 0,
            queued: 0,
          );
          await controller.refresh();
          await tester.pump();
          expect(
            find.descendant(of: slots, matching: find.text('并发 10000')),
            findsOneWidget,
          );
          final visibleSlots = find.descendant(
            of: slots,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'monitor-slot:0:',
                  ),
            ),
          );
          expect(visibleSlots.evaluate().length, lessThanOrEqualTo(10));
          expect(find.byKey(const Key('monitor-slot:0:9999')), findsNothing);
          source.fail = true;
          await controller.refresh();
          await tester.pump();
          expect(
            find.descendant(of: slots, matching: find.text('空闲')),
            findsNothing,
          );
          expect(
            controller.readings.first.target.run!.status,
            RuntimeInstanceStatus.ready,
          );
          source.fail = false;
          await tester.tap(find.byTooltip('下一页'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));
          await tester.scrollUntilVisible(
            find.text('instance-24'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('instance-24'), findsOneWidget);
          expect(find.text('instance-0'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          final calls = source.calls;
          await controller.refresh();
          expect(source.calls, calls);
        },
      );
    }
  }
}
