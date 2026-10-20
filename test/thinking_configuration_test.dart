import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';

import 'fixtures/generation_runtime.dart';

import 'llm_playground_test.dart' show LlmTestRuntime, writeLlmStream;

void main() {
  test('llama public thought budget keeps native fields, aliases and service-default semantics', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.streamResponse = writeLlmStream;
    const template = {
      'enable_thinking': true,
      'preserve_reasoning': false,
      'style': 'concise',
      'metadata': {'revision': 3},
    };
    for (final stream in [false, true]) {
      final request = await _llamaPost(fixture, {
        'stream': stream,
        'reasoning_effort': 'medium',
        'reasoning_budget_tokens': 128,
        'chat_template_kwargs': template,
      });
      expect(request.status, 200, reason: request.body);
      expect(fixture.io.bodies.last['reasoning_budget_tokens'], 128);
      expect(fixture.io.bodies.last['chat_template_kwargs'], template);
      for (final value in [-1, 0, 2147483647]) {
        final response = await _llamaPost(fixture, {
          'stream': stream,
          'thinking_budget_tokens': value,
        });
        expect(response.status, 200, reason: response.body);
        expect(fixture.io.bodies.last['reasoning_budget_tokens'], value);
        expect(
          fixture.io.bodies.last.containsKey('thinking_budget_tokens'),
          isFalse,
        );
      }
      final closed = await _llamaPost(fixture, {
        'stream': stream,
        'reasoning_budget_tokens': null,
        'thinking_budget_tokens': 12,
      });
      expect(closed.status, 200, reason: closed.body);
      expect(fixture.io.bodies.last['reasoning_budget_tokens'], 0);
      final inherited = await _llamaPost(fixture, {'stream': stream});
      expect(inherited.status, 200, reason: inherited.body);
      expect(
        fixture.io.bodies.last.containsKey('reasoning_budget_tokens'),
        isFalse,
      );
      for (final fields in [
        {'reasoning_budget_tokens': -2},
        {'reasoning_budget_tokens': 2147483648},
        {'reasoning_budget_tokens': 1.5},
        {'thinking_token_budget': 0},
      ]) {
        final before = fixture.io.bodies.length;
        final response = await _llamaPost(fixture, {
          'stream': stream,
          ...fields,
        });
        expect(response.status, 400, reason: '$fields ${response.body}');
        expect(fixture.io.bodies.length, before);
      }
    }
  });
  test('Splash thought defaults, scheduling and shared cache overrides keep admitted snapshots', () async {
    const template = {
      'enable_thinking': true,
      'style': 'concise',
      'metadata': {'revision': 3},
    };
    final fixture = await GenerationTestRuntime.create(
      defaults: GenerationConfiguration({
        'reasoning_effort': 'medium',
        'thinking_token_budget': 8,
        'preserve_thinking': true,
        'chat_template_kwargs': template,
        'priority': 'foreground',
        'timeout': 30,
        'cache_salt': 'instance-A',
      }),
      formValues: {
        '--default-reasoning-effort': 'low',
        '--thinking-token-budget': '64',
        '--request-timeout': '2s',
      },
    );
    addTearDown(fixture.close);
    final run = fixture.store.runsFor(fixture.definition.id).single;
    expect(
      fixture.source.io.launchArguments.last,
      containsAllInOrder(['--thinking-token-budget', '64']),
    );
    expect(
      fixture.source.io.launchArguments.last,
      containsAllInOrder(['--request-timeout', '2s']),
    );
    for (final stream in [false, true]) {
      final response = await fixture.post({
        'stream': stream,
        'thinking_token_budget': null,
        'cache_salt': null,
        'timeout': null,
        'priority': 'background',
      });
      expect(response.status, 200, reason: response.body);
      final body = fixture.source.io.chatBodies.last;
      expect(body['thinking_token_budget'], 0);
      expect(body.containsKey('cache_salt'), isFalse);
      expect(body.containsKey('timeout'), isFalse);
      expect(body['priority'], 'background');
      expect(body['chat_template_kwargs'], template);
    }
    final admitted = fixture.post({}, prompt: 'hold');
    await fixture.source.io.holdReached.future.timeout(
      const Duration(seconds: 5),
    );
    final oldBody = Map<String, Object?>.from(
      fixture.source.io.chatBodies.last,
    );
    await fixture.saveDefaults(
      GenerationConfiguration({
        'reasoning_effort': 'high',
        'thinking_token_budget': -1,
        'preserve_thinking': false,
        'chat_template_kwargs': template,
        'priority': 'normal',
        'timeout': 10,
        'cache_salt': 'instance-B',
      }),
    );
    for (final stream in [false, true]) {
      final response = await fixture.post({'stream': stream});
      expect(response.status, 200, reason: response.body);
      final body = fixture.source.io.chatBodies.last;
      expect(body['thinking_token_budget'], -1);
      expect(body['preserve_thinking'], false);
      expect(body['priority'], 'normal');
      expect(body['timeout'], 10);
      expect(body['cache_salt'], 'instance-B');
    }
    expect(oldBody['thinking_token_budget'], 8);
    expect(oldBody['priority'], 'foreground');
    expect(oldBody['timeout'], 30);
    expect(oldBody['cache_salt'], 'instance-A');
    fixture.source.io.releaseHeld.complete();
    await admitted;
    final restored = LaunchInstances(
      catalog: fixture.catalog,
      file: fixture.store.file,
    );
    addTearDown(restored.close);
    await restored.load();
    expect(
      restored
          .find(fixture.definition.id)!
          .configuration
          .generation
          .values['thinking_token_budget'],
      -1,
    );
    expect(
      restored
          .find(fixture.definition.id)!
          .configuration
          .generation
          .values['chat_template_kwargs'],
      template,
    );
    expect(
      restored.find(fixture.definition.id)!.configuration.loadingIdentity,
      fixture.definition.configuration.loadingIdentity,
    );
    expect(fixture.store.runsFor(fixture.definition.id).single.id, run.id);
    expect(fixture.source.io.starts, 1);
  });

  test('effective Splash timeout controls gateway JSON/SSE waiting and request override', () async {
    for (final stream in [false, true]) {
      for (final explicit in [false, true]) {
        final fixture = await GenerationTestRuntime.create(
          defaults: GenerationConfiguration({'timeout': explicit ? 0.8 : 0.15}),
        );
        try {
          fixture.source.io.holdChatResponses = true;
          final release = Timer(const Duration(milliseconds: 500), () {
            if (!fixture.source.io.releaseHeld.isCompleted) {
              fixture.source.io.releaseHeld.complete();
            }
          });
          try {
            final response = await fixture.post({
              'stream': stream,
              if (explicit) 'timeout': 0.15,
            });
            expect(response.status, 504, reason: response.body);
            expect(fixture.source.io.chatBodies.last['timeout'], 0.15);
          } finally {
            release.cancel();
          }
        } finally {
          await fixture.close();
        }
      }
    }
  });

  test('template boolean types and Splash reserved controls fail clearly before dispatch', () async {
    final splash = await GenerationTestRuntime.create();
    addTearDown(splash.close);
    final llama = await LlmTestRuntime.create();
    addTearDown(llama.close);
    for (final fields in [
      {
        'chat_template_kwargs': {'enable_thinking': 'yes'},
      },
      {
        'chat_template_kwargs': {'preserve_thinking': 'no'},
      },
      {
        'chat_template_kwargs': {'messages': []},
      },
      {
        'chat_template_kwargs': {'tools': []},
      },
      {
        'chat_template_kwargs': {'add_generation_prompt': true},
      },
      {'reasoning_budget_tokens': 0},
      {'thinking_token_budget': -2},
      {'priority': 'urgent'},
      {'timeout': 0},
      {'timeout': 1e300},
      {'cache_salt': ''},
    ]) {
      final before = splash.source.io.chatBodies.length;
      final response = await splash.post(fields);
      expect(response.status, 400, reason: '$fields ${response.body}');
      expect(splash.source.io.chatBodies.length, before);
    }
    for (final fields in [
      {
        'chat_template_kwargs': {'enable_thinking': 'yes'},
      },
      {
        'chat_template_kwargs': {'preserve_reasoning': 'no'},
      },
      {'preserve_thinking': true},
      {'priority': 'foreground'},
      {'timeout': 1},
      {'cache_salt': 'domain'},
    ]) {
      final before = llama.io.bodies.length;
      final response = await _llamaPost(llama, fields);
      expect(response.status, 400, reason: '$fields ${response.body}');
      expect(llama.io.bodies.length, before);
    }
  });
}

Future<({int status, String body})> _llamaPost(
  LlmTestRuntime fixture,
  Map<String, Object?> fields,
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
        ...fields,
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
