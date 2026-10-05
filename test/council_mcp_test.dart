import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
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
    expect((await client.listTools()).tools.single.name, 'consult_jev_council');
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
            name: 'consult_jev_council',
            arguments: {
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
      expect(stoppedRpc.structuredContent!['scope'], 'none');
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
      (await reconnected.listTools()).tools.single.name,
      'consult_jev_council',
    );
  });
  test('SDK cancellation aborts only its own consultation while a peer client continues with the same PIDs', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
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
      name: 'consult_jev_council',
      arguments: {
        'state': state,
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
    expect(result.structuredContent!['scope'], 'ensemble');
    expect(result.structuredContent!['status'], 'ok');
    releaseA.complete();
    runtime.io.respond = null;
    expect(
      (await b.callTool(input('next'))).structuredContent!['scope'],
      'ensemble',
    );
    expect(
      runtime.engine.state.instances.map((instance) => instance.pid),
      pids,
    );
    expect(runtime.io.killedChildren, 0);
  });
  test('the actual Codex protocol profile preserves full, single and zero-seat results through the SDK', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
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
      name: 'consult_jev_council',
      arguments: {
        'state': '旧版协议验收',
        'options': [
          {'id': 'accept', 'text': '接受'},
          {'id': 'reject', 'text': '拒绝'},
        ],
      },
    );
    final full = await client.callTool(input());
    expect(full.isError, isFalse);
    expect(full.structuredContent!['scope'], 'ensemble');
    expect(full.structuredContent!['aggregate_scores'], {
      'accept': 0.5,
      'reject': 0.5,
    });
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
    expect(single.structuredContent!['status'], 'partial');
    expect(single.structuredContent!['scope'], 'single_model');
    expect(single.structuredContent!['aggregate_scores'], isNull);
    expect(single.structuredContent!['votes'], isNull);
    expect(
      (single.structuredContent!['seats'] as List).map(
        (seat) => seat['status'],
      ),
      contains('not_ready'),
    );
    expect(
      jsonDecode((single.content.single as TextContent).text),
      single.structuredContent,
    );
    await runtime.engine.stop(ids.last);
    final none = await client.callTool(input());
    expect(none.isError, isTrue);
    expect(none.structuredContent!['status'], 'failed');
    expect(none.structuredContent!['scope'], 'none');
    expect(none.structuredContent!['aggregate_scores'], isNull);
    expect(
      jsonDecode((none.content.single as TextContent).text),
      none.structuredContent,
    );
    final invalid = await client.callTool(
      CallToolRequest(name: 'consult_jev_council', arguments: {'state': 1}),
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
    final server = CouncilMcpServer(controller: council, port: 0);
    addTearDown(server.close);
    await server.start();
    final validOptions = [
      {'id': 'accept', 'text': '接受'},
      {'id': 'reject', 'text': '拒绝'},
    ];
    final bad = <Map<String, dynamic>>[
      {},
      {'state': 9, 'options': validOptions},
      {'state': '', 'options': 'not-a-list'},
      {
        'state': '',
        'options': [
          {'id': 'same', 'text': '一'},
          {'id': 'same', 'text': '二'},
        ],
      },
      {
        'state': '',
        'options': [
          {'id': ' ', 'text': '一'},
          {'id': 'reject', 'text': '二'},
        ],
      },
      {
        'state': '',
        'options': [
          {'id': 'accept', 'text': ' '},
          {'id': 'reject', 'text': '二'},
        ],
      },
      {
        'state': '',
        'options': [
          {'id': 'accept'},
        ],
      },
      {
        'state': '',
        'options': [1, 2],
      },
      {'state': '', 'options': validOptions, 'execute': true},
    ];
    for (final protocol in [McpProtocol.stable, McpProtocol.legacy]) {
      final client = await _connect(server.endpoint!, protocol: protocol);
      addTearDown(client.close);
      for (final args in bad) {
        final result = await client.callTool(
          CallToolRequest(name: 'consult_jev_council', arguments: args),
        );
        expect(result.isError, isTrue);
        final payload = result.structuredContent!;
        expect(payload['schema_version'], 1);
        expect(payload['status'], 'failed');
        expect(payload['scope'], 'none');
        expect(payload['error']['code'], 'invalid_input');
        expect(payload['seats'], isEmpty);
        expect(payload['aggregate_scores'], isNull);
        expect(payload['top_choices'], isNull);
        expect(payload['votes'], isNull);
        expect(payload['disagreement'], isNull);
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
    expect((await client.listTools()).tools.single.name, 'consult_jev_council');
    expect(runtime.engine.state.instances, isEmpty);
  });
  test('modern and legacy SDK clients share the same ready seats and receive identical structured and text results', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
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
      name: 'consult_jev_council',
      arguments: {
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
      expect(payload['scope'], 'ensemble');
      expect(payload['status'], 'ok');
      expect(payload['aggregate_scores'], {'accept': 0.5, 'reject': 0.5});
      expect(jsonDecode((result.content.single as TextContent).text), payload);
      expect(
        (payload['seats'] as List).map((seat) => seat['instance']['id']),
        ids,
      );
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
    expect(afterDisconnect.structuredContent!['scope'], 'ensemble');
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
      expect(discovered.tools.single.name, 'consult_jev_council');
      expect(discovered.tools.single.inputSchema.toJson()['required'], [
        'state',
        'options',
      ]);
      expect(
        discovered.tools.single.outputSchema!.toJson()['required'],
        containsAll([
          'schema_version',
          'request_id',
          'status',
          'scope',
          'seats',
          'aggregate_scores',
          'votes',
          'disagreement',
        ]),
      );
      final result = await client.callTool(
        CallToolRequest(
          name: 'consult_jev_council',
          arguments: {
            'state': '没有运行模型',
            'options': [
              {'id': 'accept', 'text': '接受'},
              {'id': 'reject', 'text': '拒绝'},
            ],
          },
        ),
      );
      expect(result.isError, isTrue);
      expect(result.structuredContent!['status'], 'failed');
      expect(result.structuredContent!['scope'], 'none');
      expect(
        jsonDecode((result.content.single as TextContent).text),
        result.structuredContent,
      );
      expect(runtime.engine.state.instances, isEmpty);
      expect(server.state.status, CouncilMcpStatus.running);
    },
  );
}
