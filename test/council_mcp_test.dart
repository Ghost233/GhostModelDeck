import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_scenarios.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'fixtures/council_runtime.dart';

Future<McpClient> _connect(
  Uri endpoint, {
  McpProtocol protocol = McpProtocol.stable,
  String? protocolVersion,
}) async {
  final client = McpClient(
    const Implementation(name: 'jev-test', version: '1'),
    options: McpClientOptions(
      protocol: protocol,
      protocolVersion: protocolVersion,
    ),
  );
  await client.connect(StreamableHttpClientTransport(endpoint));
  return client;
}

Future<(int, dynamic)> _http(
  Uri endpoint,
  dynamic body, {
  String method = 'POST',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, endpoint);
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'application/json, text/event-stream');
    headers.forEach(request.headers.set);
    if (method == 'POST') {
      request.write(body is String ? body : jsonEncode(body));
    }
    final response = await request.close();
    final raw = await utf8.decoder.bind(response).join();
    dynamic value;
    try {
      value = raw.isEmpty ? null : jsonDecode(raw);
    } on FormatException {
      value = raw;
    }
    return (response.statusCode, value);
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('unconfigured scenarios stay out of default discovery without blocking a known instance name', () async {
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
    final definition = await instances.save(
      name: 'Existing instance',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    await instances.start(definition.id);
    final controller = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
    );
    addTearDown(controller.close);
    final server = CouncilMcpServer(controller: controller, port: 0);
    addTearDown(server.close);
    await server.start();
    final client = await _connect(server.endpoint!);
    addTearDown(client.close);
    final response = await client.callTool(
      CallToolRequest(
        name: CouncilMcpServer.batchToolName,
        arguments: {
          'model': definition.publicName,
          'state': 'A choice',
          'questions': {
            'pick': {
              'type': 'choice',
              'instructions': 'Choose an action.',
              'criteria': {'accept': 'Accept', 'reject': 'Reject'},
            },
          },
        },
      ),
    );
    expect(response.isError, isNot(true));
    expect(response.structuredContent!['model'], definition.publicName);
    final discovery = await client.callTool(
      CallToolRequest(name: CouncilMcpServer.discoveryToolName, arguments: {}),
    );
    expect(discovery.structuredContent!['data'], isEmpty);
  });
  test(
    'configured scenario uses the same model name for public HTTP and MCP',
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
      final definition = await instances.save(
        name: 'Selected instance',
        artifactId: runtime.library.state.artifacts.single.id,
        engineId: EngineCatalog.officialId,
        configuration: EngineLaunchConfiguration(
          formValues: {'--ctx-size': '8192'},
        ),
        jevRequestTimeoutSeconds: 90,
      );
      await instances.start(definition.id);
      final controller = CouncilController(
        catalog: runtime.catalog,
        launchInstances: instances,
        scenarioRegistryFile: File('${runtime.root.path}/scenarios.json'),
      );
      addTearDown(controller.close);
      await controller.scenarios.save(
        0,
        ModelScenario(
          displayName: '4k上线+视觉',
          modelName: 'fast-v',
          instanceId: definition.id,
        ),
      );
      final server = CouncilMcpServer(controller: controller, port: 0);
      addTearDown(server.close);
      await server.start();
      expect(server.codexConfig, contains('tool_timeout_sec = 100'));
      final client = await _connect(server.endpoint!);
      addTearDown(client.close);
      expect(
        client.getInstructions(),
        allOf(contains('4k上线+视觉'), contains('fast-v'), contains('8192')),
      );
      final legacyClient = await _connect(
        server.endpoint!,
        protocol: McpProtocol.legacy,
        protocolVersion: '2025-06-18',
      );
      addTearDown(legacyClient.close);
      expect(
        (await legacyClient.listTools()).tools.every(
          (tool) => tool.description!.contains('4k上线+视觉'),
        ),
        isTrue,
      );
      await controller.scenarios.save(
        0,
        ModelScenario(
          displayName: '新场景说明',
          modelName: 'fast-v',
          instanceId: definition.id,
        ),
      );
      expect(
        (await legacyClient.listTools()).tools.every(
          (tool) =>
              tool.description!.contains('新场景说明') &&
              !tool.description!.contains('4k上线+视觉'),
        ),
        isTrue,
      );
      final reconnected = await _connect(server.endpoint!);
      addTearDown(reconnected.close);
      expect(reconnected.getInstructions(), contains('新场景说明'));
      final discovery = await client.callTool(
        CallToolRequest(
          name: CouncilMcpServer.discoveryToolName,
          arguments: {},
        ),
      );
      expect(
        (discovery.structuredContent!['data'] as List).map((row) => row['id']),
        ['fast-v'],
      );
      final request = {
        'model': 'fast-v',
        'state': 'A choice',
        'questions': {
          'pick': {
            'type': 'choice',
            'instructions': 'Choose an action.',
            'criteria': {'accept': 'Accept', 'reject': 'Reject'},
          },
        },
      };
      final mcpResult = await client.callTool(
        CallToolRequest(
          name: CouncilMcpServer.batchToolName,
          arguments: request,
        ),
      );
      expect(mcpResult.isError, isNot(true));
      expect(mcpResult.structuredContent!['model'], 'fast-v');
      final routes = PublicModelRoutes(
        library: runtime.library,
        runtimes: runtime.catalog.runtimes.toList(),
        instances: instances,
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
      final (status, result) = await _http(
        gateway.baseUrl!.resolve('/v1/systemone'),
        request,
      );
      expect(status, 200);
      expect(result['model'], 'fast-v');
      expect(result['answers'], mcpResult.structuredContent!['answers']);
      final (listStatus, listing) = await _http(
        gateway.baseUrl!.resolve('/v1/models'),
        null,
        method: 'GET',
      );
      expect(listStatus, 200);
      expect(
        (listing['data'] as List).map((row) => row['id']),
        containsAll([definition.publicName, 'fast-v']),
      );
      await instances.stop(definition.id);
      final coldMcp = await client.callTool(
        CallToolRequest(
          name: CouncilMcpServer.batchToolName,
          arguments: request,
        ),
      );
      expect(coldMcp.structuredContent!['error']['code'], 'model_not_ready');
      expect(
        (await _http(gateway.baseUrl!.resolve('/v1/systemone'), request)).$1,
        503,
      );
      final coldList = await client.callTool(
        CallToolRequest(
          name: CouncilMcpServer.discoveryToolName,
          arguments: {},
        ),
      );
      expect(coldList.structuredContent!['data'], isEmpty);
      expect(
        instances.runsFor(definition.id).any((run) => run.hasLiveProcess),
        isFalse,
      );
      await instances.delete(definition.id);
      final missing = await client.callTool(
        CallToolRequest(
          name: CouncilMcpServer.batchToolName,
          arguments: request,
        ),
      );
      expect(missing.structuredContent!['error']['code'], 'model_not_found');
      expect(
        (await _http(gateway.baseUrl!.resolve('/v1/systemone'), request)).$1,
        404,
      );
    },
  );
  test(
    'in-flight scenario decisions keep their instance when the binding changes',
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
      final first = await instances.save(
        name: 'First',
        artifactId: runtime.library.state.artifacts.single.id,
        engineId: EngineCatalog.officialId,
        configuration: EngineLaunchConfiguration(),
      );
      final second = await instances.copy(first.id);
      final firstRun = await instances.start(first.id);
      final secondRun = await instances.start(second.id);
      final controller = CouncilController(
        catalog: runtime.catalog,
        launchInstances: instances,
      );
      addTearDown(controller.close);
      await controller.scenarios.save(
        0,
        ModelScenario(
          displayName: 'Selected',
          modelName: 'fast-v',
          instanceId: first.id,
        ),
      );
      final server = CouncilMcpServer(controller: controller, port: 0);
      addTearDown(server.close);
      await server.start();
      final client = await _connect(server.endpoint!);
      addTearDown(client.close);
      final arrived = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      runtime.io.requests.clear();
      runtime.io.respond = (request, response) async {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
        return response;
      };
      Future<CallToolResult> call() => client.callTool(
        CallToolRequest(
          name: CouncilMcpServer.batchToolName,
          arguments: {
            'model': 'fast-v',
            'state': 'A choice',
            'questions': {
              'pick': {
                'type': 'choice',
                'instructions': 'Choose.',
                'criteria': {'a': 'Accept', 'b': 'Reject'},
              },
            },
          },
        ),
      );
      final pending = call();
      await arrived.future.timeout(const Duration(seconds: 2));
      await controller.scenarios.save(
        0,
        ModelScenario(
          displayName: 'Changed',
          modelName: 'fast-v',
          instanceId: second.id,
        ),
      );
      release.complete();
      final original = await pending;
      expect(original.isError, isNot(true));
      expect(runtime.io.requests.single['model'], firstRun.id);
      expect((await call()).isError, isNot(true));
      expect(runtime.io.requests.map((request) => request['model']), [
        firstRun.id,
        secondRun.id,
      ]);
    },
  );
  for (final protocol in [McpProtocol.stable, McpProtocol.legacy]) {
    test(
      'MCP $protocol publishes usage guidance and local decision boundaries',
      () async {
        final runtime = await CouncilRuntime.create(modelCount: 0);
        addTearDown(runtime.close);
        final council = CouncilController(catalog: runtime.catalog);
        addTearDown(council.close);
        final server = CouncilMcpServer(controller: council, port: 0);
        addTearDown(server.close);
        await server.start();
        final client = await _connect(
          server.endpoint!,
          protocol: protocol,
          protocolVersion: protocol == McpProtocol.legacy ? '2025-06-18' : null,
        );
        addTearDown(client.close);
        expect(
          client.getInstructions(),
          allOf([
            contains('局部语义判断'),
            contains('确定性的计算、精确匹配和排序使用代码'),
            contains('已有有效模型名称时直接复用'),
            contains('当宿主允许从 JavaScript 编排环境调用相关工具时'),
            contains('实际操作由宿主工具执行'),
            contains('步数和时间上限'),
            contains('携带当前状态和操作记录交回主模型'),
            contains('在候选项中显式提供 handoff'),
            contains('confidence 描述分布形状，不代表正确率'),
            contains('任务完成应依据实际状态和验收条件验证'),
          ]),
        );
        final tools = {
          for (final tool in (await client.listTools()).tools) tool.name: tool,
        };
        expect(
          tools[CouncilMcpServer.toolName]!.description,
          allOf(
            contains('有限候选项'),
            contains('model 必填'),
            contains('共享同一状态的多个判断使用 decide_jev_batch'),
          ),
        );
        expect(
          tools[CouncilMcpServer.batchToolName]!.description,
          allOf(
            contains('共享同一 state 的多个独立问题'),
            contains('有前后依赖的问题应分步调用'),
            contains('具体以所选模型的能力验证为准'),
            contains('confidence 描述分布形状，不代表正确率'),
          ),
        );
        expect(
          tools[CouncilMcpServer.discoveryToolName]!.description,
          allOf(
            contains('首次选择模型、模型名称未知或调用提示模型不可用时使用'),
            contains('已有有效名称时直接复用'),
            contains('不代表该模型支持所有题型'),
          ),
        );
        expect(runtime.engine.state.instances, isEmpty);
      },
    );
  }
  test('HTTP and MCP report saved member partial results without borrowing an unbound peer', () async {
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
    final first = await instances.save(
      name: 'First',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final second = await instances.copy(first.id);
    final controller = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
    );
    addTearDown(controller.close);
    await controller.models.save(
      JevModelDefinition.council(
        name: 'committee',
        seats: controller.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final run = await instances.start(first.id);
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: runtime.catalog.runtimes.toList(),
      instances: instances,
    );
    final http = PublicGatewayServer(
      routes: routes,
      jevModels: controller.models,
      port: 0,
    );
    final mcp = CouncilMcpServer(controller: controller, port: 0);
    await http.start();
    await mcp.start();
    addTearDown(() async {
      await http.stop();
      http.close();
      routes.close();
      await mcp.stop();
      mcp.close();
    });
    final client = await _connect(mcp.endpoint!);
    addTearDown(client.close);
    final args = {
      'model': 'committee',
      'state': 'Choose',
      'questions': {
        'pick': {
          'type': 'choice',
          'instructions': 'Pick',
          'criteria': {'a': 'A', 'b': 'B'},
        },
      },
    };
    runtime.io.requests.clear();
    final (status, body) = await _http(
      http.baseUrl!.resolve('/v1/systemone'),
      args,
    );
    final rpc = await client.callTool(
      CallToolRequest(name: CouncilMcpServer.batchToolName, arguments: args),
    );
    expect(status, 200);
    expect(rpc.isError, isNot(true));
    expect(rpc.structuredContent, body);
    expect(body['council']['status'], 'partial');
    final members = body['council']['members'] as List;
    expect(members, hasLength(2));
    expect(
      members.singleWhere(
        (member) => member['instance_id'] == first.id,
      )['status'],
      'ok',
    );
    expect(
      members.singleWhere(
        (member) => member['instance_id'] == second.id,
      )['status'],
      'not_ready',
    );
    expect(body['usage'], {'input_tokens': 10, 'output_tokens': 0});
    expect(runtime.io.requests.map((request) => request['model']).toSet(), {
      run.id,
    });
    await instances.stop(first.id);
  });
  test('MCP direct instance calls remain available outside unconfigured scenario discovery', () async {
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
    final definition = await instances.save(
      name: 'My instance',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final controller = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
    );
    addTearDown(controller.close);
    final server = CouncilMcpServer(controller: controller, port: 0);
    addTearDown(server.close);
    await server.start();
    final client = await _connect(server.endpoint!);
    addTearDown(client.close);
    Future<CallToolResult> call(String model) => client.callTool(
      CallToolRequest(
        name: CouncilMcpServer.batchToolName,
        arguments: {
          'model': model,
          'state': 'A choice',
          'questions': {
            'pick': {
              'type': 'choice',
              'instructions': 'Choose an action.',
              'criteria': {'accept': 'Accept', 'reject': 'Reject'},
            },
          },
        },
      ),
    );
    final cold = await call(definition.publicName);
    expect(cold.isError, isTrue);
    expect(cold.structuredContent!['error']['code'], 'model_not_ready');
    expect(instances.runsFor(definition.id), isEmpty);
    await instances.start(definition.id);
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: runtime.catalog.runtimes.toList(),
      instances: instances,
    );
    final gateway = PublicGatewayServer(
      routes: routes,
      jevModels: controller.models,
      port: 0,
    );
    await gateway.start();
    addTearDown(() async {
      await gateway.stop();
      gateway.close();
      routes.close();
    });
    final (status, listing) = await _http(
      gateway.baseUrl!.resolve('/v1/models'),
      null,
      method: 'GET',
    );
    expect(status, 200);
    expect(
      (listing['data'] as List).where(
        (row) => row['id'] == definition.publicName,
      ),
      hasLength(1),
    );
    final discovery = await client.callTool(
      CallToolRequest(name: CouncilMcpServer.discoveryToolName, arguments: {}),
    );
    expect(discovery.structuredContent!['data'], isEmpty);
    final response = await call(definition.publicName);
    expect(response.isError, isNot(true));
    expect(response.structuredContent!['model'], 'kev-q8-0');
    expect(response.structuredContent!['answers'], contains('pick'));
    await instances.renamePublicName(definition.id, 'fast');
    expect(
      (await call(definition.publicName)).structuredContent!['error']['code'],
      'model_not_found',
    );
    expect((await call('fast')).structuredContent!['model'], 'fast');
  });
  test('generated Codex budget follows the longest saved council timeout with buffer', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: bindings,
        timeout: const Duration(milliseconds: 60100),
      ),
    );
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    expect(server.codexConfig, contains('tool_timeout_sec = 71'));
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: bindings,
        timeout: const Duration(seconds: 60),
      ),
      replacing: 'hard',
    );
    expect(server.codexConfig, contains('tool_timeout_sec = 70'));
    await council.models.delete('hard');
    expect(server.codexConfig, contains('tool_timeout_sec = 20'));
  });

  test('emitted Codex config enables decision and discovery tools at the actual listener', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    expect(server.codexConfig, isEmpty);
    final running = server.changes.firstWhere(
      (s) => s.status == CouncilMcpStatus.running,
    );
    await server.start();
    expect((await running).endpoint, server.endpoint);
    expect(
      server.codexConfig,
      '[mcp_servers.ghostmodeldeck]\nurl = "${server.endpoint}"\nenabled = true\nenabled_tools = ["decide_jev", "decide_jev_batch", "list_jev_models"]\nstartup_timeout_sec = 10\ntool_timeout_sec = 20',
    );
    final client = await _connect(server.endpoint!);
    addTearDown(client.close);
    expect(
      (await client.listTools()).tools.map((tool) => tool.name),
      containsAll(['decide_jev', 'decide_jev_batch']),
    );
    await server.stop();
    expect(server.codexConfig, isEmpty);
  });
  test(
    'MCP discovers typed batches and renders the shared standard mixed result',
    () async {
      final runtime = await CouncilRuntime.create();
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      council.selectSeats(council.availableSeats.map((s) => s.id));
      await council.models.save(
        JevModelDefinition.council(
          name: 'test-council',
          seats: council.models.availableBindings,
          timeout: const Duration(seconds: 10),
        ),
      );
      final server = CouncilMcpServer(controller: council, port: 0);
      addTearDown(server.close);
      await server.start();
      final client = await _connect(server.endpoint!);
      addTearDown(client.close);
      final tools = (await client.listTools()).tools;
      expect(tools.map((t) => t.name), contains('decide_jev_batch'));
      final questions = {
        'rank': {
          'type': 'score',
          'instructions': 'Rank',
          'criteria': ['Low', 'High'],
        },
        'valid': {
          'type': 'noul',
          'instructions': 'Valid',
          'criteria': {'false': 'False', 'true': 'True'},
        },
        'route': {
          'type': 'choice',
          'instructions': 'Route',
          'criteria': {'a': 'A', 'b': 'B'},
        },
      };
      final result = await client.callTool(
        CallToolRequest(
          name: 'decide_jev_batch',
          arguments: {
            'model': 'test-council',
            'state': 'same',
            'questions': questions,
          },
        ),
      );
      final dto = result.structuredContent!;
      expect(
        dto,
        council.state.lastBatchResult!.standardResult('test-council'),
      );
      expect(jsonDecode((result.content.single as TextContent).text), dto);
      expect(dto['answers']['rank']['score'], 0.75);
      expect(dto['answers']['valid'], {'type': 'noul', 'noul': 0.8});
      expect(dto['answers']['route']['choice'], 'b');
      expect(dto.keys, ['model', 'answers', 'usage']);
      for (final bad in [
        {
          'model': 'test-council',
          'state': 'same',
          'questions': questions,
          'stream': true,
        },
        {
          'model': 'test-council',
          'state': 'same',
          'questions': {
            'bad': {
              'type': 'score',
              'instructions': 'Rank',
              'criteria': ['Only'],
            },
          },
        },
        {
          'model': 'test-council',
          'state': 'same',
          'questions': {},
          'options': [],
        },
      ]) {
        final failure = await client.callTool(
          CallToolRequest(
            name: 'decide_jev_batch',
            arguments: {'model': 'test-council', ...bad},
          ),
        );
        expect(failure.isError, isTrue);
        expect(failure.structuredContent!['error']['code'], 'invalid_input');
        expect(failure.structuredContent!.containsKey('answers'), isFalse);
        expect(
          jsonDecode((failure.content.single as TextContent).text),
          failure.structuredContent,
        );
      }
    },
  );

  test('an occupied configured port fails explicitly and retries that exact address after release', () async {
    final runtime = await CouncilRuntime.create(modelCount: 0);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = occupied.port;
    final server = CouncilMcpServer(controller: council, port: port);
    addTearDown(server.close);
    await expectLater(server.start(), throwsA(isA<SocketException>()));
    expect(server.state.status, CouncilMcpStatus.failed);
    expect(server.endpoint, isNull);
    expect(server.state.error, contains('SocketException'));
    await occupied.close(force: true);
    await server.start();
    expect(server.endpoint!.port, port);
    final client = await _connect(server.endpoint!);
    addTearDown(client.close);
    expect(
      (await client.listTools()).tools
          .singleWhere((tool) => tool.name == 'decide_jev')
          .name,
      'decide_jev',
    );
  });
  test('exact Host and Origin checks cover POST and preflight while malformed RPC stays a protocol error', () async {
    final runtime = await CouncilRuntime.create(modelCount: 0);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    final endpoint = server.endpoint!;
    final badHeaders = [
      {'Host': 'evil.example:${endpoint.port}'},
      {'Host': '127.0.0.1:${endpoint.port + 1}'},
      {'Origin': 'https://evil.example'},
      {'Origin': 'http://127.0.0.1:${endpoint.port + 1}'},
      {'Origin': 'null'},
    ];
    for (final method in ['POST', 'OPTIONS']) {
      for (final headers in badHeaders) {
        expect(
          (await _http(endpoint, {}, method: method, headers: headers)).$1,
          HttpStatus.forbidden,
        );
      }
    }
    expect(
      (await _http(
        endpoint,
        {},
        method: 'OPTIONS',
        headers: {'Origin': 'http://${endpoint.authority}'},
      )).$1,
      HttpStatus.noContent,
    );
    final malformed = await _http(endpoint, '{broken-json');
    expect(malformed.$2['error']['code'], -32700);
    final unknown = await _http(
      endpoint,
      JsonRpcRequest(
        id: 7,
        method: 'unknown/method',
        params: {},
        meta: buildProtocolRequestMeta(
          protocolVersion: '2026-07-28',
          clientCapabilities: const ClientCapabilities(),
        ),
      ).toJson(),
      headers: {
        'MCP-Protocol-Version': '2026-07-28',
        'Mcp-Method': 'unknown/method',
      },
    );
    expect(unknown.$2['error']['code'], -32601, reason: unknown.$2.toString());
    final badMeta = await _http(endpoint, {
      'jsonrpc': '2.0',
      'id': 8,
      'method': 'tools/list',
      'params': {
        '_meta': {McpMetaKey.protocolVersion: 1},
      },
    });
    expect(badMeta.$2['error']['code'], -32600);
    expect(runtime.engine.state.instances, isEmpty);
  });
  test('stopping MCP drains only its own consultation and preserves desktop work and resident engines', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    await council.models.save(
      JevModelDefinition.council(
        name: 'test-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    final client = await _connect(server.endpoint!);
    addTearDown(client.close);
    final arrived = Completer<void>(),
        desktopRelease = Completer<void>(),
        mcpRelease = Completer<void>();
    var count = 0;
    runtime.io.respond = (request, response) async {
      if (++count == 4) arrived.complete();
      await (request['state'] == 'desktop'
          ? desktopRelease.future
          : mcpRelease.future);
      return response;
    };
    final desktop = council.consult(
      state: 'desktop',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    final rpc = client
        .callTool(
          CallToolRequest(
            name: 'decide_jev',
            arguments: {
              'model': 'test-council',
              'state': 'mcp',
              'options': [
                {'id': 'accept', 'text': '接受'},
                {'id': 'reject', 'text': '拒绝'},
              ],
            },
          ),
        )
        .then<Object>((result) => result, onError: (Object error) => error);
    await arrived.future.timeout(const Duration(seconds: 3));
    await server.stop().timeout(const Duration(seconds: 3));
    expect(server.state.status, CouncilMcpStatus.stopped);
    expect(server.state.activeRequests, 0);
    expect(server.endpoint, isNull);
    expect(council.state.busy, isTrue);
    expect(runtime.io.killedChildren, 0);
    final stoppedRpc = await rpc.timeout(const Duration(seconds: 3));
    if (stoppedRpc is CallToolResult) {
      expect(stoppedRpc.isError, true);
      expect(stoppedRpc.structuredContent!.containsKey('answers'), false);
    }
    desktopRelease.complete();
    final result = await desktop.timeout(const Duration(seconds: 3));
    expect(result.scope, CouncilScope.ensemble);
    expect(result.status, CouncilStatus.ok);
    mcpRelease.complete();
    expect(council.state.lastResult, same(result));
    expect(runtime.io.killedChildren, 0);
    await server.start();
    final reconnected = await _connect(server.endpoint!);
    addTearDown(reconnected.close);
    expect(
      (await reconnected.listTools()).tools
          .singleWhere((tool) => tool.name == 'decide_jev')
          .name,
      'decide_jev',
    );
  });
  test('SDK cancellation aborts only its own consultation while a peer client continues with the same PIDs', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    await council.models.save(
      JevModelDefinition.council(
        name: 'test-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    final a = await _connect(server.endpoint!);
    final b = await _connect(server.endpoint!, protocol: McpProtocol.legacy);
    addTearDown(a.close);
    addTearDown(b.close);
    final pids = runtime.engine.state.instances
        .map((instance) => instance.pid)
        .toList();
    final arrived = Completer<void>(),
        releaseA = Completer<void>(),
        releaseB = Completer<void>();
    var count = 0;
    runtime.io.respond = (request, response) async {
      if (++count == 4) arrived.complete();
      await (request['state'] == 'cancel' ? releaseA.future : releaseB.future);
      return response;
    };
    final abort = BasicAbortController();
    CallToolRequest input(String state) => CallToolRequest(
      name: 'decide_jev',
      arguments: {
        'model': 'test-council',
        'state': state,
        if (state == 'cancel') 'debug': true,
        'options': [
          {'id': 'accept', 'text': '接受'},
          {'id': 'reject', 'text': '拒绝'},
        ],
      },
    );
    final pending = a.callTool(
      input('cancel'),
      options: RequestOptions(signal: abort.signal),
    );
    final cancelled = expectLater(pending, throwsA(isA<AbortError>()));
    final peer = b.callTool(input('peer'));
    await arrived.future.timeout(const Duration(seconds: 3));
    final oneActive = server.changes.firstWhere(
      (state) => state.activeRequests == 1,
    );
    abort.abort();
    await cancelled;
    await oneActive.timeout(const Duration(seconds: 3));
    expect(runtime.io.killedChildren, 0);
    releaseB.complete();
    final result = await peer.timeout(const Duration(seconds: 3));
    expect(result.structuredContent!['model'], 'test-council');
    expect(result.structuredContent!.containsKey('debug'), false);
    expect(result.structuredContent!['usage']['input_tokens'], 20);
    releaseA.complete();
    runtime.io.respond = null;
    expect(
      (await b.callTool(input('next'))).structuredContent!['model'],
      'test-council',
    );
    expect(
      runtime.engine.state.instances.map((instance) => instance.pid),
      pids,
    );
    expect(runtime.io.killedChildren, 0);
  });
  test('the actual Codex protocol profile preserves full, single and zero-seat standard results through the SDK', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    await council.models.save(
      JevModelDefinition.council(
        name: 'test-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    final events = <Map<String, Object?>>[];
    final server = CouncilMcpServer(
      controller: council,
      port: 0,
      observer: events.add,
    );
    addTearDown(server.close);
    await server.start();
    final client = await _connect(
      server.endpoint!,
      protocol: McpProtocol.legacy,
      protocolVersion: '2025-06-18',
    );
    addTearDown(client.close);
    await client.listTools();
    CallToolRequest input() => CallToolRequest(
      name: 'decide_jev',
      arguments: {
        'model': 'test-council',
        'state': '旧版协议验收',
        'options': [
          {'id': 'accept', 'text': '接受'},
          {'id': 'reject', 'text': '拒绝'},
        ],
      },
    );
    final full = await client.callTool(input());
    expect(full.isError, isFalse);
    expect(full.structuredContent!['model'], 'test-council');
    expect(
      full.structuredContent!['answers']['council_choice']['probabilities'],
      {'accept': 0.5, 'reject': 0.5},
    );
    expect(
      jsonDecode((full.content.single as TextContent).text),
      full.structuredContent,
    );
    final ids = runtime.engine.state.instances
        .map((instance) => instance.id)
        .toList();
    await runtime.engine.stop(ids.first);
    final single = await client.callTool(input());
    expect(single.isError, isFalse);
    expect(single.structuredContent!['usage'], {
      'input_tokens': 10,
      'output_tokens': 0,
    });
    expect(single.structuredContent!.containsKey('debug'), isFalse);
    expect(
      jsonDecode((single.content.single as TextContent).text),
      single.structuredContent,
    );
    await runtime.engine.stop(ids.last);
    final none = await client.callTool(input());
    expect(none.isError, isTrue);
    expect(none.structuredContent!['error']['code'], 'no_successful_seats');
    expect(none.structuredContent!.containsKey('answers'), isFalse);
    expect(
      jsonDecode((none.content.single as TextContent).text),
      none.structuredContent,
    );
    final invalid = await client.callTool(
      CallToolRequest(
        name: 'decide_jev',
        arguments: {'model': 'test-council', 'state': 1},
      ),
    );
    expect(invalid.isError, isTrue);
    expect(invalid.structuredContent!['error']['code'], 'invalid_input');
    expect(
      events
          .where((event) => event['kind'] == 'consultation')
          .map((event) => event['protocol_version'])
          .toSet(),
      {'2025-06-18'},
    );
  });
  test('invalid business inputs return complete structured errors in both protocol eras without model requests', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    await council.models.save(
      JevModelDefinition.council(
        name: 'test-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    final validOptions = [
      {'id': 'accept', 'text': '接受'},
      {'id': 'reject', 'text': '拒绝'},
    ];
    final bad = <Map<String, dynamic>>[
      {},
      {'model': 'test-council', 'state': null, 'options': validOptions},
      {'model': 'test-council', 'state': '', 'options': 'not-a-list'},
      {
        'model': 'test-council',
        'state': '',
        'options': [
          {'id': 'same', 'text': '一'},
          {'id': 'same', 'text': '二'},
        ],
      },
      {
        'model': 'test-council',
        'state': '',
        'options': [
          {'id': ' ', 'text': '一'},
          {'id': 'reject', 'text': '二'},
        ],
      },
      {'model': 'test-council', 'state': '', 'options': []},
      {
        'model': 'test-council',
        'state': '',
        'options': [
          {'id': 'accept'},
        ],
      },
      {
        'model': 'test-council',
        'state': '',
        'options': [1, 2],
      },
      {
        'model': 'test-council',
        'state': '',
        'options': validOptions,
        'execute': true,
      },
    ];
    for (final protocol in [McpProtocol.stable, McpProtocol.legacy]) {
      final client = await _connect(server.endpoint!, protocol: protocol);
      addTearDown(client.close);
      for (final args in bad) {
        final result = await client.callTool(
          CallToolRequest(
            name: 'decide_jev',
            arguments: {'model': 'test-council', ...args},
          ),
        );
        expect(result.isError, isTrue);
        final payload = result.structuredContent!;
        expect(payload['error']['code'], 'invalid_input');
        expect(payload.keys, ['error']);
        expect(
          jsonDecode((result.content.single as TextContent).text),
          payload,
        );
      }
      await expectLater(
        client.callTool(CallToolRequest(name: 'unknown-tool')),
        throwsA(isA<McpError>()),
      );
    }
    expect(runtime.io.requests, isEmpty);
    expect(runtime.io.killedChildren, 0);
  });
  test('the public HTTP listener bounds both declared and chunked request bodies before RPC processing', () async {
    final runtime = await CouncilRuntime.create(modelCount: 0);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final bytes = utf8.encode(jsonEncode({'padding': 'x' * (1024 * 1024 + 1)}));
    for (final chunked in [false, true]) {
      final request = await http.postUrl(server.endpoint!);
      request.headers.contentType = ContentType.json;
      if (!chunked) request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      expect(
        response.statusCode,
        HttpStatus.requestEntityTooLarge,
        reason: chunked ? 'chunked' : 'content-length',
      );
      await response.drain<void>();
    }
    final client = await _connect(server.endpoint!);
    addTearDown(client.close);
    expect(
      (await client.listTools()).tools
          .singleWhere((tool) => tool.name == 'decide_jev')
          .name,
      'decide_jev',
    );
    expect(runtime.engine.state.instances, isEmpty);
  });
  test('modern and legacy SDK clients share the same ready seats and receive identical structured and text results', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    await council.models.save(
      JevModelDefinition.council(
        name: 'test-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    final events = <Map<String, Object?>>[];
    final server = CouncilMcpServer(
      controller: council,
      port: 0,
      observer: events.add,
    );
    addTearDown(server.close);
    await server.start();
    final modern = await _connect(server.endpoint!);
    final legacy = await _connect(
      server.endpoint!,
      protocol: McpProtocol.legacy,
    );
    addTearDown(modern.close);
    addTearDown(legacy.close);
    await modern.listTools();
    await legacy.listTools();
    final ids = runtime.engine.state.instances
        .map((instance) => instance.id)
        .toList();
    final arrived = Completer<void>(), release = Completer<void>();
    var count = 0;
    runtime.io.respond = (request, response) async {
      if (++count == 4) arrived.complete();
      await release.future;
      return response;
    };
    CallToolRequest input(String state) => CallToolRequest(
      name: 'decide_jev',
      arguments: {
        'model': 'test-council',
        'state': state,
        'options': [
          {'id': 'accept', 'text': '接受'},
          {'id': 'reject', 'text': '拒绝'},
        ],
      },
    );
    final a = modern.callTool(input('modern'));
    final b = legacy.callTool(input('legacy'));
    await arrived.future.timeout(const Duration(seconds: 3));
    release.complete();
    for (final result in await Future.wait([a, b])) {
      expect(result.isError, isFalse);
      final payload = result.structuredContent!;
      expect(payload['model'], 'test-council');
      expect(payload['answers']['council_choice']['probabilities'], {
        'accept': 0.5,
        'reject': 0.5,
      });
      expect(jsonDecode((result.content.single as TextContent).text), payload);
      expect(
        runtime.io.requests
            .where((r) => r['state'] == 'modern')
            .map((r) => r['model']),
        containsAll(ids),
      );
      expect(
        runtime.io.requests
            .where((r) => r['state'] == 'legacy')
            .map((r) => r['model']),
        containsAll(ids),
      );
      expect(payload.keys, ['model', 'answers', 'usage']);
    }
    final consultationEvents = events
        .where((event) => event['kind'] == 'consultation')
        .toList();
    expect(
      consultationEvents.map((event) => event['protocol_version']).toSet(),
      {'2026-07-28', '2025-11-25'},
    );
    expect(
      events.every(
        (event) => !event.containsKey('state') && !event.containsKey('options'),
      ),
      isTrue,
    );
    await modern.close();
    final afterDisconnect = await legacy.callTool(input('still-resident'));
    expect(afterDisconnect.structuredContent!['model'], 'test-council');
    expect(runtime.engine.state.instances.map((instance) => instance.id), ids);
    expect(runtime.io.killedChildren, 0);
  });
  test(
    'the real MCP SDK discovers a council tool before any model is loaded',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 0);
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      final server = CouncilMcpServer(controller: council, port: 0);
      addTearDown(server.close);
      await server.start();
      final client = await _connect(server.endpoint!);
      addTearDown(client.close);
      final discovered = await client.listTools();
      expect(
        discovered.tools.singleWhere((tool) => tool.name == 'decide_jev').name,
        'decide_jev',
      );
      expect(
        discovered.tools
            .singleWhere((tool) => tool.name == 'decide_jev')
            .inputSchema
            .toJson()['required'],
        ['model', 'state', 'options'],
      );
      expect(discovered.tools.map((t) => t.name), contains('list_jev_models'));
      final result = await client.callTool(
        CallToolRequest(
          name: 'decide_jev',
          arguments: {
            'model': 'test-council',
            'state': '没有运行模型',
            'options': [
              {'id': 'accept', 'text': '接受'},
              {'id': 'reject', 'text': '拒绝'},
            ],
          },
        ),
      );
      expect(result.isError, isTrue);
      expect(result.structuredContent!['error']['code'], 'model_not_found');
      expect(result.structuredContent!.containsKey('answers'), isFalse);
      expect(
        jsonDecode((result.content.single as TextContent).text),
        result.structuredContent,
      );
      expect(runtime.engine.state.instances, isEmpty);
      expect(server.state.status, CouncilMcpStatus.running);
    },
  );
}
