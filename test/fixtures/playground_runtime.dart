import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'council_runtime.dart';

/// A real shared application graph; only CouncilRuntime's external engine IO is substituted.
class PlaygroundRuntime {
  PlaygroundRuntime._(
    this.runtime,
    this.council,
    this.routes,
    this.gateway,
    this.mcp,
  );
  final CouncilRuntime runtime;
  final CouncilController council;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;
  JevPlayground get playground =>
      JevPlayground(controller: council, gateway: gateway, mcp: mcp);

  static Future<PlaygroundRuntime> create({CouncilRuntimeIO? io}) async {
    final runtime = await CouncilRuntime.create(processIO: io);
    final council = CouncilController(catalog: runtime.catalog);
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [bindings.first],
        timeout: const Duration(seconds: 2),
      ),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: bindings,
        timeout: const Duration(seconds: 3),
      ),
    );
    await council.models.save(
      JevModelDefinition.native(name: 'native-kev', binding: bindings.last),
    );
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: [runtime.engine],
    );
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    final mcp = CouncilMcpServer(controller: council, port: 0);
    await gateway.start();
    await mcp.start();
    return PlaygroundRuntime._(runtime, council, routes, gateway, mcp);
  }

  Future<void> close() async {
    final release = runtime.io.release;
    if (release != null && !release.isCompleted) release.complete();
    await mcp.close();
    await gateway.stop();
    gateway.close();
    routes.close();
    await council.close();
    await runtime.close();
  }
}

Map<String, Object?> playgroundDocument(
  String model, {
  bool? debug,
  Object state = 'same',
}) => {
  'model': model,
  'state': state,
  'images': [],
  'debug': ?debug,
  'questions': {
    'route': {
      'type': 'choice',
      'instructions': [
        'Choose',
        {'why': 'same'},
      ],
      'criteria': {
        'a': {'label': 'A'},
        'b': ['B', 2],
      },
    },
    'rank': {
      'type': 'score',
      'instructions': 7,
      'criteria': [
        'Low',
        {'label': 'High'},
      ],
    },
    'valid': <String, Object?>{'type': 'noul', 'instructions': true},
  },
};
