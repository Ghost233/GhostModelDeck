import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'engine_catalog.dart';
import 'engine_launch_configuration.dart';
import 'engine_runtime.dart';
import 'llama_engine.dart';
import 'model_library.dart';
import 'splash_engine.dart';
import 'omlx_engine.dart';
import 'public_model_names.dart';

class LaunchInstance {
  const LaunchInstance({
    required this.id,
    required this.name,
    required this.publicName,
    required this.artifactId,
    required this.engineId,
    required this.configuration,
    this.revision = 1,
    this.splashAssembly,
    this.jevRequestTimeoutSeconds = 60,
    this.hasAppliedContext = false,
    this.appliedContextLength,
  });
  final String id;
  final String name;
  final String publicName;
  final String artifactId;
  final String engineId;
  final EngineLaunchConfiguration configuration;
  final int revision;
  final String? splashAssembly;
  final int jevRequestTimeoutSeconds;
  final bool hasAppliedContext;
  final int? appliedContextLength;

  LaunchInstance _withAppliedContext(int? context) => LaunchInstance(
    id: id,
    name: name,
    publicName: publicName,
    artifactId: artifactId,
    engineId: engineId,
    configuration: configuration,
    revision: revision,
    splashAssembly: splashAssembly,
    jevRequestTimeoutSeconds: jevRequestTimeoutSeconds,
    hasAppliedContext: true,
    appliedContextLength: context,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'public_name': publicName,
    'artifact_id': artifactId,
    'engine_id': engineId,
    'configuration': configuration.toJson(),
    'revision': revision,
    'splash_assembly': splashAssembly,
    'jev_request_timeout_seconds': jevRequestTimeoutSeconds,
    if (hasAppliedContext) 'applied_context_length': appliedContextLength,
  };
  factory LaunchInstance.fromJson(Object? value) {
    if (value is! Map ||
        [
          value['id'],
          value['name'],
          value['public_name'],
          value['artifact_id'],
          value['engine_id'],
        ].any((v) => v is! String || v.trim().isEmpty) ||
        !PublicModelNames.isValid(value['public_name'] as String) ||
        (value['applied_context_length'] != null &&
            (value['applied_context_length'] is! int ||
                value['applied_context_length'] < 1)) ||
        (value['jev_request_timeout_seconds'] != null &&
            (value['jev_request_timeout_seconds'] is! int ||
                value['jev_request_timeout_seconds'] < 1)) ||
        value['revision'] is! int ||
        value['revision'] < 1 ||
        (value['splash_assembly'] != null &&
            (value['splash_assembly'] is! String ||
                !(value['splash_assembly'] as String).startsWith('/')))) {
      throw const FormatException('实例配置无效');
    }
    return LaunchInstance(
      id: value['id'],
      name: value['name'],
      publicName: value['public_name'],
      artifactId: value['artifact_id'],
      engineId: value['engine_id'],
      configuration: EngineLaunchConfiguration.fromJson(value['configuration']),
      revision: value['revision'],
      splashAssembly: value['splash_assembly'],
      jevRequestTimeoutSeconds: value['jev_request_timeout_seconds'] ?? 60,
      hasAppliedContext: value.containsKey('applied_context_length'),
      appliedContextLength: value['applied_context_length'],
    );
  }
}

class LaunchInstances {
  LaunchInstances({
    required this.catalog,
    required this.file,
    PublicModelNames? names,
  }) : names = names ?? PublicModelNames() {
    _catalogChanges = catalog.changes.listen((_) => _publish());
    _libraryChanges = catalog.library.changes.listen((_) => _publish());
  }
  final EngineCatalog catalog;
  final File file;
  final PublicModelNames names;
  final _changes = StreamController<void>.broadcast();
  late final StreamSubscription<EngineCatalogState> _catalogChanges;
  late final StreamSubscription<LibraryState> _libraryChanges;
  List<LaunchInstance> _definitions = [];
  List<LaunchInstance> get definitions => List.unmodifiable(_definitions);
  Stream<void> get changes => _changes.stream;
  Future<({String summary, String path})> recordFailure(
    Object error,
    StackTrace stack,
  ) async {
    final details = '$error';
    final lines = details
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final cause =
        lines.where((line) => line.contains(': error:')).firstOrNull ??
        lines.firstOrNull ??
        '操作失败';
    final summary = cause.length > 360 ? '${cause.substring(0, 360)}…' : cause;
    final directory = await Directory('${file.parent.path}/instance-errors')
        .create(recursive: true);
    final log = File(
      '${directory.path}/failure-${DateTime.now().microsecondsSinceEpoch}.log',
    );
    await log.writeAsString('$details\n\n$stack\n', flush: true);
    return (summary: summary, path: log.absolute.path);
  }

