import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'decision_protocol.dart';
import 'model_library.dart';
import 'model_use_registry.dart';

enum ProviderConnection {
  pending,
  connected,
  connectionFailed,
  authenticationRequired,
}

enum InstanceCapability {
  pending,
  ready,
  unsupported,
  invalidResponse,
  connectionFailed,
  authenticationRequired,
}

enum InstanceOwnership { attached, managed }

class CliResult {
  const CliResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class LmStudioCli {
  Future<CliResult> run(List<String> arguments, {required Duration timeout});
}

class ProcessLmStudioCli implements LmStudioCli {
  ProcessLmStudioCli(this.path);
  final String path;

  @override
  Future<CliResult> run(
    List<String> arguments, {
    required Duration timeout,
  }) async {
    final process = await Process.start(path, arguments, runInShell: false);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(timeout);
      return CliResult(code, await output, await errors);
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      await Future.wait([output, errors]);
      rethrow;
    }
  }
}

class LmStudioRuntime {
  const LmStudioRuntime(this.identifier, this.format, this.selected);
  final String identifier;
  final String format;
  final bool selected;
}

class LmStudioModel {
  const LmStudioModel({
    required this.key,
    required this.indexedPath,
    required this.name,
    required this.format,
    required this.sizeBytes,
    this.isLocal = false,
  });
  final String key;
  final String indexedPath;
  final String name;
  final String format;
  final int sizeBytes;
  final bool isLocal;
}

class LmStudioInstance {
  const LmStudioInstance({
    required this.id,
    required this.modelKey,
    required this.indexedPath,
    this.ownership = InstanceOwnership.attached,
    this.capability = InstanceCapability.pending,
    this.runtimeVersion,
    this.error,
    this.lastResult,
    this.isLocal = false,
    this.isRemote = false,
    this.format,
    this.sizeBytes,
  });
  final String id;
  final String modelKey;
  final String indexedPath;
  final InstanceOwnership ownership;
  final InstanceCapability capability;
  final String? runtimeVersion;
  final String? error;
  final DecisionResult? lastResult;
  final bool isLocal;
  final bool isRemote;
  final String? format;
  final int? sizeBytes;
}

class LmStudioState {
  LmStudioState({
    this.connection = ProviderConnection.pending,
    this.busy = false,
    this.cliVersion,
    this.appVersion,
    this.endpoint,
    this.error,
    List<LmStudioRuntime> runtimes = const [],
    List<LmStudioModel> models = const [],
    List<LmStudioInstance> instances = const [],
  }) : runtimes = List.unmodifiable(runtimes),
       models = List.unmodifiable(models),
       instances = List.unmodifiable(instances);
  final ProviderConnection connection;
  final bool busy;
  final String? cliVersion;
  final String? appVersion;
  final Uri? endpoint;
  final String? error;
  final List<LmStudioRuntime> runtimes;
  final List<LmStudioModel> models;
  final List<LmStudioInstance> instances;
}

class LmStudioProvider {
  LmStudioProvider({
    required this.library,
    String? cliPath,
    LmStudioCli? cli,
    Uri? endpoint,
    ModelUseRegistry? useRegistry,
    this.ioTimeout = const Duration(seconds: 10),
    this.loadTimeout = const Duration(seconds: 120),
  }) : _cli =
           cli ??
           ProcessLmStudioCli(
             cliPath ?? '${Platform.environment['HOME']}/.lmstudio/bin/lms',
           ),
       _configuredEndpoint = endpoint,
       _useRegistry = useRegistry ?? ModelUseRegistry(library);
  final ModelLibrary library;
  final LmStudioCli _cli;
  final Uri? _configuredEndpoint;
  final ModelUseRegistry _useRegistry;
  final Duration ioTimeout;
  final Duration loadTimeout;
  final _changes = StreamController<LmStudioState>.broadcast();
  LmStudioState _state = LmStudioState();
  LmStudioState get state => _state;
  Stream<LmStudioState> get changes => _changes.stream;
  String? _token;
  String? _modelLibraryPath;
  String? get confirmedModelLibraryPath => _modelLibraryPath;
  Future<void> _operations = Future.value();
  final _owned = <String, LmStudioInstance>{};
  final _reservedFiles = <String, Set<String>>{};

