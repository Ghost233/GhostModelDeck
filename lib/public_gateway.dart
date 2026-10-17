import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'chat_protocol.dart';
import 'decision_protocol.dart';
import 'embedding_protocol.dart';
import 'engine_runtime.dart';
import 'jev_models.dart';
import 'jev_debug.dart';
import 'llama_engine.dart';
import 'model_library.dart';
import 'omlx_engine.dart';
import 'launch_instances.dart';
import 'public_model_names.dart';
import 'model_scenarios.dart';

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

/// Public names are allocated from model names and persisted by artifact
/// identity. Collision suffixes remain stable across restarts and never
/// expose native aliases or internal ports. Enable/disable is an explicit
/// business operation; cold, unknown or ambiguous routes are refused with
/// zero upstream contact.
class PublicModelRoutes {
  PublicModelRoutes({
    required this._library,
    required List<EngineRuntime> runtimes,
    this._runtimeSources,
    this._registryFile,
    Set<String>? instanceIds,
    LaunchInstances? instances,
    this.scenarios,
  }) : _runtimes = List.unmodifiable(runtimes),
       _instances = instances,
       _instanceIds = instanceIds == null
           ? null
           : Set.unmodifiable(instanceIds) {
    _librarySubscription = _library.changes.listen((_) {
      unawaited(_refreshNames());
    });
    _instanceSubscription = instances?.changes.listen((_) {
      if (!_closed) _changes.add(null);
    });
    _scenarioSubscription = scenarios?.changes.listen((_) {
      if (!_closed) _changes.add(null);
    });
  }

  static const _schema = 2;

  final ModelLibrary _library;
  final List<EngineRuntime> _runtimes;
  final Set<String>? _instanceIds;
  final LaunchInstances? _instances;
  final ModelScenarios? scenarios;
  StreamSubscription<void>? _instanceSubscription;
  StreamSubscription<void>? _scenarioSubscription;
  Iterable<String> get _registeredIds =>
      _instances?.definitions.map((definition) => definition.id) ?? _enabled;
  Iterable<({String id, String name})> get _registrations sync* {
    for (final id in _registeredIds.toList()..sort()) {
      yield (id: id, name: publicIdFor(id));
    }
    if (_instances != null && scenarios != null) {
      for (final scenario in scenarios!.entries) {
        if (scenario.enabled &&
            scenario.modelName.isNotEmpty &&
            scenario.instanceId != null) {
          yield (id: scenario.instanceId!, name: scenario.modelName);
        }
      }
    }
  }

  final List<EngineRuntime> Function()? _runtimeSources;
  final File? _registryFile;
  final Set<String> _enabled = {};
  final _publicIds = <String, String>{};
  final _persistedIds = <String, String>{};
  final _changes = StreamController<void>.broadcast();
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  late final StreamSubscription<LibraryState> _librarySubscription;
  Object? _nameStorageError;
  String? get error => _nameStorageError?.toString();

  Future<void> _refreshNames() async {
    try {
      await load();
      if (_closed) return;
      var dirty = _nameStorageError != null;
      for (final artifact in _library.state.artifacts) {
        if (_enabled.contains(artifact.id)) {
          final name = publicIdFor(artifact.id);
          if (_persistedIds[artifact.id] != name) dirty = true;
        }
      }
      if (dirty) {
        await _persist();
        _nameStorageError = null;
        if (!_closed) _changes.add(null);
      }
    } catch (error) {
      _nameStorageError = error;
      if (!_closed) _changes.add(null);
    }
  }

  bool _closed = false;

  Stream<void> get changes => _changes.stream;

  String publicIdFor(String artifactId) {
    if (_instances != null) {
      final definition = _instances.find(artifactId);
      if (definition == null) throw StateError('实例配置不存在：$artifactId');
      return definition.publicName;
    }
    final saved = _publicIds[artifactId];
    if (saved != null) return saved;
    final artifact = _library.state.artifacts
        .where((a) => a.id == artifactId)
        .singleOrNull;
    if (artifact == null) throw StateError('模型不在当前模型库中：$artifactId');
    final base = PublicModelNames.normalize(artifact.name);
    var candidate = base;
    var suffix = 2;
    while (_publicIds.containsValue(candidate)) {
      candidate = '$base-${suffix++}';
    }
    _publicIds[artifactId] = candidate;
    return candidate;
  }

