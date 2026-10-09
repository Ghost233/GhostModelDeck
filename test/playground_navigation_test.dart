import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/main.dart';
import 'package:ghost_model_deck/mcp_page.dart';
import 'package:ghost_model_deck/llm_playground_page.dart';
import 'package:ghost_model_deck/jev_playground_page.dart';
import 'package:ghost_model_deck/settings_page.dart';
import 'package:ghost_model_deck/council_page.dart';

void main() {
  testWidgets('顶层区域先于侧栏，引擎六入口与共享设置可访问', (tester) async {
    tester.view.physicalSize = const Size(900, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _runWithCleanup(tester, () async {
      await _openApp(tester);
      final tabs = find.byKey(const Key('workspace-tabs'));
      expect(tabs, findsOneWidget);
      expect(find.text('引擎'), findsOneWidget);
      expect(find.text('测试场'), findsOneWidget);
      expect(
        tester.getBottomLeft(tabs).dy,
        lessThanOrEqualTo(tester.getTopLeft(_navigation('发现模型')).dy),
      );
      for (final label in ['发现模型', '模型库', '下载任务', '引擎管理', '委员会配置', 'MCP']) {
        await tester.scrollUntilVisible(
          _navigation(label),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(_navigation(label).hitTestable(), findsOneWidget);
      }
      expect(find.text('设置').hitTestable(), findsOneWidget);
      expect(find.text('推理测试场'), findsNothing);
      expect(find.text('LLM 基础测试'), findsNothing);
      expect(find.text('基准评测'), findsNothing);
    });
  });
  testWidgets('测试场能力Tab、基础入口及两区共享设置只使用既有页面', (tester) async {
    tester.view.physicalSize = const Size(900, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _runWithCleanup(tester, () async {
      await _openApp(tester);
      await _tap(tester, find.text('测试场'));
      final capabilities = find.byKey(const Key('playground-capability-tabs'));
      expect(capabilities, findsOneWidget);
      expect(find.text('通用 LLM'), findsOneWidget);
      expect(find.text('JEV'), findsOneWidget);
      expect(
        tester.getBottomLeft(capabilities).dy,
        lessThanOrEqualTo(tester.getTopLeft(_navigation('基础测试')).dy),
      );
      expect(find.byType(LlmPlaygroundPage), findsOneWidget);
      expect(
        tester.widget<LlmPlaygroundPage>(find.byType(LlmPlaygroundPage)).active,
        isTrue,
      );
      expect(_navigation('MCP'), findsNothing);
      expect(_navigation('模型库'), findsNothing);
      expect(find.text('基准评测'), findsNothing);
      await _tap(tester, _navigation('设置'));
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        tester
            .widget<LlmPlaygroundPage>(
              find.byType(LlmPlaygroundPage, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      await _tap(tester, find.text('JEV'));
      expect(find.byType(JevPlaygroundPage), findsOneWidget);
      expect(
        tester.widget<JevPlaygroundPage>(find.byType(JevPlaygroundPage)).active,
        isTrue,
      );
      await _tap(tester, find.text('引擎'));
      expect(_navigation('发现模型'), findsOneWidget);
      expect(
        tester
            .widget<JevPlaygroundPage>(
              find.byType(JevPlaygroundPage, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      await _tap(tester, _navigation('设置'));
      expect(find.byType(SettingsPage), findsOneWidget);
    });
  });
  testWidgets('区域能力和设置切换保留编辑器Element输入并共用原生产graph', (tester) async {
    tester.view.physicalSize = const Size(900, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _runWithCleanup(tester, () async {
      await _openApp(tester);
      await _tap(tester, find.text('测试场'));
      final llmElement = tester.element(find.byType(LlmPlaygroundPage));
      final gateway = tester
          .widget<LlmPlaygroundPage>(find.byType(LlmPlaygroundPage))
          .gateway;
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      const llmInput =
          '{"model":"","messages":[{"role":"user","content":"kept LLM request"}],"stream":false,"max_tokens":32}';
      await tester.enterText(find.byKey(const Key('llm-json')), llmInput);
      await _tap(tester, find.text('JEV'));
      final jevElement = tester.element(find.byType(JevPlaygroundPage));
      final jev = tester.widget<JevPlaygroundPage>(
        find.byType(JevPlaygroundPage),
      );
      expect(identical(jev.gateway, gateway), isTrue);
      expect(
        tester
            .widget<LlmPlaygroundPage>(
              find.byType(LlmPlaygroundPage, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      await _tap(tester, find.byKey(const Key('playground-json-mode')));
      const jevInput =
          '{"model":"","state":"kept JEV request","questions":{"q":{"type":"choice","instructions":"Pick","criteria":{"a":"A","b":"B"}}}}';
      await tester.enterText(
        find.byKey(const Key('playground-json')),
        jevInput,
      );
      await _tap(tester, _navigation('设置'));
      expect(
        tester
            .widget<JevPlaygroundPage>(
              find.byType(JevPlaygroundPage, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      await _tap(tester, find.text('引擎'));
      await tester.scrollUntilVisible(
        _navigation('委员会配置'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await _tap(tester, _navigation('委员会配置'));
      final council = tester
          .widget<CouncilPage>(find.byType(CouncilPage))
          .controller;
      expect(identical(council.models, gateway.jevModels), isTrue);
      expect(identical(council, jev.mcp.controller), isTrue);
      await _tap(tester, find.text('测试场'));
      expect(tester.element(find.byType(JevPlaygroundPage)), same(jevElement));
      expect(
        tester.widget<JevPlaygroundPage>(find.byType(JevPlaygroundPage)).active,
        isTrue,
      );
      expect(
        jsonDecode(
          tester
              .widget<TextField>(find.byKey(const Key('playground-json')))
              .controller!
              .text,
        ),
        jsonDecode(jevInput),
      );
      await _tap(tester, find.text('通用 LLM'));
      expect(tester.element(find.byType(LlmPlaygroundPage)), same(llmElement));
      expect(
        tester.widget<LlmPlaygroundPage>(find.byType(LlmPlaygroundPage)).active,
        isTrue,
      );
      expect(
        jsonDecode(
          tester
              .widget<TextField>(find.byKey(const Key('llm-json')))
              .controller!
              .text,
        ),
        jsonDecode(llmInput),
      );
    });
  });
}

Finder _navigation(String label) => find.widgetWithText(ListTile, label);

Future<void> _runWithCleanup(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  Object? primaryError;
  StackTrace? primaryStack;
  try {
    await action();
  } catch (error, stack) {
    primaryError = error;
    primaryStack = stack;
  }
  try {
    await _stopApp(tester);
  } catch (error, stack) {
    if (primaryError == null) {
      Error.throwWithStackTrace(error, stack);
    }
    stderr.writeln('Navigation cleanup also failed: $error\n$stack');
  }
  if (primaryError != null) {
    Error.throwWithStackTrace(primaryError, primaryStack!);
  }
}

Future<void> _stopApp(WidgetTester tester) async {
  Object? primaryError;
  StackTrace? primaryStack;
  try {
    if (find.text('引擎').evaluate().isNotEmpty) {
      await _tap(tester, find.text('引擎'));
    }
    if (find.byType(McpPage).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        _navigation('MCP'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(_navigation('MCP'));
      await tester.pump();
    }
    final server = tester.widget<McpPage>(find.byType(McpPage)).server;
    await tester.runAsync(server.stop);
  } catch (error, stack) {
    primaryError = error;
    primaryStack = stack;
  }
  try {
    await tester.pumpWidget(const SizedBox.shrink());
  } catch (error, stack) {
    if (primaryError == null) {
      Error.throwWithStackTrace(error, stack);
    }
    stderr.writeln('Navigation widget unmount also failed: $error\n$stack');
  }
  if (primaryError != null) {
    Error.throwWithStackTrace(primaryError, primaryStack!);
  }
}

class _Network extends HttpOverrides {}

Future<void> _openApp(WidgetTester tester) async {
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(const GhostModelDeckApp());
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }, _Network()),
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(finder);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }, _Network()),
  );
  await tester.pumpAndSettle();
}
