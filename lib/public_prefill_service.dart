import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'engine_runtime.dart';
import 'generation_configuration.dart';
import 'generation_seed.dart';
import 'prefill_operation_id.dart';
import 'prefill_operation_ledger.dart';
import 'public_prefill_control.dart';
import 'public_prefill_request.dart';
import 'public_prefill_response.dart';
import 'splash_engine.dart';
import 'splash_operation_client.dart';

/// Runtime selection must be made from the actual owned instance, not headers.
abstract interface class PublicPrefillRuntime {
  String get generation;
  String get owner;
  String get nativeModel;
  GenerationConfiguration get defaults;
  bool supportsPrefill(SplashOperationPath path);
  Future<bool> isCurrent();
  Future<T> withClient<T>(
    Future<T> Function(
      SplashOperationClient client,
      String nativeModel,
      String responseModel,
      DecisionCancellation cancellation,
    )
    work, {
    DecisionCancellation? cancellation,
  });
}

/// Binds the public generation to a specific managed Splash/native run.
class SplashPublicPrefillRuntime implements PublicPrefillRuntime {
  SplashPublicPrefillRuntime._(
    this.engine,
    this.instance,
    this.identity,
    this.generation,
    this.defaults,
  );
  final SplashEngine engine;
  final RuntimeInstance instance;
  final SplashOperationIdentity identity;
  @override
  final String generation;
  @override
  final GenerationConfiguration defaults;
  @override
  bool supportsPrefill(SplashOperationPath path) =>
      identity.supportsPrefill(path);
  static String ownerFor(RuntimeInstance instance) =>
      'splash:${instance.launchInstanceId ?? instance.artifactId}';
  @override
  String get owner => ownerFor(instance);
  @override
  String get nativeModel => instance.id;

  static Future<SplashPublicPrefillRuntime> create({
    required SplashEngine engine,
    required RuntimeInstance instance,
    required PrefillOperationLedger ledger,
    GenerationConfiguration defaults = const GenerationConfiguration.empty(),
  }) async {
    if (instance.temporaryTest ||
        instance.status != RuntimeInstanceStatus.ready ||
        !instance.acceptingRequests ||
        !instance.hasLiveProcess) {
      throw StateError('Splash 实例未就绪');
    }
    final identity = await engine.withTrackedClient<SplashOperationIdentity?>(
      instance.id,
      expectedGeneration: instance.generation,
      work: (client, nativeModel, responseModel, cancellation) async {
        try {
          return await client.identity(cancellation: cancellation);
        } on SplashPrefillEndpointMissing {
          // Return normally so the engine checks the same instance again.
          return null;
        }
      },
    );
    if (identity == null) {
      throw SplashPrefillEndpointMissing(
        instanceId: instance.id,
        generation: instance.generation,
      );
    }
    final binding = jsonEncode([
      instance.id,
      instance.generation,
      instance.launchRevision,
      identity.serviceInstance,
      identity.runtimeGeneration,
      identity.capabilities.bindingValues,
      defaults.toJson(),
    ]);
    return SplashPublicPrefillRuntime._(
      engine,
      instance,
      identity,
      ledger.publicGeneration(binding),
      defaults,
    );
  }