  bool isEnabled(String artifactId) => _instances == null
      ? _enabled.contains(artifactId)
      : _instances.find(artifactId) != null;

  Future<void> load() {
    if (_loaded || _closed) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    if (_loaded || _closed) return;
    if (_instances != null) {
      await _instances.load();
      await scenarios?.load();
      _loaded = true;
      return;
    }
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
    final ids = value['publicIds'];
    if (ids is! Map ||
        ids.entries.any(
          (e) =>
              e.key is! String ||
              e.value is! String ||
              (e.value as String).toLowerCase() != e.value ||
              !RegExp(
                r'^[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*$',
                unicode: true,
              ).hasMatch(e.value as String),
        ) ||
        ids.values.toSet().length != ids.length) {
      throw StateError('公开模型名称登记文件无效：${file.path}');
    }
    _publicIds.clear();
    _publicIds.addAll(ids.cast<String, String>());
    _persistedIds.addAll(ids.cast<String, String>());
    _enabled.addAll(enabled.cast<String>());
    for (final id in _enabled) {
      if (_library.state.artifacts.any((a) => a.id == id)) publicIdFor(id);
    }
    _loaded = true;
  }

  Future<void> enable(String artifactId) async {
    _ensureOpen();
    await load();
    if (_instances != null) {
      if (_instances.find(artifactId) == null) throw StateError('实例配置不存在');
      return;
    }
    final artifact = _library.state.artifacts
        .where((entry) => entry.id == artifactId)
        .firstOrNull;
    if (artifact == null) {
      throw StateError('公开模型不存在于模型库：$artifactId');
    }
    if (_instanceIds == null &&
        artifact.kind != AssetKind.chat &&
        artifact.kind != AssetKind.embedding) {
      throw StateError('仅标准文本或嵌入模型可登记公开访问：$artifactId');
    }
    final publicId = publicIdFor(artifactId);
    final conflict = _enabled.any(
      (other) => other != artifactId && publicIdFor(other) == publicId,
    );
    if (conflict) {
      throw StateError('公开模型 ID 冲突：$publicId');
    }
    final changed = _enabled.add(artifactId);
    await _persist();
    if (changed) _changes.add(null);
  }

  Future<void> disable(String artifactId) async {
    _ensureOpen();
    await load();
    if (_instances != null) throw StateError('公开访问随保存实例的启动和停止管理');
    if (_enabled.remove(artifactId)) {
      await _persist();
      _changes.add(null);
    }
  }

  /// Enabled artifacts that currently have at least one ready text instance.
  List<PublicModelEntry> listModels({
    RuntimeCapability requiredCapability = RuntimeCapability.textGeneration,
  }) {
    final entries = <PublicModelEntry>[];
    for (final entry in _registrations) {
      final artifactId = entry.id;
      final ready = _readyInstances(artifactId, requiredCapability);
      if (requiredCapability == RuntimeCapability.embeddings
          ? ready.length == 1
          : ready.isNotEmpty) {
        entries.add(
          PublicModelEntry(
            publicId: entry.name,
            artifactId: ready.first.instance.artifactId,
          ),
        );
      }
    }
    return entries;
  }

