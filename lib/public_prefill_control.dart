import 'dart:async';

import 'prefill_operation_ledger.dart';

/// Control operations are authorized independently from the public request ID.
/// The resolver must use current, trusted runtime bindings, not client headers.
class PublicPrefillControl {
  PublicPrefillControl({
    required this.ledger,
    required this.resolveCurrentGeneration,
    required this.cancelNative,
    this.recover,
    this.cancelTimeout = const Duration(seconds: 5),
  });

  final PrefillOperationLedger ledger;
  final Future<String?> Function(String operationId) resolveCurrentGeneration;
  final Future<void> Function(String operationId, String token) cancelNative;
  final Duration cancelTimeout;
  final Future<PrefillOperationView> Function(
    String id,
    String token,
    PrefillOperationView view,
  )?
  recover;

  Future<PrefillOperationView> status(String id, String token) async {
    try {
      final view = await ledger.query(id, token);
      if (!view.terminal && recover != null) {
        try {
          return await recover!(id, token, view);
        } catch (_) {
          return view;
        }
      }
      return view;
    } on PrefillOperationForbidden {
      final generation = await resolveCurrentGeneration(id);
      if (generation == null) rethrow;
      return ledger.queryUnadmitted(id, token, generation);
    }
  }

  Future<PrefillOperationView> cancel(String id, String token) async {
    PrefillOperationView view;
    try {
      view = await ledger.requestCancel(id, token);
    } on PrefillOperationForbidden {
      final generation = await resolveCurrentGeneration(id);
      if (generation == null) rethrow;
      view = await ledger.fenceUnadmitted(id, token, generation);
      if (!view.identityOnly && !view.terminal) {
        view = await ledger.requestCancel(id, token);
      }
    }
    if (!view.terminal && view.cancelRequested) {
      try {
        await cancelNative(id, token).timeout(cancelTimeout);
      } catch (_) {
        // A failed cancellation is still pending until native release is proven.
      }
    }
    return view;
  }

  Map<String, Object?> toJson(PrefillOperationView view) => {
    'request_id': view.id,
    'state': switch (view.state) {
      PrefillOperationState.cancelRequested => 'cancel_requested',
      _ => view.state.name,
    },
    'terminal': view.terminal,
    'lease_released': view.leaseReleased,
    if (!view.terminal && view.cancelRequested) 'cancel_requested': true,
    'runtime_generation': ?view.generation,
    if (!view.identityOnly) ...{
      'model': ?view.model,
      'cache_salt_sha256': ?view.cacheSaltHash,
    },
    if (view.nativeDispatchNotStarted) ...{
      'native_dispatch': 'not_started',
      'proof_scope': view.identityOnly ? 'identity_only' : 'bound',
    },
    if (view.state == PrefillOperationState.rejected)
      'error': {
        'code': view.identityOnly ? 'not_admitted' : 'capacity_unavailable',
        'stage': 'admission',
      },
    if (view.state == PrefillOperationState.failed)
      'error': {
        'code': switch (view.resultFailure) {
          PrefillResultFailure.unavailable => 'result_unavailable',
          PrefillResultFailure.invalid => 'invalid_response',
          null => 'operation_failed',
        },
        'stage': view.resultFailure == null ? 'unknown' : 'response',
      },
    if (view.terminal && !view.identityOnly && view.nativeEvidence == null)
      'children': <Object>[],
    if (view.nativeEvidence case final evidence?)
      'children': [
        for (final child in evidence.children)
          {
            'question_id': child.questionId,
            'native_request_id': ?child.nativeRequestId,
            'runtime_generation': ?child.runtimeGeneration,
            'state': child.state,
            'prompt_tokens': ?child.promptTokens,
            'matched_prompt_tokens': ?child.matchedPromptTokens,
            'deduplicated_tokens': ?child.deduplicatedTokens,
            'completion_tokens': ?child.completionTokens,
            'lease_released': child.leaseReleased,
          },
      ],
  };
}
