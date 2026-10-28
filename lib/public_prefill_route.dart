import 'jev_models.dart';
import 'prefill_operation_ledger.dart';
import 'public_gateway.dart';
import 'public_prefill_service.dart';
import 'splash_engine.dart';
import 'splash_operation_client.dart';

/// Resolves public aliases to an already running, uniquely owned Splash run.
class PublicPrefillRouteResolver {
  const PublicPrefillRouteResolver({
    required this.routes,
    required this.ledger,
    this.jevModels,
  });
  final PublicModelRoutes routes;
  final PrefillOperationLedger ledger;
  final JevModels? jevModels;

  Future<PublicPrefillRuntime> resolve(
    SplashOperationPath path,
    String model,
  ) async {
    final target = routes.resolve(model);
    final engine = target.runtime;
    if (engine is! SplashEngine) throw StateError('目标实例不是 Splash');
    if (path == SplashOperationPath.systemone) {
      final models = jevModels;
      final definition = models?.definitionFor(model);
      if (models == null ||
          definition == null ||
          definition.source != JevModelSource.native ||
          definition.bindings.length != 1 ||
          !engine.supportsSystemone ||
          !models.callableModels.any(
            (entry) => entry.definition.name == model,
          )) {
        throw StateError('目标不是就绪的原生决策实例');
      }
      final binding = definition.bindings.single;
      if (binding.artifactId != target.instance.artifactId ||
          binding.instanceId != null &&
              binding.instanceId != target.instance.launchInstanceId ||
          !identical(
            models.controller.catalog.runtimeFor(binding.engineId),
            engine,
          )) {
        throw StateError('公开模型与原生决策实例绑定不一致');
      }
    }
    return SplashPublicPrefillRuntime.create(
      engine: engine,
      instance: target.instance,
      ledger: ledger,
      defaults: target.generationDefaults,
    );
  }
}
