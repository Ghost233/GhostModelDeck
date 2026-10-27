import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_connections_page.dart';
import 'package:ghost_model_deck/model_scenarios.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/embedding_runtime.dart';

void main() {
  testWidgets('embedding only advertises its actual protocol', (tester) async {
    tester.view.physicalSize = const Size(900, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        final fixture = await EmbeddingTestRuntime.create();
        final instances = LaunchInstances(
          catalog: fixture.catalog,
          file: File('${fixture.root.path}/instances.json'),
        );
        final instance = await instances.save(
          name: 'Embedding test',
          artifactId: fixture.asset.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        );
        final controller = CouncilController(
          catalog: fixture.catalog,
          launchInstances: instances,
        );
        final routes = PublicModelRoutes(
          library: fixture.library,
          instances: instances,
          runtimes: fixture.catalog.runtimes.toList(),
        );
        final gateway = PublicGatewayServer(
          routes: routes,
          jevModels: controller.models,
          port: 0,
        );
        final mcp = CouncilMcpServer(controller: controller, port: 0);
        try {
          await gateway.start();
          await mcp.start();
          await instances.start(instance.id);
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: Scaffold(
                  body: ModelConnectionsPage(
                    instances: instances,
                    gateway: gateway,
                    mcp: mcp,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.byKey(Key('connection:available:${instance.publicName}')),
            180,
            scrollable: find
                .descendant(
                  of: find.byType(ModelConnectionsPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(Key('connection:available:${instance.publicName}')),
            findsOneWidget,
          );
          expect(find.text('协议：OpenAI Embeddings'), findsOneWidget);
          expect(find.textContaining('协议：OpenAI Chat'), findsNothing);
          expect(find.text('协议：MCP · JEV'), findsNothing);
          expect(tester.takeException(), isNull);
          return true;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await gateway.stop();
          gateway.close();
          routes.close();
          await mcp.close();
          await controller.close();
          await instances.close();
          await fixture.close();
        }
      }, _NetworkBoundary()),
    );
    expect(result, isTrue);
  });

  testWidgets(
    'page shows shared addresses, callable models and live parameters',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final result = await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final runtime = await CouncilRuntime.create(
            modelCount: 1,
            sourceSystemone: true,
          );
          runtime.io.capacityProperties = {
            'total_slots': 2,
            'default_generation_settings': {'n_ctx': 8192},
          };
          final instances = LaunchInstances(
            catalog: runtime.catalog,
            file: File('${runtime.root.path}/instances.json'),
          );
          final instance = await instances.save(
            name: 'Connection test',
            artifactId: runtime.library.state.artifacts.single.id,
            engineId: EngineCatalog.officialId,
            configuration: EngineLaunchConfiguration(
              generation: GenerationConfiguration({
                'temperature': 0.4,
                'top_p': 0.9,
              }),
            ),
          );
          final council = CouncilController(
            catalog: runtime.catalog,
            launchInstances: instances,
          );
          final routes = PublicModelRoutes(
            library: runtime.library,
            instances: instances,
            runtimes: runtime.catalog.runtimes.toList(),
            scenarios: council.scenarios,
          );
          final gateway = PublicGatewayServer(
            routes: routes,
            jevModels: council.models,
            port: 0,
          );
          final mcp = CouncilMcpServer(controller: council, port: 0);
          String? clipboard;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          try {
            final fixedGateway = PublicGatewayServer(
              routes: routes,
              jevModels: council.models,
            );
            final fixedMcp = CouncilMcpServer(controller: council);
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: ModelConnectionsPage(
                    instances: instances,
                    gateway: fixedGateway,
                    mcp: fixedMcp,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(const Key('connection:overview-http')),
                  )
                  .data,
              'http://127.0.0.1:54841/v1/',
            );
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(const Key('connection:overview-mcp')),
                  )
                  .data,
              'http://127.0.0.1:54842/mcp',
            );
            expect(find.text('HTTP API：未启动'), findsOneWidget);
            expect(find.text('MCP：未启动'), findsOneWidget);
            await tester.pumpWidget(const SizedBox.shrink());
            fixedGateway.close();
            await fixedMcp.close();
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: ModelConnectionsPage(
                    instances: instances,
                    gateway: gateway,
                    mcp: mcp,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            String value(String id) => tester
                .widget<SelectableText>(find.byKey(Key('connection:$id')))
                .data!;
            expect(value('overview-http'), '启动后分配地址');
            expect(value('overview-mcp'), '启动后分配地址');
            expect(find.text('HTTP API：未启动'), findsOneWidget);
            expect(find.textContaining('当前没有可通过已启动服务调用的模型'), findsOneWidget);
            await gateway.start();
            await mcp.start();
            await tester.pumpAndSettle();
            expect(
              value('overview-http'),
              gateway.baseUrl!.resolve('/v1/').toString(),
            );
            expect(value('overview-mcp'), mcp.endpoint.toString());
            await tester.tap(find.byTooltip('复制OpenAI 基础地址'));
            await tester.pump();
            expect(clipboard, gateway.baseUrl!.resolve('/v1/').toString());
            await instances.start(instance.id);
            await council.scenarios.save(
              0,
              ModelScenario(
                displayName: '快速场景',
                modelName: 'fast-scenario',
                instanceId: instance.id,
              ),
            );
            await council.models.save(
              JevModelDefinition.council(
                name: 'test-council',
                seats: [
                  JevModelBinding(
                    artifactId: instance.artifactId,
                    engineId: instance.engineId,
                    instanceId: instance.id,
                  ),
                ],
                timeout: const Duration(seconds: 60),
              ),
            );
            await instances.save(
              id: instance.id,
              name: instance.name,
              artifactId: instance.artifactId,
              engineId: instance.engineId,
              configuration: EngineLaunchConfiguration(
                formValues: {'--ctx-size': '16384'},
                generation: GenerationConfiguration({
                  'temperature': 0.4,
                  'top_p': 0.9,
                }),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              value('available:${instance.publicName}'),
              instance.publicName,
            );
            expect(value('available:fast-scenario'), 'fast-scenario');
            expect(value('available:test-council'), 'test-council');
            expect(
              find.textContaining('协议：OpenAI Chat、JEV HTTP、MCP · JEV'),
              findsNWidgets(2),
            );
            expect(
              find.text('模型：${runtime.library.state.artifacts.single.name}'),
              findsNWidgets(3),
            );
            expect(find.textContaining('温度：0.4'), findsNWidgets(2));
            expect(find.textContaining('Top P：0.9'), findsNWidgets(2));
            expect(find.textContaining('上下文（每槽）：8192'), findsNWidgets(3));
            expect(find.textContaining('并发槽位：2'), findsNWidgets(3));
            expect(find.textContaining('上下文（每槽）：16384'), findsNothing);
            await gateway.stop();
            await tester.pumpAndSettle();
            expect(value('overview-http'), '启动后分配地址');
            expect(find.textContaining('协议：OpenAI Chat'), findsNothing);
            expect(find.text('协议：MCP · JEV'), findsNWidgets(3));
            await instances.stop(instance.id);
            await tester.pumpAndSettle();
            expect(
              find.byKey(Key('connection:available:${instance.publicName}')),
              findsNothing,
            );
            expect(find.textContaining('当前没有可通过已启动服务调用的模型'), findsOneWidget);
            return true;
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            );
            await gateway.stop();
            gateway.close();
            routes.close();
            await mcp.close();
            await council.close();
            await instances.close();
            await runtime.close();
          }
        }, _NetworkBoundary()),
      );
      expect(result, isTrue);
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