  Future<void> _operations = Future.value();
  final _starts = <String, Future<RuntimeInstance>>{};
  final _startCancellations = <String, DecisionCancellation>{};
  final _runOrigins = <String, EngineRegistration>{};
  final _appliedContexts = <String, int?>{};
  ({Object error, StackTrace stack})? _persistenceFailure;
  String? get persistenceError => _persistenceFailure == null
      ? null
      : '生效容量保存失败：${_persistenceFailure!.error}';
  int? contextLengthFor(String id) {
    final definition = find(id);
    if (definition == null) return null;
    return _appliedContexts.containsKey(id)
        ? _appliedContexts[id]
        : definition.hasAppliedContext
        ? definition.appliedContextLength
        : definition.configuration.contextLength;
  }

  EngineRegistration? runningOrigin(String id) => _runOrigins[id];
  String? runningVersion(String id) {
    for (final runtime in catalog.runtimes) {
      final run = runtime.runtimeInstances
          .where((run) => run.launchInstanceId == id && run.hasLiveProcess)
          .singleOrNull;
      if (run == null) continue;
      if (runtime is LlamaEngine) {
        final version = runtime.state.instances
            .singleWhere((instance) => instance.id == run.id)
            .binaryVersion;
        if (version != null) {
          return '${version.semanticVersion} · ${version.commit}';
        }
      }
      if (runtime is SplashEngine) return runtime.actualVersionFor(run.id);
      if (runtime is OmlxEngine) return runtime.actualVersionFor(run.id);
      return _runOrigins[id]?.version;
    }
    return null;
  }

  EngineLaunchCommand? actualCommand(String id) {
    for (final runtime in catalog.runtimes) {
      final run = runtime.runtimeInstances
          .where((run) => run.launchInstanceId == id && run.hasLiveProcess)
          .singleOrNull;
      if (run == null) continue;
      if (runtime is LlamaEngine) {
        return runtime.state.instances
            .singleWhere((instance) => instance.id == run.id)
            .launchCommand;
      }
      if (runtime is SplashEngine) return runtime.actualCommandFor(run.id);
      if (runtime is OmlxEngine) return runtime.actualCommandFor(run.id);
    }
    return null;
  }

  bool isStarting(String id) => _starts.containsKey(id);
  void cancelPendingStarts() {
    for (final token in _startCancellations.values) {
      token.cancel();
    }
  }

  bool _loaded = false;
  bool _closed = false;
  Future<void>? _closing;
  void beginShutdown() {
    _closed = true;
    cancelPendingStarts();
  }