  Future<T> _serial<T>(Future<T> Function() work) {
    final operation = _operations.then((_) => work());
    _operations = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> confirmModelLibrary(String path) => _serial(() async {
    final canonical = await Directory(path).resolveSymbolicLinks();
    if (_modelLibraryPath != null &&
        _modelLibraryPath != canonical &&
        (state.instances.isNotEmpty || _reservedFiles.isNotEmpty)) {
      throw const LmStudioException('请先停止运行实例并刷新，再修改关联目录');
    }
    _modelLibraryPath = canonical;
    await _protectFiles();
  });

  Future<LmStudioInstance> load(String artifactId) => _serial(() async {
    await _discover();
    if (state.cliVersion != 'CLI commit: 69d945a') {
      throw const LmStudioException('此 CLI 版本的精确加载尚未验证');
    }
    if (_modelLibraryPath == null ||
        library.state.rootPath != _modelLibraryPath) {
      throw const LmStudioException('请先确认 LM Studio 与当前模型库使用同一目录');
    }
    final selected = library.state.artifacts
        .where((value) => value.id == artifactId)
        .toList();
    if (selected.length != 1 ||
        selected.single.kind != AssetKind.decision ||
        selected.single.integrity != AssetIntegrity.complete ||
        !selected.single.fingerprintsVerified) {
      throw const LmStudioException('请选择完整且已核验的决策模型');
    }
    final asset = selected.single;
    final prefix = '${_modelLibraryPath!}${Platform.pathSeparator}';
    final candidates = state.models
        .where(
          (model) =>
              model.isLocal &&
              model.format.toLowerCase() == asset.format.toLowerCase() &&
              asset.files.any(
                (file) =>
                    file.path.startsWith(prefix) &&
                    file.path.substring(prefix.length) == model.indexedPath,
              ) &&
              model.sizeBytes == asset.sizeBytes,
        )
        .toList();
    if (candidates.length != 1) {
      throw const LmStudioException('LM Studio 无唯一匹配的本地模型变体');
    }
    final model = candidates.single;
    final random = Random.secure();
    final identifier =
        'ghostmodeldeck-${List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    if (state.instances.any((value) => value.id == identifier)) {
      throw const LmStudioException('实例标识冲突');
    }
    _reservedFiles[identifier] = asset.files.map((file) => file.path).toSet();
    await _protectFiles();
    var created = false;
    String? cliFailure;
    try {
      final verified = (await library.verify([asset.id])).single;
      if (verified.integrity != AssetIntegrity.complete ||
          verified.files.length != asset.files.length ||
          verified.files.any(
            (file) => !asset.files.any(
              (previous) =>
                  previous.path == file.path &&
                  previous.sizeBytes == file.sizeBytes &&
                  previous.sha256 == file.sha256,
            ),
          )) {
        throw const LmStudioException('模型在加载前变化，请重新核验');
      }
    } catch (_) {
      // No external load was attempted, so this is a definite local failure.
      _reservedFiles.remove(identifier);
      await _protectFiles();
      rethrow;
    }
    try {
      final result = await _cli.run([
        'load',
        '--exact',
        '--local',
        model.indexedPath,
        '--identifier',
        identifier,
        '--context-length',
        '2048',
        '-y',
      ], timeout: loadTimeout);
      created = result.exitCode == 0;
      if (!created) {
        final reason = _safeCliReason(result.stderr);
        cliFailure = reason.isEmpty ? 'CLI 退出码 ${result.exitCode}' : reason;
      }
    } catch (_) {
      // An interrupted CLI does not establish that its instance was never created.
    }
    String? confirmedFailure;
    try {
      await _discover();
      _reservedFiles.remove(identifier);
      final instances = state.instances
          .where((value) => value.id == identifier)
          .toList();
      if (created &&
          instances.length == 1 &&
          instances.single.isLocal &&
          instances.single.indexedPath == model.indexedPath &&
          instances.single.modelKey == model.key &&
          instances.single.format == model.format &&
          instances.single.sizeBytes == model.sizeBytes) {
        final instance = instances.single;
        _owned[identifier] = instance;
        _replaceInstances([
          for (final value in state.instances)
            value.id == identifier
                ? _withInstance(value, ownership: InstanceOwnership.managed)
                : value,
        ]);
        await _protectFiles();
        return state.instances.singleWhere((value) => value.id == identifier);
      }
      await _protectFiles();
      if (!created && cliFailure != null && instances.isEmpty) {
        confirmedFailure = cliFailure;
      }
    } catch (_) {
      // Retain reserved paths when discovery fails; do not allow unsafe deletion.
      if (!state.instances.any((value) => value.id == identifier)) {
        _reservedFiles[identifier] = asset.files
            .map((file) => file.path)
            .toSet();
      }
      await _protectFiles();
    }
    if (confirmedFailure != null) {
      throw LmStudioException('加载失败：$confirmedFailure');
    }
    throw const LmStudioException('加载未能确认；请刷新实例状态');
  });

