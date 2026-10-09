import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'chat_protocol.dart';
import 'decision_protocol.dart';
import 'engine_runtime.dart';
import 'jev_models.dart';
import 'jev_debug.dart';
import 'llama_engine.dart';
import 'model_library.dart';
import 'omlx_engine.dart';

/// Public business rejection with an HTTP verdict, never a silent fallback.
class PublicRequestException implements Exception {
  const PublicRequestException(this.statusCode, this.type, this.message);
  final int statusCode;
  final String type;
  final String message;
  @override
  String toString() => message;
}

class PublicModelEntry {
  const PublicModelEntry({required this.publicId, required this.artifactId});
  final String publicId;
  final String artifactId;
}

/// A resolved route binds one exact runtime instance/generation per request.
class PublicRouteTarget {
  const PublicRouteTarget({
    required this.publicId,
    required this.artifactId,
    required this.runtime,
    required this.instance,
  });
  final String publicId;
  final String artifactId;
  final EngineRuntime runtime;
  final RuntimeInstance instance;
}

/// Public route identity layer. Public model IDs derive from the model
/// library's own stable artifact identity, survive restarts, and never
/// expose native aliases or internal ports. Enable/disable is an explicit
/// business operation; cold, unknown or ambiguous routes are refused with
/// zero upstream contact.
class PublicModelRoutes {
  PublicModelRoutes({
    required this._library,
    required List<EngineRuntime> runtimes,
    this._registryFile,
  }) : _runtimes = List.unmodifiable(runtimes);

  static const _schema = 1;

  final ModelLibrary _library;
  final List<EngineRuntime> _runtimes;
  final File? _registryFile;
  final Set<String> _enabled = {};
  final _changes = StreamController<void>.broadcast();
  bool _loaded = false;
  bool _closed = false;

  Stream<void> get changes => _changes.stream;

  String publicIdFor(String artifactId) => 'gmd-$artifactId';

  bool isEnabled(String artifactId) => _enabled.contains(artifactId);