  LaunchInstance? find(String id) =>
      _definitions.where((v) => v.id == id).singleOrNull;
  List<LaunchInstance> forModel(String artifactId) =>
      definitions.where((v) => v.artifactId == artifactId).toList();

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _operations.then((_) async {
      if (_closed) throw StateError('实例管理已关闭');
      return action();
    });
    _operations = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> load() => _serial(_load);
  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map ||
          value['schema'] != 1 ||
          value['instances'] is! List) {
        throw const FormatException('实例登记文件无效');
      }
      final parsed = (value['instances'] as List)
          .map(LaunchInstance.fromJson)
          .toList();
      if (parsed.map((v) => v.id).toSet().length != parsed.length) {
        throw const FormatException('实例身份重复');
      }
      names.claimAll({
        for (final definition in parsed)
          'instance:${definition.id}': definition.publicName,
      });
      _definitions = parsed;
    } else {
      await _write([]);
    }
    _loaded = true;
    _publish();
  }

  String _newId() =>
      'instance-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

  String? missingReason(LaunchInstance definition) {
    final engine = catalog.state.entries
        .where((e) => e.id == definition.engineId)
        .firstOrNull;
    if (engine == null || engine.status != LlamaInstallationStatus.installed) {
      return '引擎缺失或未安装';
    }
    if (!catalog.library.state.scanning) {
      final asset = catalog.library.state.artifacts
          .where((asset) => asset.id == definition.artifactId)
          .firstOrNull;
      if (asset == null) return '模型缺失';
      if (asset.files.any((file) => !File(file.path).existsSync())) {
        return '模型文件缺失';
      }
      if (asset.integrity == AssetIntegrity.corrupt ||
          asset.integrity == AssetIntegrity.incomplete) {
        return '模型文件损坏或不完整';
      }
    }
    return null;
  }

  List<RuntimeInstance> runsFor(String id) => [
    for (final runtime in catalog.runtimes)
      for (final instance in runtime.runtimeInstances)
        if (instance.launchInstanceId == id) instance,
  ];

  Future<LaunchInstance> save({
    String? id,
    required String name,
    required String artifactId,
    required String engineId,
    required EngineLaunchConfiguration configuration,
    String? splashAssembly,
    int? jevRequestTimeoutSeconds,
  }) => _serial(() async {
    await _load();
    if (name.trim().isEmpty) throw ArgumentError('请输入实例名称');
    final previous = id == null ? null : find(id);
    if (id != null && previous == null) throw StateError('实例已删除');
    final budget =
        jevRequestTimeoutSeconds ?? previous?.jevRequestTimeoutSeconds ?? 60;
    if (budget < 1) throw ArgumentError('JEV 请求预算必须是正整数秒');
    final selectedEngine = catalog.state.entries
        .where((e) => e.id == engineId)
        .singleOrNull;
    if (selectedEngine != null &&
        selectedEngine.family != configuration.family) {
      throw ArgumentError('参数与引擎不一致');
    }
    if (previous == null ||
        previous.artifactId != artifactId ||
        previous.engineId != engineId) {
      if (!catalog.library.state.artifacts.any((a) => a.id == artifactId)) {
        throw StateError('模型不在当前模型库中');
      }
      final engine = catalog.state.entries
          .where(
            (e) =>
                e.id == engineId &&
                e.status == LlamaInstallationStatus.installed,
          )
          .singleOrNull;
      if (engine == null) throw StateError('引擎未安装或已解除关联');
      if (engine.family != configuration.family) {
        throw ArgumentError('参数与引擎不一致');
      }
    }
    final identity = id ?? _newId();
    final publicName =
        previous?.publicName ??
        names.suggest(
          catalog.library.state.artifacts
              .singleWhere((a) => a.id == artifactId)
              .name,
        );
    names.claim('instance:$identity', publicName);
    final definition = LaunchInstance(
      id: identity,
      name: name.trim(),
      publicName: publicName,
      artifactId: artifactId,
      engineId: engineId,
      configuration: configuration,
      revision: (previous?.revision ?? 0) + 1,
      jevRequestTimeoutSeconds: budget,
      hasAppliedContext: true,
      appliedContextLength: previous == null
          ? configuration.contextLength
          : contextLengthFor(identity),
      splashAssembly: splashAssembly?.trim().isEmpty == true
          ? null
          : splashAssembly,
    );
    try {
      await _write([
        for (final existing in definitions)
          if (existing.id != definition.id) existing,
        definition,
      ]);
    } catch (_) {
      if (previous == null) names.release('instance:$identity', publicName);
      rethrow;
    }
    return definition;
  });
  Future<void> delete(String id) => _serial(() async {
    await _load();
    if (_starts.containsKey(id) || runsFor(id).any((r) => r.hasLiveProcess)) {
      throw StateError('请先停止实例');
    }
    final previous = find(id);
    await _write(definitions.where((v) => v.id != id).toList());
    _appliedContexts.remove(id);
    if (previous != null) names.release('instance:$id', previous.publicName);
  });

  Future<LaunchInstance> copy(String id) => _serial(() async {
    await _load();
    final original = find(id);
    if (original == null) throw StateError('实例已删除');
    final copied = LaunchInstance(
      id: _newId(),
      name: '${original.name} 副本',
      publicName: names.suggest(
        catalog.library.state.artifacts
                .where((a) => a.id == original.artifactId)
                .firstOrNull
                ?.name ??
            original.publicName,
      ),
      artifactId: original.artifactId,
      engineId: original.engineId,
      configuration: original.configuration,
      splashAssembly: original.splashAssembly,
      jevRequestTimeoutSeconds: original.jevRequestTimeoutSeconds,
      hasAppliedContext: true,
      appliedContextLength: original.configuration.contextLength,
    );
    names.claim('instance:${copied.id}', copied.publicName);
    try {
      await _write([...definitions, copied]);
    } catch (_) {
      names.release('instance:${copied.id}', copied.publicName);
      rethrow;
    }
    return copied;
  });

  Future<LaunchInstance> renamePublicName(String id, String value) =>
      _serial(() async {
        await _load();
        final previous = find(id);
        if (previous == null) throw StateError('实例已删除');
        if (value.trim().isEmpty) throw ArgumentError('请输入公开调用名');
        final name = PublicModelNames.normalize(value);
        if (name == previous.publicName) return previous;
        names.claim('instance:$id', name);
        final renamed = LaunchInstance(
          id: id,
          name: previous.name,
          publicName: name,
          artifactId: previous.artifactId,
          engineId: previous.engineId,
          configuration: previous.configuration,
          revision: previous.revision,
          splashAssembly: previous.splashAssembly,
          jevRequestTimeoutSeconds: previous.jevRequestTimeoutSeconds,
          hasAppliedContext: previous.hasAppliedContext,
          appliedContextLength: previous.appliedContextLength,
        );
        try {
          await _write([
            for (final definition in definitions)
              definition.id == id ? renamed : definition,
          ]);
        } catch (_) {
          names.release('instance:$id', name);
          rethrow;
        }
        names.release('instance:$id', previous.publicName);
        return renamed;
      });
  Future<void> _write(List<LaunchInstance> definitions) async {
    definitions = [
      for (final definition in definitions)
        if (_appliedContexts.containsKey(definition.id))
          definition._withAppliedContext(_appliedContexts[definition.id])
        else
          definition,
    ];
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'instances': definitions.map((v) => v.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
    _definitions = definitions;
    _persistenceFailure = null;
    _publish();
  }

  Future<RuntimeInstance> start(String id) {
    final current = _starts[id];
    if (current != null) return current;
    final token = DecisionCancellation();
    _startCancellations[id] = token;
    final operation = _start(id, token);
    _starts[id] = operation;
    unawaited(
      operation.then<void>(
        (_) {
          _starts.remove(id);
          _startCancellations.remove(id);
          _publish();
        },
        onError: (Object _) {
          _starts.remove(id);
          _startCancellations.remove(id);
          _publish();
        },
      ),
    );
    return operation;
  }

  Future<RuntimeInstance> _start(
    String id,
    DecisionCancellation cancellation,
  ) async {
    if (_closed) throw StateError('实例管理已关闭');
    final definition = find(id);
    if (definition == null) throw StateError('实例已删除');
    final ready = runsFor(id)
        .where(
          (run) =>
              run.hasLiveProcess &&
              run.acceptingRequests &&
              run.status == RuntimeInstanceStatus.ready,
        )
        .toList();
    if (ready.length == 1) return ready.single;
    final reason = missingReason(definition);
    if (reason != null) throw StateError(reason);
    if (runsFor(id).any((r) => r.hasLiveProcess)) {
      throw StateError('实例已在运行，请先停止');
    }
    definition.configuration.validateArgumentText();
    if (_closed || cancellation.isCancelled) throw StateError('实例启动已取消');
    final runtime = catalog.runtimeFor(definition.engineId);
    _runOrigins[id] = catalog.state.entries.singleWhere(
      (entry) => entry.id == definition.engineId,
    );
    final RuntimeInstance run;
    if (runtime is LlamaEngine) {
      final started = await runtime.start(
        definition.artifactId,
        configuration: definition.configuration,
        cancellation: cancellation,
        launchInstanceId: id,
        launchRevision: definition.revision,
      );
      run = runtime.runtimeInstances.singleWhere((r) => r.id == started.id);
    } else if (runtime is SplashEngine) {
      run = await runtime.startWithConfiguration(
        definition.artifactId,
        definition.configuration,
        cancellation: cancellation,
        launchInstanceId: id,
        launchRevision: definition.revision,
        preparationHint: definition.splashAssembly == null
            ? null
            : Directory(definition.splashAssembly!),
      );
    } else if (runtime is OmlxEngine) {
      final entry = catalog.state.entries.singleWhere(
        (entry) => entry.id == definition.engineId,
      );
      run = await runtime.startWithConfiguration(
        definition.artifactId,
        definition.configuration,
        launchInstanceId: id,
        launchRevision: definition.revision,
        sourceBundle: Directory(entry.path!),
        sourceReceipt: entry.omlxReceipt,
        cancellation: cancellation,
      );
    } else {
      throw StateError('此引擎尚未接通模型运行');
    }
    if (!cancellation.isCancelled &&
        run.hasLiveProcess &&
        run.acceptingRequests &&
        run.status == RuntimeInstanceStatus.ready) {
      _appliedContexts[id] =
          definition.configuration.contextLength ??
          run.capacity?.contextPerSlot;
      try {
        await _serial(() => _write(_definitions));
      } catch (error, stack) {
        _persistenceFailure = (error: error, stack: stack);
        _publish();
      }
    }
    return run;
  }

  Future<void> stop(String id) async {
    _startCancellations[id]?.cancel();
    await _starts[id]?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    for (final runtime in catalog.runtimes) {
      for (final run in runtime.runtimeInstances.where(
        (r) => r.launchInstanceId == id && r.hasLiveProcess,
      )) {
        await runtime.stop(run.id);
      }
    }
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    beginShutdown();
    await Future.wait(
      _starts.values.map(
        (future) =>
            future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await _operations;
    for (final definition in definitions) {
      names.release('instance:${definition.id}', definition.publicName);
    }
    await _catalogChanges.cancel();
    await _libraryChanges.cancel();
    await _changes.close();
    final failure = _persistenceFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }
}
