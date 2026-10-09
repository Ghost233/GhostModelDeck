import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'council_mcp.dart';
import 'decision_protocol.dart';
import 'engine_runtime.dart' show DecisionCancellation;
import 'jev_debug.dart';
import 'jev_models.dart';
import 'public_gateway.dart';

export 'engine_runtime.dart' show DecisionCancellation;

enum JevPlaygroundMode { http, mcp }

enum JevPlaygroundStatus {
  success,
  businessError,
  invalidResponse,
  cancelled,
  timedOut,
  transportError,
}

class JevDiscoveredModel {
  const JevDiscoveredModel(this.id, this.source);
  final String id;
  final String source;
  String get label => '$id · ${source == 'council' ? '委员会' : '原生 JEV'}';
}

class JevPlaygroundResult {
  factory JevPlaygroundResult(
    JevPlaygroundStatus status,
    String message, {
    Map<String, Object?>? output,
    Map<String, Object?>? debug,
    required JevPlaygroundMode mode,
    required Duration timeout,
    required Duration elapsed,
    Map<String, Object?>? request,
    String? rawResponse,
    int? httpStatus,
  }) {
    final safe = sealDebugJson({
      'message': message,
      'output': output,
      'debug': debug,
    }, projection: JevDebugProjection.playgroundResult);
    var publicEnvelope = false;
    var publicRaw = rawResponse;
    if (rawResponse != null && output != null) {
      try {
        final rawBody = jsonDecode(rawResponse);
        if (rawBody is Map) {
          final rawOutput = Map<String, Object?>.from(rawBody)..remove('debug');
          if (jsonEncode(rawOutput) == jsonEncode(output) &&
              jsonEncode(rawBody['debug']) == jsonEncode(debug)) {
            // The parsed public output/debug already crossed their respective
            // semantic redaction boundaries. Do not reinterpret task input
            // inside public debug as credential configuration a second time.
            final safeOutput = safe['output'] as Map<String, Object?>;
            final safeBody = {
              for (final key in rawBody.keys)
                key as String: key == 'debug' ? safe['debug'] : safeOutput[key],
            };
            publicEnvelope = true;
            if (jsonEncode(rawBody) != jsonEncode(safeBody)) {
              publicRaw = jsonEncode(safeBody);
            }
          }
        }
      } on FormatException {
        // Unparsed protocol bytes cannot establish JEV task-data immunity.
      }
    }
    final evidence = sealDebugJson({
      'input': request,
      'native': {
        'result': output,
        'raw_response': publicEnvelope ? null : rawResponse,
        'request_body': request == null ? null : jsonEncode(request),
      },
    }, projection: JevDebugProjection.debug);
    final io = evidence['native'] as Map;
    return JevPlaygroundResult._(
      status,
      safe['message'] as String,
      safe['output'] as Map<String, Object?>?,
      safe['debug'] as Map<String, Object?>?,
      mode,
      timeout,
      elapsed,
      evidence['input'] as Map<String, Object?>?,
      io['request_body'] as String?,
      publicEnvelope ? publicRaw : io['raw_response'] as String?,
      httpStatus,
    );
  }
  const JevPlaygroundResult._(
    this.status,
    this.message,
    this.output,
    this.debug,
    this.mode,
    this.timeout,
    this.elapsed,
    this.request,
    this.requestBody,
    this.rawResponse,
    this.httpStatus,
  );
  final JevPlaygroundStatus status;
  final String message;
  final Map<String, Object?>? output;
  final Map<String, Object?>? debug;
  final JevPlaygroundMode mode;
  final Duration timeout;
  final Duration elapsed;
  final Map<String, Object?>? request;
  final String? requestBody;
  final String? rawResponse;
  final int? httpStatus;
  bool get diagnostic => request?['debug'] == true;

