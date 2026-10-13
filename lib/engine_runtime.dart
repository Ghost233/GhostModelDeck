import 'dart:async';

import 'chat_protocol.dart';
import 'embedding_protocol.dart';

enum EngineFamily { llamaCpp, omlx, splash }

enum RuntimeInstanceStatus { starting, ready, stopping, stopped, failed }

enum RuntimeCapability {
  choiceProbability,
  scoreProbability,
  noulScalar,
  textGeneration,
  embeddings,
}

enum DecisionFailureKind {
  notReady,
  timedOut,
  cancelled,
  invalidResponse,
  failed,
}

abstract interface class DecisionCallFailure implements Exception {
  String get message;
  DecisionFailureKind get kind;
  String? get rawResponse;
}

class RuntimeCapacity {
  const RuntimeCapacity({
    required this.contextPerSlot,
    required this.slotCount,
  });
  final int contextPerSlot;
  final int slotCount;

  static RuntimeCapacity? fromLlamaProperties(Map<String, dynamic> properties) {
    final settings = properties['default_generation_settings'];
    final context = settings is Map ? settings['n_ctx'] : null;
    final slots = properties['total_slots'];
    if (context is! int || context <= 0 || slots is! int || slots <= 0) {
      return null;
    }
    return RuntimeCapacity(contextPerSlot: context, slotCount: slots);
  }
}

/// Immutable observations, not another owner of processes or request permits.
class RuntimeInstance {
  RuntimeInstance({
    required this.id,
    required this.artifactId,
    required this.status,
    required this.generation,
    required this.activeRequests,
    required this.acceptingRequests,
    required this.hasLiveProcess,
    required Set<RuntimeCapability> capabilities,
    this.error,
    this.capacity,
    this.temporaryTest = false,
    this.launchInstanceId,
    this.launchRevision,
  }) : capabilities = Set.unmodifiable(capabilities);
  final String id;
  final String artifactId;
  final RuntimeInstanceStatus status;
  final int generation;
  final int activeRequests;
  final bool acceptingRequests;
  final bool hasLiveProcess;
  final Set<RuntimeCapability> capabilities;
  final String? error;
  final bool temporaryTest;
  final String? launchInstanceId;
  final int? launchRevision;
  final RuntimeCapacity? capacity;
}

abstract interface class EmbeddingRuntime implements EngineRuntime {
  Future<EmbeddingResult> generateEmbeddings(
    String instanceId,
    EmbeddingRequest request, {
    Duration timeout = const Duration(seconds: 120),
    DecisionCancellation? cancellation,
  });
}

/// The catalog returns its existing owner through this family-neutral interface.
abstract interface class EngineRuntime {
  List<RuntimeInstance> get runtimeInstances;
  Future<RuntimeInstance> startRuntime(String artifactId);
  Future<TextResult> generateText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  });
  Stream<TextStreamEvent> streamText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  });
  Future<void> stop(String instanceId);
  void Function() holdStartAdmission();
  Future<void> stopManaged();
  Future<void> shutdown();
}

class DecisionCancellation {
  final _cancelled = Completer<void>();
  final _listeners = <Object, void Function()>{};
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    final callbacks = _listeners.values.toList();
    _listeners.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void Function() listen(void Function() callback) {
    if (isCancelled) {
      callback();
      return () {};
    }
    final key = Object();
    _listeners[key] = callback;
    return () => _listeners.remove(key);
  }
}