  /// Per-request resolution. Refusals happen before any upstream contact.
  PublicRouteTarget resolve(
    String publicId, {
    RuntimeCapability requiredCapability = RuntimeCapability.textGeneration,
  }) {
    _ensureOpen();
    final artifactId = _registrations
        .where((entry) => entry.name == publicId)
        .firstOrNull
        ?.id;
    if (artifactId == null || !isEnabled(artifactId)) {
      throw const PublicRequestException(
        404,
        'model_not_found',
        '公开模型不存在或未启用公开访问',
      );
    }
    final ready = _readyInstances(artifactId, requiredCapability);
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
      artifactId: hit.instance.artifactId,
      runtime: hit.runtime,
      instance: hit.instance,
    );
  }

  List<({EngineRuntime runtime, RuntimeInstance instance})> _readyInstances(
    String artifactId,
    RuntimeCapability capability,
  ) {
    final found = <({EngineRuntime runtime, RuntimeInstance instance})>[];
    // Linked and source-built registrations can arrive after these routes.
    // Several catalog entries may also share one runtime pool.
    final runtimes = Set<EngineRuntime>.identity()
      ..addAll(_runtimeSources?.call() ?? _runtimes);
    for (final runtime in runtimes) {
      for (final instance in runtime.runtimeInstances) {
        if ((_instances == null
                ? instance.artifactId == artifactId
                : instance.launchInstanceId == artifactId) &&
            (_instanceIds == null
                ? !instance.temporaryTest
                : _instanceIds.contains(instance.id)) &&
            instance.status == RuntimeInstanceStatus.ready &&
            !(_instances?.isStarting(artifactId) ?? false) &&
            instance.acceptingRequests &&
            instance.hasLiveProcess &&
            instance.capabilities.contains(capability) &&
            (capability != RuntimeCapability.embeddings ||
                runtime is EmbeddingRuntime)) {
          found.add((runtime: runtime, instance: instance));
        }
      }
    }
    return found;
  }

  /// Saved instances publish applied capacity, not pending edits. Legacy routes
  /// use the sole callable runtime's observation. Ambiguous routes stay absent.
  List<Map<String, Object?>> capacityModels() {
    final entries = <Map<String, Object?>>[];
    for (final entry in _registrations) {
      final artifactId = entry.id;
      final artifact = _library.state.artifacts
          .where(
            (artifact) =>
                artifact.id ==
                (_instances?.find(artifactId)?.artifactId ?? artifactId),
          )
          .firstOrNull;
      if (_instances == null &&
          (artifact == null ||
              (artifact.kind != AssetKind.chat &&
                  artifact.kind != AssetKind.embedding))) {
        continue;
      }
      final capability =
          (_instances == null
              ? artifact!.kind == AssetKind.embedding
              : _readyInstances(
                  artifactId,
                  RuntimeCapability.embeddings,
                ).isNotEmpty)
          ? RuntimeCapability.embeddings
          : RuntimeCapability.textGeneration;
      final ready = _readyInstances(artifactId, capability);
      if (ready.length != 1) continue;
      final capacity = ready.single.instance.capacity;
      final context = _instances == null
          ? capacity?.contextPerSlot
          : _instances.contextLengthFor(artifactId);
      if (capacity == null ||
          context == null ||
          context <= 0 ||
          capacity.slotCount <= 0) {
        continue;
      }
      final publicId = entry.name;
      entries.add({
        'key': publicId,
        'type': capability == RuntimeCapability.embeddings
            ? 'embedding'
            : 'llm',
        'source': 'ghost-model-deck',
        'loaded_instances': [
          {
            'id': publicId,
            'config': {
              'context_length': context,
              'max_concurrent_requests': capacity.slotCount,
            },
          },
        ],
      });
    }
    return entries;
  }

  Future<void> _persist() {
    final file = _registryFile;
    if (file == null) return Future.value();
    final enabled = _enabled.toList()..sort();
    final names = Map<String, String>.from(_publicIds);
    final text = jsonEncode({
      'schema': _schema,
      'enabled': enabled,
      'publicIds': names,
    });
    final operation = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
      _persistedIds.clear();
      _persistedIds.addAll(names);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('公开路由层已关闭');
    if (_nameStorageError != null) {
      throw StateError('公开模型名称保存失败：$_nameStorageError');
    }
  }

  void close() {
    _closed = true;
    unawaited(_librarySubscription.cancel());
    unawaited(_instanceSubscription?.cancel());
    unawaited(_scenarioSubscription?.cancel());
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
        final nativeModels =
            jevModels?.callableModels ?? <JevModelAvailability>[];
        final nativeNames = nativeModels
            .map((entry) => entry.definition.name)
            .toSet();
        _sendJson(request.response, 200, {
          'object': 'list',
          'data': [
            for (final entry in nativeModels)
              {
                ...entry.toJson(),
                'object': 'model',
                'owned_by': 'ghostmodeldeck',
              },
            for (final entry in _routes.listModels())
              if (!nativeNames.contains(entry.publicId))
                {
                  'id': entry.publicId,
                  'object': 'model',
                  'owned_by': 'ghostmodeldeck',
                },
            for (final entry in _routes.listModels(
              requiredCapability: RuntimeCapability.embeddings,
            ))
              {
                'id': entry.publicId,
                'object': 'model',
                'owned_by': 'ghostmodeldeck',
                'type': 'embedding',
                'source': 'embedding',
              },
          ],
        });
        return;
      }
      if (request.method == 'GET' && path == '/api/v1/models') {
        _sendJson(request.response, 200, {
          'source': 'ghost-model-deck',
          'models': [
            ..._routes.capacityModels(),
            ...?jevModels?.capacityModels(),
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
      if (request.method == 'POST' && path == '/v1/embeddings') {
        await _embeddings(request, inflight.cancellation);
        return;
      }
      _sendError(request.response, 404, 'invalid_request_error', '路径不存在');
    } on JevRequestException catch (error) {
      _sendJson(request.response, error.statusCode, error.toJson());
    } on DecisionProtocolException catch (error) {
      _sendJson(request.response, 400, {
        'error': {'code': 'invalid_input', 'message': error.message},
      });
    } on EmbeddingProtocolException catch (error) {
      _sendError(request.response, 400, 'invalid_request_error', error.message);
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
          // Cancelling an unread dart:io request destroys its socket. Finish
          // the bounded rejection first so clients receive the actual 413.
          _sendJson(
            request.response,
            413,
            const JevRequestException(
              413,
              'invalid_input',
              'typed 请求超出字节上限',
            ).toJson(),
          );
          await request.response.done;
          return;
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

  Future<void> _embeddings(
    HttpRequest request,
    DecisionCancellation cancellation,
  ) async {
    final builder = BytesBuilder(copy: false);
    final body = StreamIterator<List<int>>(request);
    final cancelled = cancellation.whenCancelled.then<bool>(
      (_) => throw const PublicRequestException(409, 'cancelled', '本次调用已取消'),
    );
    try {
      while (await Future.any([body.moveNext(), cancelled])) {
        builder.add(body.current);
        if (builder.length > _bodyLimit) {
          request.response.persistentConnection = false;
          _sendError(
            request.response,
            413,
            'invalid_request_error',
            '请求体超过 1MiB 上限',
          );
          await request.response.done;
          return;
        }
      }
    } finally {
      await body.cancel();
    }
    if (cancellation.isCancelled) {
      throw const PublicRequestException(409, 'cancelled', '本次调用已取消');
    }
    final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    if (decoded is! Map) {
      throw const EmbeddingProtocolException('请求体需要是 JSON 对象');
    }
    final parsed = EmbeddingRequest.fromJson(
      Map<String, Object?>.from(decoded),
    );
    final target = _routes.resolve(
      parsed.model,
      requiredCapability: RuntimeCapability.embeddings,
    );
    final runtime = target.runtime;
    if (runtime is! EmbeddingRuntime) {
      throw const PublicRequestException(
        503,
        'model_not_ready',
        '嵌入运行实例当前不可调用',
      );
    }
    await _jsonConnection(request, cancellation, () async {
      try {
        final result = await runtime.generateEmbeddings(
          target.instance.id,
          parsed,
          cancellation: cancellation,
        );
        return (
          200,
          sealDebugJson({
            ...result.toJson(),
            'model': target.publicId,
          }, projection: JevDebugProjection.embeddingResponse),
        );
      } on DecisionCallFailure catch (error) {
        return _upstreamError(error.kind.name);
      } on LlamaEngineException {
        // Identity failures retain their original error and cleanup in the
        // engine. The public connection must still receive an HTTP verdict.
        return _upstreamError('failed');
      } on EmbeddingProtocolException {
        return _upstreamError('invalidResponse');
      }
    });
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
      } on DecisionCallFailure catch (error) {
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
              if (finished.isCompleted) return;
              try {
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
              } catch (error, stack) {
                if (!finished.isCompleted) {
                  finished.completeError(error, stack);
                }
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
          // The first actual frame owns SSE headers. Earlier failures must
          // still be able to select their truthful JSON status and headers.
          if (!started || finished.isCompleted) return;
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
        if (error is DecisionCallFailure) {
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
