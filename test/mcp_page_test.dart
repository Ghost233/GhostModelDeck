import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/mcp_page.dart';

import 'fixtures/council_runtime.dart';

void main() {
  testWidgets(
    'MCP management starts the real listener and shows its actual connection configuration',
    (tester) async {
      late CouncilRuntime runtime;
      late CouncilController council;
      late CouncilMcpServer server;
      await tester.runAsync(() async {
        runtime = await CouncilRuntime.create(modelCount: 0);
        council = CouncilController(catalog: runtime.catalog);
        server = CouncilMcpServer(controller: council, port: 0);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await server.close();
          await council.close();
          await runtime.close();
        });
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
