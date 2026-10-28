import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chat_protocol.dart';
import 'decision_protocol.dart';
import 'jev_debug.dart';
import 'jev_models.dart';
import 'prefill_operation_ledger.dart';
import 'public_prefill_request.dart';
import 'splash_operation_client.dart';

/// Only validated native completion plus release can become public prefill.
class PublicPrefillResponse {
  static Map<String, Object?> consume({
    required PublicPrefillRequest request,
    required String nativeModel,
    required String nativeBody,
    required SplashOperationSnapshot evidence,
    required String generation,
  }) {
    if (request.kind != PrefillOperationKind.consume ||
        !RegExp(r'^[A-Za-z0-9._~-]{1,128}$').hasMatch(generation) ||
        evidence.state != 'completed' ||
        !evidence.terminal ||
        !evidence.leaseReleased ||
        utf8.encode(nativeBody).length > decisionMaxResponseBytes) {
      throw const FormatException('消费请求尚无可确认的原生终态');
    }
    final cache = <String, Object?>{
      'protocol': 'gmd-prefill/1',
      'request_id': evidence.operationId,
      'runtime_generation': generation,
      'cache_salt_sha256': sha256
          .convert(utf8.encode(request.cacheSalt))
          .toString(),
      'state': 'completed',
      'terminal': true,
      'lease_released': true,
      'children': [
        for (final child in evidence.children)
          {
            'question_id': child.questionId,
            'native_request_id': ?child.nativeRequestId,
            'runtime_generation': ?child.runtimeGeneration,
            'state': child.state,
            'prompt_tokens': ?child.promptTokens,
            'completion_tokens': ?child.completionTokens,
            'matched_prompt_tokens': ?child.matchedPromptTokens,
            'deduplicated_tokens': ?child.deduplicatedTokens,
            'lease_released': child.leaseReleased,
          },
      ],
      'evidence_source': 'engine',
    };
    if (request.path == SplashOperationPath.chat) {
      final child = evidence.children.singleOrNull;
      if (child == null ||
          child.questionId != null ||
          child.nativeRequestId == null ||
          child.runtimeGeneration != evidence.expectedRuntimeGeneration ||
          !child.leaseReleased) {
        throw const FormatException('文本生成缺少原生子请求证据');
      }
      try {
        final decoded = jsonDecode(nativeBody);
        if (decoded is! Map || decoded['object'] != 'chat.completion') {
          throw const FormatException('文本生成响应类型无效');
        }
        final result = TextResult.parse(nativeBody, expectedModel: nativeModel);
        if (child.state != result.finishReason ||
            child.completionTokens != result.outputTokens ||
            child.promptTokens == null ||
            result.usage['prompt_tokens'] != child.promptTokens ||
            result.usage['total_tokens'] !=
                child.promptTokens! + result.outputTokens) {
          throw const FormatException('文本生成用量与原生终态不一致');
        }
        return sealDebugJson({
          'id': 'chatcmpl-gmd-${evidence.operationId}',
          'object': 'chat.completion',
          'model': request.model,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': result.text},
              'finish_reason': result.finishReason,
            },
          ],
          'usage': result.usage,
          'cache': cache,
        }, projection: JevDebugProjection.llmResponse);
      } on TextProtocolException catch (error) {
        throw FormatException(error.message);
      }
    }
    try {
      final parsed = JevModelRequest.parse({
        for (final entry in request.body.entries)
          if (entry.key != 'cache_salt' && entry.key != 'prefill_only')
            entry.key: entry.value,
      });
      final result = DecisionBatchResult.parse(
        nativeBody,
        parsed.request,
        expectedModel: nativeModel,
      );
      final seen = <String>{};
      var promptTokens = 0;
      for (final child in evidence.children) {
        final question = child.questionId;
        if (question == null ||
            !parsed.request.questions.containsKey(question) ||
            !seen.add(question) ||
            child.state != 'stop' ||
            !child.leaseReleased ||
            child.nativeRequestId == null ||
            child.runtimeGeneration != evidence.expectedRuntimeGeneration ||
            child.promptTokens == null ||
            child.completionTokens != 0) {
          throw const FormatException('决策结果与原生问题子请求不一致');
        }
        promptTokens += child.promptTokens!;
      }
      if (promptTokens != result.inputTokens) {
        throw const FormatException('决策用量与原生子请求不一致');
      }
      return {...result.toJson(publicModel: request.model), 'cache': cache};
    } on DecisionProtocolException catch (error) {
      throw FormatException(error.message);
    }
  }

  static Map<String, Object?> prefill({
    required PublicPrefillRequest request,
    required String nativeModel,
    required String nativeBody,
    required SplashOperationSnapshot evidence,
    required String generation,
  }) {
    if (request.kind != PrefillOperationKind.prefill ||
        !RegExp(r'^[A-Za-z0-9._~-]{1,128}$').hasMatch(generation) ||
        utf8.encode(nativeBody).length > decisionMaxResponseBytes) {
      throw const FormatException('预填请求或代次无效');
    }
    final child = evidence.requirePrefillEvidence();
    final value = jsonDecode(nativeBody);
    if (value is! Map ||
        value['model'] != nativeModel ||
        value['usage'] is! Map) {
      throw const FormatException('原生预填响应与目标模型不匹配');
    }
    final usage = value['usage'] as Map;
    final prompt = child.promptTokens!;
    if (request.path == SplashOperationPath.chat) {
      final choices = value['choices'];
      if (value['object'] != 'chat.completion' ||
          usage['prompt_tokens'] != prompt ||
          usage['completion_tokens'] != 0 ||
          usage['total_tokens'] != prompt ||
          choices is! List ||
          choices.length != 1 ||
          choices.single is! Map) {
        throw const FormatException('原生文本预填用量或结果无效');
      }
      final choice = choices.single as Map;
      final message = choice['message'];
      final details = usage['completion_tokens_details'];
      if (choice['index'] != 0 ||
          choice['finish_reason'] != 'length' ||
          message is! Map ||
          message['role'] != 'assistant' ||
          message.keys.any(
            (key) => !{
              'role',
              'content',
              'reasoning_content',
              'tool_calls',
            }.contains(key),
          ) ||
          message['content'] != null && message['content'] != '' ||
          message['reasoning_content'] != null &&
              message['reasoning_content'] != '' ||
          message['tool_calls'] != null &&
              (message['tool_calls'] is! List ||
                  (message['tool_calls'] as List).isNotEmpty) ||
          details != null &&
              (details is! Map || details['reasoning_tokens'] != 0)) {
        throw const FormatException('原生文本预填包含生成内容或未正常结束');
      }
    } else {
      final answers = value['answers'];
      if (value['prefill_only'] != true ||
          answers is! Map ||
          answers.isNotEmpty ||
          usage['input_tokens'] != prompt ||
          usage['output_tokens'] != 0) {
        throw const FormatException('原生决策预填包含答案或用量无效');
      }
    }
    final proof = <String, Object?>{
      'protocol': 'gmd-prefill/1',
      'request_id': evidence.operationId,
      'state': 'completed',
      'terminal': true,
      'lease_released': true,
      'runtime_generation': generation,
      'cache_salt_sha256': sha256
          .convert(utf8.encode(request.cacheSalt))
          .toString(),
      'children': [
        {
          'question_id': child.questionId,
          'native_request_id': child.nativeRequestId,
          'runtime_generation': child.runtimeGeneration,
          'state': child.state,
          'prompt_tokens': child.promptTokens,
          'completion_tokens': child.completionTokens,
          'matched_prompt_tokens': ?child.matchedPromptTokens,
          'deduplicated_tokens': ?child.deduplicatedTokens,
          'lease_released': child.leaseReleased,
        },
      ],
      'generated_tokens': 0,
      'evidence_source': 'engine',
    };
    if (request.path == SplashOperationPath.systemone) {
      return {
        'object': 'systemone.prefill',
        'model': request.model,
        'prefill': proof,
      };
    }
    return {
      'id': 'chatcmpl-gmd-prefill-${evidence.operationId}',
      'object': 'chat.completion',
      'model': request.model,
      'choices': <Object>[],
      'usage': {
        'prompt_tokens': prompt,
        'completion_tokens': 0,
        'total_tokens': prompt,
      },
      'prefill': proof,
    };
  }
}
