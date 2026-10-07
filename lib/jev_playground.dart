import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'council.dart';
import 'council_mcp.dart';
import 'decision_protocol.dart';
import 'engine_runtime.dart';
import 'jev_debug.dart';
import 'jev_models.dart';
import 'llama_engine.dart';
import 'public_gateway.dart';

export 'engine_runtime.dart' show DecisionCancellation;

enum JevPlaygroundMode { native, http, mcp }

enum JevPlaygroundStatus { success, businessError, cancelled, transportError }

/// A selection pins the managed identity and generation, never a replacement.
class JevNativeSource {
  const JevNativeSource(this.engineId, this.engineName, this.instance);
  final String engineId;
  final String engineName;
  final LlamaInstance instance;
  String get model => instance.id;
  String get label => '${instance.asset.name} · $engineName · $model';
  bool get ready =>
      instance.status == LlamaInstanceStatus.ready &&
      instance.hasLiveProcess &&
      instance.acceptingRequests &&
      instance.nativeAlias != null;
  String? reason(DecisionBatchRequest? request) {
    if (!ready) {
      return instance.error ?? '实例未 Ready；测试场不会加载模型';
    }
    if (!instance.capabilities.contains(LlamaCapability.choiceProbability) ||
        request?.questions.values.any(
              (q) => !instance.capabilities.contains(
                capabilityForPrimitive(q.type),
              ),
            ) ==
            true) {
      return '实例没有本次请求需要的 JEV 题型能力';
    }
    return null;
  }
}

class JevPlaygroundResult {
  factory JevPlaygroundResult(
    JevPlaygroundStatus status,
    String message, {
    Map<String, Object?>? output,
    Map<String, Object?>? debug,
  }) {
    final safe = sealDebugJson({
      'message': message,
      'output': output,
      'debug': debug,
    });
    return JevPlaygroundResult._(
      status,
      safe['message'] as String,
      safe['output'] as Map<String, Object?>?,
      safe['debug'] as Map<String, Object?>?,
    );
  }
  const JevPlaygroundResult._(
    this.status,
    this.message,
    this.output,
    this.debug,
  );
  final JevPlaygroundStatus status;
  final String message;
  final Map<String, Object?>? output;
  final Map<String, Object?>? debug;
}

/// Only owns clients for individual calls. The application owns all services.
class JevPlayground {
  const JevPlayground({
    required this.controller,
    required this.gateway,
    required this.mcp,
  });
  final CouncilController controller;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;

  List<JevNativeSource> get nativeSources => [
    for (final engine in controller.catalog.state.entries)
      if (engine.family == EngineFamily.llamaCpp)
        for (final instance
            in controller.catalog.providerFor(engine.id).state.instances)
          JevNativeSource(engine.id, engine.name, instance),
  ];

  JevModelRequest parse(String document) =>
      JevModelRequest.parse(jsonDecode(document));

  Map<String, Object?> preview(
    JevPlaygroundMode mode,
    String document, {
    JevNativeSource? nativeSource,
  }) {
    final parsed = parse(document);
    if (mode == JevPlaygroundMode.native) {
      _native(parsed, nativeSource);
      return parsed.request.toSystemone(model: parsed.model);
    }
    // The protocol receives the complete document, including explicit debug.
    return freezeDebugJson(jsonDecode(document)) as Map<String, Object?>;
  }

  JevNativeSource _native(JevModelRequest parsed, JevNativeSource? selected) {
    if (selected == null || parsed.model != selected.model) {
      throw const JevRequestException(
        409,
        'selection_mismatch',
        'model 与原生实例选择不一致，请显式选择实例',
      );
    }
    final current = nativeSources
        .where(
          (s) =>
              s.engineId == selected.engineId &&
              s.model == selected.model &&
              s.instance.generation == selected.instance.generation,
        )
        .firstOrNull;
    if (current == null) {
      throw const JevRequestException(
        503,
        'model_not_ready',
        '所选实例代次已结束，请重新选择',
      );
    }
    final reason = current.reason(parsed.request);
    if (reason != null) {
      throw JevRequestException(
        current.ready ? 409 : 503,
        current.ready ? 'capability_mismatch' : 'model_not_ready',
        reason,
      );
    }
    return current;
  }

