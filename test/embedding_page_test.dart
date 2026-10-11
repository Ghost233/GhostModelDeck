import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/embedding_page.dart';

import 'fixtures/embedding_runtime.dart';

void main() {
  testWidgets('嵌入页公开发现、编辑批次、实际向量和余弦展示、复制与导出', (tester) async {
    final fixture = (await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(
        EmbeddingTestRuntime.create,
        _Network(),
      ),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmbeddingPage(gateway: fixture.gateway)),
        ),
      );
      await waitFor(tester, find.byKey(const Key('embedding-discovery')));
    });
    final body = jsonEncode({
      'model': fixture.publicId,
      'input': ['苹果', '香蕉'],
    });
    await tester.enterText(find.byKey(const Key('embedding-json')), body);
    await tapVisible(
      tester,
      find.byKey(const Key('embedding-run')),
      network: true,
    );
    await networkAction(
      tester,
      () => waitFor(tester, find.byKey(const Key('embedding-completed'))),
    );
    expect(find.text('向量数量：2 · 维度：2'), findsOneWidget);
    expect(find.text('两条输入余弦相似度：0.000000'), findsOneWidget);
    expect(fixture.io.bodies.single['input'], ['苹果', '香蕉']);
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
    await tapVisible(tester, find.byKey(const Key('embedding-result-copy')));
    final evidence = jsonDecode(copied!) as Map;
    expect(evidence['request_body'], body);
    expect(evidence['usage']['prompt_tokens'], 8);
    final destination = File('${fixture.root.path}/export.json');
    await tapVisible(tester, find.byKey(const Key('embedding-export')));
    await tester.enterText(
      find.byKey(const Key('embedding-export-path')),
      destination.path,
    );
    await tapVisible(
      tester,
      find.byKey(const Key('embedding-export-confirm')),
      network: true,
    );
    await networkAction(
      tester,
      () => waitFor(tester, find.byKey(const Key('embedding-export-message'))),
    );
    final exported =
        jsonDecode((await tester.runAsync(destination.readAsString))!) as Map;
    expect(exported['result']['request_body'], body);
    expect(exported['result']['completed'], isTrue);
    expect(exported['timeout_us'], 120000000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离页取消普通嵌入HTTP，返回保留输入、取消证据和实际期限', (tester) async {
    final fixture = (await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(
        EmbeddingTestRuntime.create,
        _Network(),
      ),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    await tester.runAsync(() async {
      // The real engine HTTP server must complete these outside FakeAsync.
      fixture.io.release = Completer<void>();
      fixture.io.held = Completer<void>();
    });
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmbeddingPage(gateway: fixture.gateway)),
        ),
      );
      await waitFor(tester, find.byKey(const Key('embedding-discovery')));
    });
    final body = jsonEncode({'model': fixture.publicId, 'input': 'hold'});
    await tester.enterText(find.byKey(const Key('embedding-json')), body);
    await tester.enterText(find.byKey(const Key('embedding-timeout')), '1.5');
    await tapVisible(
      tester,
      find.byKey(const Key('embedding-run')),
      network: true,
    );
    await tester.runAsync(
      () => fixture.io.held!.future.timeout(const Duration(seconds: 3)),
    );
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmbeddingPage(gateway: fixture.gateway, active: false),
          ),
        ),
      );
      await waitFor(tester, find.byKey(const Key('embedding-cancelled')));
    });
    expect(fixture.io.release!.isCompleted, isFalse);
    await networkAction(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EmbeddingPage(gateway: fixture.gateway)),
        ),
      );
      await waitFor(tester, find.byKey(const Key('embedding-discovery')));
    });
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('embedding-json')))
          .controller!
          .text,
      body,
    );
    final evidence = jsonDecode(
      tester
          .widget<SelectableText>(find.byKey(const Key('embedding-result')))
          .data!,
    ) as Map;
    expect(evidence['cancelled'], isTrue);
    expect(evidence['completed'], isFalse);
    expect(evidence['timeout_us'], 1500000);
    expect(tester.takeException(), isNull);
  });
}

class _Network extends HttpOverrides {}

Future<void> networkAction(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(action, _Network()),
  );
  await tester.pump();
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(until)) {
      fail('Embedding public UI action did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

Future<void> tapVisible(
  WidgetTester tester,
  Finder finder, {
  bool network = false,
}) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  if (network) {
    await networkAction(tester, () async {
      await tester.tap(finder);
    });
  } else {
    await tester.tap(finder);
    await tester.pump();
  }
}
