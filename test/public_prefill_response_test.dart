import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/public_prefill_request.dart';
import 'package:ghost_model_deck/public_prefill_response.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

void main() {
  test('zero-output response needs matching native evidence and hides native alias', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var consume = false;
      String? questionId;
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'operation_id': 'op',
            'service_instance': 'service',
            'state': 'completed',
            'terminal': true,
            'lease_released': true,
            'children': [
              {
                'question_id': questionId,
                'native_request_id': 42,
                'runtime_generation': 7,
                'state': consume ? 'stop' : 'length',
                'lease_released': true,
                'prompt_tokens': 12,
                'completion_tokens': consume && questionId == null ? 2 : 0,
                'matched_prompt_tokens': 4,
              },
            ],
          }),
        );
        await request.response.close();
      });
      final native = SplashOperationClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final snapshot = await native.query(
        operationId: 'op',
        token: 'a' * 64,
        expected: const SplashOperationIdentity('service', 7),
      );
      final input = PublicPrefillRequest.parse(SplashOperationPath.chat, {
        'model': 'public-model',
        'messages': [
          {'role': 'user', 'content': '材料'},
        ],
        'max_tokens': 0,
        'cache_salt': 'private-salt',
      });
      String nativeBody({int completion = 0, String model = 'native-alias'}) =>
          jsonEncode({
            'model': model,
            'object': 'chat.completion',
            'choices': [
              {
                'index': 0,
                'finish_reason': 'length',
                'message': {'role': 'assistant', 'content': ''},
              },
            ],
            'usage': {
              'prompt_tokens': 12,
              'completion_tokens': completion,
              'total_tokens': 12 + completion,
            },
          });
      final result = PublicPrefillResponse.prefill(
        request: input,
        nativeModel: 'native-alias',
        nativeBody: nativeBody(),
        evidence: snapshot,
        generation: 'public-generation',
      );
      expect(result['model'], 'public-model');
      expect(result['choices'], isEmpty);
      expect((result['prefill'] as Map)['generated_tokens'], 0);
      expect(
        ((result['prefill'] as Map)['children'] as List)
            .single['matched_prompt_tokens'],
        4,
      );
      expect(result.toString(), isNot(contains('native-alias')));
      expect(result.toString(), isNot(contains('private-salt')));
      expect(
        () => PublicPrefillResponse.prefill(
          request: input,
          nativeModel: 'native-alias',
          nativeBody: nativeBody(completion: 1),
          evidence: snapshot,
          generation: 'public-generation',
        ),
        throwsFormatException,
      );
      consume = true;
      final consumeEvidence = await native.query(
        operationId: 'op',
        token: 'a' * 64,
        expected: const SplashOperationIdentity('service', 7),
      );
      final finalRequest = PublicPrefillRequest.parse(
        SplashOperationPath.chat,
        {...input.body, 'max_tokens': 32},
      );
      String finalBody(String text) => jsonEncode({
        'model': 'native-alias',
        'object': 'chat.completion',
        'choices': [
          {
            'index': 0,
            'finish_reason': 'stop',
            'message': {'role': 'assistant', 'content': text},
          },
        ],
        'usage': {
          'prompt_tokens': 12,
          'completion_tokens': 2,
          'total_tokens': 14,
        },
      });
      final answer = PublicPrefillResponse.consume(
        request: finalRequest,
        nativeModel: 'native-alias',
        nativeBody: finalBody('回答'),
        evidence: consumeEvidence,
        generation: 'public-generation',
      );
      expect(answer['model'], 'public-model');
      expect((answer['choices'] as List).single['message']['content'], '回答');
      expect(
        ((answer['cache'] as Map)['children'] as List)
            .single['matched_prompt_tokens'],
        4,
      );
      expect((answer['cache'] as Map)['state'], 'completed');
      expect(answer.toString(), isNot(contains('native-alias')));
      expect(
        (answer['cache'] as Map)['cache_salt_sha256'],
        sha256.convert(utf8.encode('private-salt')).toString(),
      );
      expect(
        () => PublicPrefillResponse.consume(
          request: finalRequest,
          nativeModel: 'native-alias',
          nativeBody: finalBody(''),
          evidence: consumeEvidence,
          generation: 'public-generation',
        ),
        throwsFormatException,
      );
      expect(
        () => PublicPrefillResponse.prefill(
          request: input,
          nativeModel: 'native-alias',
          nativeBody: nativeBody(model: 'other'),
          evidence: snapshot,
          generation: 'public-generation',
        ),
        throwsFormatException,
      );
      final decision = PublicPrefillRequest.parse(
        SplashOperationPath.systemone,
        {
          'model': 'public-decision',
          'state': {'text': '材料'},
          'prefill_only': true,
          'cache_salt': 'decision-salt',
        },
      );
      final decisionFinal = PublicPrefillRequest.parse(
        SplashOperationPath.systemone,
        {
          ...decision.body,
          'prefill_only': false,
          'questions': {
            'q': {
              'type': 'choice',
              'instructions': '选择',
              'criteria': {'a': 'A', 'b': 'B'},
            },
          },
        },
      );
      final decisionRaw = jsonEncode({
        'model': 'native-decision',
        'usage': {'input_tokens': 12, 'output_tokens': 0},
        'answers': {
          'q': {
            'type': 'choice',
            'choice': 'a',
            'confidence': 0.6,
            'probabilities': {'a': 0.6, 'b': 0.4},
          },
        },
      });
      questionId = 'other';
      final wrongEvidence = await native.query(
        operationId: 'op',
        token: 'a' * 64,
        expected: const SplashOperationIdentity('service', 7),
      );
      expect(
        () => PublicPrefillResponse.consume(
          request: decisionFinal,
          nativeModel: 'native-decision',
          nativeBody: decisionRaw,
          evidence: wrongEvidence,
          generation: 'public-generation',
        ),
        throwsFormatException,
      );
      questionId = 'q';
      final decisionEvidence = await native.query(
        operationId: 'op',
        token: 'a' * 64,
        expected: const SplashOperationIdentity('service', 7),
      );
      final decisionAnswer = PublicPrefillResponse.consume(
        request: decisionFinal,
        nativeModel: 'native-decision',
        nativeBody: decisionRaw,
        evidence: decisionEvidence,
        generation: 'public-generation',
      );
      expect(decisionAnswer['model'], 'public-decision');
      expect((decisionAnswer['answers'] as Map)['q']['choice'], 'a');
      expect(
        ((decisionAnswer['cache'] as Map)['children'] as List)
            .single['question_id'],
        'q',
      );
      String decisionBody({
        int output = 0,
        Map<String, Object?> answers = const {},
      }) => jsonEncode({
        'model': 'native-decision',
        'prefill_only': true,
        'answers': answers,
        'usage': {'input_tokens': 12, 'output_tokens': output},
      });
      final resultDecision = PublicPrefillResponse.prefill(
        request: decision,
        nativeModel: 'native-decision',
        nativeBody: decisionBody(),
        evidence: snapshot,
        generation: 'public-generation',
      );
      expect(resultDecision['object'], 'systemone.prefill');
      expect(resultDecision['model'], 'public-decision');
      expect(resultDecision.containsKey('answers'), isFalse);
      expect(
        () => PublicPrefillResponse.prefill(
          request: decision,
          nativeModel: 'native-decision',
          nativeBody: decisionBody(answers: {'q': {}}),
          evidence: snapshot,
          generation: 'public-generation',
        ),
        throwsFormatException,
      );
    }, _NetworkBoundary());
  });
}

class _NetworkBoundary extends HttpOverrides {}