  /// Discovery traverses the selected real protocol entry, not registry preview.
  Future<Map<String, Object?>> discover(
    JevPlaygroundMode mode, {
    DecisionCancellation? cancellation,
  }) async {
    if (mode == JevPlaygroundMode.native) {
      return sealDebugJson({
        'instances': [
          for (final s in nativeSources)
            {
              'model': s.model,
              'engine_id': s.engineId,
              'generation': s.instance.generation,
              'reason': s.reason(null),
            },
        ],
      });
    }
    if (mode == JevPlaygroundMode.http) {
      if (gateway.state != PublicGatewayState.running ||
          gateway.baseUrl == null) {
        throw StateError('HTTP 服务未运行：${gateway.error ?? gateway.state.name}');
      }
      return (await _http(
        gateway.baseUrl!.resolve('/v1/models'),
        null,
        cancellation,
      )).$2;
    }
    return _mcp(CouncilMcpServer.discoveryToolName, const {}, cancellation);
  }

  Future<JevPlaygroundResult> run(
    JevPlaygroundMode mode,
    String document, {
    JevNativeSource? nativeSource,
    DecisionCancellation? cancellation,
    Duration nativeTimeout = const Duration(seconds: 10),
  }) async {
    final token = cancellation ?? DecisionCancellation();
    try {
      final payload = preview(mode, document, nativeSource: nativeSource);
      if (token.isCancelled) {
        if (mode != JevPlaygroundMode.native) {
          return JevPlaygroundResult(
            JevPlaygroundStatus.cancelled,
            '客户端已取消；未收到业务结果，协议 debug 不可用',
          );
        }
        throw const JevRequestException(409, 'cancelled', '本次调用已取消');
      }
      if (mode == JevPlaygroundMode.native) {
        final parsed = parse(document);
        return await _runNative(
          parsed,
          _native(parsed, nativeSource),
          token,
          nativeTimeout,
        );
      }
      final Map<String, Object?> received;
      if (mode == JevPlaygroundMode.http) {
        if (gateway.state != PublicGatewayState.running ||
            gateway.baseUrl == null) {
          throw StateError('HTTP 服务未运行：${gateway.error ?? gateway.state.name}');
        }
        received = (await _http(
          gateway.baseUrl!.resolve('/v1/systemone'),
          payload,
          token,
        )).$2;
      } else {
        received = await _mcp(CouncilMcpServer.batchToolName, payload, token);
      }
      // Only actual received business JSON is presented as protocol output.
      final debug = received['debug'];
      final output = Map<String, Object?>.from(received)..remove('debug');
      return JevPlaygroundResult(
        output.containsKey('error')
            ? JevPlaygroundStatus.businessError
            : JevPlaygroundStatus.success,
        output.containsKey('error') ? '服务返回本次业务错误' : '已收到本次协议结果',
        output: output,
        debug: debug is Map ? Map<String, Object?>.from(debug) : null,
      );
    } on JevRequestException catch (error) {
      final body = Map<String, Object?>.from(error.toJson())..remove('debug');
      return JevPlaygroundResult(
        error.code == 'cancelled'
            ? JevPlaygroundStatus.cancelled
            : JevPlaygroundStatus.businessError,
        error.message,
        output: body,
        debug: error.debug,
      );
    } on DecisionProtocolException catch (error) {
      return JevPlaygroundResult(
        JevPlaygroundStatus.businessError,
        error.message,
      );
    } on FormatException catch (error) {
      return JevPlaygroundResult(
        JevPlaygroundStatus.businessError,
        'JSON 格式错误：${error.message}',
      );
    } catch (error) {
      return JevPlaygroundResult(
        token.isCancelled
            ? JevPlaygroundStatus.cancelled
            : JevPlaygroundStatus.transportError,
        token.isCancelled ? '客户端已取消；未收到业务结果，协议 debug 不可用' : '协议连接错误：$error',
      );
    }
  }

