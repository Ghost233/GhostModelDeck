import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';

import 'fixtures/generation_runtime.dart';
import 'llm_playground_test.dart' show LlmTestRuntime, writeLlmStream;

const _disabled = <String, Object?>{
  'top_k': null,
  'top_p': null,
  'min_p': null,
  'repeat_penalty': null,
  'presence_penalty': null,
  'frequency_penalty': null,
};

void main() {
  test('Splash sampling disable overrides defaults and persists for the next public JSON/SSE request', () async {
    final fixture = await GenerationTestRuntime.create(
      defaults: GenerationConfiguration({
        'top_k': 20,
        'top_p': 0.7,
        'min_p': 0.1,
        'repeat_penalty': 1.2,
        'presence_penalty': 0.2,
        'frequency_penalty': -0.3,
      }),
    );
    addTearDown(fixture.close);
    final run = fixture.store.runsFor(fixture.definition.id).single;
    for (final stream in [false, true]) {
      final overrides = {..._disabled, 'stream': stream};
      if (stream) {
        overrides.remove('repeat_penalty');
        overrides['repetition_penalty'] = null;
      }
      final response = await fixture.post(overrides);
      expect(response.status, 200, reason: response.body);
      final body = fixture.source.io.chatBodies.last;
      expect(body['top_k'], 0);
      expect(body['top_p'], 1);
      expect(body['min_p'], 0);
      expect(body['repetition_penalty'], 1);
      expect(body['presence_penalty'], 0);
      expect(body['frequency_penalty'], 0);
    }
    final admitted = fixture.post({}, prompt: 'hold');
    await fixture.source.io.holdReached.future.timeout(
      const Duration(seconds: 5),
    );
    final oldBody = Map<String, Object?>.from(
      fixture.source.io.chatBodies.last,
    );
    await fixture.saveDefaults(GenerationConfiguration(_disabled));
    for (final stream in [false, true]) {
      final response = await fixture.post({'stream': stream});
      expect(response.status, 200, reason: response.body);
      final body = fixture.source.io.chatBodies.last;
      expect(body['top_k'], 0);
      expect(body['top_p'], 1);
      expect(body['min_p'], 0);
      expect(body['repetition_penalty'], 1);
      expect(body['presence_penalty'], 0);
      expect(body['frequency_penalty'], 0);
    }
    expect(oldBody['top_k'], 20);
    expect(oldBody['top_p'], 0.7);
    fixture.source.io.releaseHeld.complete();
    await admitted;
    final restored = LaunchInstances(
      catalog: fixture.catalog,
      file: fixture.store.file,
    );
    addTearDown(restored.close);
    await restored.load();
    expect(
      restored.find(fixture.definition.id)!.configuration.generation.values,
      _disabled,
    );
    expect(fixture.store.runsFor(fixture.definition.id).single.id, run.id);
    expect(fixture.source.io.starts, 1);
  });
  test(
    'llama sampling uses its native zero Top P and penalty ranges',
    () async {
      final fixture = await LlmTestRuntime.create();
      addTearDown(fixture.close);
      fixture.io.streamResponse = writeLlmStream;
      for (final stream in [false, true]) {
        final response = await _llamaPost(fixture, {
          'stream': stream,
          'top_p': 0,
          'min_p': 0,
          'presence_penalty': 3,
          'frequency_penalty': -3,
          'repeat_penalty': 0.0001,
        });
        expect(response.status, 200, reason: response.body);
        expect(fixture.io.bodies.last['top_p'], 0);
        expect(fixture.io.bodies.last['min_p'], 0);
        expect(fixture.io.bodies.last['presence_penalty'], 3);
        expect(fixture.io.bodies.last['frequency_penalty'], -3);
        expect(fixture.io.bodies.last['repeat_penalty'], 0.0001);
        final disabled = await _llamaPost(fixture, {
          ..._disabled,
          'stream': stream,
        });
        expect(disabled.status, 200, reason: disabled.body);
        expect(fixture.io.bodies.last['top_k'], 0);
        expect(fixture.io.bodies.last['top_p'], 1);
        expect(fixture.io.bodies.last['min_p'], 0);
        expect(fixture.io.bodies.last['repeat_penalty'], 1);
        expect(fixture.io.bodies.last['presence_penalty'], 0);
        expect(fixture.io.bodies.last['frequency_penalty'], 0);
      }
    },
  );

  test(
    'Splash applies its float32 and penalty constraints before native dispatch',
    () async {
      final fixture = await GenerationTestRuntime.create();
      addTearDown(fixture.close);
      for (final stream in [false, true]) {
        final valid = await fixture.post({
          'stream': stream,
          'top_p': 1.401298464324817e-45,
          'repeat_penalty': 1.401298464324817e-45,
          'presence_penalty': 2,
          'frequency_penalty': -2,
          'min_p': 0,
        });
        expect(valid.status, 200, reason: valid.body);
        expect(
          fixture.source.io.chatBodies.last['top_p'],
          1.401298464324817e-45,
        );
        expect(
          fixture.source.io.chatBodies.last['repetition_penalty'],
          1.401298464324817e-45,
        );
        for (final invalid in [
          {'top_p': 0},
          {'presence_penalty': 3},
          {'frequency_penalty': -3},
          {'repeat_penalty': 1e-50},
          {'repeat_penalty': 1e39},
        ]) {
          final before = fixture.source.io.chatBodies.length;
          final response = await fixture.post({'stream': stream, ...invalid});
          expect(response.status, 400, reason: '$invalid ${response.body}');
          expect(fixture.source.io.chatBodies.length, before);
        }
      }
    },
  );
}

Future<({int status, String body})> _llamaPost(
  LlmTestRuntime fixture,
  Map<String, Object?> values,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      fixture.gateway.baseUrl!.resolve('/v1/chat/completions'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'model': fixture.publicId,
        'messages': [
          {'role': 'user', 'content': 'Reply OK'},
        ],
        ...values,
      }),
    );
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}
