import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';

import 'council.dart';

enum CouncilMcpStatus { stopped, starting, running, stopping, failed }

class CouncilMcpState {
  const CouncilMcpState({
    required this.status,
    this.endpoint,
    this.error,
    this.activeRequests = 0,
  });
  final CouncilMcpStatus status;
  final Uri? endpoint;
  final String? error;
  final int activeRequests;
}

/// HTTP/session routing belongs here; the SDK owns the MCP protocol itself.
class CouncilMcpServer {
  CouncilMcpServer({
    required this.controller,
    this.port = 54842,
    this.observer,
  });
  static const toolName = 'consult_jev_council';
  final CouncilController controller;
  final int port;
  final void Function(Map<String, Object?> event)? observer;
  final _changes = StreamController<CouncilMcpState>.broadcast();
  final _sessions = <String, StreamableHTTPServerTransport>{};
  final _transports = <StreamableHTTPServerTransport>{};
  final _inflight = <DecisionCancellation, Future<CallToolResult>>{};
  HttpServer? _listener;
  CouncilMcpStatus _status = CouncilMcpStatus.stopped;
  String? _error;
  Future<void> _operations = Future.value();
  static final _protocolKey = Object();
  Uri? get endpoint => _listener == null
      ? null
      : Uri.parse('http://127.0.0.1:${_listener!.port}/mcp');
  Stream<CouncilMcpState> get changes => _changes.stream;
  CouncilMcpState get state => CouncilMcpState(
    status: _status,
    endpoint: endpoint,
    error: _error,
    activeRequests: _inflight.length,
  );
  String get codexConfig => endpoint == null
      ? ''
      : '[mcp_servers.ghostmodeldeck]\nurl = "${endpoint!}"\nenabled = true\nenabled_tools = ["$toolName"]\nstartup_timeout_sec = 10\ntool_timeout_sec = 20';

