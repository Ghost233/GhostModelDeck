import 'dart:convert';

import 'package:ghost_model_deck/decision_protocol.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'fixtures/council_runtime.dart';
import 'jev_protocol_test.dart' show post;

void main() {
  test(
    'HTTP and MCP preserve complex native JSON for every named source',
    () async {
      final harness = await JsonProtocolRuntime.create();
      final runtime = harness.runtime;
      final http = harness.http;
      final client = harness.client;
      runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': {
          'q/选择': {
            'type': 'choice',
            'choice': 'z',
            'probabilities': {'z': 0.75, 'a': 0.25},
            'confidence': 0.5,
          },
          'q-score': {
            'type': 'score',
            'score': 0.75,
            'legend': {
              '1': ['High', true, null],
              '0': {
                'meta': {'a': 1, 'b': 2},
                'label': 'Low',
              },
            },
            'probabilities': {'1': 0.75, '0': 0.25},
            'confidence': 0.5,
          },
          'q-noul-omit': {'type': 'noul', 'noul': 0.8},
          'q-noul-values': {'type': 'noul', 'noul': 0.2},
        },
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      for (final name in ['quick', 'hard', 'native-kev']) {
        for (final debug in [false, true]) {
          final args = complexInput(name)..['debug'] = debug;
          runtime.io.requests.clear();
          final wire = await post(http.baseUrl!.resolve('/v1/systemone'), args);
          final rpc = await client.callTool(
            CallToolRequest(name: 'decide_jev_batch', arguments: args),
          );
          expect(wire.$1, 200, reason: '$name HTTP: ${wire.$2}');
          expect(rpc.isError, isNot(true));
          expect(
            {...rpc.structuredContent!}..remove('debug'),
            {...wire.$2 as Map}..remove('debug'),
          );
          expect(
            jsonDecode((rpc.content.single as TextContent).text),
            rpc.structuredContent,
          );
          expect(wire.$2['model'], name);
          expect(wire.$2['usage'], {
            'input_tokens': name == 'hard' ? 26 : 13,
            'output_tokens': 0,
          });
          expect(wire.$2['answers']['q-score']['legend'], {
            '0': {
              'label': 'Low',
              'meta': {'b': 2, 'a': 1},
            },
            '1': ['High', true, null],
          });
          expect(wire.$2['answers']['q-score']['confidence'], 0.5);
          expect(runtime.io.requests, hasLength(name == 'hard' ? 4 : 2));
          for (final sent in runtime.io.requests) {
            expect(
              runtime.engine.state.instances.map((i) => i.id),
              contains(sent['model']),
            );
            final expected = {...args}..remove('debug');
            expect({...sent, 'model': name}, expected);
          }
          expect((wire.$2 as Map).containsKey('debug'), debug);
          expect(
            runtime.engine.state.instances.every((i) => i.activeRequests == 0),
            true,
          );
          expect(runtime.io.killedChildren, 0);
        }
      }
    },
  );
  test(
    'a single JSON choice keeps confidence one through both protocols',
    () async {
      final h = await JsonProtocolRuntime.create();
      h.runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': {
          'pick': {
            'type': 'choice',
            'choice': 'only',
            'probabilities': {'only': 1.0},
            'confidence': 1.0,
          },
        },
        'usage': {'input_tokens': 7, 'output_tokens': 0},
      });
      await h.verify(
        {
          'state': false,
          'questions': {
            'pick': {
              'type': 'choice',
              'instructions': {},
              'criteria': {
                'only': {
                  'data': [null],
                },
              },
            },
          },
        },
        {
          'pick': {
            'type': 'choice',
            'choice': 'only',
            'probabilities': {'only': 1.0},
            'confidence': 1.0,
          },
        },
        tokens: 7,
      );
    },
  );

  test(
    'all legal JSON scalars and descriptions reach every HTTP and MCP source',
    () async {
      final h = await JsonProtocolRuntime.create();
      const choice = {
        'pick': {
          'type': 'choice',
          'choice': 'z',
          'probabilities': {'a': 0.25, 'z': 0.75},
          'confidence': 0.5,
        },
      };
      h.runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': choice,
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      final values = <Object>[
        '文本',
        0,
        -2,
        1.25,
        false,
        true,
        [
          '段',
          null,
          {'k': 1},
        ],
        {
          'payload': [1, null],
        },
        '',
        [],
        {},
      ];
      for (final value in values) {
        for (final field in ['state', 'instructions']) {
          await h.verify({
            'state': field == 'state' ? value : 'context',
            'questions': {
              'pick': {
                'type': 'choice',
                'instructions': field == 'instructions' ? value : 'Choose',
                'criteria': {'a': 'A', 'z': 'Z'},
              },
            },
          }, choice);
        }
      }
      for (final description in <Object?>[
        'A',
        0,
        1.25,
        false,
        ['A', null],
        {'label': 'A'},
        null,
        '',
        [],
        {},
      ]) {
        await h.verify({
          'state': 'context',
          'questions': {
            'pick': {
              'type': 'choice',
              'instructions': 'Choose',
              'criteria': {'a': description, 'z': 'Z'},
            },
          },
        }, choice);
        final score = {
          'rank': {
            'type': 'score',
            'score': 0.75,
            'legend': {'0': description, '1': 'High'},
            'probabilities': {'0': 0.25, '1': 0.75},
            'confidence': 0.5,
          },
        };
        h.runtime.io.respond = (request, _) async => jsonEncode({
          'model': request['model'],
          'answers': score,
          'usage': {'input_tokens': 13, 'output_tokens': 0},
        });
        await h.verify({
          'state': 'context',
          'questions': {
            'rank': {
              'type': 'score',
              'instructions': 'Rank',
              'criteria': [description, 'High'],
            },
          },
        }, score);
        h.runtime.io.respond = (request, _) async => jsonEncode({
          'model': request['model'],
          'answers': choice,
          'usage': {'input_tokens': 13, 'output_tokens': 0},
        });
      }
    },
  );

  test(
    'noul criteria presence and supported no-image extensions stay exact',
    () async {
      final h = await JsonProtocolRuntime.create();
      const answer = {
        'valid': {'type': 'noul', 'noul': 0.8},
      };
      h.runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': answer,
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      for (final criteria in <Map<String, Object?>>[
        {},
        {'criteria': null},
        {'criteria': {}},
        {
          'criteria': {'false': null},
        },
        {
          'criteria': {
            'true': {'label': '是'},
          },
        },
        {
          'criteria': {
            'false': false,
            'true': ['是', 1],
            'note': {'keep': true},
          },
        },
      ]) {
        for (final extension in <Map<String, Object?>>[
          {},
          {'images': null},
          {'images': []},
        ]) {
          await h.verify({
            'state': {
              'payload': {
                'other': [null, false],
              },
            },
            ...extension,
            'questions': {
              'valid': {
                'type': 'noul',
                'instructions': {'task': []},
                ...criteria,
              },
            },
          }, answer);
        }
      }
      const levels = [
        'L0',
        0,
        false,
        null,
        {'x': 1},
        ['L5'],
        true,
        7,
        8,
        'L9',
      ];
      const score = {
        'rank': {
          'type': 'score',
          'score': 1.0,
          'legend': {
            '0': 'L0',
            '1': 0,
            '2': false,
            '3': null,
            '4': {'x': 1},
            '5': ['L5'],
            '6': true,
            '7': 7,
            '8': 8,
            '9': 'L9',
          },
          'probabilities': {
            '0': 0.0,
            '1': 1.0,
            '2': 0.0,
            '3': 0.0,
            '4': 0.0,
            '5': 0.0,
            '6': 0.0,
            '7': 0.0,
            '8': 0.0,
            '9': 0.0,
          },
          'confidence': 1.0,
        },
      };
      h.runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': score,
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      await h.verify({
        'state': 'context',
        'questions': {
          'rank': {'type': 'score', 'instructions': 'Rank', 'criteria': levels},
        },
      }, score);
    },
  );

  test(
    'MCP single retains structured and original text convenience inputs',
    () async {
      final h = await JsonProtocolRuntime.create();
      const answers = {
        'council_choice': {
          'type': 'choice',
          'choice': 'z',
          'probabilities': {'a': 0.25, 'z': 0.75},
          'confidence': 0.5,
        },
      };
      h.runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': answers,
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      for (final text in [
        false,
        {'label': 'A'},
        'A',
        null,
      ]) {
        for (final name in ['quick', 'hard', 'native-kev']) {
          final args = {
            'model': name,
            'state': {
              'k': [null],
            },
            'instructions': ['choose'],
            'options': [
              {'id': 'a', 'text': text},
              {'id': 'z', 'text': 'Z'},
            ],
          };
          h.runtime.io.requests.clear();
          final rpc = await h.client.callTool(
            CallToolRequest(name: 'decide_jev', arguments: args),
          );
          final batch = {
            'model': name,
            'state': {
              'k': [null],
            },
            'questions': {
              'council_choice': {
                'type': 'choice',
                'instructions': ['choose'],
                'criteria': {'a': text, 'z': 'Z'},
              },
            },
          };
          final wire = await post(
            h.http.baseUrl!.resolve('/v1/systemone'),
            batch,
          );
          expect(wire.$1, 200);
          expect(rpc.isError, isNot(true));
          expect(rpc.structuredContent, wire.$2);
          expect(jsonDecode((rpc.content.single as TextContent).text), wire.$2);
          for (final sent in h.runtime.io.requests) {
            expect({...sent, 'model': name}, batch);
          }
        }
      }
      final rpc = await h.client.callTool(
        CallToolRequest(
          name: 'decide_jev',
          arguments: {
            'model': 'quick',
            'state': 'original',
            'options': [
              {'id': 'a', 'text': 'A'},
              {'id': 'z', 'text': 'Z'},
            ],
          },
        ),
      );
      expect(rpc.isError, isNot(true));
      expect(rpc.structuredContent!['answers'], answers);
      expect(
        h
            .runtime
            .io
            .requests
            .last['questions']['council_choice']['instructions'],
        '根据上下文，从候选项中选择最合适的一项。',
      );
      for (final extra in [
        {'debug': null},
        {'instructions': null},
        {
          'options': [
            {'id': 'a'},
          ],
        },
        {
          'options': [
            {'id': 'a', 'text': 'A', 'unknown': true},
          ],
        },
      ]) {
        final failed = await h.client.callTool(
          CallToolRequest(
            name: 'decide_jev',
            arguments: {
              'model': 'native-kev',
              'state': 'context',
              'options': [
                {'id': 'a', 'text': 'A'},
              ],
              ...extra,
            },
          ),
        );
        expect(failed.isError, true);
        expect(failed.structuredContent!['error']['code'], 'invalid_input');
      }
      final tools = (await h.client.listTools()).tools;
      final schema = tools
          .singleWhere((t) => t.name == 'decide_jev_batch')
          .inputSchema
          .toJson();
      expect(schema['properties']['state']['type'], [
        'string',
        'number',
        'boolean',
        'object',
        'array',
      ]);
      expect(schema['properties']['images'], {
        'type': ['array', 'null'],
        'maxItems': 0,
      });
      expect(
        schema['properties']['questions']['additionalProperties']['required'],
        ['type', 'instructions'],
      );
      expect(
        schema['properties']['questions']['additionalProperties']['oneOf'],
        hasLength(3),
      );
    },
  );

  test(
    'invalid native inputs give HTTP and MCP errors without model calls',
    () async {
      final h = await JsonProtocolRuntime.create();
      final badQuestions = <Object?>[
        null,
        [],
        {},
        {'pick': []},
        {
          'pick': {
            'type': 'unknown',
            'instructions': 'I',
            'criteria': {'a': 'A'},
          },
        },
        {
          'pick': {
            'type': 'choice',
            'criteria': {'a': 'A'},
          },
        },
        {
          'pick': {
            'type': 'choice',
            'instructions': null,
            'criteria': {'a': 'A'},
          },
        },
        {
          'pick': {'type': 'choice', 'instructions': 'I', 'criteria': {}},
        },
        {
          'pick': {
            'type': 'choice',
            'instructions': 'I',
            'criteria': ['A'],
          },
        },
        {
          'rank': {
            'type': 'score',
            'instructions': 'I',
            'criteria': ['A'],
          },
        },
        {
          'rank': {
            'type': 'score',
            'instructions': 'I',
            'criteria': List.filled(11, 'A'),
          },
        },
        {
          'valid': {'type': 'noul', 'instructions': 'I', 'criteria': []},
        },
        {
          'valid': {'type': 'noul', 'instructions': 'I', 'criteria': false},
        },
        {
          'pick': {
            'type': 'choice',
            'instructions': 'I',
            'criteria': {'a': 'A'},
            'temperature': 1,
          },
        },
        {
          ' ': {'type': 'noul', 'instructions': 'I'},
        },
        {
          for (var i = 0; i < 33; i++)
            '$i': {'type': 'noul', 'instructions': 'I'},
        },
        {
          'pick': {
            'type': 'choice',
            'instructions': 'I',
            'criteria': {for (var i = 0; i < 256; i++) '$i': 'A'},
          },
        },
      ];
      final inputs = <Map<String, dynamic>>[
        for (final questions in badQuestions)
          {'state': 'context', 'questions': questions},
        {
          'questions': {
            'valid': {'type': 'noul', 'instructions': 'I'},
          },
        },
        {
          'state': null,
          'questions': {
            'valid': {'type': 'noul', 'instructions': 'I'},
          },
        },
        for (final extra in [
          {'seed': 7},
          {
            'images': ['data:image/png;base64,AA=='],
          },
          {'images': {}},
          {'debug': 'yes'},
          {'stream': true},
        ])
          {
            'state': 'context',
            'questions': {
              'valid': {'type': 'noul', 'instructions': 'I'},
            },
            ...extra,
          },
      ];
      for (final name in ['hard', 'native-kev']) {
        for (final input in inputs) {
          h.runtime.io.requests.clear();
          final args = {'model': name, ...input};
          final wire = await post(
            h.http.baseUrl!.resolve('/v1/systemone'),
            args,
          );
          final rpc = await h.client.callTool(
            CallToolRequest(name: 'decide_jev_batch', arguments: args),
          );
          expect(wire.$1, 400, reason: jsonEncode(args));
          expect(rpc.isError, true);
          expect(rpc.structuredContent, wire.$2);
          expect(wire.$2['error']['code'], 'invalid_input');
          expect((wire.$2 as Map).containsKey('answers'), false);
          expect(h.runtime.io.requests, isEmpty);
        }
      }
      expect(h.runtime.io.killedChildren, 0);
      expect(
        h.runtime.engine.state.instances.every((i) => i.activeRequests == 0),
        true,
      );
    },
  );

  test(
    'request snapshots stay deeply immutable while identities are checked',
    () async {
      final h = await JsonProtocolRuntime.create();
      h.runtime.io.respond = (request, _) async => jsonEncode({
        'model': request['model'],
        'answers': {
          'pick': {
            'type': 'choice',
            'choice': 'z',
            'probabilities': {'a': 0.25, 'z': 0.75},
            'confidence': 0.5,
          },
        },
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      for (final name in ['quick', 'hard', 'native-kev']) {
        final raw = <String, dynamic>{
          'model': name,
          'state': {
            'values': [true, null],
          },
          'images': [],
          'questions': {
            'pick': {
              'type': 'choice',
              'instructions': [
                'choose',
                {'strict': true},
              ],
              'criteria': {
                'a': {
                  'labels': ['A', null],
                },
                'z': false,
              },
            },
          },
        };
        final parsed = JevModelRequest.parse(raw);
        final request = parsed.request;
        h.runtime.io.requests.clear();
        h.runtime.io.holdIdentity(expected: name == 'hard' ? 2 : 1);
        final pending = h.council.models.decide(name, request);
        await h.runtime.io.identityArrived!.future.timeout(
          const Duration(seconds: 2),
        );
        raw['state']['values'][0] = false;
        raw['questions']['pick']['instructions'][1]['strict'] = false;
        raw['questions']['pick']['criteria']['a']['labels'][0] = 'changed';
        raw['images'].add('not-an-image');
        expect(
          () => (request.state as Map)['values'][0] = false,
          throwsUnsupportedError,
        );
        expect(
          () =>
              (request.questions['pick']!.instructions as List).add('changed'),
          throwsUnsupportedError,
        );
        expect(
          () =>
              ((request.questions['pick'] as ChoiceQuestion).options['a']
                      as Map)['labels'][0] =
                  'changed',
          throwsUnsupportedError,
        );
        expect(
          () => (request.toSystemone()['images'] as List).add('changed'),
          throwsUnsupportedError,
        );
        request.toSystemone()['questions'] = {};
        h.runtime.io.identityRelease!.complete();
        final result = await pending;
        expect(result['model'], name);
        expect(h.runtime.io.requests, hasLength(name == 'hard' ? 2 : 1));
        for (final sent in h.runtime.io.requests) {
          expect(sent['state'], {
            'values': [true, null],
          });
          expect(sent['images'], []);
          expect(sent['questions'], {
            'pick': {
              'type': 'choice',
              'instructions': [
                'choose',
                {'strict': true},
              ],
              'criteria': {
                'a': {
                  'labels': ['A', null],
                },
                'z': false,
              },
            },
          });
        }
        expect(
          h.runtime.engine.state.instances.every((i) => i.activeRequests == 0),
          true,
        );
      }
      final mutableState = {
        'values': <Object?>[true, null],
      };
      final mutableLevels = <Object?>[
        {
          'label': ['Low', null],
        },
        ['High', true],
      ];
      final mutableInstructions = <Object?>[
        'rank',
        {'strict': true},
      ];
      final mutableCriteria = {
        'true': <Object?>['Yes', null],
        'note': {'keep': true},
      };
      final question = ScoreQuestion(
        instructions: mutableInstructions,
        levels: mutableLevels,
      );
      final request = DecisionBatchRequest(
        state: mutableState,
        questions: {
          'rank': question,
          'valid': NoulQuestion.fromCriteria(
            instructions: false,
            criteria: mutableCriteria,
            hasCriteria: true,
          ),
        },
      );
      final selected = h.runtime.engine.state.instances.last;
      h.runtime.io.respond = (sent, _) async => jsonEncode({
        'model': sent['model'],
        'answers': {
          'rank': {
            'type': 'score',
            'score': 0.75,
            'legend': {
              '0': {
                'label': ['Low', null],
              },
              '1': ['High', true],
            },
            'probabilities': {'0': 0.25, '1': 0.75},
            'confidence': 0.37,
          },
          'valid': {'type': 'noul', 'noul': 0.8},
        },
        'usage': {'input_tokens': 13, 'output_tokens': 0},
      });
      h.runtime.io.holdIdentity(expected: 1);
      final pending = h.runtime.engine.decideBatch(selected.id, request);
      await h.runtime.io.identityArrived!.future.timeout(
        const Duration(seconds: 2),
      );
      mutableState['values']![0] = false;
      (mutableLevels[0] as Map)['label'][0] = 'changed';
      (mutableInstructions[1] as Map)['strict'] = false;
      (mutableCriteria['true'] as List)[0] = 'changed';
      (mutableCriteria['note'] as Map)['keep'] = false;
      h.runtime.io.identityRelease!.complete();
      final result = await pending;
      expect(result.answers['rank']!.toJson()['legend'], {
        '0': {
          'label': ['Low', null],
        },
        '1': ['High', true],
      });
      expect(result.answers['rank']!.toJson()['confidence'], 0.37);
      expect(
        () =>
            ((result.answers['rank'] as ScoreAnswer).legend['0']
                    as Map)['label'][0] =
                'changed',
        throwsUnsupportedError,
      );
      expect(h.runtime.io.requests.last['questions']['valid']['criteria'], {
        'true': ['Yes', null],
        'note': {'keep': true},
      });
      expect(
        h.runtime.engine.state.instances.every((i) => i.activeRequests == 0),
        true,
      );
      expect(h.runtime.io.killedChildren, 0);
    },
  );

  test(
    'public Dart input rejects non-JSON values and the existing byte limit',
    () async {
      final h = await JsonProtocolRuntime.create();
      final cycle = <Object?>[];
      cycle.add(cycle);
      for (final value in <Object>[
        DateTime(2026),
        double.nan,
        double.infinity,
        {1: 'bad key'},
        cycle,
        Object(),
      ]) {
        expect(
          () => JevModelRequest.parse({
            'model': 'native-kev',
            'state': {'nested': value},
            'questions': {
              'valid': {'type': 'noul', 'instructions': true},
            },
          }),
          throwsA(isA<DecisionProtocolException>()),
        );
      }
      expect(
        () => JevModelRequest.parse({
          'model': 'native-kev',
          'state': 'x' * decisionMaxRequestBytes,
          'questions': {
            'valid': {'type': 'noul', 'instructions': true},
          },
        }),
        throwsA(isA<DecisionProtocolException>()),
      );
      expect(h.runtime.io.requests, isEmpty);
      expect(h.runtime.io.killedChildren, 0);
    },
  );

  test(
    'structured score legend preserves array order and scalar meaning',
    () async {
      final h = await JsonProtocolRuntime.create();
      for (final legend in <Object?>[
        {
          '0': ['second', 'first'],
          '1': true,
        },
        {
          '0': ['first', 'second'],
          '1': 'true',
        },
        {
          '0': ['first', 'second'],
          '1': null,
        },
      ]) {
        h.runtime.io.respond = (request, _) async => jsonEncode({
          'model': request['model'],
          'answers': {
            'rank': {
              'type': 'score',
              'score': 0.75,
              'legend': legend,
              'probabilities': {'0': 0.25, '1': 0.75},
              'confidence': 0.5,
            },
          },
          'usage': {'input_tokens': 13, 'output_tokens': 0},
        });
        for (final name in ['hard', 'native-kev']) {
          final args = {
            'model': name,
            'state': 'context',
            'questions': {
              'rank': {
                'type': 'score',
                'instructions': 'Rank',
                'criteria': [
                  ['first', 'second'],
                  true,
                ],
              },
            },
          };
          final wire = await post(
            h.http.baseUrl!.resolve('/v1/systemone'),
            args,
          );
          final rpc = await h.client.callTool(
            CallToolRequest(name: 'decide_jev_batch', arguments: args),
          );
          expect(wire.$1, 502);
          expect(rpc.isError, true);
          expect(rpc.structuredContent, wire.$2);
          expect((wire.$2 as Map).containsKey('answers'), false);
        }
      }
    },
  );
}

Map<String, dynamic> complexInput(String model) => {
  'model': model,
  'state': {
    'case': 'c0',
    'items': [
      {
        'name': '甲',
        'flags': [true, null, 0],
      },
    ],
    'debug': {'note': 'task content'},
  },
  'images': [],
  'questions': {
    'q/选择': {
      'type': 'choice',
      'instructions': [
        'route',
        {'strict': true},
      ],
      'criteria': {
        'a': {
          'summary': 'A',
          'tags': [null, 1],
        },
        'z': false,
      },
    },
    'q-score': {
      'type': 'score',
      'instructions': {
        'task': 'rank',
        'bounds': [0, 1],
      },
      'criteria': [
        {
          'label': 'Low',
          'meta': {'b': 2, 'a': 1},
        },
        ['High', true, null],
      ],
    },
    'q-noul-omit': {'type': 'noul', 'instructions': true},
    'q-noul-values': {
      'type': 'noul',
      'instructions': 0,
      'criteria': {
        'false': ['No', null],
        'true': {'reason': 'Yes', 'code': 1},
        'note': {'keep': true},
      },
    },
  },
};

class JsonProtocolRuntime {
  JsonProtocolRuntime(
    this.runtime,
    this.council,
    this.http,
    this.mcp,
    this.client,
  );
  final CouncilRuntime runtime;
  final CouncilController council;
  final PublicGatewayServer http;
  final CouncilMcpServer mcp;
  final McpClient client;
  static Future<JsonProtocolRuntime> create() async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    for (final name in ['quick', 'hard']) {
      await council.models.save(
        JevModelDefinition.council(
          name: name,
          seats: name == 'quick' ? [bindings.first] : bindings,
          timeout: const Duration(seconds: 3),
        ),
      );
    }
    await council.models.save(
      JevModelDefinition.native(name: 'native-kev', binding: bindings.last),
    );
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: [runtime.engine],
    );
    addTearDown(routes.close);
    final http = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    addTearDown(http.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await http.start();
    await mcp.start();
    final client = McpClient(
      const Implementation(name: 'json-input-test', version: '1'),
    );
    addTearDown(client.close);
    await client.connect(StreamableHttpClientTransport(mcp.endpoint!));
    runtime.io.recordChoiceConsultations = true;
    return JsonProtocolRuntime(runtime, council, http, mcp, client);
  }

  Future<void> verify(
    Map<String, dynamic> input,
    Map<String, dynamic> answers, {
    int tokens = 13,
  }) async {
    for (final name in ['quick', 'hard', 'native-kev']) {
      final args = {'model': name, ...input};
      runtime.io.requests.clear();
      final wire = await post(http.baseUrl!.resolve('/v1/systemone'), args);
      final rpc = await client.callTool(
        CallToolRequest(name: 'decide_jev_batch', arguments: args),
      );
      expect(wire.$1, 200, reason: '$name ${jsonEncode(args)}: ${wire.$2}');
      expect(rpc.isError, isNot(true));
      expect(rpc.structuredContent, wire.$2);
      expect(jsonDecode((rpc.content.single as TextContent).text), wire.$2);
      expect(wire.$2, {
        'model': name,
        'answers': answers,
        'usage': {
          'input_tokens': name == 'hard' ? 2 * tokens : tokens,
          'output_tokens': 0,
        },
      });
      expect(runtime.io.requests, hasLength(name == 'hard' ? 4 : 2));
      final definition = council.models.definitions.singleWhere(
        (m) => m.name == name,
      );
      final expectedIds = definition.bindings
          .map(
            (b) => runtime.engine.state.instances
                .singleWhere((i) => i.asset.id == b.artifactId)
                .id,
          )
          .toSet();
      expect(runtime.io.requests.map((r) => r['model']).toSet(), expectedIds);
      for (final sent in runtime.io.requests) {
        expect({...sent, 'model': name}, args);
      }
      expect(
        runtime.engine.state.instances.every((i) => i.activeRequests == 0),
        true,
      );
      expect(mcp.state.activeRequests, 0);
      expect(runtime.io.killedChildren, 0);
    }
  }
}
