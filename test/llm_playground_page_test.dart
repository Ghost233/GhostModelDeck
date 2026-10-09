import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/llm_playground_page.dart';

import 'llm_playground_test.dart'
    show
        LlmTestRuntime,
        llmDocument,
        waitForLlmPermitRelease,
        DiscoveryRelay,
        DiscoveryRouting;

void main() {
  testWidgets('替代发现和离页销毁释放挂起公开GET，旧响应不能写回当前模型列表', (tester) async {
    final fixture = (await tester.runAsync(
      () =>
          HttpOverrides.runWithHttpOverrides(LlmTestRuntime.create, _Network()),
    ))!;
    final relay = (await tester.runAsync(
      () => DiscoveryRelay.create(() => fixture.gateway.baseUrl),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(relay.close);
      await tester.runAsync(fixture.close);
    });
    Future<void> routed(Future<void> Function() action) async {
      await tester.runAsync(
        () =>
            HttpOverrides.runWithHttpOverrides(action, DiscoveryRouting(relay)),
      );
      await tester.pump();
    }

    await routed(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
    });
    final first = (await tester.runAsync(() => relay.received(0)))!;
    expect(first.responseText, contains(fixture.publicId));
    // A real gateway lifecycle event asks the active page to replace discovery.
    await routed(fixture.gateway.stop);
    await tester.runAsync(
      () => first.closed.future.timeout(const Duration(seconds: 2)),
    );
    await fixture.routes.disable(fixture.asset.id);
    await routed(fixture.gateway.start);
    final replacement = (await tester.runAsync(() => relay.received(1)))!;
    await routed(() async {
      await replacement.release();
      await waitForWidget(tester, find.byKey(const Key('llm-discovery')));
    });
    await tester.runAsync(first.release);
    await tester.pump();
    expect(find.text('没有 Ready 且公开可调用的文本模型，请在引擎中准备。'), findsOneWidget);
    await routed(() async {
      await tester.tap(find.byKey(const Key('llm-discover')));
    });
    final leaving = (await tester.runAsync(() => relay.received(2)))!;
    await routed(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LlmPlaygroundPage(gateway: fixture.gateway, active: false),
          ),
        ),
      );
    });
    await tester.runAsync(
      () => leaving.closed.future.timeout(const Duration(seconds: 2)),
    );
    await routed(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
    });
    final disposing = (await tester.runAsync(() => relay.received(3)))!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => disposing.closed.future.timeout(const Duration(seconds: 2)),
    );
    expect(fixture.io.bodies, isEmpty);
  });

  testWidgets('LLM 编辑器公开发现、JSON与表单保留多消息、提交与会话留存', (tester) async {
    final fixture = (await tester.runAsync(
      () =>
          HttpOverrides.runWithHttpOverrides(LlmTestRuntime.create, _Network()),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
      await waitForWidget(tester, find.byKey(const Key('llm-discovery')));
    });
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-discover')));
      await waitForWidget(tester, find.byKey(const Key('llm-discovery')));
    });
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: find.byKey(const Key('llm-model')),
              matching: find.byType(DropdownButton<String>),
            ),
          )
          .items!
          .map((e) => e.value),
      [fixture.publicId],
    );
    await tapVisible(tester, find.byKey(const Key('llm-json-mode')));
    await tester.pump();
    final document = llmDocument(fixture.publicId);
    await tester.enterText(
      find.byKey(const Key('llm-json')),
      jsonEncode(document),
    );
    await tapVisible(tester, find.byKey(const Key('llm-form-mode')));
    await tester.pump();
    expect(find.byKey(const Key('llm-message-3')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('llm-message-1')),
      'Edited user text  ',
    );
    await tapVisible(tester, find.byKey(const Key('llm-json-mode')));
    await tester.pump();
    (document['messages'] as List)[1]['content'] = 'Edited user text  ';
    expect(
      jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ),
      document,
    );
    await tester.ensureVisible(find.byKey(const Key('llm-run')));
    await tester.pumpAndSettle();
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-run')));
      await waitForWidget(tester, find.byKey(const Key('llm-completed')));
    });
    expect(find.text('Hello.'), findsOneWidget);
    expect(find.textContaining('stop'), findsWidgets);
    expect(fixture.io.bodies.last['messages'], document['messages']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LlmPlaygroundPage(gateway: fixture.gateway, active: false),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
      ),
    );
    expect(find.byKey(const Key('llm-completed')), findsOneWidget);
    expect(
      jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ),
      document,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('llm-timeout')))
          .initialValue,
      '120',
    );
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('llm-result-copy')));
    await tapVisible(tester, find.byKey(const Key('llm-result-copy')));
    await tester.pump();
    expect(clipboard.single.method, 'Clipboard.setData');
    expect((clipboard.single.arguments as Map)['text'], contains('Hello.'));
  });
  testWidgets('LLM 复制证据保留合法消息和助手任务文本，metadata凭据脱敏', (tester) async {
    final fixture = (await tester.runAsync(
      () =>
          HttpOverrides.runWithHttpOverrides(LlmTestRuntime.create, _Network()),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    const task = 'Authorization: allow {"api_key":"ordinary task value"}';
    fixture.io.responseText = task;
    fixture.io.responseUsage = {
      'prompt_tokens': 4,
      'completion_tokens': 2,
      'total_tokens': 6,
      'api_key': 'metadata-secret',
    };
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
      await waitForWidget(tester, find.byKey(const Key('llm-discovery')));
    });
    await tapVisible(tester, find.byKey(const Key('llm-json-mode')));
    final document = llmDocument(fixture.publicId);
    (document['messages'] as List)[1]['content'] = task;
    await tester.enterText(
      find.byKey(const Key('llm-json')),
      jsonEncode(document),
    );
    await tester.ensureVisible(find.byKey(const Key('llm-run')));
    await tester.pumpAndSettle();
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-run')));
      await waitForWidget(tester, find.byKey(const Key('llm-completed')));
    });
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
    await tapVisible(tester, find.byKey(const Key('llm-result-copy')));
    final evidence = jsonDecode(copied!) as Map;
    expect(evidence['request']['messages'][1]['content'], task);
    expect(evidence['text'], task);
    expect(evidence['usage']['api_key'], '[redacted]');
    expect(copied, isNot(contains('metadata-secret')));
    expect(
      jsonDecode(
        evidence['raw_response'] as String,
      )['choices'][0]['message']['content'],
      task,
    );
  });
  testWidgets('LLM 导出当前输入及真实请求快照，保留期限且不覆盖已有文件', (tester) async {
    final fixture = (await tester.runAsync(
      () =>
          HttpOverrides.runWithHttpOverrides(LlmTestRuntime.create, _Network()),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
      await waitForWidget(tester, find.byKey(const Key('llm-discovery')));
    });
    await tapVisible(tester, find.byKey(const Key('llm-json-mode')));
    final sent = llmDocument(fixture.publicId);
    final originalBody = jsonEncode(sent);
    await tester.enterText(find.byKey(const Key('llm-json')), originalBody);
    await tester.ensureVisible(find.byKey(const Key('llm-run')));
    await tester.pumpAndSettle();
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-run')));
      await waitForWidget(tester, find.byKey(const Key('llm-completed')));
    });
    final edited = llmDocument(fixture.publicId);
    (edited['messages'] as List)[1]['content'] = 'Edited after response';
    await tester.enterText(
      find.byKey(const Key('llm-json')),
      jsonEncode(edited),
    );
    await tester.enterText(find.byKey(const Key('llm-timeout')), '0.5');
    final destination = File('${fixture.root.path}/evidence.json');
    await tapVisible(tester, find.byKey(const Key('llm-export')));
    await tester.enterText(
      find.byKey(const Key('llm-export-path')),
      destination.path,
    );
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-export-confirm')));
      await waitForWidget(tester, find.byKey(const Key('llm-export-message')));
    });
    final raw = (await tester.runAsync(destination.readAsString))!;
    final record = jsonDecode(raw) as Map;
    expect(jsonDecode(record['input_json'] as String), edited);
    expect(record['request'], sent);
    expect(record['result']['request_body'], originalBody);
    expect(record['timeout_us'], 120000000);
    expect(record['result']['completed'], isTrue);
    await tapVisible(tester, find.byKey(const Key('llm-export')));
    await tester.enterText(
      find.byKey(const Key('llm-export-path')),
      destination.path,
    );
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-export-confirm')));
      await waitForWidget(tester, find.textContaining('导出失败'));
    });
    expect((await tester.runAsync(destination.readAsString))!, raw);
  });
  testWidgets('离页取消实际SSE，返回仍保留输入、已有文本和实际客户端期限', (tester) async {
    final fixture = (await tester.runAsync(
      () =>
          HttpOverrides.runWithHttpOverrides(LlmTestRuntime.create, _Network()),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    fixture.io.release = Completer<void>();
    fixture.io.streamResponse = (response, alias) async {
      response.write(
        'data: ${jsonEncode({
          'model': alias,
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'Held delta'},
              'finish_reason': null,
            },
          ],
        })}\n\n',
      );
      await response.flush();
      await fixture.io.release!.future;
    };
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
      await waitForWidget(tester, find.byKey(const Key('llm-discovery')));
    });
    await tapVisible(tester, find.byKey(const Key('llm-json-mode')));
    final document = llmDocument(fixture.publicId, stream: true);
    await tester.enterText(
      find.byKey(const Key('llm-json')),
      jsonEncode(document),
    );
    await tester.enterText(find.byKey(const Key('llm-timeout')), '1.5');
    await tester.ensureVisible(find.byKey(const Key('llm-run')));
    await tester.pumpAndSettle();
    await networkAction(tester, () async {
      await tester.tap(find.byKey(const Key('llm-run')));
      await waitForWidget(tester, find.byKey(const Key('llm-running')));
    });
    expect(find.text('Held delta'), findsOneWidget);
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LlmPlaygroundPage(gateway: fixture.gateway, active: false),
          ),
        ),
      );
      await waitForWidget(tester, find.byKey(const Key('llm-cancelled')));
      await waitForLlmPermitRelease(fixture);
    });
    expect(fixture.io.release!.isCompleted, isFalse);
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
        ),
      );
    });
    expect(find.byKey(const Key('llm-cancelled')), findsOneWidget);
    expect(find.text('Held delta'), findsOneWidget);
    expect(
      jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ),
      document,
    );
    expect(
      jsonDecode(
        tester
            .widget<SelectableText>(find.byKey(const Key('llm-result')))
            .data!,
      )['timeout_us'],
      1500000,
    );
  });
}

Future<void> networkAction(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(action, _Network()),
  );
  await tester.pump();
}

Future<void> waitForWidget(WidgetTester tester, Finder finder) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(until)) {
      fail('LLM editor action did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

class _Network extends HttpOverrides {}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}
