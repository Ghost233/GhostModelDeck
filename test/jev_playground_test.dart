import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/playground_runtime.dart';

import 'package:ghost_model_deck/jev_models.dart';

void main() {
  test('native playground uses the selected managed instance and actual raw result', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: [runtime.engine],
    );
    addTearDown(routes.close);
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    addTearDown(gateway.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final playground = JevPlayground(
      controller: council,
      gateway: gateway,
      mcp: mcp,
    );
    final source = playground.nativeSources.singleWhere(
      (s) => s.model == runtime.engine.state.instances.first.id,
    );
    final document = jsonEncode({
      'model': source.model,
      'state': {
        'nested': ['文字', 7, true, null],
      },
      'images': [],
      'questions': {
        'valid': {
          'type': 'noul',
          'instructions': [
            'Valid',
            {'why': 'same'},
          ],
        },
      },
    });
    final result = await playground.run(
      JevPlaygroundMode.native,
      document,
      nativeSource: source,
    );
    expect(result.status, JevPlaygroundStatus.success);
    expect(result.output!['model'], source.model);
    expect(result.output!['answers'], {
      'valid': {'type': 'noul', 'noul': 0.8},
    });
    expect(result.output!['usage'], {'input_tokens': 10, 'output_tokens': 0});
    expect(runtime.io.requests.single, jsonDecode(document));
    expect(runtime.io.killedChildren, 0);
    expect(
      runtime.engine.state.instances.every((i) => i.activeRequests == 0),
      true,
    );
  });
  test('real HTTP and SDK MCP playground calls route named mixed requests and discovery', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final playground = fixture.playground;
    for (final name in ['quick', 'hard', 'native-kev']) {
      final document = playgroundDocument(
        name,
        state: {
          'nested': ['文字', 7, true, null],
        },
      );
      final http = await playground.run(
        JevPlaygroundMode.http,
        jsonEncode(document),
      );
      final mcp = await playground.run(
        JevPlaygroundMode.mcp,
        jsonEncode(document),
      );
      expect(http.status, JevPlaygroundStatus.success);
      expect(mcp.status, JevPlaygroundStatus.success);
      expect(mcp.output, http.output);
      expect(http.output!.keys, ['model', 'answers', 'usage']);
      expect(http.output!['model'], name);
      expect(http.output!['usage'], {
        'input_tokens': name == 'hard' ? 20 : 10,
        'output_tokens': 0,
      });
      expect((http.output!['answers'] as Map)['valid'], {
        'type': 'noul',
        'noul': 0.8,
      });
      if (name == 'native-kev') {
        expect((http.output!['answers'] as Map)['route'], {
          'type': 'choice',
          'choice': 'b',
          'probabilities': {'a': 0.25, 'b': 0.75},
          'confidence': 0.5,
        });
      }
      final debug = await playground.run(
        JevPlaygroundMode.mcp,
        jsonEncode({...document, 'debug': true}),
      );
      expect(debug.status, JevPlaygroundStatus.success);
      expect(debug.debug!['model'], name);
      expect(
        debug.debug!['source'],
        name == 'native-kev' ? 'native' : 'council',
      );
      expect(debug.debug!['converted_result'], debug.output);
      expect(
        () => (debug.debug!['input'] as Map)['state'] = 'change',
        throwsUnsupportedError,
      );
    }
    for (final mode in [JevPlaygroundMode.http, JevPlaygroundMode.mcp]) {
      final discovery = await playground.discover(mode);
      expect(jsonEncode(discovery), contains('quick'));
      expect(jsonEncode(discovery), contains('hard'));
      expect(jsonEncode(discovery), contains('native-kev'));
    }
    for (final body in fixture.runtime.io.requests) {
      expect((body['questions'] as Map).keys.toList(), [
        'route',
        'rank',
        'valid',
      ]);
    }
    expect(fixture.runtime.io.killedChildren, 0);
    expect(fixture.gateway.state, PublicGatewayState.running);
    expect(fixture.mcp.state.status, CouncilMcpStatus.running);
  });

  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode cancellation seals this call and drains permits without closing resident services',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        final source = fixture.playground.nativeSources.first;
        final name = mode == JevPlaygroundMode.native ? source.model : 'hard';
        final arrived = Completer<void>();
        final held = Completer<void>();
        final unrelatedArrived = Completer<void>();
        final unrelatedHeld = Completer<void>();
        addTearDown(() {
          if (!held.isCompleted) held.complete();
          if (!unrelatedHeld.isCompleted) unrelatedHeld.complete();
        });
        fixture.runtime.io.respond = (body, raw) async {
          if (body['state'] == 'cancelled') {
            if (!arrived.isCompleted) arrived.complete();
            await held.future;
          }
          if (body['state'] == 'unrelated') {
            if (!unrelatedArrived.isCompleted) unrelatedArrived.complete();
            await unrelatedHeld.future;
          }
          return raw;
        };
        final first = await fixture.playground.run(
          mode,
          jsonEncode(playgroundDocument(name)),
          nativeSource: source,
        );
        expect(first.status, JevPlaygroundStatus.success);
        final token = DecisionCancellation();
        final pending = fixture.playground.run(
          mode,
          jsonEncode(playgroundDocument(name, debug: true, state: 'cancelled')),
          nativeSource: source,
          cancellation: token,
        );
        await arrived.future.timeout(const Duration(seconds: 5));
        var unrelatedFinished = false;
        final unrelated = fixture.playground
            .run(
              mode,
              jsonEncode(
                playgroundDocument(
                  mode == JevPlaygroundMode.native ? name : 'quick',
                  debug: true,
                  state: 'unrelated',
                ),
              ),
              nativeSource: source,
            )
            .then((result) {
              unrelatedFinished = true;
              return result;
            });
        await unrelatedArrived.future.timeout(const Duration(seconds: 5));
        final cancellationWatch = Stopwatch()..start();
        token.cancel();
        final cancelled = await pending.timeout(const Duration(seconds: 5));
        expect(cancelled.status, JevPlaygroundStatus.cancelled);
        if (mode == JevPlaygroundMode.native) {
          expect(cancelled.output!['error'], containsPair('code', 'cancelled'));
          expect(cancelled.debug!['input'], containsPair('state', 'cancelled'));
          expect((cancelled.debug!['native'] as Map)['raw_response'], isNull);
        } else {
          expect(cancelled.output, isNull);
          expect(cancelled.debug, isNull);
          expect(cancelled.message, contains('未收到业务结果'));
        }
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (fixture.runtime.engine.state.instances.fold<int>(
                  0,
                  (sum, i) => sum + i.activeRequests,
                ) !=
                1 ||
            (mode == JevPlaygroundMode.mcp &&
                fixture.mcp.state.activeRequests != 1)) {
          if (DateTime.now().isAfter(until)) {
            fail('cancelled request did not drain before external IO release');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(cancellationWatch.elapsed, lessThan(const Duration(seconds: 1)));
        expect(unrelatedFinished, false);
        final sealed = jsonEncode(cancelled.debug);
        held.complete();
        final third = await fixture.playground.run(
          mode,
          jsonEncode(playgroundDocument(name, state: 'third')),
          nativeSource: source,
        );
        expect(third.status, JevPlaygroundStatus.success);
        expect(unrelatedFinished, false);
        final thirdOutput = jsonEncode(third.output);
        unrelatedHeld.complete();
        final unrelatedResult = await unrelated.timeout(
          const Duration(seconds: 5),
        );
        expect(unrelatedResult.status, JevPlaygroundStatus.success);
        expect(
          unrelatedResult.debug!['input'],
          containsPair('state', 'unrelated'),
        );
        expect(
          fixture.runtime.engine.state.instances.every(
            (i) => i.activeRequests == 0,
          ),
          true,
        );
        expect(jsonEncode(third.output), thirdOutput);
        expect(jsonEncode(cancelled.debug), sealed);
        expect(fixture.runtime.io.killedChildren, 0);
        expect(fixture.gateway.state, PublicGatewayState.running);
        expect(fixture.mcp.state.status, CouncilMcpStatus.running);
      },
    );
  }

  test('native debug fixes call-name metadata at entry and redacts the complete raw projection', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final source = fixture.playground.nativeSources.last;
    final arrived = Completer<void>();
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    fixture.runtime.io.respond = (body, raw) async {
      arrived.complete();
      await held.future;
      return jsonEncode({
        ...jsonDecode(raw) as Map,
        'marker': 'full native extra',
        'diagnostic': {'API_KEY': 'playground-secret'},
        'echo': 'playground-secret',
      });
    };
    final pending = fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(playgroundDocument(source.model, debug: true)),
      nativeSource: source,
    );
    await arrived.future.timeout(const Duration(seconds: 3));
    await fixture.council.models.save(
      JevModelDefinition.native(
        name: 'renamed',
        binding: fixture.council.models.definitions
            .singleWhere((d) => d.name == 'native-kev')
            .bindings
            .single,
      ),
      replacing: 'native-kev',
    );
    held.complete();
    final result = await pending;
    expect((result.debug!['configuration'] as Map)['fixed_call_names'], [
      'native-kev',
    ]);
    expect(result.output!['marker'], 'full native extra');
    expect(jsonEncode(result.output), isNot(contains('playground-secret')));
    expect(jsonEncode(result.debug), isNot(contains('playground-secret')));
    expect(
      (result.debug!['native'] as Map)['raw_response'],
      contains('full native extra'),
    );
    expect(
      () => (result.output!['diagnostic'] as Map)['API_KEY'] = 'change',
      throwsUnsupportedError,
    );
  });

  test('protocol business timeouts and engine errors preserve actual received evidence', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final binding = fixture.council.models.definitions
        .singleWhere((d) => d.name == 'native-kev')
        .bindings
        .single;
    await fixture.council.models.save(
      JevModelDefinition.council(
        name: 'deadline',
        seats: [binding],
        timeout: const Duration(milliseconds: 150),
      ),
    );
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    fixture.runtime.io.respond = (body, raw) async {
      if (body['state'] == 'timeout') await held.future;
      return raw;
    };
    for (final mode in [JevPlaygroundMode.http, JevPlaygroundMode.mcp]) {
      final timeout = await fixture.playground.run(
        mode,
        jsonEncode(
          playgroundDocument('deadline', debug: true, state: 'timeout'),
        ),
      );
      expect(timeout.status, JevPlaygroundStatus.businessError);
      expect(timeout.output!['error'], containsPair('code', 'timed_out'));
      expect(timeout.output!.containsKey('answers'), false);
      expect(timeout.debug!['input'], containsPair('state', 'timeout'));
      expect((timeout.debug!['seats'] as List).single['raw_response'], isNull);
      fixture.runtime.io.consultationStatus = 502;
      final error = await fixture.playground.run(
        mode,
        jsonEncode(
          playgroundDocument('hard', debug: true, state: 'engine-error'),
        ),
      );
      expect(error.status, JevPlaygroundStatus.businessError);
      expect(
        error.output!['error'],
        containsPair('code', 'no_successful_seats'),
      );
      expect(
        (error.debug!['seats'] as List).every((s) => s['http_status'] == 502),
        true,
      );
      fixture.runtime.io.consultationStatus = 200;
    }
    held.complete();
    expect(
      fixture.runtime.engine.state.instances.every(
        (i) => i.activeRequests == 0,
      ),
      true,
    );
  });

  test('native admission reports not-ready and required capability without an engine call', () async {
    final io = CouncilRuntimeIO()..failScoreForOther = true;
    final fixture = await PlaygroundRuntime.create(io: io);
    addTearDown(fixture.close);
    final source = fixture.playground.nativeSources.singleWhere(
      (s) => s.instance.asset.name.contains('Other'),
    );
    fixture.runtime.io.requests.clear();
    final capability = await fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(playgroundDocument(source.model)),
      nativeSource: source,
    );
    expect(
      capability.output!['error'],
      containsPair('code', 'capability_mismatch'),
    );
    expect(fixture.runtime.io.requests, isEmpty);
    await fixture.runtime.engine.stop(source.model);
    final stopped = await fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(playgroundDocument(source.model)),
      nativeSource: source,
    );
    expect(stopped.output!['error'], containsPair('code', 'model_not_ready'));
    expect(fixture.runtime.io.requests, isEmpty);
  });

  test('real protocols report ambiguous native binding and retain a whole successful council seat', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final binding = fixture.council.models.definitions
        .singleWhere((d) => d.name == 'native-kev')
        .bindings
        .single;
    await fixture.runtime.engine.start(binding.artifactId);
    fixture.runtime.io.requests.clear();
    for (final mode in [JevPlaygroundMode.http, JevPlaygroundMode.mcp]) {
      final rejected = await fixture.playground.run(
        mode,
        jsonEncode(playgroundDocument('native-kev', debug: true)),
      );
      expect(rejected.status, JevPlaygroundStatus.businessError);
      expect(rejected.output!['error'], containsPair('code', 'route_conflict'));
      expect((rejected.debug!['native'] as Map)['dispatched'], false);
      expect(fixture.runtime.io.requests, isEmpty);
      expect(
        jsonEncode(await fixture.playground.discover(mode)),
        isNot(contains('native-kev')),
      );
      final partial = await fixture.playground.run(
        mode,
        jsonEncode(playgroundDocument('hard', debug: true)),
      );
      expect(partial.status, JevPlaygroundStatus.success);
      expect(partial.output!['usage'], {
        'input_tokens': 10,
        'output_tokens': 0,
      });
      expect((partial.debug!['valid_seats'] as List).length, 1);
      fixture.runtime.io.requests.clear();
    }
  });

  test(
    'native error status and debug never display upstream credentials',
    () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      fixture.runtime.io.consultationStatus = 502;
      fixture.runtime.io.respond = (body, raw) async =>
          'authorization: Bearer status-secret\nstatus-secret';
      final source = fixture.playground.nativeSources.first;
      final result = await fixture.playground.run(
        JevPlaygroundMode.native,
        jsonEncode(playgroundDocument(source.model, debug: true)),
        nativeSource: source,
      );
      expect(result.status, JevPlaygroundStatus.businessError);
      expect(result.message, isNot(contains('status-secret')));
      expect(jsonEncode(result.output), isNot(contains('status-secret')));
      expect(jsonEncode(result.debug), isNot(contains('status-secret')));
    },
  );

  test('missing or unknown model and invalid JSON fail explicitly without reusing a previous payload', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    fixture.runtime.io.requests.clear();
    for (final mode in [JevPlaygroundMode.http, JevPlaygroundMode.mcp]) {
      final missing = playgroundDocument('quick')..remove('model');
      final invalid = await fixture.playground.run(mode, jsonEncode(missing));
      expect(invalid.status, JevPlaygroundStatus.businessError);
      expect(invalid.message, contains('model 需要是非空字符串'));
      final unknown = await fixture.playground.run(
        mode,
        jsonEncode(playgroundDocument('unknown')),
      );
      expect(unknown.output!['error'], containsPair('code', 'model_not_found'));
      expect(unknown.message, '服务返回本次业务错误');
      final malformed = await fixture.playground.run(mode, '{broken');
      expect(malformed.message, contains('JSON 格式错误'));
    }
    expect(fixture.runtime.io.requests, isEmpty);
  });
  test('a selection made while loading records the actual ready alias at admission', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    fixture.runtime.io.holdIdentity(expected: 1);
    final starting = fixture.runtime.engine.start(
      fixture.council.models.availableBindings.last.artifactId,
    );
    late JevNativeSource selected;
    try {
      await fixture.runtime.io.identityArrived!.future.timeout(
        const Duration(seconds: 5),
      );
      selected = fixture.playground.nativeSources.last;
    } finally {
      fixture.runtime.io.identityRelease!.complete();
      await starting;
    }
    expect(selected.ready, false);
    final result = await fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(playgroundDocument(selected.model, debug: true)),
      nativeSource: selected,
    );
    expect(result.status, JevPlaygroundStatus.success);
    expect(
      (result.debug!['configuration'] as Map)['native_alias'],
      selected.model,
    );
  });
  test('native cancellation retains validated raw task data and hides unknown credentials', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final source = fixture.playground.nativeSources.first;
    final token = DecisionCancellation();
    fixture.runtime.io.respond = (body, raw) async => jsonEncode({
      ...jsonDecode(raw) as Map,
      'marker': 'accepted-before-cancel',
      'diagnostic': {'API_KEY': 'accepted-extra-token'},
    });
    final subscription = fixture.runtime.engine.changes.listen((state) {
      if (state.instances.any(
        (instance) =>
            instance.lastBatchResult?.rawResponse.contains(
              'accepted-before-cancel',
            ) ==
            true,
      )) {
        token.cancel();
      }
    });
    addTearDown(subscription.cancel);
    final document = credentialNamedJevDocument(source.model, debug: true);
    final result = await fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(document),
      nativeSource: source,
      cancellation: token,
    );
    expect(result.status, JevPlaygroundStatus.cancelled);
    final input = result.debug!['input'] as Map;
    expect(input['state'], document['state']);
    expect(input['questions'], document['questions']);
    final raw = jsonDecode(
      (result.debug!['native'] as Map)['raw_response'] as String,
    );
    expect(raw['answers'], credentialNamedJevAnswers);
    expect(raw['diagnostic'], {'API_KEY': '[redacted]'});
    expect(jsonEncode(result.debug), isNot(contains('accepted-extra-token')));
    expect(
      fixture.runtime.engine.state.instances.every(
        (i) => i.activeRequests == 0,
      ),
      true,
    );
  });
  test('native rejected raw JSON cannot claim response immunity through model or answers', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final source = fixture.playground.nativeSources.first;
    fixture.runtime.io.respond = (body, raw) async => jsonEncode({
      'model': 'Authorization: Bearer invalid-model-token',
      'answers': {
        'q': {
          'type': 'score',
          'legend': {'API_KEY': 'invalid-legend-token'},
        },
      },
    });
    final result = await fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(credentialNamedJevDocument(source.model, debug: true)),
      nativeSource: source,
    );
    expect(result.status, JevPlaygroundStatus.businessError);
    expect((result.output!['error'] as Map)['code'], 'invalid_response');
    final raw = jsonDecode(
      (result.debug!['native'] as Map)['raw_response'] as String,
    );
    expect(raw['model'], 'Authorization: [redacted]');
    expect(raw['answers']['q']['legend'], {'API_KEY': '[redacted]'});
    for (final secret in ['invalid-model-token', 'invalid-legend-token']) {
      expect(jsonEncode(result.debug), isNot(contains(secret)));
    }
  });
  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode unknown nested response shapes cannot establish JEV task immunity',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        fixture.runtime.io.respond = (body, raw) async =>
            jsonEncode(nestedCredentialJevResponse(raw));
        final source = fixture.playground.nativeSources.first;
        for (final name
            in mode == JevPlaygroundMode.native
                ? [source.model]
                : ['quick', 'hard', 'native-kev']) {
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            final result = await fixture.playground.run(
              mode,
              jsonEncode(document),
              nativeSource: source,
            );
            expect(result.status, JevPlaygroundStatus.success);
            expect(result.output!['answers'], credentialNamedJevAnswers);
            final responses = <Map>[];
            if (mode == JevPlaygroundMode.native) responses.add(result.output!);
            if (debug) {
              expect(
                (result.debug!['input'] as Map)['questions'],
                document['questions'],
              );
              expect(
                (result.debug!['input'] as Map)['state'],
                document['state'],
              );
              final ios = result.debug!['source'] == 'council'
                  ? result.debug!['seats'] as List
                  : [result.debug!['native']];
              for (final io in ios) {
                responses.add(
                  jsonDecode((io as Map)['raw_response'] as String) as Map,
                );
              }
            } else {
              expect(result.debug, isNull);
            }
            for (final response in responses) {
              expect(response['server_metadata']['state'], {
                'API_KEY': '[redacted]',
              });
              expect(response['response_metadata']['answers']['q']['legend'], {
                'API_KEY': '[redacted]',
              });
              expect(
                response['diagnostic']['model'],
                'Authorization: [redacted]',
              );
              final encoded = response['encoded_metadata'] as List;
              expect(jsonDecode(encoded.first as String)['state'], {
                'API_KEY': '[redacted]',
              });
              expect(
                jsonDecode(encoded.last as String)['answers']['q']['legend'],
                {'Authorization': '[redacted]'},
              );
              expect(
                response['echo'],
                '[redacted] [redacted] [redacted] [redacted] [redacted]',
              );
              expect(response['answers'], credentialNamedJevAnswers);
            }
            for (final secret in [
              'shape-secret',
              'response-legend-token',
              'unique-secret',
              'encoded-question-token',
              'encoded-answer-token',
            ]) {
              expect(jsonEncode(result.output), isNot(contains(secret)));
              expect(jsonEncode(result.debug), isNot(contains(secret)));
            }
          }
        }
        for (final request in fixture.runtime.io.requests) {
          expect(
            request['questions'],
            credentialNamedJevDocument('ignored')['questions'],
          );
          expect(
            request['state'],
            credentialNamedJevDocument('ignored')['state'],
          );
        }
      },
    );
  }
  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode response answer extras cannot inherit request question credential immunity',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        fixture.runtime.io.respond = (body, raw) async =>
            jsonEncode(credentialExtraJevResponse(raw));
        final source = fixture.playground.nativeSources.first;
        for (final name
            in mode == JevPlaygroundMode.native
                ? [source.model]
                : ['quick', 'hard', 'native-kev']) {
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            final result = await fixture.playground.run(
              mode,
              jsonEncode(document),
              nativeSource: source,
            );
            expect(result.status, JevPlaygroundStatus.success);
            final answers = result.output!['answers'] as Map;
            expect(answers['cookie'], credentialNamedJevAnswers['cookie']);
            expect(
              answers['authorization'],
              credentialNamedJevAnswers['authorization'],
            );
            expect(answers['api_key']['probabilities'], {
              'authorization': 0.25,
              'cookie': 0.75,
            });
            if (mode == JevPlaygroundMode.native) {
              expect(answers['api_key']['instructions'], {
                'API_KEY': '[redacted]',
              });
              expect(result.output!['server_log'], 'Authorization: [redacted]');
              expect(result.output!['unrelated_typed'], {
                'type': 'choice',
                'instructions': {'API_KEY': '[redacted]'},
              });
            }
            if (debug) {
              expect(
                (result.debug!['input'] as Map)['questions'],
                document['questions'],
              );
              final ios = result.debug!['source'] == 'council'
                  ? result.debug!['seats'] as List
                  : [result.debug!['native']];
              for (final io in ios) {
                final raw = jsonDecode((io as Map)['raw_response'] as String);
                expect(raw['answers']['api_key']['instructions'], {
                  'API_KEY': '[redacted]',
                });
                expect(
                  raw['answers']['cookie'],
                  credentialNamedJevAnswers['cookie'],
                );
                expect(raw['server_log'], 'Authorization: [redacted]');
              }
            } else {
              expect(result.debug, isNull);
            }
            for (final secret in [
              'answer-extra-secret',
              'unknown-header-token',
              'unlisted-cookie-token',
              'typed-object-secret',
            ]) {
              expect(jsonEncode(result.output), isNot(contains(secret)));
              expect(jsonEncode(result.debug), isNot(contains(secret)));
            }
          }
        }
        expect(fixture.runtime.io.requests, isNotEmpty);
        for (final body in fixture.runtime.io.requests) {
          expect(
            body['questions'],
            credentialNamedJevDocument('ignored')['questions'],
          );
        }
      },
    );
  }
  test('native default output redacts unknown plaintext credential extras without a debug sibling', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final source = fixture.playground.nativeSources.first;
    fixture.runtime.io.respond = (body, raw) async => jsonEncode({
      ...jsonDecode(raw) as Map,
      'server_log': 'Authorization: Bearer extra-secret',
      'unlisted_trace': ['Cookie: sid=extra-cookie-secret'],
      'echo': 'extra-secret extra-cookie-secret',
    });
    final result = await fixture.playground.run(
      JevPlaygroundMode.native,
      jsonEncode(credentialNamedJevDocument(source.model)),
      nativeSource: source,
    );
    expect(result.status, JevPlaygroundStatus.success);
    expect(result.debug, isNull);
    expect(result.output!['answers'], credentialNamedJevAnswers);
    expect(result.output!['server_log'], 'Authorization: [redacted]');
    expect(result.output!['unlisted_trace'], ['Cookie: [redacted]']);
    expect(result.output!['echo'], '[redacted] [redacted]');
    for (final secret in ['extra-secret', 'extra-cookie-secret']) {
      expect(jsonEncode(result.output), isNot(contains(secret)));
    }
  });
  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode legal credential-looking JEV IDs and JSON descriptions survive native and real HTTP/MCP default and debug',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        final source = fixture.playground.nativeSources.first;
        for (final name
            in mode == JevPlaygroundMode.native
                ? [source.model]
                : ['quick', 'hard', 'native-kev']) {
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            final result = await fixture.playground.run(
              mode,
              jsonEncode(document),
              nativeSource: source,
            );
            expect(result.status, JevPlaygroundStatus.success);
            expect(result.output, {
              'model': name,
              'answers': credentialNamedJevAnswers,
              'usage': {
                'input_tokens': name == 'hard' ? 20 : 10,
                'output_tokens': 0,
              },
            });
            if (debug) {
              final input = result.debug!['input'] as Map;
              expect(input['questions'], document['questions']);
              expect(input['state'], document['state']);
              final ios =
                  (result.debug!['source'] == 'council'
                          ? result.debug!['seats'] as List
                          : [result.debug!['native']])
                      .cast<Map>();
              for (final io in ios) {
                expect(io['request']['questions'], document['questions']);
                expect(io['request']['state'], document['state']);
                expect(
                  jsonDecode(io['request_body'] as String)['questions'],
                  document['questions'],
                );
                expect(
                  jsonDecode(io['raw_response'] as String)['answers'],
                  credentialNamedJevAnswers,
                );
              }
              if (result.debug!['source'] == 'council') {
                final council = result.debug!['council'] as Map;
                expect(council['request']['questions'], document['questions']);
                for (final seat in council['seats'] as List) {
                  expect(seat['answers'], credentialNamedJevAnswers);
                  expect(
                    jsonDecode(seat['raw_response'] as String)['answers'],
                    credentialNamedJevAnswers,
                  );
                }
                if (name == 'hard') {
                  final totals = council['aggregates'] as Map;
                  expect(totals.keys.toList(), [
                    'api_key',
                    'cookie',
                    'authorization',
                  ]);
                  expect(totals['api_key']['probabilities'], {
                    'authorization': 0.25,
                    'cookie': 0.75,
                  });
                  expect(totals['api_key']['votes'], {
                    'authorization': 0,
                    'cookie': 2,
                  });
                  expect(totals['cookie']['legend'], {
                    '0': 'Authorization: allow',
                    '1': {'api_key': 'Authorization: allow'},
                  });
                }
              }
              expect(result.debug!['converted_result'], result.output);
            } else {
              expect(result.debug, isNull);
            }
          }
        }
      },
    );
  }
}
