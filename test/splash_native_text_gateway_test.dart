import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/generation_configuration.dart';

import 'fixtures/generation_runtime.dart';
import 'fixtures/native_text_api.dart';

void main() {
  test('native Splash Responses and Messages preserve wire formats and owner credentials', () async {
    final fixture = await GenerationTestRuntime.create(
      defaults: GenerationConfiguration({
        'max_tokens': 32,
        'temperature': .4,
        'thinking_token_budget': 1024,
        'reasoning_effort': 'low',
      }),
      formValues: {'--api-key': 'splash-owner-key'},
    );
    addTearDown(fixture.close);
    final model = fixture.definition.publicName;
    final seen = <String, Map<String, Object?>>{};
    fixture.source.io.nativeText = (request, alias) async {
      expect(request.headers.value('Authorization'), 'Bearer splash-owner-key');
      expect(request.headers.value('x-api-key'), isNull);
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, Object?>;
      expect(body['model'], alias);
      final path = request.uri.path;
      seen[path] = body;
      if (path == '/v1/responses') {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'event: response.created\r\n'
          'data: {"type":"response.created",\r\n'
          'data: "response":{"id":"resp-1","model":"$alias"}}\r\n\r\n'
          'event: response.output_text.delta\n'
          'data: {"type":"response.output_text.delta","delta":"你好"}\n\n'
          'event: response.completed\n'
          'data: {"type":"response.completed","response":{"id":"resp-1","model":"$alias","status":"completed"}}\n\n',
        );
      } else {
        expect(request.headers.value('anthropic-version'), '2023-06-01');
        request.response.write(
          jsonEncode(
            path.endsWith('/count_tokens')
                ? {'input_tokens': 4}
                : {
                    'type': 'message',
                    'model': alias,
                    'content': [
                      {'type': 'text', 'text': 'Hello.'},
                    ],
                  },
          ),
        );
      }
      await request.response.close();
    };
    final format = {
      'type': 'json_schema',
      'name': 'answer',
      'schema': {'type': 'object'},
    };
    final responses = await postNativeText(
      fixture.gateway.baseUrl!,
      '/v1/responses',
      {
        'model': model,
        'input': 'hello',
        'stream': true,
        'text': {'format': format},
        'temperature': .2,
      },
    );
    expect(responses.status, 200);
    expect(responses.mime, 'text/event-stream');
    expect(responses.body, contains('event: response.output_text.delta'));
    expect(responses.body, contains('"delta":"你好"'));
    expect(responses.body, contains('"model":"$model"'));
    expect(responses.body, contains('event: response.completed'));
    expect(seen['/v1/responses']!['text'], {'format': format});
    expect(seen['/v1/responses']!['temperature'], .2);
    expect(seen['/v1/responses']!['max_output_tokens'], 32);
    final messageBody = {
      'model': model,
      'messages': [
        {'role': 'user', 'content': 'hello'},
      ],
    };
    final messages = await postNativeText(
      fixture.gateway.baseUrl!,
      '/v1/messages',
      messageBody,
    );
    expect(messages.status, 200);
    expect(jsonDecode(messages.body), {
      'type': 'message',
      'model': model,
      'content': [
        {'type': 'text', 'text': 'Hello.'},
      ],
    });
    expect(seen['/v1/messages']!['max_tokens'], 32);
    expect(seen['/v1/messages']!['temperature'], .4);
    expect(seen['/v1/messages']!['thinking'], {
      'type': 'enabled',
      'budget_tokens': 1024,
    });
    expect(seen['/v1/messages']!['output_config'], {'effort': 'low'});
    final count = await postNativeText(
      fixture.gateway.baseUrl!,
      '/v1/messages/count_tokens',
      messageBody,
    );
    expect(count.status, 200);
    expect(jsonDecode(count.body), {'input_tokens': 4});
    expect(
      seen['/v1/messages/count_tokens']!.containsKey('max_tokens'),
      isFalse,
    );
    final rejected = await postNativeText(
      fixture.gateway.baseUrl!,
      '/v1/messages',
      {...messageBody, 'model': 'no-such-model'},
    );
    expect(rejected.status, 404);
    expect(jsonDecode(rejected.body)['type'], 'error');
  });
}
