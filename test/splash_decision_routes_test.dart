import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/splash_engine.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;
import 'runtime_monitor_test.dart' show splashStatus;

void main() {
  test('council retains Splash native HTTP failure bodies', () async {
    final fixture = await DecisionRouteFixture.create();
    addTearDown(fixture.close);
    final saved = await fixture.save('failure');
    await fixture.instances.start(saved.id);
    fixture.council.selectSeats(
      fixture.council.availableSeats.map((seat) => seat.id),
    );
    fixture.native.io.decisionStatus = 501;
    final consultation = await fixture.council.consult(
      state: 'x',
      options: {'a': 'red', 'b': 'green'},
    );
    expect(consultation.status, CouncilStatus.failed);
    expect(consultation.seats.single.status, CouncilSeatStatus.failed);
    expect(consultation.seats.single.rawResponse, contains('answers'));
  });
  test('Splash declares JEV without startup inference, routes native and council HTTP/MCP, and stops discovery', () async {
    final fixture = await DecisionRouteFixture.create();
    addTearDown(fixture.close);
    final saved = await fixture.save('first');
    expect(fixture.council.models.definitionFor(saved.publicName), isNotNull);
    final run = await fixture.instances.start(saved.id);
    expect(
      run.capabilities,
      containsAll([
        RuntimeCapability.choiceProbability,
        RuntimeCapability.scoreProbability,
        RuntimeCapability.noulScalar,
      ]),
    );
    expect(fixture.native.io.decisionBodies, isEmpty);
    final peer = await fixture.save('second');
    await fixture.instances.start(peer.id);
    await fixture.council.models.save(
      JevModelDefinition.council(
        name: 'splash-council',
        seats: [
          for (final definition in [saved, peer])
            JevModelBinding(
              artifactId: definition.artifactId,
              engineId: definition.engineId,
              instanceId: definition.id,
            ),
        ],
        timeout: const Duration(seconds: 60),
      ),
    );
    final playground = JevPlayground(
      gateway: fixture.gateway,
      mcp: fixture.mcp,
    );
    for (final mode in JevPlaygroundMode.values) {
      for (final name in [saved.publicName, 'splash-council']) {
        final result = await playground.run(
          mode,
          jsonEncode(document(name, debug: true)),
        );
        expect(
          result.status,
          JevPlaygroundStatus.success,
          reason: result.rawResponse,
        );
        expect(result.output!['model'], name);
        expect((result.output!['answers'] as Map).keys, [
          'route',
          'quality',
          'truth',
        ]);
        expect(
          result.debug!['source'],
          name == saved.publicName ? 'native' : 'council',
        );
      }
    }
    final raw = fixture.native.io.decisionBodies.first;
    expect(raw['model'], run.id);
    expect(raw['state'], {'evidence': 'same'});
    expect(raw['questions'], document(saved.publicName)['questions']);
    expect(
      fixture.council.models.capacityModels().where(
        (m) => m['key'] == saved.publicName,
      ),
      isNotEmpty,
    );
    await fixture.instances.stop(saved.id);
    final stopped = await playground.run(
      JevPlaygroundMode.http,
      jsonEncode(document(saved.publicName)),
    );
    expect(stopped.status, isNot(JevPlaygroundStatus.success));
    expect(fixture.instances.runsFor(peer.id).single.hasLiveProcess, isTrue);
  });
  for (final failure in ['http', 'malformed', 'identity']) {
    test('Splash JEV $failure retains real failure and raw evidence', () async {
      final fixture = await SplashRuntimeFixture.create(
        supportsSystemone: true,
      );
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      if (failure == 'http') fixture.io.decisionStatus = 501;
      if (failure == 'malformed') {
        fixture.io.decisionResponse = (_) => {'model': 'wrong', 'answers': {}};
      }
      if (failure == 'identity') {
        fixture.io.afterDecision = () => fixture.io.wrongPid = true;
      }
      await expectLater(
        engine.decide(
          run.id,
          DecisionRequest(
            state: 'x',
            instructions: 'choose',
            options: {'a': 'a', 'b': 'b'},
          ),
        ),
        throwsA(
          isA<SplashRequestException>()
              .having((e) => e.kind, 'kind', switch (failure) {
                'malformed' => DecisionFailureKind.invalidResponse,
                'identity' => DecisionFailureKind.notReady,
                _ => DecisionFailureKind.failed,
              })
              .having((e) => e.rawResponse, 'raw', isNotNull),
        ),
      );
      expect(engine.runtimeInstances.single.activeRequests, 0);
      if (failure != 'identity') {
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
      }
    });
  }
  for (final timeout in [true, false]) {
    test(
      'Splash pending JEV ${timeout ? 'timeout' : 'cancel'} drains only the current request',
      () async {
        final fixture = await SplashRuntimeFixture.create(
          supportsSystemone: true,
        );
        addTearDown(fixture.close);
        final engine = fixture.engine();
        addTearDown(() async {
          await engine.shutdown();
          await engine.close();
        });
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        final run = await engine.startRuntime(fixture.asset.id);
        final cancellation = DecisionCancellation();
        fixture.io.decisionEntered = Completer<void>();
        final release = fixture.io.decisionRelease = Completer<void>();
        final pending = engine.decide(
          run.id,
          DecisionRequest(
            state: 'x',
            instructions: 'choose',
            options: {'a': 'a', 'b': 'b'},
          ),
          cancellation: cancellation,
          timeout: timeout
              ? const Duration(milliseconds: 100)
              : const Duration(seconds: 60),
        );
        final rejected = expectLater(
          pending,
          throwsA(
            isA<SplashRequestException>().having(
              (e) => e.kind,
              'kind',
              timeout
                  ? DecisionFailureKind.timedOut
                  : DecisionFailureKind.cancelled,
            ),
          ),
        );
        try {
          await fixture.io.decisionEntered!.future;
          if (!timeout) cancellation.cancel();
          await rejected;
        } finally {
          release.complete();
          fixture.io.decisionRelease = null;
        }
        expect(engine.runtimeInstances.single.activeRequests, 0);
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
        expect(
          (await engine.decide(
            run.id,
            DecisionRequest(
              state: 'next',
              instructions: 'choose',
              options: {'a': 'a', 'b': 'b'},
            ),
          )).choice,
          'a',
        );
      },
    );
  }
  test(
    'Splash monitoring uses its owned identity and never admits a generation',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      fixture.io.monitorStatus = splashStatus();
      final data = await engine.readTelemetry(
        run.id,
        cancellation: DecisionCancellation(),
      );
      expect(data.running, 2);
      expect(data.decodePerSecond, 50);
      expect(fixture.io.chatModels, isEmpty);
      expect(fixture.io.decisionBodies, isEmpty);
      fixture.io.wrongPid = true;
      await expectLater(
        engine.readTelemetry(run.id, cancellation: DecisionCancellation()),
        throwsStateError,
      );
      expect(
        engine.runtimeInstances.single.status,
        RuntimeInstanceStatus.ready,
      );
    },
  );
}