  Future<void> load() async {
    if (_loaded || _closed) return;
    final file = _registryFile;
    if (file == null || !file.existsSync()) {
      _loaded = true;
      return;
    }
    final Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } on FormatException {
      // Keep _loaded false: the explicit failure must stay retry-visible.
      throw StateError('公开模型登记文件无效：${file.path}');
    }
    final enabled = value is Map ? value['enabled'] : null;
    if (value is! Map ||
        value['schema'] != _schema ||
        enabled is! List ||
        enabled.any((entry) => entry is! String)) {
      throw StateError('公开模型登记文件无效：${file.path}');
    }
    _enabled.addAll(enabled.cast<String>());
    _loaded = true;
  }

  Future<void> enable(String artifactId) async {
    _ensureOpen();
    await load();
    final artifact = _library.state.artifacts
        .where((entry) => entry.id == artifactId)
        .firstOrNull;
    if (artifact == null) {
      throw StateError('公开模型不存在于模型库：$artifactId');
    }
    if (artifact.kind != AssetKind.chat) {
      throw StateError('仅标准文本对话模型可公开访问：$artifactId');
    }
    final publicId = publicIdFor(artifactId);
    final conflict = _enabled.any(
      (other) => other != artifactId && publicIdFor(other) == publicId,
    );
    if (conflict) {
      throw StateError('公开模型 ID 冲突：$publicId');
    }
    if (_enabled.add(artifactId)) {
      await _persist();
      _changes.add(null);
    }
  }

  Future<void> disable(String artifactId) async {
    _ensureOpen();
    await load();
    if (_enabled.remove(artifactId)) {
      await _persist();
      _changes.add(null);
    }
  }

  /// Enabled artifacts that currently have at least one ready text instance.
  List<PublicModelEntry> listModels() {
    final entries = <PublicModelEntry>[];
    for (final artifactId in _enabled.toList()..sort()) {
      if (_readyInstances(artifactId).isNotEmpty) {
        entries.add(
          PublicModelEntry(
            publicId: publicIdFor(artifactId),
            artifactId: artifactId,
          ),
        );
      }
    }
    return entries;
  }

  /// Per-request resolution. Refusals happen before any upstream contact.
  PublicRouteTarget resolve(String publicId) {
    if (publicId.length != 68 || !publicId.startsWith('gmd-')) {
      throw const PublicRequestException(404, 'model_not_found', '公开模型不存在');
    }
    final artifactId = publicId.substring(4);
    if (!_enabled.contains(artifactId)) {
      throw const PublicRequestException(
        404,
        'model_not_found',
        '公开模型不存在或未启用公开访问',
      );
    }
    final ready = _readyInstances(artifactId);
    if (ready.isEmpty) {
      throw const PublicRequestException(
        503,
        'model_not_ready',
        '公开模型当前没有就绪实例，客户端不得隐式加载',
      );
    }
    if (ready.length > 1) {
      throw const PublicRequestException(
        409,
        'route_conflict',
        '公开模型路由冲突：存在多个就绪实例',
      );
    }
    final hit = ready.single;
    return PublicRouteTarget(
      publicId: publicId,
      artifactId: artifactId,
      runtime: hit.runtime,
      instance: hit.instance,
    );
  }

  List<({EngineRuntime runtime, RuntimeInstance instance})> _readyInstances(
    String artifactId,
  ) {
    final found = <({EngineRuntime runtime, RuntimeInstance instance})>[];
    for (final runtime in _runtimes) {
      for (final instance in runtime.runtimeInstances) {
        if (instance.artifactId == artifactId &&
            instance.status == RuntimeInstanceStatus.ready &&
            instance.acceptingRequests &&
            instance.hasLiveProcess &&
            instance.capabilities.contains(RuntimeCapability.textGeneration)) {
          found.add((runtime: runtime, instance: instance));
        }
      }
    }
    return found;
  }

  Future<void> _persist() async {
    final file = _registryFile;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final enabled = _enabled.toList()..sort();
    await file.writeAsString(
      jsonEncode({'schema': _schema, 'enabled': enabled}),
    );
  }

  void _ensureOpen() {
    if (_closed) throw StateError('公开路由层已关闭');
  }

  void close() {
    _closed = true;
    unawaited(_changes.close());
  }
}

enum PublicGatewayState { stopped, starting, running, stopping, failed }

class _InflightRequest {
  _InflightRequest({this.ownedId});
  final String? ownedId;
  bool claimed = false;
  final cancellation = DecisionCancellation();
  final drained = Completer<void>();
}

/// An in-process owner's capability for one actual HTTP JEV call.
/// The opaque header binds the wire request; it cannot cancel another handle.
class PublicJevRequestLease {
  PublicJevRequestLease._(this._gateway, this._request);
  final PublicGatewayServer _gateway;
  final _InflightRequest _request;
  String get id => _request.ownedId!;
  bool cancel() {
    if (_request.drained.isCompleted || _request.cancellation.isCancelled) {
      return false;
    }
    _request.cancellation.cancel();
    return true;
  }

  Future<void> close() async {
    cancel();
    if (!_request.claimed) _gateway._finish(_request);
    await _request.drained.future;
  }
}

class _ParsedChat {
  const _ParsedChat({
    required this.model,
    required this.request,
    required this.stream,
  });
  final String model;
  final TextRequest request;
  final bool stream;
}

/// The public loopback text API: GET /v1/models and
/// POST /v1/chat/completions (JSON + SSE) on a fixed port. Every refusal is
/// explicit; upstream failures are never disguised as success and public
/// replies never carry credentials, native aliases or internal details.
class PublicGatewayServer {
  PublicGatewayServer({
    required this._routes,
    this.jevModels,
    this.port = defaultPort,
    this.heartbeatInterval = const Duration(seconds: 15),
  });

