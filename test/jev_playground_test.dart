import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/playground_runtime.dart';

import 'package:ghost_model_deck/jev_models.dart';

void main() {
  test(
    'JEV export preserves primary write failure when cleanup also fails',
    () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      final destination = _FailingExportFile();
      await expectLater(
        fixture.playground.exportTo(
          destination,
          document: jsonEncode(playgroundDocument('quick')),
        ),
        throwsA(
          isA<FileSystemException>()
              .having(
                (error) => error.message,
                'primary write cause',
                contains('primary write failed'),
              )
              .having(
                (error) => error.message,
                'secondary cleanup cause',
                contains('secondary cleanup failed'),
              ),
        ),
      );
      expect(destination.exclusiveCreated, isTrue);
      expect(destination.writeAttempted, isTrue);
      expect(destination.cleanupAttempted, isTrue);
    },
  );

  for (final mode in JevPlaygroundMode.values) {
    for (final invalidJson in [true, false]) {
      test(
        '$mode invalid external engine ${invalidJson ? 'JSON' : 'typed answer'} remains an explicit response failure with raw evidence',
        () async {
          final fixture = await PlaygroundRuntime.create();
          addTearDown(fixture.close);
          var engineRaw = '';
          fixture.runtime.io.respond = (body, raw) async {
            if (invalidJson) {
              engineRaw = '{not-json: external-engine-evidence';
            } else {
              final response = jsonDecode(raw) as Map;
              response['answers']['route']['probabilities'] = {
                'a': 0.9,
                'b': 0.9,
              };
              engineRaw = jsonEncode(response);
            }
            return engineRaw;
          };
          final document = playgroundDocument('native-kev', debug: true);
          final result = await fixture.playground.run(
            mode,
            jsonEncode(document),
          );
          expect(result.status.name, 'invalidResponse');
          expect(result.message, contains('响应'));
          expect(result.message, isNot(contains('JSON 格式错误')));
          expect(
            result.output!['error'],
            containsPair('code', 'invalid_response'),
          );
          expect(result.output!.containsKey('answers'), false);
          expect(
            result.httpStatus,
            mode == JevPlaygroundMode.http ? 502 : isNull,
          );
          expect(result.rawResponse, isNotNull);
          final publicRaw = jsonDecode(result.rawResponse!) as Map;
          expect(publicRaw['error'], result.output!['error']);
          expect(
            (publicRaw['debug']['native'] as Map)['raw_response'],
            engineRaw,
          );
          expect((result.debug!['native'] as Map)['raw_response'], engineRaw);
          expect(result.request, document);
          final invalidInput = await fixture.playground.run(mode, '{bad-input');
          expect(invalidInput.status, JevPlaygroundStatus.businessError);
          expect(invalidInput.message, contains('JSON 格式错误'));
          expect(invalidInput.rawResponse, isNull);
        },
      );
    }
  }
  test(
    'public raw response and export match an independent ordinary HTTP client',
    () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      final document = jsonEncode(credentialNamedJevDocument('native-kev'));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        fixture.gateway.baseUrl!.resolve('/v1/systemone'),
      );
      request.headers.contentType = ContentType.json;
      request.write(document);
      final response = await request.close();
      final independentRaw = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200);
      final result = await fixture.playground.run(
        JevPlaygroundMode.http,
        document,
      );
      expect(result.status, JevPlaygroundStatus.success);
      expect(result.rawResponse, independentRaw);
      expect(result.request, jsonDecode(document));
      expect(result.httpStatus, 200);
      expect(result.mode, JevPlaygroundMode.http);
      expect(result.timeout, const Duration(seconds: 30));
      expect(result.elapsed, greaterThan(Duration.zero));
      expect(result.output, jsonDecode(independentRaw));
      final file = File('${fixture.runtime.root.path}/export.json');
      await fixture.playground.exportTo(
        file,
        document: jsonEncode({
          ...jsonDecode(document) as Map,
          'state': 'edited after run',
        }),
        result: result,
      );
      final saved = jsonDecode(await file.readAsString()) as Map;
      expect(saved['request'], jsonDecode(document));
      expect(saved['result']['raw_response'], independentRaw);
      expect(saved['result']['output'], result.output);
      expect(saved['result']['channel'], 'http');
      await expectLater(
        fixture.playground.exportTo(file, document: document, result: result),
        throwsA(isA<FileSystemException>()),
      );
      expect(jsonDecode(await file.readAsString()), saved);
    },
  );
  test('client deadline ends a real public HTTP request distinctly from cancellation', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final arrived = Completer<void>();
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    final pending = fixture.playground.run(
      JevPlaygroundMode.http,
      jsonEncode(playgroundDocument('quick')),
      timeout: const Duration(milliseconds: 100),
    );
    await arrived.future;
    final result = await pending.timeout(const Duration(seconds: 2));
    expect(result.status, JevPlaygroundStatus.timedOut);
    expect(result.output, isNull);
    expect(result.debug, isNull);
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

        final name = 'hard';
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
        );
        expect(first.status, JevPlaygroundStatus.success);
        final token = DecisionCancellation();
        final pending = fixture.playground.run(
          mode,
          jsonEncode(playgroundDocument(name, debug: true, state: 'cancelled')),

          cancellation: token,
        );
        await arrived.future.timeout(const Duration(seconds: 5));
        var unrelatedFinished = false;
        final unrelated = fixture.playground
            .run(
              mode,
              jsonEncode(
                playgroundDocument('quick', debug: true, state: 'unrelated'),
              ),
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

        expect(cancelled.output, isNull);
        expect(cancelled.debug, isNull);
        expect(cancelled.message, contains('未收到业务结果'));

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

  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode header-looking API identities survive discovery and remain callable with faithful debug',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        await saveHeaderNamedJevModels(fixture);
        fixture.runtime.io.respond = (body, raw) async => jsonEncode({
          ...jsonDecode(raw) as Map,
          'diagnostic': {'API_KEY': 'identity-unrelated-token'},
          'echo': 'identity-unrelated-token',
        });

        final discovery = await fixture.playground.discover(mode);
        final ids = (discovery['data'] as List)
            .map((row) => row['id'] as String)
            .toList();
        final names = [...headerNamedNativeModels, ...headerNamedCouncilModels];
        expect(ids, containsAll(names));
        for (final name in ids.where(names.contains)) {
          final document = headerNamedJevDocument(name);
          final result = await fixture.playground.run(
            mode,
            jsonEncode(document),
          );
          expect(result.status, JevPlaygroundStatus.success);
          expect(result.output!['model'], name);
          expect(result.output!['answers'], headerNamedJevAnswers);
          expect((result.debug!['input'] as Map)['state'], document['state']);
          expect(
            (result.debug!['input'] as Map)['questions'],
            document['questions'],
          );
          expect(result.debug!['converted_result'], result.output);
          final ios = result.debug!['source'] == 'council'
              ? result.debug!['seats'] as List
              : [result.debug!['native']];
          for (final io in ios) {
            final record = io as Map;
            expect(record['request']['state'], document['state']);
            expect(record['request']['questions'], document['questions']);
            expect(
              jsonDecode(record['request_body'] as String)['questions'],
              document['questions'],
            );
            expect(
              jsonDecode(record['raw_response'] as String)['answers'],
              headerNamedJevAnswers,
            );
            expect(jsonDecode(record['raw_response'] as String)['diagnostic'], {
              'API_KEY': '[redacted]',
            });
          }

          expect((result.debug!['configuration'] as Map)['name'], name);

          expect(
            jsonEncode(result.debug),
            isNot(contains('identity-unrelated-token')),
          );
          expect(
            jsonEncode(result.output),
            isNot(contains('identity-unrelated-token')),
          );
        }
      },
    );
  }

  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode unknown nested response shapes cannot establish JEV task immunity',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        fixture.runtime.io.respond = (body, raw) async =>
            jsonEncode(nestedCredentialJevResponse(raw));

        for (final name in ['quick', 'hard', 'native-kev']) {
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            final result = await fixture.playground.run(
              mode,
              jsonEncode(document),
            );
            expect(result.status, JevPlaygroundStatus.success);
            expect(result.output!['answers'], credentialNamedJevAnswers);
            final responses = <Map>[];

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

        for (final name in ['quick', 'hard', 'native-kev']) {
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            final result = await fixture.playground.run(
              mode,
              jsonEncode(document),
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

  for (final mode in JevPlaygroundMode.values) {
    test(
      '$mode legal credential-looking JEV IDs and JSON descriptions survive native and real HTTP/MCP default and debug',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);

        for (final name in ['quick', 'hard', 'native-kev']) {
          for (final debug in [false, true]) {
            final document = credentialNamedJevDocument(name, debug: debug);
            final result = await fixture.playground.run(
              mode,
              jsonEncode(document),
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
              final publicRaw = jsonDecode(result.rawResponse!) as Map;
              expect(publicRaw['debug']['input']['state'], document['state']);
              expect(
                publicRaw['debug']['input']['questions'],
                document['questions'],
              );

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

/// External file I/O boundary only; the public exporter remains production.
class _FailingExportFile implements File {
  bool exclusiveCreated = false;
  bool writeAttempted = false;
  bool cleanupAttempted = false;
  @override
  String get path => '/controlled-export/export.json';
  @override
  bool get isAbsolute => true;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    exclusiveCreated = exclusive;
    return this;
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    writeAttempted = true;
    throw const FileSystemException('primary write failed');
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    cleanupAttempted = true;
    throw const FileSystemException('secondary cleanup failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