  Future<void> _serial(Future<void> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> start() {
    if (controller.isShuttingDown) return Future.error(StateError('应用正在退出'));
    return _serial(() async {
      if (controller.isShuttingDown) throw StateError('应用正在退出');
      if (_listener != null) return;
      _status = CouncilMcpStatus.starting;
      _error = null;
      _publish();
      try {
        _listener = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _status = CouncilMcpStatus.running;
        _listener!.listen(_handle);
        _publish();
      } catch (error) {
        _status = CouncilMcpStatus.failed;
        _error = error.toString();
        _publish();
        rethrow;
      }
    });
  }

  Future<void> stop() => _serial(() async {
    _status = CouncilMcpStatus.stopping;
    _publish();
    final drain = _inflight.values.toList();
    for (final token in _inflight.keys.toList()) {
      token.cancel();
    }
    final listener = _listener;
    _listener = null;
    await listener?.close(force: true);
    for (final transport in _transports.toList()) {
      await transport.close();
    }
    await Future.wait(
      drain.map(
        (future) =>
            future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    _transports.clear();
    _sessions.clear();
    _status = CouncilMcpStatus.stopped;
    _publish();
  });

  Future<void> close() async {
    await stop();
    await _changes.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final uri = endpoint;
      final host = request.headers.value(HttpHeaders.hostHeader);
      final origin = request.headers.value('origin');
      if (uri == null ||
          host != uri.authority ||
          origin != null && origin != 'http://${uri.authority}') {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (request.uri.path != '/mcp') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (request.method == 'OPTIONS') {
        request.response.headers.set(
          'Access-Control-Allow-Origin',
          origin ?? 'http://${uri.authority}',
        );
        request.response.headers.set(
          'Access-Control-Allow-Methods',
          'POST, GET, DELETE, OPTIONS',
        );
        request.response.headers.set(
          'Access-Control-Allow-Headers',
          'Content-Type, MCP-Protocol-Version, MCP-Session-Id, Mcp-Method, Mcp-Name',
        );
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      dynamic body;
      if (request.method == 'POST') {
        final bytes = BytesBuilder(copy: false);
        var received = 0;
        await for (final chunk in request) {
          received += chunk.length;
          if (received > 1024 * 1024) {
            request.response.statusCode = HttpStatus.requestEntityTooLarge;
            request.response.persistentConnection = false;
            await request.response.close();
            return;
          }
          bytes.add(chunk);
        }
        try {
          body = jsonDecode(utf8.decode(bytes.takeBytes()));
        } on FormatException {
          await _rpcError(request, -32700, 'Invalid JSON');
          return;
        }
      }
      final headerVersion = request.headers.value('mcp-protocol-version');
      final meta = body is Map
          ? ((body['params'] is Map ? body['params']['_meta'] : null) ??
                body['_meta'])
          : null;
      final metaVersion = meta is Map ? meta[McpMetaKey.protocolVersion] : null;
      final version =
          headerVersion ?? (metaVersion is String ? metaVersion : null);
      _observe({
        'kind': 'rpc',
        'method': body is Map && body['method'] is String
            ? body['method']
            : null,
        'protocol_version': version,
        'rpc_id': body is Map && (body['id'] is String || body['id'] is num)
            ? body['id']
            : null,
        'tool':
            body is Map &&
                body['params'] is Map &&
                body['params']['name'] is String
            ? body['params']['name']
            : null,
      });
      final modern = version != null && isStatelessProtocolVersion(version);
      final sessionId = request.headers.value('mcp-session-id');
      final initialize = body is Map && body['method'] == 'initialize';
      StreamableHTTPServerTransport transport;
      var transient = false;
      if (!modern && sessionId != null) {
        final existing = _sessions[sessionId];
        if (existing == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        transport = existing;
      } else {
        if (!modern && !initialize) {
          await _rpcError(request, -32600, 'Initialize a session first');
          return;
        }
        transient = modern;
        late StreamableHTTPServerTransport created;
        created = StreamableHTTPServerTransport(
          options: StreamableHTTPServerTransportOptions(
            sessionIdGenerator: modern ? () => null : _newId,
            onsessioninitialized: modern
                ? null
                : (id) => _sessions[id] = created,
            enableJsonResponse: true,
            enableDnsRebindingProtection: true,
            allowedHosts: const {'127.0.0.1'},
            allowedOrigins: {'http://${uri.authority}'},
          ),
        );
        final mcp = _createProtocol();
        mcp.server.onclose = () {
          _transports.remove(created);
          _sessions.removeWhere((_, value) => identical(value, created));
        };
        transport = created;
        _transports.add(transport);
        await mcp.connect(created);
      }
      if (_status != CouncilMcpStatus.running) {
        await transport.close();
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      try {
        await runZoned(
          () => transport.handleRequest(request, body),
          zoneValues: {_protocolKey: version},
        );
      } finally {
        if (transient || transport.sessionId == null) {
          await transport.close();
          _transports.remove(transport);
        }
      }
    } catch (_) {
      try {
        await _rpcError(request, -32603, 'MCP request failed');
      } catch (_) {
        /* A disconnected client has no response socket. */
      }
    }
  }

  McpServer _createProtocol() {
    final mcp = McpServer(
      const Implementation(name: 'ghostmodeldeck', version: '0.1.0'),
      options: const McpServerOptions(protocol: McpProtocol.stable),
    );
    mcp.registerTool(
      toolName,
      description: '咨询已运行的决策委员会，返回每席原始意见、综合评分、分歧与故障。',
      inputSchema: JsonObject.fromJson(_inputSchema),
      outputSchema: JsonObject.fromJson(_outputSchema),
      annotations: const ToolAnnotations(
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: _call,
    );
    // Application validation preserves structured failures, including bad input.
    mcp.server.setRequestHandler<JsonRpcCallToolRequest>(
      'tools/call',
      (request, extra) async {
        final call = request.callParams;
        if (call.name != toolName) {
          throw McpError(
            ErrorCode.invalidParams.value,
            'Unknown tool: ${call.name}',
          );
        }
        if (request.params?['task'] != null) {
          throw McpError(
            ErrorCode.invalidParams.value,
            'Task augmentation is not supported',
          );
        }
        return _call(call.arguments, extra);
      },
      (id, params, meta) =>
          JsonRpcCallToolRequest(id: id, params: params!, meta: meta),
    );
    return mcp;
  }

  Future<CallToolResult> _call(
    Map<String, dynamic> args,
    RequestHandlerExtra extra,
  ) async {
    final protocol =
        extra.protocolVersion ?? Zone.current[_protocolKey] as String?;
    final cancellation = DecisionCancellation();
    final subscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    if (extra.signal.aborted) cancellation.cancel();
    final future = _consult(args, cancellation);
    _inflight[cancellation] = future;
    _publish();
    try {
      final result = await future;
      final payload = result.structuredContent!;
      _observe({
        'kind': 'consultation',
        'method': 'tools/call',
        'protocol_version': protocol,
        'rpc_id': extra.requestId,
        'tool': toolName,
        'request_id': payload['request_id'],
        'status': payload['status'],
        'seat_instance_ids': [
          for (final seat in payload['seats'] as List)
            (seat as Map)['instance']['id'],
        ],
      });
      return result;
    } finally {
      _inflight.remove(cancellation);
      await subscription.cancel();
      _publish();
    }
  }

  Future<CallToolResult> _consult(
    Map<String, dynamic> args,
    DecisionCancellation cancellation,
  ) async {
    final started = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    var validated = false;
    Map<String, dynamic> payload;
    try {
      JsonObject.fromJson(_inputSchema).validate(args);
      final raw = args['options'] as List;
      final options = <String, String>{};
      for (final value in raw) {
        final option = value as Map;
        final id = option['id'] as String, text = option['text'] as String;
        if (id.trim().isEmpty ||
            text.trim().isEmpty ||
            options.containsKey(id)) {
          throw const FormatException('候选 ID 必须唯一，ID 与内容不能为空');
        }
        options[id] = text;
      }
      validated = true;
      if (_status != CouncilMcpStatus.running) throw StateError('MCP 服务正在停止');
      payload = Map<String, dynamic>.from(
        (await controller.consult(
          state: args['state'] as String,
          options: options,
          cancellation: cancellation,
        )).toJson(),
      );
    } catch (error) {
      payload = {
        'schema_version': 1,
        'request_id': _newId(),
        'status': 'failed',
        'scope': 'none',
        'request': args,
        'started_at': started.toIso8601String(),
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        'elapsed_us': watch.elapsedMicroseconds,
        'seats': [],
        'aggregate_scores': null,
        'top_choices': null,
        'votes': null,
        'disagreement': null,
        'error': {
          'code': !validated
              ? 'invalid_input'
              : _status != CouncilMcpStatus.running
              ? 'service_stopping'
              : 'consultation_failed',
          'message': error.toString(),
        },
      };
    }
    return CallToolResult(
      content: [TextContent(text: jsonEncode(payload))],
      structuredContent: payload,
      isError: payload['status'] == 'failed',
    );
  }

  Future<void> _rpcError(HttpRequest request, int code, String message) async {
    request.response.statusCode = HttpStatus.badRequest;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(
        JsonRpcError(
          id: null,
          error: JsonRpcErrorData(code: code, message: message),
        ).toJson(),
      ),
    );
    await request.response.close();
  }

  void _observe(Map<String, Object?> event) {
    try {
      observer?.call(Map.unmodifiable(event));
    } catch (_) {
      /* Observation cannot change the consultation. */
    }
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }
}

String _newId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

const _inputSchema = <String, dynamic>{
  'type': 'object',
  'required': ['state', 'options'],
  'additionalProperties': false,
  'properties': {
    'state': {'type': 'string', 'description': '本次判断的完整上下文。'},
    'options': {
      'type': 'array',
      'minItems': 2,
      'maxItems': 255,
      'items': {
        'type': 'object',
        'required': ['id', 'text'],
        'additionalProperties': false,
        'properties': {
          'id': {'type': 'string', 'minLength': 1},
          'text': {'type': 'string', 'minLength': 1},
        },
      },
    },
  },
};

const _outputSchema = <String, dynamic>{
  'type': 'object',
  'required': [
    'schema_version',
    'request_id',
    'status',
    'scope',
    'request',
    'started_at',
    'completed_at',
    'elapsed_us',
    'seats',
    'aggregate_scores',
    'top_choices',
    'votes',
    'disagreement',
  ],
  'properties': {
    'schema_version': {'type': 'integer', 'const': 1},
    'request_id': {'type': 'string', 'minLength': 1},
    'status': {
      'type': 'string',
      'enum': ['ok', 'partial', 'failed'],
    },
    'scope': {
      'type': 'string',
      'enum': ['ensemble', 'single_model', 'none'],
    },
    'request': {'type': 'object'},
    'started_at': {'type': 'string'},
    'completed_at': {'type': 'string'},
    'elapsed_us': {'type': 'integer', 'minimum': 0},
    'seats': {
      'type': 'array',
      'items': {'type': 'object'},
    },
    'aggregate_scores': {
      'type': ['object', 'null'],
      'additionalProperties': {'type': 'number', 'minimum': 0, 'maximum': 1},
    },
    'top_choices': {
      'type': ['array', 'null'],
      'items': {'type': 'string'},
    },
    'votes': {
      'type': ['object', 'null'],
      'additionalProperties': {'type': 'integer', 'minimum': 0},
    },
    'disagreement': {
      'type': ['number', 'null'],
      'minimum': 0,
      'maximum': 1,
    },
  },
};
