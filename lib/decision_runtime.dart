import 'decision_protocol.dart';
import 'engine_launch_configuration.dart';
import 'engine_runtime.dart';
import 'model_library.dart';
import 'jev_debug.dart';

/// Identity-bound observations used by public JEV routes and council seats.
abstract interface class DecisionInstance {
  String get id;
  LibraryArtifact get asset;
  Uri get endpoint;
  int? get pid;
  int get generation;
  bool get decisionReady;
  Set<RuntimeCapability> get decisionCapabilities;
  RuntimeCapacity? get capacity;
  int? get maxDecisionConcurrentRequests;
  String? get binarySha256;
  String? get nativeAlias;
  Map<String, Object?>? get decisionSourceIdentity;
  EngineLaunchCommand? get launchCommand;
}

abstract interface class DecisionRuntime implements EngineRuntime {
  bool get supportsSystemone;
  List<DecisionInstance> get decisionInstances;
  Future<DecisionResult> decide(
    String instanceId,
    DecisionRequest request, {
    Duration timeout = const Duration(seconds: 60),
    DecisionCancellation? cancellation,
  });
  Future<DecisionBatchResult> decideBatch(
    String instanceId,
    DecisionBatchRequest request, {
    Duration timeout = const Duration(seconds: 60),
    DecisionCancellation? cancellation,
    DecisionIOTrace? ioTrace,
  });
}
