import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';

import 'council.dart';
import 'decision_protocol.dart';
import 'jev_models.dart';

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
  static const toolName = 'decide_jev';
  static const batchToolName = 'decide_jev_batch';
  static const discoveryToolName = 'list_jev_models';
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
  String get codexConfig {
    final address = endpoint;
    if (address == null) return '';
    final timeoutSeconds = controller.models.definitions.fold<int>(
      20,
      (budget, model) => max(
        budget,
        (model.timeout.inMicroseconds / Duration.microsecondsPerSecond).ceil() +
            10,
      ),
    );
    return '[mcp_servers.ghostmodeldeck]\nurl = "$address"\nenabled = true\nenabled_tools = ["$toolName", "$batchToolName", "$discoveryToolName"]\nstartup_timeout_sec = 10\ntool_timeout_sec = $timeoutSeconds';
  }

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
        await controller.models.load();
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
      description: '按必填 model 调用已配置的原生 JEV 或委员会，返回标准 JEV choice 结果。用 list_jev_models 发现当前可调用名称。',
      inputSchema: JsonObject.fromJson(_inputSchema),
      outputSchema: JsonObject.fromJson(_outputSchema),
      annotations: const ToolAnnotations(
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: _call,
    );
    mcp.registerTool(
      batchToolName,
      description: '按必填 model 批量调用 choice、score、noul，返回 model/answers/usage。confidence 描述分布形状，不表示正确率。',
      inputSchema: JsonObject.fromJson(_batchInputSchema),
      outputSchema: JsonObject.fromJson(_batchOutputSchema),
      annotations: const ToolAnnotations(
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: (args, extra) => _call(args, extra, typed: true),
    );
    mcp.registerTool(
      discoveryToolName,
      description: '列出当前具有唯一可用绑定的 JEV 调用名称和来源类型；实际请求还需题型能力验证。',
      inputSchema: JsonObject.fromJson(const {
        'type': 'object',
        'additionalProperties': false,
      }),
      annotations: const ToolAnnotations(
        readOnlyHint: true,
        openWorldHint: false,
      ),
      callback: (args, extra) => _discover(args),
    );
    // Application validation preserves structured failures, including bad input.
    mcp.server.setRequestHandler<JsonRpcCallToolRequest>(
      'tools/call',
      (request, extra) async {
        final call = request.callParams;
        if (call.name == discoveryToolName) return _discover(call.arguments);
        if (call.name != toolName && call.name != batchToolName) {
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
        return _call(call.arguments, extra, typed: call.name == batchToolName);
      },
      (id, params, meta) =>
          JsonRpcCallToolRequest(id: id, params: params!, meta: meta),
    );
    return mcp;
  }

  Future<CallToolResult> _call(
    Map<String, dynamic> args,
    RequestHandlerExtra extra, {
    bool typed = false,
  }) async {
    final protocol =
        extra.protocolVersion ?? Zone.current[_protocolKey] as String?;
    final cancellation = DecisionCancellation();
    final subscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    if (extra.signal.aborted) cancellation.cancel();
    final future = _consult(args, cancellation, typed: typed);
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
        'tool': typed ? batchToolName : toolName,
        'model': payload['model'],
        'status': result.isError == true ? 'failed' : 'ok',
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
    DecisionCancellation cancellation, {
    bool typed = false,
  }) async {
    Map<String, dynamic> payload;
    var failed = false;
    try {
      final parsed = typed
          ? JevModelRequest.parse(args)
          : JevModelRequest.single(args);
      if (_status != CouncilMcpStatus.running) {
        throw const JevRequestException(503, 'service_stopping', 'MCP 服务正在停止');
      }
      payload = Map<String, dynamic>.from(
        await controller.models.decide(
          parsed.model,
          parsed.request,
          cancellation: cancellation,
          debug: parsed.debug,
        ),
      );
    } on JevRequestException catch (error) {
      failed = true;
      payload = Map<String, dynamic>.from(error.toJson());
    } on DecisionProtocolException catch (error) {
      failed = true;
      payload = {
        'error': {'code': 'invalid_input', 'message': error.message},
      };
    }
    return CallToolResult(
      content: [TextContent(text: jsonEncode(payload))],
      structuredContent: payload,
      isError: failed,
    );
  }

  Future<CallToolResult> _discover(Map<String, dynamic> args) async {
    if (args.isNotEmpty) {
      final payload = {
        'error': {'code': 'invalid_input', 'message': '模型发现不接受参数'},
      };
      return CallToolResult(
        content: [TextContent(text: jsonEncode(payload))],
        structuredContent: payload,
        isError: true,
      );
    }
    await controller.models.load();
    final payload = {
      'object': 'list',
      'data': [for (final m in controller.models.callableModels) m.toJson()],
    };
    return CallToolResult(
      content: [TextContent(text: jsonEncode(payload))],
      structuredContent: payload,
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

const _batchInputSchema = <String, dynamic>{
  'type': 'object',
  'required': ['model', 'state', 'questions'],
  'additionalProperties': false,
  'properties': {
    'model': {'type': 'string', 'minLength': 1},
    'state': {'type': 'string'},
    'stream': {'type': 'boolean', 'const': false},
    'debug': {'type': 'boolean', 'default': false},
    'questions': {
      'type': 'object',
      'minProperties': 1,
      'maxProperties': 32,
      'additionalProperties': {
        'type': 'object',
        'required': ['type', 'instructions', 'criteria'],
        'additionalProperties': false,
        'properties': {
          'type': {
            'type': 'string',
            'enum': ['choice', 'score', 'noul'],
          },
          'instructions': {'type': 'string', 'minLength': 1},
          'criteria': {
            'type': ['object', 'array'],
            'items': {'type': 'string'},
            'additionalProperties': {'type': 'string'},
          },
        },
      },
    },
  },
};
const _inputSchema = <String, dynamic>{
  'type': 'object',
  'required': ['model', 'state', 'options'],
  'additionalProperties': false,
  'properties': {
    'model': {'type': 'string', 'minLength': 1},
    'state': {'type': 'string'},
    'instructions': {'type': 'string', 'minLength': 1},
    'debug': {'type': 'boolean', 'default': false},
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
  'anyOf': [
    {
      'required': ['model', 'answers', 'usage'],
    },
    {
      'required': ['error'],
    },
  ],
  'properties': {
    'model': {'type': 'string'},
    'answers': {
      'type': 'object',
      'additionalProperties': {'type': 'object'},
    },
    'usage': {
      'type': 'object',
      'required': ['input_tokens', 'output_tokens'],
      'properties': {
        'input_tokens': {'type': 'integer', 'minimum': 0},
        'output_tokens': {'type': 'integer', 'const': 0},
      },
    },
    'debug': {'type': 'object'},
    'error': {
      'type': 'object',
      'required': ['code', 'message'],
      'properties': {
        'code': {'type': 'string'},
        'message': {'type': 'string'},
      },
    },
  },
};
const _batchOutputSchema = _outputSchema;
