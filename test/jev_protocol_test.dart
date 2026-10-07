import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('real HTTP and MCP require model and route the same standard mixed result and discovery', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
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
    addTearDown(routes.close);
    final http = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    addTearDown(http.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await http.start();
    await mcp.start();
    final client = McpClient(
      const Implementation(name: 'named-model-test', version: '1'),
    );
    addTearDown(client.close);
    await client.connect(StreamableHttpClientTransport(mcp.endpoint!));
    final tools = (await client.listTools()).tools;
    expect(tools.map((t) => t.name).toSet(), {
      'decide_jev',
      'decide_jev_batch',
      'list_jev_models',
    });
    expect(
      mcp.codexConfig,
      contains('"decide_jev", "decide_jev_batch", "list_jev_models"'),
    );
    for (final name in ['decide_jev', 'decide_jev_batch']) {
      expect(
        tools
            .singleWhere((t) => t.name == name)
            .inputSchema
            .toJson()['required'],
        contains('model'),
      );
    }
    final questions = {
      'route': {
        'type': 'choice',
        'instructions': 'Choose',
        'criteria': {'a': 'A', 'b': 'B'},
      },
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
    };
    for (final name in ['quick', 'hard', 'native-kev']) {
      final args = {'model': name, 'state': 'same', 'questions': questions};
      final wire = await post(http.baseUrl!.resolve('/v1/systemone'), args);
      final rpc = await client.callTool(
        CallToolRequest(name: 'decide_jev_batch', arguments: args),
      );
      expect(wire.$1, 200);
      expect(rpc.isError, isNot(true));
      expect(rpc.structuredContent, wire.$2);
      expect(jsonDecode((rpc.content.single as TextContent).text), wire.$2);
      expect((wire.$2 as Map).keys, ['model', 'answers', 'usage']);
      expect(wire.$2['model'], name);
      expect(wire.$2['usage'], {
        'input_tokens': name == 'hard' ? 20 : 10,
        'output_tokens': 0,
      });
    }
    final discovered = await client.callTool(
      CallToolRequest(name: 'list_jev_models', arguments: {}),
    );
    final listed = await get(http.baseUrl!.resolve('/v1/models'));
    expect(discovered.structuredContent!['data'], [
      {'id': 'quick', 'source': 'council'},
      {'id': 'hard', 'source': 'council'},
      {'id': 'native-kev', 'source': 'native'},
    ]);
    expect(
      (listed.$2 as Map)['data']
          .map((m) => {'id': m['id'], 'source': m['source']})
          .toList(),
      discovered.structuredContent!['data'],
    );
    for (final args in [
      {'state': 'missing', 'questions': questions},
      {'model': 'unknown', 'state': 'unknown', 'questions': questions},
    ]) {
      final wire = await post(http.baseUrl!.resolve('/v1/systemone'), args);
      final rpc = await client.callTool(
        CallToolRequest(name: 'decide_jev_batch', arguments: args),
      );
      expect(wire.$1, args.containsKey('model') ? 404 : 400);
      expect(rpc.isError, true);
      expect(rpc.structuredContent, wire.$2);
      expect(wire.$2, isNot(contains('answers')));
    }
  });
  test('real HTTP and MCP enforce batch capabilities while a valid council peer remains available', () async {
    final io = CouncilRuntimeIO()..failScoreForOther = true;
    final runtime = await CouncilRuntime.create(processIO: io);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final other = runtime.engine.state.instances.singleWhere(
      (i) => i.asset.files.first.path.contains('/Other/'),
    );
    final binding = council.models.availableBindings.singleWhere(
      (b) => b.artifactId == other.asset.id,
    );
    await council.models.save(
      JevModelDefinition.native(name: 'partial-native', binding: binding),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final routes = PublicModelRoutes(
      library: runtime.library,
      runtimes: [runtime.engine],
    );
    addTearDown(routes.close);
    final http = PublicGatewayServer(
      routes: routes,
      jevModels: council.models,
      port: 0,
    );
    addTearDown(http.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await http.start();
    await mcp.start();
    final client = McpClient(
      const Implementation(name: 'capability-test', version: '1'),
    );
    addTearDown(client.close);
    await client.connect(StreamableHttpClientTransport(mcp.endpoint!));
    final questions = {
      'pick': {
        'type': 'choice',
        'instructions': 'Choose',
        'criteria': {'a': 'A', 'b': 'B'},
      },
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
    };
    final nativeArgs = {
      'model': 'partial-native',
      'state': 'mixed',
      'questions': questions,
    };
    io.requests.clear();
    final failure = await post(
      http.baseUrl!.resolve('/v1/systemone'),
      nativeArgs,
    );
    final rpcFailure = await client.callTool(
      CallToolRequest(name: 'decide_jev_batch', arguments: nativeArgs),
    );
    expect(failure.$1, 409);
    expect(failure.$2['error']['code'], 'capability_mismatch');
    expect(rpcFailure.isError, true);
    expect(rpcFailure.structuredContent, failure.$2);
    expect((failure.$2 as Map).containsKey('answers'), false);
    expect(io.requests, isEmpty);
    final councilArgs = {
      'model': 'hard',
      'state': 'mixed',
      'questions': questions,
    };
    final partial = await post(
      http.baseUrl!.resolve('/v1/systemone'),
      councilArgs,
    );
    final rpcPartial = await client.callTool(
      CallToolRequest(name: 'decide_jev_batch', arguments: councilArgs),
    );
    expect(partial.$1, 200);
    expect(rpcPartial.isError, isNot(true));
    expect(rpcPartial.structuredContent, partial.$2);
    expect(partial.$2['usage'], {'input_tokens': 10, 'output_tokens': 0});
    expect(io.requests.map((r) => r['model']), isNot(contains(other.id)));
    final discovery = await client.callTool(
      CallToolRequest(name: 'list_jev_models', arguments: {}),
    );
    expect(discovery.structuredContent!['data'], [
      {'id': 'partial-native', 'source': 'native'},
      {'id': 'hard', 'source': 'council'},
    ]);
    final choiceOnly = await post(http.baseUrl!.resolve('/v1/systemone'), {
      'model': 'partial-native',
      'state': 'choice',
      'questions': {'pick': questions['pick']},
    });
    expect(choiceOnly.$1, 200);
    expect(choiceOnly.$2['model'], 'partial-native');
    expect(choiceOnly.$2['answers']['pick']['choice'], 'b');
    expect(choiceOnly.$2['usage'], {'input_tokens': 10, 'output_tokens': 0});
    expect(
      runtime.engine.state.instances.where((i) => i.activeRequests != 0),
      isEmpty,
    );
    expect(io.killedChildren, 0);
  });
}

Future<(int, dynamic)> post(Uri url, Object body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join()),
    );
  } finally {
    client.close(force: true);
  }
}

Future<(int, dynamic)> get(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join()),
    );
  } finally {
    client.close(force: true);
  }
}
