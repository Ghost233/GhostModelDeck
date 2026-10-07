import 'dart:async';
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
  test('real HTTP and both MCP tools project per-call debug for both sources and errors', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final file = File('${runtime.root.path}/private/models.json');
    final council = CouncilController(
      catalog: runtime.catalog,
      modelRegistryFile: file,
    );
    addTearDown(council.close);
    final binding = council.models.availableBindings.single;
    await council.models.save(
      JevModelDefinition.native(name: 'native', binding: binding),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [binding],
        timeout: const Duration(seconds: 2),
      ),
    );
    final stored = await file.readAsString();
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
      const Implementation(name: 'call-debug-test', version: '1'),
    );
    addTearDown(client.close);
    await client.connect(StreamableHttpClientTransport(mcp.endpoint!));
    runtime.io.respond = (body, raw) async => jsonEncode({
      ...jsonDecode(raw) as Map,
      'marker': body['state'],
      'diagnostic': {
        'Authorization': 'Bearer protocol-api-secret',
        'Cookie': 'sid=protocol-cookie-secret',
      },
      'echo': 'protocol-api-secret',
    });
    for (final name in ['quick', 'native']) {
      for (final tool in ['decide_jev_batch', 'decide_jev']) {
        for (final debug in [null, false, true]) {
          final marker = '$name-$tool-$debug';
          final single = tool == 'decide_jev';
          final question = {
            'type': 'choice',
            'instructions': 'Choose',
            'criteria': single
                ? {'accept': 'Accept', 'reject': 'Reject'}
                : {'a': 'A', 'b': 'B'},
          };
          final body = <String, Object?>{
            'model': name,
            'state': marker,
            'questions': {single ? 'council_choice' : 'pick': question},
            'debug': ?debug,
          };
          final args = single
              ? <String, Object?>{
                  'model': name,
                  'state': marker,
                  'instructions': 'Choose',
                  'options': [
                    {'id': 'accept', 'text': 'Accept'},
                    {'id': 'reject', 'text': 'Reject'},
                  ],
                  'debug': ?debug,
                }
              : body;
          final wire = await post(http.baseUrl!.resolve('/v1/systemone'), body);
          final rpc = await client.callTool(
            CallToolRequest(name: tool, arguments: args),
          );
          expect(wire.$1, 200);
          expect(rpc.isError, isNot(true));
          final payload = rpc.structuredContent!;
          expect(jsonDecode((rpc.content.single as TextContent).text), payload);
          expect(
            {
              for (final e in payload.entries)
                if (e.key != 'debug') e.key: e.value,
            },
            {
              for (final e in wire.$2.entries)
                if (e.key != 'debug') e.key: e.value,
            },
          );
          for (final response in [wire.$2, payload]) {
            expect(response.containsKey('debug'), debug == true);
            if (debug != true) {
              expect(response.keys, ['model', 'answers', 'usage']);
              continue;
            }
            final trace = response['debug'] as Map;
            expect(trace['model'], name);
            expect(trace['source'], name == 'native' ? 'native' : 'council');
            expect(trace['configuration']['name'], name);
            expect(trace['input']['state'], marker);
            final io = name == 'native'
                ? trace['native'] as Map
                : (trace['seats'] as List).single as Map;
            expect(io['request']['state'], marker);
            expect((io['request'] as Map).containsKey('debug'), false);
            expect(jsonDecode(io['raw_response'] as String)['marker'], marker);
            expect(trace['converted_result'], {
              for (final e in response.entries)
                if (e.key != 'debug') e.key: e.value,
            });
            final serialized = jsonEncode(response);
            for (final secret in [
              'protocol-api-secret',
              'protocol-cookie-secret',
              'incoming-http-secret',
              'incoming-cookie-secret',
            ]) {
              expect(serialized, isNot(contains(secret)));
            }
          }
        }
      }
    }
    runtime.io.consultationStatus = 503;
    runtime.io.respond = (_, _) async =>
        'Authorization: Bearer protocol-error-secret';
    for (final name in ['quick', 'native']) {
      final body = {
        'model': name,
        'state': 'failure',
        'debug': true,
        'questions': {
          'pick': {
            'type': 'choice',
            'instructions': 'Choose',
            'criteria': {'a': 'A', 'b': 'B'},
          },
        },
      };
      final wire = await post(http.baseUrl!.resolve('/v1/systemone'), body);
      final rpc = await client.callTool(
        CallToolRequest(name: 'decide_jev_batch', arguments: body),
      );
      expect(wire.$1, 502);
      expect(rpc.isError, true);
      expect(
        jsonDecode((rpc.content.single as TextContent).text),
        rpc.structuredContent,
      );
      for (final response in [wire.$2, rpc.structuredContent!]) {
        expect(response.containsKey('answers'), false);
        expect(
          (response['error'] as Map)['code'],
          name == 'native' ? 'engine_error' : 'no_successful_seats',
        );
        final debug = response['debug'] as Map;
        expect(debug['converted_result'], {'error': response['error']});
        expect(jsonEncode(response), isNot(contains('protocol-error-secret')));
        final io = name == 'native'
            ? debug['native'] as Map
            : (debug['seats'] as List).single as Map;
        expect(io['raw_response'], contains('[redacted]'));
        expect(io['http_status'], 503);
      }
    }
    expect(await file.readAsString(), stored);
    expect(runtime.engine.state.instances.single.activeRequests, 0);
    expect(runtime.io.killedChildren, 0);
  });
  test('HTTP disconnect ends bounded work while a same-instance peer and later request succeed', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final binding = council.models.availableBindings.single;
    await council.models.save(
      JevModelDefinition.native(name: 'native', binding: binding),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [binding],
        timeout: const Duration(seconds: 1),
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
    await http.start();
    final pid = runtime.engine.state.instances.single.pid;
    for (final name in ['quick', 'native']) {
      final arrived = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      runtime.io.respond = (body, raw) async {
        if (body['state'] == 'disconnect-$name') {
          arrived.complete();
          await release.future;
        }
        return raw;
      };
      final body = {
        'model': name,
        'state': 'disconnect-$name',
        'debug': true,
        'questions': {
          'pick': {
            'type': 'choice',
            'instructions': 'Choose',
            'criteria': {'a': 'A', 'b': 'B'},
          },
        },
      };
      final encoded = utf8.encode(jsonEncode(body));
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        http.baseUrl!.port,
      );
      addTearDown(socket.destroy);
      socket.write(
        'POST /v1/systemone HTTP/1.1\r\nHost: 127.0.0.1:${http.baseUrl!.port}\r\nContent-Type: application/json\r\nContent-Length: ${encoded.length}\r\n\r\n',
      );
      socket.add(encoded);
      await socket.flush();
      await arrived.future.timeout(const Duration(seconds: 2));
      final drained = runtime.engine.changes.firstWhere(
        (s) => s.instances.single.activeRequests == 0,
      );
      socket.destroy();
      final peer = await post(http.baseUrl!.resolve('/v1/systemone'), {
        ...body,
        'state': 'peer-$name',
        'debug': false,
      });
      expect(peer.$1, 200);
      expect(peer.$2.keys, ['model', 'answers', 'usage']);
      await drained.timeout(const Duration(seconds: 12));
      release.complete();
      final next = await post(http.baseUrl!.resolve('/v1/systemone'), {
        ...body,
        'state': 'next-$name',
        'debug': false,
      });
      expect(next.$1, 200);
      expect(runtime.engine.state.instances.single.activeRequests, 0);
      expect(runtime.engine.state.instances.single.pid, pid);
      expect(runtime.io.killedChildren, 0);
    }
  });
}

Future<(int, Map<String, dynamic>)> post(
  Uri uri,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer incoming-http-secret',
    );
    request.headers.set(HttpHeaders.cookieHeader, 'sid=incoming-cookie-secret');
    request.write(jsonEncode(body));
    final response = await request.close();
    final raw = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    return (response.statusCode, Map<String, dynamic>.from(raw));
  } finally {
    client.close(force: true);
  }
}
