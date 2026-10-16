import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/mcp_page.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/jev_models.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/decision_gguf.dart';

void main() {
  testWidgets(
    'MCP scene editor separates Chinese descriptions from model names and saves without starting',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late CouncilRuntime runtime;
      late LaunchInstances instances;
      late CouncilController controller;
      late CouncilMcpServer server;
      late String instanceId;
      late String councilId;
      await tester.runAsync(() async {
        runtime = await CouncilRuntime.create(
          modelCount: 0,
          sourceSystemone: true,
        );
        final models = Directory('${runtime.root.path}/models');
        await writeDecisionKev(models, ordinaryChat: true);
        await runtime.library.scan(models);
        instances = LaunchInstances(
          catalog: runtime.catalog,
          file: File('${runtime.root.path}/instances.json'),
        );
        final selected = await instances.save(
          name: 'Selected instance',
          artifactId: runtime.library.state.artifacts.single.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        );
        instanceId = selected.id;
        controller = CouncilController(
          catalog: runtime.catalog,
          launchInstances: instances,
          scenarioRegistryFile: File('${runtime.root.path}/scenarios.json'),
        );
        await controller.models.save(
          JevModelDefinition.council(
            name: 'saved-committee',
            seats: controller.models.availableBindings,
            timeout: const Duration(seconds: 2),
          ),
        );
        councilId = controller.models.definitions.single.id;
        server = CouncilMcpServer(controller: controller, port: 0);
      });
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await server.close();
          await controller.close();
          await instances.close();
          await runtime.close();
        }),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(body: McpPage(server: server)),
          ),
        );
        await controller.models.load();
      });
      await tester.pumpAndSettle();
      expect(find.text('短上下文'), findsOneWidget);
      expect(find.text('长上下文＋视觉'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-scenario-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('scenario-display-name')),
        '4k上线+视觉',
      );
      await tester.enterText(
        find.byKey(const Key('scenario-model-name')),
        'fast-v',
      );
      await tester.tap(find.byKey(const Key('scenario-binding')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Selected instance').last);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final changed = controller.scenarios.changes.first;
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await changed.timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(find.text('4k上线+视觉'), findsOneWidget);
      expect(find.text('fast-v'), findsOneWidget);
      expect(controller.scenarios.entries.first.instanceId, instanceId);
      await tester.tap(find.byKey(const Key('edit-scenario-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scenario-binding')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('saved-committee').last);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final changed = controller.scenarios.changes.first;
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await changed.timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(controller.scenarios.entries.first.instanceId, isNull);
      expect(controller.scenarios.entries.first.councilId, councilId);
      for (final enabled in [false, true]) {
        await tester.runAsync(() async {
          final changed = controller.scenarios.changes.first;
          await tester.tap(find.byType(Switch).first);
          await changed.timeout(const Duration(seconds: 2));
        });
        await tester.pumpAndSettle();
        expect(controller.scenarios.entries.first.enabled, enabled);
        expect(controller.scenarios.entries.first.councilId, councilId);
      }
      expect(runtime.engine.state.instances, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'MCP management starts the real listener and shows its actual connection configuration',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      late CouncilMcpServer server;
      await tester.runAsync(() async {
        runtime = await CouncilRuntime.create(modelCount: 0);
        council = CouncilController(catalog: runtime.catalog);
        await council.models.load();
        server = CouncilMcpServer(controller: council, port: 0);
      });
      addTearDown(() async {
        final completed = await tester.runAsync<bool>(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await () async {
            await server.close();
            await council.close();
            await runtime.close();
          }().timeout(const Duration(seconds: 3));
          return true;
        });
        expect(
          completed,
          isTrue,
          reason: 'MCP page resources must finish closing',
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(28),
              child: McpPage(server: server),
            ),
          ),
        ),
      );
      expect(find.text('未启动'), findsOneWidget);
      await tester.runAsync(() async {
        final started = server.changes.firstWhere(
          (state) => state.status == CouncilMcpStatus.running,
        );
        await tester.tap(find.text('启动'));
        await started.timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(find.text('运行中'), findsOneWidget);
      expect(find.text(server.endpoint!.toString()), findsOneWidget);
      expect(find.text('复制 Codex 配置'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.runAsync(() async {
        final stopped = server.changes.firstWhere(
          (state) => state.status == CouncilMcpStatus.stopped,
        );
        await tester.tap(find.text('停止'));
        await stopped.timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(find.text('未启动'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