  Map<String, Object?> toJson() => {
    'channel': mode.name,
    'status': status.name,
    'message': message,
    'timeout_us': timeout.inMicroseconds,
    'elapsed_us': elapsed.inMicroseconds,
    'diagnostic': diagnostic,
    'request': request,
    'request_json': requestBody,
    'http_status': httpStatus,
    'raw_response': rawResponse,
    'output': output,
    'debug': debug,
  };
}

/// Only owns clients for individual calls. The application owns all services.
class JevPlayground {
  const JevPlayground({required this.gateway, required this.mcp});
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;

  JevModelRequest parse(String document) =>
      JevModelRequest.parse(jsonDecode(document));

  Map<String, Object?> preview(JevPlaygroundMode mode, String document) {
    parse(document);
    // Preserve all legal request content, including explicit public debug.
    return freezeDebugJson(jsonDecode(document)) as Map<String, Object?>;
  }

  List<JevDiscoveredModel> modelsFromDiscovery(Map<String, Object?> discovery) {
    final data = discovery['data'];
    if (data is! List) throw const FormatException('发现响应缺少模型列表');
    final models = <JevDiscoveredModel>[];
    for (final row in data) {
      if (row is! Map || row['id'] is! String) {
        throw const FormatException('发现响应包含无效模型身份');
      }
      final source = row['source'];
      if (source == 'native' || source == 'council') {
        models.add(JevDiscoveredModel(row['id'] as String, source as String));
      }
    }
    return List.unmodifiable(models);
  }

  /// Discovery traverses the selected real protocol entry, not registry preview.
  Future<Map<String, Object?>> discover(
    JevPlaygroundMode mode, {
    DecisionCancellation? cancellation,
  }) async {
    if (mode == JevPlaygroundMode.http) {
      if (gateway.state != PublicGatewayState.running ||
          gateway.baseUrl == null) {
        throw StateError('HTTP 服务未运行：${gateway.error ?? gateway.state.name}');
      }
      return sealDebugJson(
        (await _http(
          gateway.baseUrl!.resolve('/v1/models'),
          null,
          cancellation,
        )).body,
        projection: JevDebugProjection.discovery,
      );
    }
    return sealDebugJson(
      (await _mcp(
        CouncilMcpServer.discoveryToolName,
        const {},
        cancellation,
      )).body,
      projection: JevDebugProjection.discovery,
    );
  }

