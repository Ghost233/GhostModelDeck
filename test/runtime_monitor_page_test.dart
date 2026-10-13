import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/runtime_monitor_controller.dart';
import 'package:ghost_model_deck/runtime_monitor_page.dart';

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
          final controller = RuntimeMonitorController(
            targets: () => [for (var i = 0; i < 25; i++) target('$i', source)],
            interval: const Duration(hours: 1),
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
          expect(find.textContaining('已注册 25'), findsOneWidget);
          expect(find.text('instance 24'), findsNothing);
          await tester.tap(find.text('instance 0'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.textContaining('平均速度变化'), findsOneWidget);
          expect(find.textContaining('输入 32 / 100 token'), findsOneWidget);
          await tester.tap(find.byTooltip('下一页'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));
          await tester.scrollUntilVisible(
            find.text('instance 24'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('instance 24'), findsOneWidget);
          expect(find.text('instance 0'), findsNothing);
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