  Future<JevPlaygroundResult> _runNative(
    JevModelRequest parsed,
    JevNativeSource selected,
    DecisionCancellation token,
    Duration timeout,
  ) async {
    final fixedCallNames = [
      for (final d in controller.models.definitions)
        if (d.source == JevModelSource.native &&
            d.bindings.single.engineId == selected.engineId &&
            d.bindings.single.artifactId == selected.instance.asset.id)
          d.name,
    ];
    final trace = parsed.debug ? DecisionIOTrace() : null;
    final watch = Stopwatch()..start();
    final remove = token.listen(() => trace?.seal());
    Map<String, Object?>? evidence(Map<String, Object?> result, String status) {
      if (!parsed.debug) return null;
      trace!.seal();
      return sealDebugJson({
        'source': 'native',
        'model': parsed.model,
        'configuration': {
          'engine_id': selected.engineId,
          'artifact_id': selected.instance.asset.id,
          'instance_id': selected.model,
          'generation': selected.instance.generation,
          'native_alias': selected.instance.nativeAlias,
          'fixed_call_names': fixedCallNames,
          'timeout_us': timeout.inMicroseconds,
        },
        'input': parsed.request.toSystemone(model: parsed.model),
        'native': {'status': status, ...trace.toJson()},
        'converted_result': result,
        'elapsed_us': watch.elapsedMicroseconds,
      });
    }

    try {
      final result = await controller.catalog
          .providerFor(selected.engineId)
          .decideBatch(
            selected.model,
            parsed.request,
            timeout: timeout,
            cancellation: token,
            ioTrace: trace,
          );
      await Future<void>.value();
      if (token.isCancelled) {
        throw const LlamaRequestException(
          '本次决策已取消',
          kind: DecisionFailureKind.cancelled,
        );
      }
      final raw = Map<String, Object?>.from(
        jsonDecode(result.rawResponse) as Map,
      );
      return JevPlaygroundResult(
        JevPlaygroundStatus.success,
        '已收到所选实例原生结果',
        output: raw,
        debug: evidence(raw, 'ok'),
      );
    } on LlamaEngineException catch (error) {
      final code = token.isCancelled
          ? 'cancelled'
          : error is LlamaRequestException
          ? switch (error.kind) {
              DecisionFailureKind.timedOut => 'timed_out',
              DecisionFailureKind.cancelled => 'cancelled',
              DecisionFailureKind.notReady => 'model_not_ready',
              DecisionFailureKind.invalidResponse => 'invalid_response',
              _ => 'engine_error',
            }
          : 'engine_error';
      final body = <String, Object?>{
        'error': {'code': code, 'message': error.message},
      };
      return JevPlaygroundResult(
        code == 'cancelled'
            ? JevPlaygroundStatus.cancelled
            : JevPlaygroundStatus.businessError,
        error.message,
        output: body,
        debug: evidence(body, code),
      );
    } finally {
      remove();
      trace?.seal();
      watch.stop();
    }
  }

  Future<(int, Map<String, Object?>)> _http(
    Uri uri,
    Map<String, Object?>? payload,
    DecisionCancellation? token,
  ) async {
    final lease = payload == null ? null : gateway.leaseJevRequest();
    final client = HttpClient();
    HttpClientRequest? request;
    final remove = token?.listen(() {
      lease?.cancel();
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
      if (lease != null) {
        request.headers.set(PublicGatewayServer.ownedRequestHeader, lease.id);
      }
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(payload));
      }
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      if (body is! Map) throw const FormatException('服务结果需要是 JSON 对象');
      return (response.statusCode, Map<String, Object?>.from(body));
    } finally {
      remove?.call();
      client.close(force: true);
      await lease?.close();
    }
  }

  Future<Map<String, Object?>> _mcp(
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
      final body =
          result.structuredContent ??
          jsonDecode((result.content.single as TextContent).text);
      if (body is! Map) throw const FormatException('MCP 结果需要是 JSON 对象');
      return Map<String, Object?>.from(body);
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