  Future<JevPlaygroundResult> run(
    JevPlaygroundMode mode,
    String document, {
    DecisionCancellation? cancellation,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final token = cancellation ?? DecisionCancellation();
    var deadlineReached = false;
    Timer? deadline;
    final watch = Stopwatch()..start();
    Map<String, Object?>? sent;
    JevPlaygroundResult finish(
      JevPlaygroundStatus status,
      String message, {
      Map<String, Object?>? output,
      Map<String, Object?>? debug,
      String? rawResponse,
      int? httpStatus,
    }) => JevPlaygroundResult(
      status,
      message,
      output: output,
      debug: debug,
      mode: mode,
      timeout: timeout,
      elapsed: watch.elapsed,
      request: sent,
      rawResponse: rawResponse,
      httpStatus: httpStatus,
    );
    try {
      if (timeout <= Duration.zero) {
        throw const DecisionProtocolException('客户端期限必须大于零');
      }
      final documentValue = jsonDecode(document);
      final parsed = JevModelRequest.parse(documentValue);
      final payload = freezeDebugJson(documentValue) as Map<String, Object?>;
      sent = payload;
      if (token.isCancelled) throw StateError('客户端已取消');
      deadline = Timer(timeout, () {
        deadlineReached = true;
        token.cancel();
      });
      final _JevReply reply;
      if (mode == JevPlaygroundMode.http) {
        if (gateway.state != PublicGatewayState.running ||
            gateway.baseUrl == null) {
          throw StateError('HTTP 服务未运行：${gateway.error ?? gateway.state.name}');
        }
        reply = await _http(
          gateway.baseUrl!.resolve('/v1/systemone'),
          payload,
          token,
        );
      } else {
        reply = await _mcp(CouncilMcpServer.batchToolName, payload, token);
      }
      if (token.isCancelled) throw StateError('客户端已取消');
      // Only actual received business JSON is presented as protocol output.
      final received = reply.body;
      final debug = received['debug'];
      final output = Map<String, Object?>.from(received)..remove('debug');
      if (debug != null && debug is! Map) {
        throw _InvalidJevResponse(
          '公开 debug 响应需要是 JSON 对象',
          reply.raw,
          reply.httpStatus,
        );
      }
      final error = output['error'];
      var status = JevPlaygroundStatus.success;
      var message = '已收到本次协议结果';
      if (output.containsKey('error')) {
        if (error is! Map ||
            error['code'] is! String ||
            error['message'] is! String) {
          throw _InvalidJevResponse(
            '公开错误响应缺少错误码或消息',
            reply.raw,
            reply.httpStatus,
          );
        }
        status = error['code'] == 'invalid_response'
            ? JevPlaygroundStatus.invalidResponse
            : JevPlaygroundStatus.businessError;
        message = status == JevPlaygroundStatus.invalidResponse
            ? '服务返回非法响应：${error['message']}'
            : '服务返回本次业务错误';
      } else {
        try {
          DecisionBatchResult.parse(
            jsonEncode(output),
            parsed.request,
            expectedModel: parsed.model,
          );
        } on DecisionProtocolException catch (error) {
          throw _InvalidJevResponse(
            '公开响应无效：${error.message}',
            reply.raw,
            reply.httpStatus,
          );
        }
        if (reply.httpStatus != null &&
            (reply.httpStatus! < 200 || reply.httpStatus! >= 300)) {
          throw _InvalidJevResponse(
            'HTTP 状态与成功响应不一致',
            reply.raw,
            reply.httpStatus,
          );
        }
      }
      return finish(
        status,
        message,
        output: output,
        debug: debug is Map ? Map<String, Object?>.from(debug) : null,
        rawResponse: reply.raw,
        httpStatus: reply.httpStatus,
      );
    } on _InvalidJevResponse catch (error) {
      if (token.isCancelled) {
        return finish(
          deadlineReached
              ? JevPlaygroundStatus.timedOut
              : JevPlaygroundStatus.cancelled,
          deadlineReached
              ? '客户端期限已到；未收到业务结果，协议 debug 不可用'
              : '客户端已取消；未收到业务结果，协议 debug 不可用',
        );
      }
      return finish(
        JevPlaygroundStatus.invalidResponse,
        error.message,
        rawResponse: error.raw,
        httpStatus: error.httpStatus,
      );
    } on JevRequestException catch (error) {
      final body = Map<String, Object?>.from(error.toJson())..remove('debug');
      return finish(
        error.code == 'cancelled'
            ? JevPlaygroundStatus.cancelled
            : JevPlaygroundStatus.businessError,
        error.message,
        output: body,
        debug: error.debug,
      );
    } on DecisionProtocolException catch (error) {
      return finish(JevPlaygroundStatus.businessError, error.message);
    } on FormatException catch (error) {
      return finish(
        JevPlaygroundStatus.businessError,
        'JSON 格式错误：${error.message}',
      );
    } catch (error) {
      return finish(
        deadlineReached
            ? JevPlaygroundStatus.timedOut
            : token.isCancelled
            ? JevPlaygroundStatus.cancelled
            : JevPlaygroundStatus.transportError,
        deadlineReached
            ? '客户端期限已到；未收到业务结果，协议 debug 不可用'
            : token.isCancelled
            ? '客户端已取消；未收到业务结果，协议 debug 不可用'
            : '协议连接错误：$error',
      );
    } finally {
      deadline?.cancel();
      watch.stop();
    }
  }

  Future<void> exportTo(
    File destination, {
    required String document,
    JevPlaygroundResult? result,
    JevPlaygroundMode mode = JevPlaygroundMode.http,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!destination.isAbsolute) {
      throw ArgumentError('导出需要完整绝对路径');
    }
    Object? input;
    try {
      input = jsonDecode(document);
    } on FormatException {
      input = null;
    }
    final safeInput = sealDebugJson({
      'native': {'request_body': document},
      'input': input,
    }, projection: JevDebugProjection.debug);
    final record = {
      'input_json': (safeInput['native'] as Map)['request_body'],
      'request': result?.request ?? safeInput['input'],
      'channel': (result?.mode ?? mode).name,
      'timeout_us': (result?.timeout ?? timeout).inMicroseconds,
      'result': result?.toJson(),
    };
    await destination.create(exclusive: true);
    try {
      await destination.writeAsString(
        const JsonEncoder.withIndent('  ').convert(record),
      );
    } catch (error) {
      try {
        await destination.delete();
      } catch (cleanupError) {
        throw FileSystemException(
          '导出失败：$error；清理失败：$cleanupError',
          destination.path,
        );
      }
      rethrow;
    }
  }

  Future<_JevReply> _http(
    Uri uri,
    Map<String, Object?>? payload,
    DecisionCancellation? token,
  ) async {
    final client = HttpClient();
    HttpClientRequest? request;
    final remove = token?.listen(() {
      request?.abort();
      client.close(force: true);
    });
    try {
      if (token?.isCancelled == true) throw StateError('客户端已取消');
      request = payload == null
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      if (token?.isCancelled == true) {
        request.abort();
        throw StateError('客户端已取消');
      }
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(payload));
      }
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      return _JevReply.decode(response.statusCode, raw);
    } finally {
      remove?.call();
      client.close(force: true);
    }
  }

  Future<_JevReply> _mcp(
    String name,
    Map<String, Object?> arguments,
    DecisionCancellation? token,
  ) async {
    if (mcp.state.status != CouncilMcpStatus.running || mcp.endpoint == null) {
      throw StateError('MCP 服务未运行：${mcp.state.error ?? mcp.state.status.name}');
    }
    final client = McpClient(
      const Implementation(name: 'GhostModelDeck-playground', version: '1'),
    );
    final transport = StreamableHttpClientTransport(mcp.endpoint!);
    final abort = BasicAbortController();
    var connected = false;
    final remove = token?.listen(() {
      abort.abort();
      if (!connected) {
        client.close().ignore();
      }
    });
    try {
      if (token?.isCancelled == true) throw StateError('客户端已取消');
      await client.connect(transport);
      connected = true;
      if (token?.isCancelled == true) throw StateError('客户端已取消');
      final result = await client.callTool(
        CallToolRequest(name: name, arguments: arguments),
        options: RequestOptions(timeoutEnabled: false, signal: abort.signal),
      );
      final raw =
          result.content.length == 1 && result.content.single is TextContent
          ? (result.content.single as TextContent).text
          : jsonEncode(result.structuredContent);
      return _JevReply.decode(null, raw, structured: result.structuredContent);
    } finally {
      remove?.call();
      try {
        await transport.terminateSession();
      } finally {
        await client.close();
      }
    }
  }
}

class _JevReply {
  const _JevReply(this.httpStatus, this.raw, this.body);
  factory _JevReply.decode(int? status, String raw, {Object? structured}) {
    try {
      final value = structured ?? jsonDecode(raw);
      if (value is! Map) throw const FormatException('响应需要是 JSON 对象');
      return _JevReply(status, raw, Map<String, Object?>.from(value));
    } on FormatException catch (error) {
      throw _InvalidJevResponse('公开响应不是有效 JSON：${error.message}', raw, status);
    }
  }
  final int? httpStatus;
  final String raw;
  final Map<String, Object?> body;
}

class _InvalidJevResponse implements Exception {
  const _InvalidJevResponse(this.message, this.raw, this.httpStatus);
  final String message;
  final String raw;
  final int? httpStatus;
}
