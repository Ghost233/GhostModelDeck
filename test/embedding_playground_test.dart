import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/embedding_playground.dart';
import 'package:ghost_model_deck/engine_runtime.dart';

import 'fixtures/embedding_runtime.dart';

void main() {
  test('真实公开HTTP仅发现已加载嵌入模型，数组原文/向量/实际用量保留', () async {
    final server = await EmbeddingTestRuntime.create();
    addTearDown(server.close);
    final playground = EmbeddingPlayground(
      baseUrl: () => server.gateway.baseUrl,
    );
    expect(await playground.discover(), [server.publicId]);
    await server.routes.disable(server.asset.id);
    expect(await playground.discover(), isEmpty);
    await server.routes.enable(server.asset.id);
    final body = jsonEncode({
      'model': server.publicId,
      'input': [' 苹果 ', '香蕉'],
    });
    final result = await playground.run(body);
    expect(server.io.bodies.length, 1);
    expect(server.io.bodies.single['input'], [' 苹果 ', '香蕉']);
    expect(result.completed, isTrue);
    expect(result.statusCode, 200);
    expect(result.requestBody, body);
    expect(result.result!.vectors, [
      [3.0, 0.0],
      [0.0, 4.0],
    ]);
    expect(result.result!.usage['prompt_tokens'], 8);
    expect(jsonDecode(result.rawResponse)['model'], server.publicId);
    expect(result.timeout, const Duration(seconds: 120));
  });

  test('取消仅关闭自己的实际HTTP，独立调用与后续请求仍成功，晚结果不接受', () async {
    final server = await EmbeddingTestRuntime.create();
    addTearDown(server.close);
    server.io.release = Completer<void>();
    server.io.held = Completer<void>();
    final playground = EmbeddingPlayground(
      baseUrl: () => server.gateway.baseUrl,
    );
    final token = DecisionCancellation();
    final pending = playground.run(
      jsonEncode({'model': server.publicId, 'input': 'hold'}),
      cancellation: token,
    );
    await server.io.held!.future.timeout(const Duration(seconds: 3));
    final independent = await playground.run(
      jsonEncode({'model': server.publicId, 'input': 'other'}),
    );
    expect(independent.completed, isTrue);
    token.cancel();
    final cancelled = await pending.timeout(const Duration(seconds: 2));
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.timedOut, isFalse);
    expect(cancelled.completed, isFalse);
    expect(cancelled.result, isNull);
    expect(server.io.release!.isCompleted, isFalse);
    await waitForEmbeddingRelease(server);
    server.io.release!.complete();
    expect(cancelled.result, isNull);
    expect(
      (await playground.run(
        jsonEncode({'model': server.publicId, 'input': 'later'}),
      )).completed,
      isTrue,
    );
  });

  test('一个客户端截止覆盖连接和响应，挂起公开请求超时保留真实期限', () async {
    final server = await EmbeddingTestRuntime.create();
    addTearDown(server.close);
    server.io.release = Completer<void>();
    server.io.held = Completer<void>();
    final playground = EmbeddingPlayground(
      baseUrl: () => server.gateway.baseUrl,
    );
    final result = await playground.run(
      jsonEncode({'model': server.publicId, 'input': 'hold'}),
      timeout: const Duration(milliseconds: 300),
    );
    expect(result.timedOut, isTrue);
    expect(result.cancelled, isFalse);
    expect(result.completed, isFalse);
    expect(result.statusCode, isNull);
    expect(result.rawResponse, isEmpty);
    expect(result.timeout, const Duration(milliseconds: 300));
    expect(result.toJson()['timeout_us'], 300000);
    await waitForEmbeddingRelease(server);
  });

  test('预取消与非法输入不发请求，HTTP错误原文和无效响应真实保留', () async {
    final server = await EmbeddingTestRuntime.create();
    addTearDown(server.close);
    final playground = EmbeddingPlayground(
      baseUrl: () => server.gateway.baseUrl,
    );
    final token = DecisionCancellation()..cancel();
    final cancelled = await playground.run(
      jsonEncode({'model': server.publicId, 'input': 'a'}),
      cancellation: token,
    );
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.requestBody, isNull);
    final invalid = await playground.run(
      jsonEncode({
        'model': server.publicId,
        'input': [3],
      }),
    );
    expect(invalid.completed, isFalse);
    expect(server.io.bodies, isEmpty);
    server.io.status = 413;
    server.io.responseBody = '{"error":"input_too_large"}';
    final failed = await playground.run(
      jsonEncode({'model': server.publicId, 'input': 'a'}),
    );
    expect(failed.statusCode, 502);
    expect(failed.rawResponse, isNotEmpty);
    expect(failed.error, isNotEmpty);
    server.io.status = 200;
    server.io.responseBody = '{"model":"wrong","data":[]}';
    final wrong = await playground.run(
      jsonEncode({'model': server.publicId, 'input': 'a'}),
    );
    expect(wrong.completed, isFalse);
    expect(wrong.statusCode, 502);
    expect(wrong.rawResponse, isNotEmpty);
  });

  test('导出区分当前输入和实际已发请求，保留期限并拒绝覆盖', () async {
    final server = await EmbeddingTestRuntime.create();
    final folder = await Directory.systemTemp.createTemp(
      'gmd-embedding-export-',
    );
    addTearDown(server.close);
    addTearDown(() => folder.delete(recursive: true));
    final playground = EmbeddingPlayground(
      baseUrl: () => server.gateway.baseUrl,
    );
    final original = jsonEncode({'model': server.publicId, 'input': 'sent'});
    final result = await playground.run(
      original,
      timeout: const Duration(seconds: 3),
    );
    final destination = File('${folder.path}/evidence.json');
    final edited = jsonEncode({'model': server.publicId, 'input': 'edited'});
    await playground.exportTo(destination, document: edited, result: result);
    final contents = await destination.readAsString();
    final record = jsonDecode(contents) as Map;
    expect(record['input_json'], edited);
    expect(record['result']['request_body'], original);
    expect(record['timeout_us'], 3000000);
    expect(record['result']['completed'], isTrue);
    await expectLater(
      playground.exportTo(destination, document: 'new'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await destination.readAsString(), contents);
  });

  test('合法任务文本中的认证词保留，响应metadata认证字段脱敏', () async {
    final server = await EmbeddingTestRuntime.create();
    addTearDown(server.close);
    const task = 'Authorization: allow {"api_key":"ordinary task value"}';
    server.io.usage = {
      'prompt_tokens': 8,
      'total_tokens': 8,
      'api_key': 'real-secret',
    };
    final result = await EmbeddingPlayground(
      baseUrl: () => server.gateway.baseUrl,
    ).run(jsonEncode({'model': server.publicId, 'input': task}));
    expect(result.completed, isTrue);
    final evidence = result.toJson();
    expect((evidence['request'] as Map)['input'], task);
    expect(jsonDecode(evidence['request_body'] as String)['input'], task);
    expect((evidence['usage'] as Map)['api_key'], '[redacted]');
    expect(jsonEncode(evidence), isNot(contains('real-secret')));
  });
}

Future<void> waitForEmbeddingRelease(EmbeddingTestRuntime fixture) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (fixture.engine.runtimeInstances.any(
    (instance) => instance.activeRequests != 0,
  )) {
    if (DateTime.now().isAfter(until)) {
      fail('Cancelled embedding retained an engine request permit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