  static const defaultPort = 54841;
  static const ownedRequestHeader = 'x-gmd-owned-jev-request';
  static const _bodyLimit = 1024 * 1024;

  final PublicModelRoutes _routes;
  final JevModels? jevModels;
  final int port;

  /// SSE comment-frame cadence. dart:io only surfaces a dead client on the
  /// next write, so streaming responses need periodic writes to notice a
  /// disconnect and cancel the upstream promptly. Tests inject a short one.
  final Duration heartbeatInterval;
  final _changes = StreamController<PublicGatewayState>.broadcast();
  final _inflight = <_InflightRequest>{};
  HttpServer? _listener;
  Future<void>? _stopping;
  PublicGatewayState _state = PublicGatewayState.stopped;
  String? _error;
  bool _sealed = false;
  int _requestCounter = 0;

  PublicGatewayState get state => _state;
  String? get error => _error;
  Uri? get baseUrl {
    final listener = _listener;
    return listener == null
        ? null
        : Uri.parse('http://127.0.0.1:${listener.port}');
  }

  Stream<PublicGatewayState> get changes => _changes.stream;

  int get activeOwnedRequests =>
      _inflight.where((r) => r.ownedId != null).length;

  /// Register before connecting, so cancellation cannot race late admission.
  PublicJevRequestLease leaseJevRequest() {
    if (_sealed || _state != PublicGatewayState.running || jevModels == null) {
      throw StateError('JEV HTTP 服务未运行');
    }
    final random = Random.secure();
    final id = base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
    final request = _InflightRequest(ownedId: id);
    _inflight.add(request);
    return PublicJevRequestLease._(this, request);
  }

  void _finish(_InflightRequest request) {
    _inflight.remove(request);
    if (!request.drained.isCompleted) request.drained.complete();
  }

  Future<void> start() async {
    if (_state == PublicGatewayState.running) {
      throw StateError('公开 API 已在运行：$baseUrl');
    }
    if (_state == PublicGatewayState.failed) {
      throw StateError(_error ?? '公开 API 启动已失败');
    }
    if (_state != PublicGatewayState.stopped) {
      throw StateError('公开 API 状态不允许启动：$_state');
    }
    _setState(PublicGatewayState.starting);
    HttpServer listener;
    try {
      await _routes.load();
      await jevModels?.load();
      listener = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      _error = '公开 API 端口 $port 被占用或不可用，不做端口漂移';
      _setState(PublicGatewayState.failed);
      throw StateError(_error!);
    } catch (_) {
      _error = '公开 API 启动失败';
      _setState(PublicGatewayState.failed);
      rethrow;
    }
    _listener = listener;
    _sealed = false;
    _setState(PublicGatewayState.running);
    listener.listen((request) {
      unawaited(_handle(request));
    });
  }

  /// Lifecycle seam: revoke admission and cancel in-flight requests before
  /// engines begin their drain. Listener teardown happens in [stop].
  void beginShutdown() {
    _sealed = true;
    for (final request in _inflight.toList()) {
      request.cancellation.cancel();
      if (request.ownedId != null && !request.claimed) _finish(request);
    }
  }

  Future<void> stop() {
    if (_state == PublicGatewayState.stopped) return Future.value();
    return _stopping ??= _stop();
  }

  Future<void> _stop() async {
    _setState(PublicGatewayState.stopping);
    beginShutdown();
    final listener = _listener;
    _listener = null;
    await listener?.close(force: true);
    if (_inflight.isNotEmpty) {
      await Future.wait([
        for (final request in _inflight) request.drained.future,
      ]);
    }
    _stopping = null;
    _setState(PublicGatewayState.stopped);
  }

  void close() {
    unawaited(stop().whenComplete(_changes.close));
  }

