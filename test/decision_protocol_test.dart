import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/decision_protocol.dart';

void main() {
  test(
    'typed input refuses streaming, empty IDs and invalid ordered rubrics',
    () {
      final q = ScoreQuestion(instructions: 'Rank', levels: ['Low', 'High']);
      expect(
        () =>
            DecisionBatchRequest(state: '', questions: {'q': q}, stream: true),
        throwsA(isA<DecisionProtocolException>()),
      );
      expect(
        () => DecisionBatchRequest(state: '', questions: {' ': q}),
        throwsA(isA<DecisionProtocolException>()),
      );
      for (final levels in <List<String>>[
        [],
        ['One'],
        List.filled(11, 'Level'),
      ]) {
        expect(
          () => ScoreQuestion(instructions: 'Rank', levels: levels),
          throwsA(isA<DecisionProtocolException>()),
        );
      }
    },
  );
  test('typed batch rejects malformed or mismatched answers atomically', () {
    final request = DecisionBatchRequest(
      state: '',
      questions: {
        'q': ScoreQuestion(instructions: 'Rank', levels: ['Low', 'High']),
        'n': NoulQuestion(
          instructions: 'Valid',
          falseText: 'False',
          trueText: 'True',
        ),
      },
    );
    Map<String, dynamic> body() => {
      'model': 'owned',
      'usage': {'input_tokens': 2, 'output_tokens': 0},
      'answers': {
        'q': {
          'type': 'score',
          'confidence': 0.5,
          'score': 0.75,
          'legend': {'0': 'Low', '1': 'High'},
          'probabilities': {'0': 0.25, '1': 0.75},
        },
        'n': {'type': 'noul', 'noul': 0.8},
      },
    };
    final mutations = <void Function(Map<String, dynamic>)>[
      (b) => b['model'] = 'foreign',
      (b) => b['usage']['output_tokens'] = 1,
      (b) => b['usage']['input_tokens'] = -1,
      (b) => b['answers'].remove('n'),
      (b) => b['answers']['extra'] = {'type': 'noul', 'noul': 0.8},
      (b) => b['answers']['q']['type'] = 'choice',
      (b) => b['answers']['q']['score'] = 1, // mode is NOT expectation
      (b) => b['answers']['q']['score'] = -1,
      (b) => b['answers']['q']['legend'] = {'0': 'High', '1': 'Low'},
      (b) => b['answers']['q']['probabilities'] = {'0': 0.25, '2': 0.75},
      (b) => b['answers']['q']['probabilities'] = {'0': 0.25, '1': 0.7},
      (b) => b['answers']['q']['probabilities'] = {'0': '0.25', '1': 0.75},
      (b) => b['answers']['n']['noul'] = 2,
      (b) => b['answers']['n']['noul'] = '0.8',
      (b) => b['answers']['n']['confidence'] = 0.8,
      (b) => b['answers']['n']['probabilities'] = {'true': 0.8, 'false': 0.2},
    ];
    for (final mutate in mutations) {
      final b = body();
      mutate(b);
      expect(
        () => DecisionBatchResult.parse(
          jsonEncode(b),
          request,
          expectedModel: 'owned',
        ),
        throwsA(isA<DecisionProtocolException>()),
        reason: jsonEncode(b),
      );
    }
    for (final raw in [
      '{broken',
      '{"model":"owned","usage":{"input_tokens":1,"output_tokens":0},"answers":{"q":{"type":"score","score":NaN},"n":{"type":"noul","noul":Infinity}}}',
    ]) {
      expect(
        () => DecisionBatchResult.parse(raw, request, expectedModel: 'owned'),
        throwsA(isA<DecisionProtocolException>()),
      );
    }
  });

  test('mixed typed batch preserves ordinal score and true-head scalar', () {
    final request = DecisionBatchRequest(
      state: 'context',
      questions: {
        'route': ChoiceQuestion(
          instructions: 'Route',
          options: {'a': 'A', 'b': 'B'},
        ),
        'rank': ScoreQuestion(
          instructions: 'Rank',
          levels: ['Low', 'Medium', 'High'],
        ),
        'valid': NoulQuestion(
          instructions: 'Valid',
          falseText: 'False',
          trueText: 'True',
        ),
      },
    );
    expect(request.toSystemone(model: 'owned')['questions'], {
      'route': {
        'type': 'choice',
        'instructions': 'Route',
        'criteria': {'a': 'A', 'b': 'B'},
      },
      'rank': {
        'type': 'score',
        'instructions': 'Rank',
        'criteria': ['Low', 'Medium', 'High'],
      },
      'valid': {
        'type': 'noul',
        'instructions': 'Valid',
        'criteria': {'false': 'False', 'true': 'True'},
      },
    });
    final result = DecisionBatchResult.parse(
      jsonEncode({
        'model': 'owned',
        'answers': {
          'route': {
            'type': 'choice',
            'confidence': 0.5,
            'choice': 'b',
            'probabilities': {'a': 0.25, 'b': 0.75},
          },
          'rank': {
            'type': 'score',
            'confidence': 0.5,
            'score': 1.25,
            'legend': {'0': 'Low', '1': 'Medium', '2': 'High'},
            'probabilities': {'0': 0.25, '1': 0.25, '2': 0.5},
          },
          'valid': {'type': 'noul', 'noul': 0.8},
        },
        'usage': {'input_tokens': 10, 'output_tokens': 0},
      }),
      request,
      expectedModel: 'owned',
    );
    expect((result.answers['rank']! as ScoreAnswer).score, 1.25);
    expect((result.answers['valid']! as NoulAnswer).noul, 0.8);
    expect(result.answers['valid']!.toJson(), {'type': 'noul', 'noul': 0.8});
    expect(() => result.answers.clear(), throwsUnsupportedError);
  });
}
