import 'dart:convert';

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

Map<String, Object?> credentialNamedJevDocument(
  String model, {
  bool debug = false,
}) => {
  'model': model,
  'debug': debug,
  'state': {
    'api_key': 'ordinary task value',
    'authorization': 'allow',
    'cookie': [
      true,
      {'api_key': 7},
    ],
  },
  'questions': {
    'api_key': {
      'type': 'choice',
      'instructions': {
        'authorization': [
          'allow',
          {'cookie': false},
        ],
      },
      'criteria': {
        'authorization': {'cookie': 'nonsecret'},
        'cookie': [
          'Authorization: allow',
          {'api_key': 3},
        ],
      },
    },
    'cookie': {
      'type': 'score',
      'instructions': 'Authorization: allow',
      'criteria': [
        'Authorization: allow',
        {'api_key': 'Authorization: allow'},
      ],
    },
    'authorization': {
      'type': 'noul',
      'instructions': '{"api_key":"task JSON"}',
    },
  },
};

const credentialNamedJevAnswers = {
  'api_key': {
    'type': 'choice',
    'choice': 'cookie',
    'confidence': 0.5,
    'probabilities': {'authorization': 0.25, 'cookie': 0.75},
  },
  'cookie': {
    'type': 'score',
    'score': 0.75,
    'confidence': 0.5,
    'legend': {
      '0': 'Authorization: allow',
      '1': {'api_key': 'Authorization: allow'},
    },
    'probabilities': {'0': 0.25, '1': 0.75},
  },
  'authorization': {'type': 'noul', 'noul': 0.8},
};

Map<String, Object?> credentialExtraJevResponse(String raw) {
  final response = jsonDecode(raw) as Map;
  final answers = response['answers'] as Map;
  return {
    ...response.cast<String, Object?>(),
    'answers': {
      ...answers,
      'api_key': {
        ...answers['api_key'] as Map,
        'instructions': {'API_KEY': 'answer-extra-secret'},
      },
    },
    'server_log': 'Authorization: Bearer unknown-header-token',
    'unlisted_trace': ['Cookie: sid=unlisted-cookie-token'],
    'unrelated_typed': {
      'type': 'choice',
      'instructions': {'API_KEY': 'typed-object-secret'},
    },
    'echo': 'answer-extra-secret unknown-header-token unlisted-cookie-token typed-object-secret',
  };
}
