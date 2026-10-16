import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_scenarios.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/decision_protocol.dart';

import 'fixtures/council_runtime.dart';

Map<String, dynamic> request(String model) => {
  'model': model,
  'state': 'Choose an action.',
  'questions': {
    'pick': {
      'type': 'choice',
      'instructions': 'Choose.',
      'criteria': {'a': 'Accept', 'b': 'Reject'},
    },
  },
};

Future<(int, Map)> http(Uri uri, [Map<String, dynamic>? body]) async {
  final client = HttpClient();
  try {
    final query = await client.openUrl(body == null ? 'GET' : 'POST', uri);
    if (body != null) {
      query.headers.contentType = ContentType.json;
      query.write(jsonEncode(body));
    }
    final response = await query.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join()) as Map,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('public capacities change only after successful restart and refreshed MCP descriptions follow them', () async {
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      sourceSystemone: true,
    );
    addTearDown(runtime.close);
    runtime.io.capacityProperties = {
      'default_generation_settings': {'n_ctx': 65536},
      'total_slots': 1,
    };
    final instances = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(instances.close);
    final small = await instances.save(
      name: 'Small',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '8192'},
      ),
    );
    await instances.save(
      name: 'Large',
      artifactId: small.artifactId,
      engineId: small.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '32768'},
      ),
    );
    final controller = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
      modelRegistryFile: File('${runtime.root.path}/committees.json'),
      scenarioRegistryFile: File('${runtime.root.path}/scenarios.json'),
    );
    addTearDown(controller.close);
    await controller.models.save(
      JevModelDefinition.council(
        name: 'committee',
        seats: controller.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    await controller.scenarios.save(
      0,
      ModelScenario(
        displayName: 'Combined',
        modelName: 'combined',
        councilId: controller.models.definitions.single.id,
      ),
    );
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: runtime.catalog.runtimes.toList(),
      instances: instances,
      scenarios: controller.scenarios,
    );
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: controller.models,
      port: 0,
    );
    final mcp = CouncilMcpServer(controller: controller, port: 0);
    addTearDown(() async {
      await gateway.stop();
      gateway.close();
      routes.close();
    });
    addTearDown(mcp.close);
    await gateway.start();
    await mcp.start();
    final client = McpClient(
      const Implementation(name: 'capacity-refresh', version: '1'),
    );
    addTearDown(client.close);
    await client.connect(StreamableHttpClientTransport(mcp.endpoint!));
    expect(client.getInstructions(), contains('上下文=8192'));
    Future<void> check(int context) async {
      final response = await http(gateway.baseUrl!.resolve('/api/v1/models'));
      expect(response.$1, 200);
      final rows = (response.$2['models'] as List).where(
        (row) =>
            [small.publicName, 'committee', 'combined'].contains(row['key']),
      );
      expect(rows.map((row) => row['key']).toSet(), {
        small.publicName,
        'committee',
        'combined',
      });
      for (final row in rows) {
        expect(row['loaded_instances'][0]['config']['context_length'], context);
      }
      final tools = await client.listTools();
      expect(
        tools.tools
            .firstWhere((tool) => tool.name == CouncilMcpServer.batchToolName)
            .description,
        contains('上下文=$context'),
      );
    }

    final first = await instances.start(small.id);
    await check(8192);
    await instances.save(
      id: small.id,
      name: small.name,
      artifactId: small.artifactId,
      engineId: small.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '16384'},
      ),
    );
    await check(8192);
    expect(instances.runsFor(small.id).single.id, first.id);
    await instances.stop(small.id);
    runtime.io.holdIdentity(expected: 1);
    final failed = instances
        .start(small.id)
        .then<Object>((run) => run, onError: (Object error) => error);
    await runtime.io.identityArrived!.future.timeout(
      const Duration(seconds: 5),
    );
    final pending = instances
        .runsFor(small.id)
        .lastWhere((run) => run.hasLiveProcess);
    runtime.io.identityAliases[pending.id] = 'foreign-model';
    runtime.io.identityRelease!.complete();
    await failed;
    expect(instances.contextLengthFor(small.id), 8192);
    expect(controller.models.scenarioInstructions, contains('上下文=8192'));
    expect(controller.models.discoverableScenarios, isEmpty);
    await instances.stop(small.id);
    final restarted = await instances.start(small.id);
    expect(restarted.id, isNot(first.id));
    await check(16384);
    await instances.stop(small.id);
    await instances.close();
    final reopened = LaunchInstances(
      catalog: runtime.catalog,
      file: instances.file,
    );
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.contextLengthFor(small.id), 16384);
  });
  test('context impact previews all configured members and scenes without saving or starting', () async {
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      sourceSystemone: true,
    );
    addTearDown(runtime.close);
    final instances = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(instances.close);
    Future<LaunchInstance> save(String name, int context) => instances.save(
      name: name,
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '$context'},
      ),
    );
    final small = await save('Small', 8192);
    await save('Large', 32768);
    final controller = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
      modelRegistryFile: File('${runtime.root.path}/committees.json'),
      scenarioRegistryFile: File('${runtime.root.path}/scenarios.json'),
    );
    addTearDown(controller.close);
    await controller.models.save(
      JevModelDefinition.council(
        name: 'committee',
        seats: controller.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    await controller.scenarios.save(
      0,
      ModelScenario(
        displayName: 'Direct',
        modelName: 'direct',
        instanceId: small.id,
      ),
    );
    await controller.scenarios.save(
      1,
      ModelScenario(
        displayName: 'Combined',
        modelName: 'combined',
        councilId: controller.models.definitions.single.id,
      ),
    );
    final before = await instances.file.readAsString();
    final impact = controller.models.previewContextChange(
      small.id,
      EngineLaunchConfiguration(formValues: {'--ctx-size': '65536'}),
    );
    expect(impact, [
      (label: '实例 Small', before: 8192, after: 65536),
      (label: '委员会 committee', before: 8192, after: 32768),
      (label: '场景 Direct（direct）', before: 8192, after: 65536),
      (label: '场景 Combined（combined）', before: 8192, after: 32768),
    ]);
    expect(await instances.file.readAsString(), before);
    expect(
      instances.definitions.expand(
        (instance) => instances.runsFor(instance.id),
      ),
      isEmpty,
    );
    expect(
      controller.models.scenarioContextLength(controller.scenarios.entries[1]),
      8192,
    );
  });
  for (final legacy in [false, true]) {
    test(
      'committee identity and scene binding survive rename and reopen (legacy=$legacy)',
      () async {
        final runtime = await CouncilRuntime.create(
          modelCount: 1,
          sourceSystemone: true,
        );
        addTearDown(runtime.close);
        final instances = LaunchInstances(
          catalog: runtime.catalog,
          file: File('${runtime.root.path}/instances.json'),
        );
        addTearDown(instances.close);
        await instances.save(
          name: 'Saved',
          artifactId: runtime.library.state.artifacts.single.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        );
        final models = File('${runtime.root.path}/committees.json');
        final scenarios = File('${runtime.root.path}/scenarios.json');
        CouncilController create() => CouncilController(
          catalog: runtime.catalog,
          launchInstances: instances,
          modelRegistryFile: models,
          scenarioRegistryFile: scenarios,
        );
        var controller = create();
        addTearDown(() => controller.close());
        await controller.models.save(
          JevModelDefinition.council(
            name: 'committee-original',
            seats: controller.models.availableBindings,
            timeout: const Duration(seconds: 2),
          ),
        );
        if (legacy) {
          await controller.close();
          final value = jsonDecode(await models.readAsString()) as Map;
          for (final model in value['models'] as List) {
            model.remove('id');
          }
          await models.writeAsString(jsonEncode(value));
          controller = create();
          await controller.models.load();
        }
        final original = controller.models.definitions.single;
        await controller.scenarios.save(
          0,
          ModelScenario(
            displayName: '固定场景',
            modelName: 'long-v',
            councilId: original.id,
          ),
        );
        await controller.models.save(
          JevModelDefinition.council(
            name: 'committee-renamed',
            seats: original.bindings,
            timeout: original.timeout,
          ),
          replacing: original.name,
        );
        await controller.close();
        controller = create();
        await controller.models.load();
        final restored = controller.models.definitions.single;
        expect(restored.name, 'committee-renamed');
        expect(restored.id, original.id);
        final scene = controller.scenarios.entries.first;
        expect(scene.councilId, original.id);
        expect(scene.instanceId, isNull);
        expect(scene.modelName, 'long-v');
        expect(controller.models.scenarioContextLength(scene), 4096);
      },
    );
  }
  test('committee scenes use saved identities, partial availability and the minimum of all configured contexts', () async {
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      sourceSystemone: true,
    );
    addTearDown(runtime.close);
    runtime.io.capacityProperties = {
      'default_generation_settings': {'n_ctx': 32768},
      'total_slots': 1,
    };
    final instances = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(instances.close);
    final first = await instances.save(
      name: 'Small context',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '8192'},
      ),
    );
    final second = await instances.save(
      name: 'Large context',
      artifactId: first.artifactId,
      engineId: first.engineId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '32768'},
      ),
    );
    final controller = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
      modelRegistryFile: File('${runtime.root.path}/committees.json'),
      scenarioRegistryFile: File('${runtime.root.path}/scenarios.json'),
    );
    addTearDown(controller.close);
    await controller.models.save(
      JevModelDefinition.council(
        name: 'actual-council',
        seats: controller.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final committee = controller.models.definitions.single;
    await controller.scenarios.save(
      0,
      ModelScenario(
        displayName: '长上下文＋视觉',
        modelName: 'long-v',
        councilId: committee.id,
      ),
    );
    final mcp = CouncilMcpServer(controller: controller, port: 0);
    addTearDown(mcp.close);
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: runtime.catalog.runtimes.toList(),
      instances: instances,
      scenarios: controller.scenarios,
    );
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: controller.models,
      port: 0,
    );
    addTearDown(() async {
      await gateway.stop();
      gateway.close();
      routes.close();
    });
    await gateway.start();
    await mcp.start();
    final client = McpClient(
      const Implementation(name: 'committee-scenario-test', version: '1'),
    );
    addTearDown(client.close);
    await client.connect(StreamableHttpClientTransport(mcp.endpoint!));
    Future<CallToolResult> discover() => client.callTool(
      CallToolRequest(name: CouncilMcpServer.discoveryToolName, arguments: {}),
    );
    Future<CallToolResult> call() => client.callTool(
      CallToolRequest(
        name: CouncilMcpServer.batchToolName,
        arguments: request('long-v'),
      ),
    );
    expect((await discover()).structuredContent!['data'], isEmpty);
    expect(
      (await call()).structuredContent!['error']['code'],
      'no_successful_seats',
    );
    expect(runtime.io.requests, isEmpty);
    expect(client.getInstructions(), contains('上下文=8192'));
    final secondRun = await instances.start(second.id);
    expect(
      ((await discover()).structuredContent!['data'] as List).single['id'],
      'long-v',
    );
    runtime.io.requests.clear();
    final partial = await call();
    expect(partial.isError, isNot(true));
    expect(partial.structuredContent!['model'], 'long-v');
    expect(partial.structuredContent!['council']['status'], 'partial');
    expect(
      {
        for (final member
            in partial.structuredContent!['council']['members'] as List)
          member['instance_id']: member['status'],
      },
      {first.id: 'not_ready', second.id: 'ok'},
    );
    expect(runtime.io.requests.single['model'], secondRun.id);
    final saving = controller.scenarios.save(
      0,
      ModelScenario(
        displayName: 'Pending route',
        modelName: 'long-v',
        instanceId: second.id,
      ),
    );
    final saved = saving.then<Object>(
      (_) => true,
      onError: (Object error) => error,
    );
    JevEvaluationLock? admitted;
    final admission = controller.models.lockForEvaluation('long-v').then((
      lock,
    ) {
      admitted = lock;
      return lock;
    });
    try {
      await expectLater(admission, throwsA(isA<DecisionProtocolException>()));
    } finally {
      admitted?.release();
      await saved;
    }
    expect(await saved, isTrue);
    await controller.scenarios.save(
      0,
      ModelScenario(
        displayName: 'Selected committee',
        modelName: 'long-v',
        councilId: committee.id,
      ),
    );
    final selection = await controller.models.lockForEvaluation('long-v');
    try {
      await controller.scenarios.save(
        0,
        ModelScenario(
          displayName: '视觉仅作用户说明',
          modelName: 'long-v',
          councilId: committee.id,
        ),
      );
      expect(selection.isCurrent, isTrue);
      await expectLater(
        controller.scenarios.save(
          0,
          ModelScenario(
            displayName: 'Changed target',
            modelName: 'long-v',
            instanceId: first.id,
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        controller.models.save(
          JevModelDefinition.council(
            name: 'actual-council',
            seats: committee.bindings,
            timeout: const Duration(seconds: 3),
          ),
          replacing: 'actual-council',
        ),
        throwsA(isA<DecisionProtocolException>()),
      );
      await expectLater(
        controller.models.delete('actual-council'),
        throwsA(isA<DecisionProtocolException>()),
      );
    } finally {
      selection.release();
    }
    final capacities = await http(gateway.baseUrl!.resolve('/api/v1/models'));
    final advertised = (capacities.$2['models'] as List).singleWhere(
      (row) => row['key'] == 'long-v',
    );
    expect(advertised['loaded_instances'][0]['config']['context_length'], 8192);
    final wire = await http(
      gateway.baseUrl!.resolve('/v1/systemone'),
      request('long-v'),
    );
    expect(wire.$1, 200);
    expect(wire.$2['council']['status'], 'partial');
    await controller.models.save(
      JevModelDefinition.council(
        name: 'renamed-council',
        seats: committee.bindings,
        timeout: committee.timeout,
      ),
      replacing: 'actual-council',
    );
    expect(controller.models.definitions.single.id, committee.id);
    expect((await call()).structuredContent!['model'], 'long-v');
    expect(
      (await http(
        gateway.baseUrl!.resolve('/v1/systemone'),
        request('actual-council'),
      )).$1,
      404,
    );
    expect(
      (await http(
        gateway.baseUrl!.resolve('/v1/systemone'),
        request('renamed-council'),
      )).$1,
      200,
    );
    final firstRun = await instances.start(first.id);
    runtime.io.requests.clear();
    final full = await call();
    expect(full.structuredContent!['council']['status'], 'ok');
    expect(runtime.io.requests.map((value) => value['model']).toSet(), {
      firstRun.id,
      secondRun.id,
    });
    await instances.stop(first.id);
    expect(
      (await client.listTools()).tools.first.description,
      contains('上下文=8192'),
    );
    await instances.stop(second.id);
    expect((await discover()).structuredContent!['data'], isEmpty);
    await controller.models.delete('renamed-council');
    await controller.models.save(
      JevModelDefinition.council(
        name: 'renamed-council',
        seats: committee.bindings,
        timeout: committee.timeout,
      ),
    );
    expect(controller.models.definitions.single.id, isNot(committee.id));
    expect(
      (await call()).structuredContent!['error']['code'],
      'model_not_found',
    );
    expect((await discover()).structuredContent!['data'], isEmpty);
  });
}