  String _safeCliReason(String raw) {
    var value = raw
        .replaceAll(RegExp(r'\x1B\][^\x07]*(?:\x07|\x1B\\)'), '')
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
    final token = _token;
    if (token != null) {
      value = value
          .replaceAll(token, '<REDACTED>')
          .replaceAll(Uri.encodeComponent(token), '<REDACTED>');
    }
    value = value.replaceAll(
      RegExp(r'authorization\s*:\s*[^\r\n]+', caseSensitive: false),
      'Authorization: <REDACTED>',
    );
    value = value.replaceAll(
      RegExp(r'\bBearer\s+\S+', caseSensitive: false),
      'Bearer <REDACTED>',
    );
    value = value.replaceAllMapped(
      RegExp(
        r'''(\b(?:[\w.-]*[_-])?(?:api[_-]?key|token|password|secret)\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&]+)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<REDACTED>',
    );
    value = value.replaceAllMapped(
      RegExp(r'\b(https?://)[^/\s:@]+:[^@\s]+@', caseSensitive: false),
      (match) => '${match[1]}<REDACTED>@',
    );
    value = value
        .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return value.length > 1024 ? '${value.substring(0, 1024)}…' : value;
  }

  Future<void> stop(String instanceId) => _serial(() async {
    await _discover();
    if (!_owned.containsKey(instanceId)) {
      throw const LmStudioException('仅可停止本应用创建的受管实例');
    }
    try {
      await _command(['unload', instanceId]);
    } catch (_) {
      /* Reconcile an ambiguous unload. */
    }
    await _discover();
    if (state.instances.any((value) => value.id == instanceId)) {
      throw const LmStudioException('实例尚未确认停止');
    }
    await _protectFiles();
  });

  Future<void> stopManaged() async {
    for (final identifier in _owned.keys.toList()) {
      await stop(identifier);
    }
  }

  void setToken(String? token) {
    _token = token == null || token.isEmpty ? null : token;
  }

  Future<DecisionResult?> probe(String instanceId) async {
    try {
      return await decide(
        instanceId,
        DecisionRequest(
          state: 'A change has been requested.',
          instructions: 'Choose an action.',
          options: {
            'keep': 'Keep the current setting.',
            'change': 'Apply the requested change.',
          },
        ),
      );
    } on LmStudioException {
      return null;
    }
  }

  Future<DecisionResult> decide(
    String instanceId,
    DecisionRequest request,
  ) async {
    final instance = state.instances
        .where((value) => value.id == instanceId)
        .toList();
    if (instance.length != 1 || state.endpoint == null) {
      throw const LmStudioException('实例不可用，请刷新');
    }
    final expected = instance.single;
    final endpoint = state.endpoint!;
    final client = HttpClient()..connectionTimeout = ioTimeout;
    HttpClientRequest? outgoing;
    final watch = Stopwatch()..start();
    Future<DecisionResult> perform() async {
      outgoing = await client.postUrl(endpoint.resolve('/v1/systemone'));
      outgoing!.headers.contentType = ContentType.json;
      if (_token != null) {
        outgoing!.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_token',
        );
      }
      outgoing!.write(jsonEncode(request.toSystemone(model: instanceId)));
      final response = await outgoing!.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const _CapabilityFailure(
          InstanceCapability.authenticationRequired,
          '需要 LM Studio API 令牌',
        );
      }
      if (response.statusCode == 404 || response.statusCode == 501) {
        throw const _CapabilityFailure(
          InstanceCapability.unsupported,
          '此实例未提供 typed decision 接口',
        );
      }
      if (response.statusCode != 200) {
        throw _CapabilityFailure(
          InstanceCapability.invalidResponse,
          '决策请求失败（HTTP ${response.statusCode}）',
        );
      }
      return DecisionResult.parse(
        raw,
        request,
        expectedModel: instanceId,
        elapsed: watch.elapsed,
      );
    }

    try {
      final result = await perform().timeout(ioTimeout);
      if (state.endpoint != endpoint || !_uniqueIdentity(expected)) {
        throw const DecisionProtocolException('决策期间实例身份已变化，请重新验证');
      }
      _updateInstance(expected, InstanceCapability.ready, result: result);
      return result;
    } on _CapabilityFailure catch (error) {
      _updateInstance(expected, error.capability, error: error.message);
      throw LmStudioException(error.message);
    } on DecisionProtocolException catch (error) {
      _updateInstance(
        expected,
        InstanceCapability.invalidResponse,
        error: error.message,
      );
      throw LmStudioException(error.message);
    } catch (_) {
      _updateInstance(
        expected,
        InstanceCapability.connectionFailed,
        error: '决策连接失败或超时',
      );
      throw const LmStudioException('决策连接失败或超时');
    } finally {
      outgoing?.abort();
      client.close(force: true);
    }
  }

  void _updateInstance(
    LmStudioInstance expected,
    InstanceCapability capability, {
    String? error,
    DecisionResult? result,
  }) {
    if (!_uniqueIdentity(expected)) return;
    final instances = [
      for (final value in state.instances)
        _sameIdentity(value, expected)
            ? LmStudioInstance(
                id: value.id,
                modelKey: value.modelKey,
                indexedPath: value.indexedPath,
                ownership: value.ownership,
                capability: capability,
                runtimeVersion: value.runtimeVersion,
                error: error,
                lastResult: result,
                isLocal: value.isLocal,
                isRemote: value.isRemote,
                format: value.format,
                sizeBytes: value.sizeBytes,
              )
            : value,
    ];
    _publish(
      LmStudioState(
        connection: capability == InstanceCapability.authenticationRequired
            ? ProviderConnection.authenticationRequired
            : state.connection == ProviderConnection.authenticationRequired
            ? ProviderConnection.connected
            : state.connection,
        cliVersion: state.cliVersion,
        appVersion: state.appVersion,
        endpoint: state.endpoint,
        runtimes: state.runtimes,
        models: state.models,
        instances: instances,
      ),
    );
  }

  Future<String> _command(List<String> arguments) async {
    final result = await _cli.run(arguments, timeout: ioTimeout);
    if (result.exitCode != 0) {
      throw const LmStudioException('LM Studio CLI 操作失败');
    }
    return result.stdout;
  }

  Future<void> refresh() => _serial(() async {
    try {
      await _discover();
    } catch (_) {
      _publish(
        LmStudioState(
          connection: ProviderConnection.connectionFailed,
          cliVersion: state.cliVersion,
          endpoint: state.endpoint,
          runtimes: state.runtimes,
          models: state.models,
          instances: state.instances,
          error: '无法读取 LM Studio，请检查应用与 CLI',
        ),
      );
    }
  });

  Future<void> _discover() async {
    final version = (await _command(['--version'])).trim();
    final server = jsonDecode(
      await _command(['server', 'status', '--json']),
    ) as Map<String, dynamic>;
    final runtimes = <LmStudioRuntime>[];
    for (final line in (await _command(['runtime', 'ls'])).split('\n')) {
      final match = RegExp(r'^\s*(\S+@\S+)\s+(✓\s+)?(\S+)\s*$')
          .firstMatch(line);
      if (match != null) {
        runtimes.add(LmStudioRuntime(match[1]!, match[3]!, match[2] != null));
      }
    }
    final rawModels = jsonDecode(await _command(['ls', '--json'])) as List;
    final models = [
      for (final value in rawModels)
        LmStudioModel(
          key: value['modelKey'] as String,
          indexedPath: value['path'] as String,
          name: (value['displayName'] ?? value['modelKey']) as String,
          format: value['format'] as String,
          sizeBytes: value['sizeBytes'] as int,
          isLocal:
              value.containsKey('deviceIdentifier') &&
              value['deviceIdentifier'] == null,
        ),
    ];
    final rawInstances = jsonDecode(await _command(['ps', '--json'])) as List;
    final instances = [
      for (final value in rawInstances)
        LmStudioInstance(
          id: value['identifier'] as String,
          modelKey: value['modelKey'] as String,
          indexedPath: value['path'] as String,
          isLocal:
              value.containsKey('deviceIdentifier') &&
              value['deviceIdentifier'] == null,
          isRemote: value['deviceIdentifier'] is String,
          format: value['format'] as String?,
          sizeBytes: value['sizeBytes'] as int?,
        ),
    ];
    final port = server['port'];
    final endpoint =
        _configuredEndpoint ??
        (port is int && port > 0 && port <= 65535
            ? Uri.parse('http://127.0.0.1:$port')
            : null);
    for (final id in _owned.keys.toList()) {
      final matches = instances.where((value) => value.id == id).toList();
      if (matches.length != 1 || !_sameIdentity(matches.single, _owned[id]!)) {
        _owned.remove(id);
      }
    }
    final reconciled = [
      for (final instance in instances)
        _withInstance(
          instance,
          ownership: _owned.containsKey(instance.id)
              ? InstanceOwnership.managed
              : InstanceOwnership.attached,
          previous: state.instances
              .where((value) => _sameIdentity(value, instance))
              .firstOrNull,
        ),
    ];
    _publish(
      LmStudioState(
        connection: server['running'] == true && endpoint != null
            ? ProviderConnection.connected
            : ProviderConnection.connectionFailed,
        cliVersion: version,
        endpoint: endpoint,
        runtimes: runtimes,
        models: models,
        instances: reconciled,
        error: server['running'] == true ? null : 'LM Studio 服务未运行',
      ),
    );
    await _protectFiles();
  }

  bool _sameIdentity(LmStudioInstance a, LmStudioInstance b) =>
      a.id == b.id &&
      a.modelKey == b.modelKey &&
      a.indexedPath == b.indexedPath &&
      a.isLocal == b.isLocal &&
      a.isRemote == b.isRemote &&
      a.format == b.format &&
      a.sizeBytes == b.sizeBytes;

  bool _uniqueIdentity(LmStudioInstance expected) {
    final matches = state.instances
        .where((value) => value.id == expected.id)
        .toList();
    return matches.length == 1 && _sameIdentity(matches.single, expected);
  }

  LmStudioInstance _withInstance(
    LmStudioInstance value, {
    InstanceOwnership? ownership,
    LmStudioInstance? previous,
  }) => LmStudioInstance(
    id: value.id,
    modelKey: value.modelKey,
    indexedPath: value.indexedPath,
    isLocal: value.isLocal,
    isRemote: value.isRemote,
    format: value.format,
    sizeBytes: value.sizeBytes,
    ownership: ownership ?? value.ownership,
    capability: previous?.capability ?? value.capability,
    runtimeVersion: value.runtimeVersion,
    error: previous?.error ?? value.error,
    lastResult: previous?.lastResult ?? value.lastResult,
  );

  void _replaceInstances(List<LmStudioInstance> instances) => _publish(
    LmStudioState(
      connection: state.connection,
      cliVersion: state.cliVersion,
      appVersion: state.appVersion,
      endpoint: state.endpoint,
      runtimes: state.runtimes,
      models: state.models,
      instances: instances,
    ),
  );

  Future<void> _protectFiles() async {
    final paths = {for (final files in _reservedFiles.values) ...files};
    final root = _modelLibraryPath;
    if (root != null) {
      for (final instance in state.instances.where(
        (value) => !value.isRemote,
      )) {
        final path = File('$root/${instance.indexedPath}').absolute.uri
            .normalizePath()
            .toFilePath();
        if (!path.startsWith('$root${Platform.pathSeparator}')) continue;
        paths.add(path);
        for (final asset in library.state.artifacts.where(
          (value) => value.files.any((file) => file.path == path),
        )) {
          paths.addAll(asset.files.map((file) => file.path));
        }
      }
    }
    await _useRegistry.update(this, paths);
  }

  void _publish(LmStudioState value) {
    _state = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  void close() {
    _token = null;
    _changes.close();
  }
}

class _CapabilityFailure implements Exception {
  const _CapabilityFailure(this.capability, this.message);
  final InstanceCapability capability;
  final String message;
}

class LmStudioException implements Exception {
  const LmStudioException(this.message);
  final String message;
  @override
  String toString() => message;
}