  Future<void> _handle(HttpRequest request) async {
    var inflight = _InflightRequest();
    _inflight.add(inflight);
    try {
      if (_sealed) {
        _sendError(request.response, 503, 'service_unavailable', '公开 API 正在停止');
        return;
      }
      final authority = request.headers.host ?? '';
      final authorityPort = request.headers.port;
      final boundPort = _listener?.port ?? port;
      if ((authority != '127.0.0.1' && authority != 'localhost') ||
          authorityPort != boundPort) {
        _sendError(request.response, 403, 'forbidden', '仅允许本机回环访问');
        return;
      }
      final path = request.uri.path;
      final handles = request.headers[ownedRequestHeader];
      if (handles != null) {
        if (request.method != 'POST' ||
            path != '/v1/systemone' ||
            handles.length != 1 ||
            handles.single.contains(',')) {
          throw const JevRequestException(
            400,
            'invalid_owned_request',
            '调用句柄需要唯一的 JEV HTTP 请求',
          );
        }
        final owned = _inflight
            .where((r) => r.ownedId == handles.single)
            .firstOrNull;
        if (owned == null) {
          throw const JevRequestException(
            404,
            'unknown_owned_request',
            '调用句柄不存在或已释放',
          );
        }
        if (owned.claimed) {
          throw const JevRequestException(
            409,
            'duplicate_owned_request',
            '调用句柄已经用于另一个请求',
          );
        }
        if (owned.cancellation.isCancelled) {
          throw const JevRequestException(409, 'cancelled', '本次调用已取消');
        }
        _finish(inflight);
        inflight = owned;
        inflight.claimed = true;
      }
      if (request.method == 'GET' && path == '/v1/models') {
        _sendJson(request.response, 200, {
          'object': 'list',
          'data': [
            for (final entry
                in jevModels?.callableModels ?? <JevModelAvailability>[])
              {
                ...entry.toJson(),
                'object': 'model',
                'owned_by': 'ghostmodeldeck',
              },
            for (final entry in _routes.listModels())
              {
                'id': entry.publicId,
                'object': 'model',
                'owned_by': 'ghostmodeldeck',
              },
          ],
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/systemone' &&
          jevModels != null) {
        await _systemone(request, inflight.cancellation);
        return;
      }
      if (request.method == 'POST' && path == '/v1/chat/completions') {
        await _chat(request, inflight.cancellation);
        return;
      }
      _sendError(request.response, 404, 'invalid_request_error', '路径不存在');
    } on JevRequestException catch (error) {
      _sendJson(request.response, error.statusCode, error.toJson());
    } on DecisionProtocolException catch (error) {
      _sendJson(request.response, 400, {
        'error': {'code': 'invalid_input', 'message': error.message},
      });
    } on FormatException {
      _sendJson(request.response, 400, {
        'error': {'code': 'invalid_input', 'message': '请求体不是有效 JSON'},
      });
    } on PublicRequestException catch (error) {
      _sendError(request.response, error.statusCode, error.type, error.message);
    } finally {
      _finish(inflight);
    }
  }

  Future<void> _systemone(
    HttpRequest request,
    DecisionCancellation cancellation,
  ) async {
    final bytes = BytesBuilder(copy: false);
    final body = StreamIterator<List<int>>(request);
    final cancelled = cancellation.whenCancelled.then<bool>(
      (_) => throw const JevRequestException(409, 'cancelled', '本次调用已取消'),
    );
    try {
      while (await Future.any([body.moveNext(), cancelled])) {
        bytes.add(body.current);
        if (bytes.length > decisionMaxRequestBytes) {
          request.response.persistentConnection = false;
          throw const JevRequestException(
            413,
            'invalid_input',
            'typed 请求超出字节上限',
          );
        }
      }
    } finally {
      await body.cancel();
    }
    if (cancellation.isCancelled) {
      throw const JevRequestException(409, 'cancelled', '本次调用已取消');
    }
    final parsed = JevModelRequest.parse(
      jsonDecode(utf8.decode(bytes.takeBytes())),
    );
    await _jsonConnection(request, cancellation, () async {
      final result = await jevModels!.decide(
        parsed.model,
        parsed.request,
        cancellation: cancellation,
        debug: parsed.debug,
      );
      return (200, result);
    });
  }

  /// Own the accepted non-streaming connection while inference is pending.
  /// HttpResponse.done otherwise observes a disconnect only after a write;
  /// detaching lets an ordinary client's socket close cancel without sending
  /// early success headers or requiring an in-process cancellation handle.
  Future<void> _jsonConnection(
    HttpRequest request,
    DecisionCancellation cancellation,
    Future<(int, Object)> Function() operation,
  ) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    var peerClosed = false;
    void disconnected() {
      peerClosed = true;
      cancellation.cancel();
    }

    final subscription = socket.listen(
      (_) {},
      onDone: disconnected,
      onError: (Object _) => disconnected(),
    );
    try {
      late (int, Object) reply;
      try {
        reply = await operation();
      } on JevRequestException catch (error) {
        reply = (error.statusCode, error.toJson());
      }
      if (!peerClosed) {
        final bytes = utf8.encode(jsonEncode(reply.$2));
        socket.add(
          ascii.encode(
            'HTTP/1.1 ${reply.$1} Response\r\n'
            'Content-Type: application/json; charset=utf-8\r\n'
            'Content-Length: ${bytes.length}\r\n'
            'Connection: close\r\n\r\n',
          ),
        );
        socket.add(bytes);
        await socket.flush();
      }
    } on SocketException {
      cancellation.cancel();
    } finally {
      await subscription.cancel();
      socket.destroy();
    }
  }

  Future<void> _chat(
    HttpRequest request,
    DecisionCancellation cancellation,
  ) async {
    final parsed = await _readChat(request);
    if (parsed == null) return;
    final target = _routes.resolve(parsed.model);
    if (parsed.stream) {
      unawaited(
        request.response.done.then(
          (_) => cancellation.cancel(),
          onError: (Object _) => cancellation.cancel(),
        ),
      );
      await _chatStream(request, parsed, target, cancellation);
    } else {
      await _chatOnce(request, parsed, target, cancellation);
    }
  }

  Future<_ParsedChat?> _readChat(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    final body = StreamIterator<List<int>>(request);
    try {
      while (await body.moveNext()) {
        builder.add(body.current);
        if (builder.length > _bodyLimit) {
          request.response.persistentConnection = false;
          // Cancelling an unread dart:io request destroys its socket. Finish
          // the bounded rejection first so clients receive the actual 413.
          _sendError(
            request.response,
            413,
            'invalid_request_error',
            '请求体超过 1MiB 上限',
          );
          await request.response.done;
          return null;
        }
      }
    } finally {
      await body.cancel();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    } on FormatException {
      throw const PublicRequestException(
        400,
        'invalid_request_error',
        '请求体不是有效 JSON',
      );
    }
    if (decoded is! Map) {
      throw const PublicRequestException(
        400,
        'invalid_request_error',
        '请求体需要是 JSON 对象',
      );
    }
    const allowed = {
      'model',
      'messages',
      'stream',
      'max_tokens',
      'temperature',
      'top_p',
    };
    for (final key in decoded.keys) {
      if (!allowed.contains(key)) {
        throw PublicRequestException(
          400,
          'invalid_request_error',
          '不支持的字段：$key',
        );
      }
    }
    final model = decoded['model'];
    if (model is! String || model.isEmpty) {
      throw const PublicRequestException(
        400,
        'invalid_request_error',
        'model 需要是非空字符串',
      );
    }
    final messages = decoded['messages'];
    if (messages is! List || messages.isEmpty) {
      throw const PublicRequestException(
        400,
        'invalid_request_error',
        'messages 需要是非空数组',
      );
    }
    final typed = <TextMessage>[];
    try {
      for (final entry in messages) {
        if (entry is! Map) {
          throw const PublicRequestException(
            400,
            'invalid_request_error',
            '消息需要是对象',
          );
        }
        for (final key in entry.keys) {
          if (key != 'role' && key != 'content') {
            throw PublicRequestException(
              400,
              'invalid_request_error',
              '不支持的消息字段：$key',
            );
          }
        }
        final role = entry['role'];
        final content = entry['content'];
        if (role is! String) {
          throw const PublicRequestException(
            400,
            'invalid_request_error',
            '消息 role 需要是字符串',
          );
        }
        if (content is List) {
          throw const PublicRequestException(
            400,
            'invalid_request_error',
            '暂不支持多模态消息内容',
          );
        }
        if (content is! String) {
          throw const PublicRequestException(
            400,
            'invalid_request_error',
            '消息 content 需要是字符串',
          );
        }
        typed.add(TextMessage(role: role, content: content));
      }
      final stream = decoded['stream'];
      if (stream != null && stream is! bool) {
        throw const PublicRequestException(
          400,
          'invalid_request_error',
          'stream 需要是布尔值',
        );
      }
      final maxTokens = decoded['max_tokens'];
      if (maxTokens != null && maxTokens is! int) {
        throw const PublicRequestException(
          400,
          'invalid_request_error',
          'max_tokens 需要是整数',
        );
      }
      final temperature = decoded['temperature'];
      if (temperature != null && temperature is! num) {
        throw const PublicRequestException(
          400,
          'invalid_request_error',
          'temperature 需要是数字',
        );
      }
      final topP = decoded['top_p'];
      if (topP != null && topP is! num) {
        throw const PublicRequestException(
          400,
          'invalid_request_error',
          'top_p 需要是数字',
        );
      }
      return _ParsedChat(
        model: model,
        request: TextRequest.messages(
          messages: typed,
          maxTokens: (maxTokens as int?) ?? 32,
          temperature: (temperature as num?)?.toDouble(),
          topP: (topP as num?)?.toDouble(),
        ),
        stream: (stream as bool?) ?? false,
      );
    } on TextProtocolException catch (error) {
      throw PublicRequestException(400, 'invalid_request_error', error.message);
    }
  }

  Future<void> _chatOnce(
    HttpRequest request,
    _ParsedChat parsed,
    PublicRouteTarget target,
    DecisionCancellation cancellation,
  ) async {
    await _jsonConnection(request, cancellation, () async {
      try {
        final result = await target.runtime.generateText(
          target.instance.id,
          parsed.request,
          cancellation: cancellation,
        );
        return (
          200,
          sealDebugJson({
            'id': _nextCompletionId(),
            'object': 'chat.completion',
            'created': _nowSeconds(),
            'model': target.publicId,
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': result.text},
                'finish_reason': result.finishReason,
              },
            ],
            'usage': result.usage,
          }, projection: JevDebugProjection.llmResponse),
        );
      } on LlamaRequestException catch (error) {
        return _upstreamError(error.kind.name);
      } on OmlxRequestException catch (error) {
        return _upstreamError(error.kind.name);
      }
    });
  }

  Future<void> _chatStream(
    HttpRequest request,
    _ParsedChat parsed,
    PublicRouteTarget target,
    DecisionCancellation cancellation,
  ) async {
    final response = request.response;
    var started = false;
    StreamSubscription<TextStreamEvent>? subscription;
    Timer? heartbeat;
    try {
      final finished = Completer<void>();
      subscription = target.runtime
          .streamText(
            target.instance.id,
            parsed.request,
            cancellation: cancellation,
          )
          .listen(
            (event) {
              final result = event.result;
              if (result != null) {
                final write = started ? _writeSseFrame : _writeSseChunk;
                started = true;
                write(response, target.publicId, {
                  'index': 0,
                  'delta': <String, Object?>{},
                  'finish_reason': result.finishReason,
                }, usage: result.usage);
                response.write('data: [DONE]\n\n');
              } else if (event.delta.isNotEmpty) {
                final first = !started;
                final write = first ? _writeSseChunk : _writeSseFrame;
                started = true;
                write(response, target.publicId, {
                  'index': 0,
                  'delta': {
                    if (first) 'role': 'assistant',
                    'content': event.delta,
                  },
                  'finish_reason': null,
                });
              }
            },
            onError: (Object error) {
              if (!finished.isCompleted) finished.completeError(error);
            },
            onDone: () {
              if (!finished.isCompleted) finished.complete();
            },
          );
      if (heartbeatInterval > Duration.zero) {
        heartbeat = Timer.periodic(heartbeatInterval, (_) {
          try {
            // SSE comment frame: a dead client only surfaces on a write, at
            // which point response.done completes and cancels the upstream.
            response.write(': keep-alive\n\n');
          } catch (_) {
            // The peer is already gone.
          }
        });
      }
      await finished.future;
      await response.close();
    } catch (error) {
      if (!started) {
        // Headers are unsent until the first frame: reply truthfully.
        if (error is LlamaRequestException) {
          _sendUpstreamError(response, error.kind.name);
        } else if (error is OmlxRequestException) {
          _sendUpstreamError(response, error.kind.name);
        } else if (error is HttpException) {
          // The client went away before the first frame.
          try {
            await response.close();
          } catch (_) {}
        } else {
          _sendError(response, 502, 'upstream_error', '上游引擎请求失败');
        }
      } else {
        // Mid-stream failure: drop the connection, never fabricate DONE.
        try {
          await response.close();
        } catch (_) {
          // The peer is already gone.
        }
      }
    } finally {
      heartbeat?.cancel();
      await subscription?.cancel();
    }
  }

  void _writeSseChunk(
    HttpResponse response,
    String publicId,
    Map<String, Object?> choice, {
    Map<String, Object?>? usage,
  }) {
    response
      ..headers.contentType = ContentType('text', 'event-stream')
      ..bufferOutput = false;
    response.write(
      'data: ${jsonEncode(sealDebugJson({
        'id': _nextCompletionId(),
        'object': 'chat.completion.chunk',
        'created': _nowSeconds(),
        'model': publicId,
        'choices': [choice],
        'usage': ?usage,
      }, projection: JevDebugProjection.llmResponse))}\n\n',
    );
  }

  void _writeSseFrame(
    HttpResponse response,
    String publicId,
    Map<String, Object?> choice, {
    Map<String, Object?>? usage,
  }) {
    // Headers are only mutable before the first frame commits them.
    response.write(
      'data: ${jsonEncode(sealDebugJson({
        'id': _nextCompletionId(),
        'object': 'chat.completion.chunk',
        'created': _nowSeconds(),
        'model': publicId,
        'choices': [choice],
        'usage': ?usage,
      }, projection: JevDebugProjection.llmResponse))}\n\n',
    );
  }

  (int, Map<String, Object?>) _upstreamError(String kind) {
    final (status, type, message) = switch (kind) {
      'notReady' => (503, 'model_not_ready', '模型实例未就绪'),
      'cancelled' => (499, 'cancelled', '请求已取消'),
      'timedOut' || 'timeout' => (504, 'upstream_timeout', '上游生成超时'),
      _ => (502, 'upstream_error', '上游引擎请求失败'),
    };
    return (
      status,
      {
        'error': {'message': message, 'type': type},
      },
    );
  }

  void _sendUpstreamError(HttpResponse response, String kind) {
    final (status, body) = _upstreamError(kind);
    _sendJson(response, status, body);
  }

  String _nextCompletionId() => 'chatcmpl-gmd-${++_requestCounter}';

  int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _sendJson(HttpResponse response, int status, Object body) {
    try {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      unawaited(response.close().catchError((Object _) {}));
    } catch (_) {
      // The peer disconnected before the reply could be written.
    }
  }

  void _sendError(
    HttpResponse response,
    int status,
    String type,
    String message,
  ) {
    _sendJson(response, status, {
      'error': {'message': message, 'type': type},
    });
  }

  void _setState(PublicGatewayState state) {
    _state = state;
    _changes.add(state);
  }
}
