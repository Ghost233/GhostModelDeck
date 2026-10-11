import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/chat_protocol.dart';

import 'llm_playground_test.dart'
    show LlmTestRuntime, llmDocument, writeLlmStream, waitForLlmPermitRelease;

void main() {
  test('普通SSE延迟首帧跨过心跳周期后仍返回正确SSE头、完整文本与实际用量', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.streamResponse = (response, alias) async {
      // Hold the native first frame past several public 20ms heartbeat ticks.
      // The first SSE write must remain the operation that commits its headers.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await writeLlmStream(response, alias, first: 'Held ', rest: 'delta');
    };
    final reply = await _ordinaryStream(fixture);
    expect(reply.status, 200);
    expect(reply.contentType, 'text/event-stream');
    final decoder = TextStreamDecoder(expectedModel: fixture.publicId);
    for (final frame in reply.body.split('\n\n')) {
      final data = frame
          .split('\n')
          .where((line) => line.startsWith('data:'))
          .map((line) => line.substring(5).trimLeft())
          .toList();
      if (data.isNotEmpty) decoder.add(data.join('\n'));
    }
    final result = decoder.finish();
    expect(result.text, 'Held delta');
    expect(result.finishReason, 'stop');
    expect(result.usage, {
      'prompt_tokens': 4,
      'completion_tokens': 2,
      'total_tokens': 6,
    });
    expect(reply.body, contains('data: [DONE]'));
    expect(fixture.io.bodies.single['stream'], isTrue);
    await waitForLlmPermitRelease(fixture);
  });

  test('普通SSE首帧前延迟上游错误仍返回JSON502，不提前提交SSE头或心跳', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.streamResponse = (response, alias) async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      response.statusCode = 502;
      response.write('upstream refused');
    };
    final reply = await _ordinaryStream(fixture);
    expect(reply.status, 502);
    expect(reply.contentType, 'application/json');
    expect(jsonDecode(reply.body)['error']['type'], 'upstream_error');
    expect(reply.body, isNot(contains(': keep-alive')));
    expect(reply.body, isNot(contains('data:')));
    expect(reply.body, isNot(contains('[DONE]')));
    expect(fixture.io.bodies.single['stream'], isTrue);
    await waitForLlmPermitRelease(fixture);
  });
}

class _StreamReply {
  const _StreamReply(this.status, this.contentType, this.body);
  final int status;
  final String? contentType;
  final String body;
}

Future<_StreamReply> _ordinaryStream(LlmTestRuntime fixture) async {
  const timeout = Duration(seconds: 3);
  final client = HttpClient()..connectionTimeout = timeout;
  Future<_StreamReply> receive() async {
    final request = await client.postUrl(
      fixture.gateway.baseUrl!.resolve('/v1/chat/completions'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(llmDocument(fixture.publicId, stream: true)));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return _StreamReply(
      response.statusCode,
      response.headers.contentType?.mimeType,
      body,
    );
  }

  try {
    return await receive().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