Map<String, Object?> document(String model, {bool debug = false}) => {
  'model': model,
  'state': {'evidence': 'same'},
  'debug': debug,
  'questions': {
    'route': {
      'type': 'choice',
      'instructions': 'choose',
      'criteria': {'a': 'red', 'b': 'green'},
    },
    'quality': {
      'type': 'score',
      'instructions': 'score',
      'criteria': ['bad', 'good'],
    },
    'truth': {
      'type': 'noul',
      'instructions': 'true?',
      'criteria': {'false': 'no', 'true': 'yes'},
    },
  },
};

class DecisionRouteFixture {
  DecisionRouteFixture(
    this.native,
    this.cpp,
    this.catalog,
    this.instances,
    this.council,
    this.routes,
    this.gateway,
    this.mcp,
    this.engineId,
  );
  final SplashRuntimeFixture native;
  final LlamaEngine cpp;
  final EngineCatalog catalog;
  final LaunchInstances instances;
  final CouncilController council;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;
  final String engineId;
  static Future<DecisionRouteFixture> create() async {
    final native = await SplashRuntimeFixture.create(
      supportsSystemone: true,
      ordinaryChat: false,
    );
    native.io.monitorStatus = {
      ...splashStatus(),
      'maximum_context_tokens': 4096,
    };
    native.io.decisionResponse = (body) => {
      'model': native.io.nativeResponseModel ?? 'fixture/target:Q8',
      'answers': {
        for (final entry in (body['questions'] as Map).entries)
          '${entry.key}': switch ((entry.value as Map)['type']) {
            'choice' => {
              'type': 'choice',
              'choice': 'b',
              'probabilities': {'a': 0.25, 'b': 0.75},
              'confidence': 0.5,
            },
            'score' => {
              'type': 'score',
              'score': 0.75,
              'legend': {'0': 'bad', '1': 'good'},
              'probabilities': {'0': 0.25, '1': 0.75},
              'confidence': 0.5,
            },
            _ => {'type': 'noul', 'noul': 0.75},
          },
      },
      'usage': {'input_tokens': 10, 'output_tokens': 0},
    };
    final cpp = LlamaEngine(
      library: native.library,
      installationDirectory: Directory('${native.root.path}/cpp'),
    );
    final catalog = EngineCatalog(
      library: native.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(native.library),
      registryFile: File('${native.root.path}/engines.json'),
      splashIO: native.io,
    );
    final entry = await catalog.link(native.source.path);
    final instances = LaunchInstances(
      catalog: catalog,
      file: File('${native.root.path}/instances.json'),
    );
    final council = CouncilController(
      catalog: catalog,
      launchInstances: instances,
      modelRegistryFile: File('${native.root.path}/councils.json'),
    );
    final routes = PublicModelRoutes(
      library: native.library,
      runtimes: [cpp],
      runtimeSources: () => catalog.runtimes.toList(),
      instances: instances,
    );
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    final mcp = CouncilMcpServer(controller: council, port: 0);
    await gateway.start();
    await mcp.start();
    return DecisionRouteFixture(
      native,
      cpp,
      catalog,
      instances,
      council,
      routes,
      gateway,
      mcp,
      entry.id,
    );
  }

  Future<LaunchInstance> save(String name) => instances.save(
    name: name,
    artifactId: native.asset.id,
    engineId: engineId,
    configuration: EngineLaunchConfiguration(family: EngineFamily.splash),
    splashAssembly: native.assembly.path,
  );
  Future<void> close() async {
    await mcp.close();
    await gateway.stop();
    gateway.close();
    routes.close();
    await council.close();
    await instances.close();
    await catalog.shutdown();
    catalog.close();
    cpp.close();
    await native.close();
  }
}