  @override
  Future<bool> isCurrent() async {
    try {
      await engine.withTrackedClient(
        instance.id,
        expectedGeneration: instance.generation,
        timeout: const Duration(seconds: 5),
        work: (client, nativeModel, responseModel, cancellation) async {
          final current = await client.identity(cancellation: cancellation);
          if (current.serviceInstance != identity.serviceInstance ||
              current.runtimeGeneration != identity.runtimeGeneration ||
              !current.capabilities.sameAs(identity.capabilities)) {
            throw const SplashOperationUnavailable('Splash 原生运行代次已变化');
          }
        },
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<T> withClient<T>(
    Future<T> Function(
      SplashOperationClient client,
      String nativeModel,
      String responseModel,
      DecisionCancellation cancellation,
    )
    work, {
    DecisionCancellation? cancellation,
  }) => engine.withTrackedClient(
    instance.id,
    expectedGeneration: instance.generation,
    cancellation: cancellation,
    work: (client, nativeModel, responseModel, cancellation) async {
      final current = await client.identity(cancellation: cancellation);
      if (current.serviceInstance != identity.serviceInstance ||
          current.runtimeGeneration != identity.runtimeGeneration ||
          !current.capabilities.sameAs(identity.capabilities)) {
        throw const SplashOperationUnavailable('Splash 原生运行代次已变化');
      }
      return work(client, nativeModel, responseModel, cancellation);
    },
  );
}

class PublicPrefillReply {
  const PublicPrefillReply(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}

class _NativeOperation {
  _NativeOperation(
    SplashOperationClient client,
    this.identity,
    this.token,
    this.runtime,
    this.request,
    this.responseModel,
  ) : client = SplashOperationClient(
        endpoint: client.endpoint,
        headers: client.headers,
        timeout: const Duration(seconds: 2),
      );
  final SplashOperationClient client;
  final SplashOperationIdentity identity;
  final String token;
  final PublicPrefillRuntime runtime;
  final PublicPrefillRequest request;
  final String responseModel;
  SplashOperationSubmission? response;
  bool workSettled = false;
  bool finished = false;
  Future<void>? cancellation;
  Future<PrefillOperationView>? recovery;
}

/// Coordinates one registered operation. Transport loss keeps its lease unknown.
class PublicPrefillService {
  PublicPrefillService({
    required this.ledger,
    required this.resolve,
    this.enabled = false,
  }) {
    control = PublicPrefillControl(
      ledger: ledger,
      resolveCurrentGeneration: (id) async {
        final parsed = PrefillOperationId.parse(id);
        final runtime = _knownGenerations[parsed.generationHash];
        if (runtime == null || !await runtime.isCurrent()) return null;
        return runtime.generation;
      },
      cancelNative: (id, token) async {
        final active = _native[id];
        if (active == null || active.token != token) {
          throw StateError('native operation unavailable');
        }
        _scheduleCancellation(id, active);
      },
      recover: _recover,
    );
  }

  final PrefillOperationLedger ledger;

  /// Remains off in the application until its release gates are satisfied.
  final bool enabled;
  final Future<PublicPrefillRuntime> Function(
    SplashOperationPath path,
    String model,
  )
  resolve;
  late final PublicPrefillControl control;
  final _knownGenerations = <String, PublicPrefillRuntime>{};
  final _native = <String, _NativeOperation>{};
  final _activeSubmissions = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;

  /// Called by trusted discovery, before a client can issue an operation ID.
  Future<bool> registerRuntime(PublicPrefillRuntime runtime) async {
    if (_closed || !enabled) return false;
    if (!await runtime.isCurrent()) return false;
    _knownGenerations[sha256
            .convert(utf8.encode(runtime.generation))
            .toString()] =
        runtime;
    return true;
  }

  Future<Map<String, Object?>> capability(
    SplashOperationPath path,
    String model,
  ) async {
    final mode = path == SplashOperationPath.chat
        ? 'chat_max_tokens_zero'
        : 'systemone_state';
    final unavailable = <String, Object?>{
      'protocol': 'gmd-prefill/1',
      'supported': false,
      'mode': mode,
      'reason': 'gmd_prefill_unavailable',
    };
    if (_closed || !enabled) return unavailable;
    try {
      final runtime = await resolve(path, model);
      if (!runtime.supportsPrefill(path) || !await registerRuntime(runtime)) {
        return unavailable;
      }
      return {
        'protocol': 'gmd-prefill/1',
        'supported': true,
        'mode': mode,
        'runtime_generation': runtime.generation,
        'operation_policy': {
          'id_format': 'gmd1',
          'time_basis_ms': ledger.timeBasisMs,
          'past_window_ms': PrefillOperationId.acceptanceWindowMs,
          'future_tolerance_ms': PrefillOperationId.futureToleranceMs,
        },
      };
    } catch (_) {
      return unavailable;
    }
  }

  /// Safe only when discovery can still resolve this exact current runtime.
  Future<PrefillOperationView> refuseUnadmitted(
    String operationId,
    String token,
    String generation,
  ) async {
    if (_closed || !enabled) throw StateError('预填服务不可用');
    final parsed = PrefillOperationId.parse(operationId);
    final runtime = _knownGenerations[parsed.generationHash];
    if (runtime == null ||
        runtime.generation != generation ||
        !await runtime.isCurrent()) {
      throw PrefillOperationForbidden();
    }
    return ledger.fenceUnadmitted(operationId, token, runtime.generation);
  }

  void _scheduleCancellation(String id, _NativeOperation operation) {
    if (operation.cancellation != null || operation.finished) return;
    final task = (() async {
      for (var attempts = 0; attempts < 10 && !operation.finished; attempts++) {
        try {
          await operation.client.cancel(
            operationId: id,
            token: operation.token,
            expected: operation.identity,
          );
          return;
        } on SplashOperationUnavailable {
          if (!operation.finished) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    })();
    operation.cancellation = task;
    unawaited(
      task.catchError((Object _) {}).whenComplete(() {
        if (identical(operation.cancellation, task)) {
          operation.cancellation = null;
        }
      }),
    );
  }

  void _finishNative(String id, _NativeOperation operation) {
    operation.finished = true;
    if (identical(_native[id], operation)) _native.remove(id);
  }

  Future<PrefillOperationView> _recover(
    String id,
    String token,
    PrefillOperationView original,
  ) async {
    if (_closed) return original;
    final active = _native[id];
    if (active == null ||
        active.token != token ||
        !active.workSettled ||
        active.finished) {
      return original;
    }
    final pending = active.recovery ??= (() async {
      if (!await active.runtime.isCurrent()) return original;
      final evidence = await active.client.query(
        operationId: id,
        token: token,
        expected: active.identity,
      );
      if (!evidence.terminal ||
          !evidence.leaseReleased ||
          !await active.runtime.isCurrent()) {
        return original;
      }
      final current = await ledger.query(id, token);
      if (current.terminal) {
        _finishNative(id, active);
        return current;
      }
      String? response;
      if (evidence.state == 'completed' && !current.cancelRequested) {
        final native = active.response;
        if (native == null || native.statusCode != 200) {
          final result = await ledger.recordResultFailure(
            id,
            token,
            evidence,
            PrefillResultFailure.unavailable,
          );
          _finishNative(id, active);
          return result;
        }
        try {
          final converted = active.request.kind == PrefillOperationKind.prefill
              ? PublicPrefillResponse.prefill(
                  request: active.request,
                  nativeModel: active.responseModel,
                  nativeBody: native.body,
                  evidence: evidence,
                  generation: active.runtime.generation,
                )
              : PublicPrefillResponse.consume(
                  request: active.request,
                  nativeModel: active.responseModel,
                  nativeBody: native.body,
                  evidence: evidence,
                  generation: active.runtime.generation,
                );
          response = jsonEncode(converted);
        } on FormatException {
          final result = await ledger.recordResultFailure(
            id,
            token,
            evidence,
            PrefillResultFailure.invalid,
          );
          _finishNative(id, active);
          return result;
        } on SplashOperationUnavailable {
          final result = await ledger.recordResultFailure(
            id,
            token,
            evidence,
            PrefillResultFailure.invalid,
          );
          _finishNative(id, active);
          return result;
        }
      }
      final result = await ledger.recordTerminal(
        id,
        token,
        evidence,
        response: response,
      );
      _finishNative(id, active);
      return result;
    })();
    try {
      return await pending;
    } finally {
      if (identical(active.recovery, pending)) active.recovery = null;
    }
  }

  Future<PublicPrefillReply> submit({
    required String operationId,
    required String token,
    required String generation,
    required PublicPrefillRequest request,
    DecisionCancellation? cancellation,
  }) async {
    if (_closed || !enabled) throw StateError('预填服务不可用');
    final operation = _submit(
      operationId: operationId,
      token: token,
      generation: generation,
      request: request,
      cancellation: cancellation,
    );
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _activeSubmissions.add(settled);
    try {
      return await operation;
    } finally {
      _activeSubmissions.remove(settled);
    }
  }

  Future<PublicPrefillReply> _submit({
    required String operationId,
    required String token,
    required String generation,
    required PublicPrefillRequest request,
    DecisionCancellation? cancellation,
  }) async {
    final existing = await ledger.replay(
      operationId: operationId,
      token: token,
      model: request.model,
      generation: generation,
      cacheSalt: request.cacheSalt,
      request: request.body,
      kind: request.kind,
    );
    if (existing != null) return _replay(existing);
    final runtime = await resolve(request.path, request.model);
    if (!runtime.supportsPrefill(request.path)) throw StateError('预填能力尚未启用');
    if (generation != runtime.generation) throw PrefillOperationConflict();
    if (!await runtime.isCurrent()) throw StateError('运行身份未确认');
    _knownGenerations[sha256
            .convert(utf8.encode(runtime.generation))
            .toString()] =
        runtime;
    // Validate the effective instance defaults before registering or sending.
    final nativeBody = request.toSplash(
      nativeModel: runtime.nativeModel,
      defaults: runtime.defaults,
    );
    if (utf8.encode(encodeGenerationRequest(nativeBody)).length > 1024 * 1024) {
      throw const FormatException('原生请求超出字节上限');
    }
    final admission = await ledger.admit(
      operationId: operationId,
      token: token,
      model: request.model,
      owner: runtime.owner,
      generation: runtime.generation,
      cacheSalt: request.cacheSalt,
      request: request.body,
      kind: request.kind,
    );
    if (!admission.created) return _replay(admission.operation);
    try {
      final completed = await runtime
          .withClient<({SplashOperationSnapshot evidence, String? response})?>((
            client,
            nativeModel,
            responseModel,
            cancellation,
          ) async {
            if (nativeModel != runtime.nativeModel) {
              throw StateError('原生模型身份已变化');
            }
            final identity = await client.identity(cancellation: cancellation);
            await ledger.bindNative(operationId, token, identity);
            final active = _NativeOperation(
              client,
              identity,
              token,
              runtime,
              request,
              responseModel,
            );
            _native[operationId] = active;
            if ((await ledger.query(operationId, token)).state ==
                PrefillOperationState.cancelRequested) {
              _scheduleCancellation(operationId, active);
            }
            final response = await client.submit(
              path: request.path,
              kind: request.kind == PrefillOperationKind.prefill
                  ? SplashOperationKind.prefill
                  : SplashOperationKind.consume,
              operationId: operationId,
              token: token,
              expected: identity,
              body: nativeBody,
              cancellation: cancellation,
            );
            active.response = response;
            final evidence = await client.query(
              operationId: operationId,
              token: token,
              expected: identity,
              cancellation: cancellation,
            );
            if (!evidence.terminal || !evidence.leaseReleased) {
              await ledger.markUnknown(operationId, token);
              return null;
            }
            if (response.statusCode != 200 || evidence.state != 'completed') {
              return (evidence: evidence, response: null);
            }
            final converted = request.kind == PrefillOperationKind.prefill
                ? PublicPrefillResponse.prefill(
                    request: request,
                    nativeModel: responseModel,
                    nativeBody: response.body,
                    evidence: evidence,
                    generation: runtime.generation,
                  )
                : PublicPrefillResponse.consume(
                    request: request,
                    nativeModel: responseModel,
                    nativeBody: response.body,
                    evidence: evidence,
                    generation: runtime.generation,
                  );
            return (evidence: evidence, response: jsonEncode(converted));
          }, cancellation: cancellation);
      if (completed == null) {
        return _replay(await ledger.query(operationId, token));
      }
      final ended = await ledger.recordTerminal(
        operationId,
        token,
        completed.evidence,
        response: completed.response,
      );
      final active = _native[operationId];
      if (active != null) _finishNative(operationId, active);
      return _replay(ended);
    } catch (_) {
      try {
        await ledger.markUnknown(operationId, token);
        return _replay(await ledger.query(operationId, token));
      } catch (_) {
        return const PublicPrefillReply(503, {
          'error': {
            'code': 'prefill_capability_unconfirmed',
            'message': '操作状态暂不可确认',
          },
        });
      }
    } finally {
      final active = _native[operationId];
      if (active != null) active.workSettled = true;
    }
  }

  PublicPrefillReply _replay(PrefillOperationView view) {
    if (view.state == PrefillOperationState.completed &&
        view.response != null) {
      return PublicPrefillReply(
        200,
        Map<String, Object?>.from(jsonDecode(view.response!) as Map),
      );
    }
    if (!view.terminal) return PublicPrefillReply(202, control.toJson(view));
    return PublicPrefillReply(
      view.state == PrefillOperationState.rejected ? 503 : 409,
      control.toJson(view),
    );
  }

  /// The owning gateway must stop and cancel requests before closing this service.
  Future<void> close() => _closing ??= (() async {
    _closed = true;
    await Future.wait(_activeSubmissions.toList());
    final operations = _native.values.toList();
    for (final operation in operations) {
      operation.finished = true;
    }
    await Future.wait([
      for (final operation in operations)
        if (operation.cancellation != null)
          operation.cancellation!.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
      for (final operation in operations)
        if (operation.recovery != null)
          operation.recovery!.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
    ]);
    _native.clear();
    _knownGenerations.clear();
  })();
}
