import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'llama_engine.dart';
import 'engine_runtime.dart';
import 'model_library.dart';
import 'model_use_registry.dart';

enum EngineSource { managed, linked }

class EngineRegistration {
  const EngineRegistration({
    required this.id,
    required this.name,
    required this.source,
    required this.status,
    this.family = EngineFamily.llamaCpp,
    this.version,
    this.path,
    this.sha256,
    this.archiveSha256,
    this.binarySha256,
    this.release,
    this.binaryVersion,
    this.error,
  });
  final String id;
  final String name;
  final EngineSource source;
  final EngineFamily family;
  final LlamaInstallationStatus status;
  final String? version;
  final String? path;

  /// Legacy digest: managed archive or linked executable. Prefer typed fields.
  final String? sha256;
  final String? archiveSha256;
  final String? binarySha256;
  final LlamaRelease? release;
  final LlamaBinaryVersion? binaryVersion;
  String get installationId => id;
  final String? error;
}

class EngineCatalogState {
  const EngineCatalogState({
    this.entries = const [],
    this.busy = false,
    this.error,
  });
  final List<EngineRegistration> entries;
  final bool busy;
  final String? error;
}

class EngineRun {
  const EngineRun(this.engine, this.instance);
  final EngineRegistration engine;
  final RuntimeInstance instance;
}

class EngineRemovalPlan {
  EngineRemovalPlan._(
    this._owner, {
    required this.entry,
    required List<String> paths,
    required this.sizeBytes,
    this._managed,
  }) : paths = List.unmodifiable(paths);
  final Object _owner;
  final EngineRegistration entry;
  final List<String> paths;
  final int sizeBytes;
  final LlamaRemovalPlan? _managed;
}

class EngineCatalog {
  EngineCatalog({
    required this.library,
    required this.officialEngine,
    this.standardEngine,
    required this.useRegistry,
    required this.registryFile,
    EngineProcessIO? io,
  }) : io = io ?? NativeEngineProcessIO() {
    for (final provider in _managed.values) {
      _subscriptions.add(provider.changes.listen((_) => _publish()));
    }
  }
  static const officialId = 'official-llama-b11381';
  static const standardId = 'official-llama-v0.5.0';
  Map<String, LlamaEngine> get _managed => {
    officialId: officialEngine,
    standardId: ?standardEngine,
  };
  Iterable<LlamaEngine> get _providers => [
    ..._managed.values,
    ..._linked.values,
  ];
  final ModelLibrary library;
  final LlamaEngine officialEngine;
  final LlamaEngine? standardEngine;
  final ModelUseRegistry useRegistry;
  final File registryFile;
  final EngineProcessIO io;
  final _changes = StreamController<EngineCatalogState>.broadcast();
  final _linked = <String, LlamaEngine>{};
  final _names = <String, String>{};
  final _subscriptions = <StreamSubscription<LlamaEngineState>>[];
  Future<void> _operations = Future.value();
  bool _loaded = false;
  bool _shuttingDown = false;
  Future<void>? _shutdown;
  bool _recycling = false;
  Future<void>? _recycle;
  final _admissionReleases = <LlamaEngine, void Function()>{};
  bool _busy = false;
  String? _error;
  Stream<EngineCatalogState> get changes => _changes.stream;
  EngineCatalogState get state => EngineCatalogState(
    busy: _busy,
    error: _error,
    entries: List.unmodifiable([
      for (final entry in _managed.entries)
        EngineRegistration(
          id: entry.key,
          name: entry.key == officialId
              ? 'llama.cpp · JEV b11381'
              : 'llama.cpp · 标准 v0.5.0',
          source: EngineSource.managed,
          status: entry.value.state.installation,
          version: entry.value.observedVersion,
          path: entry.value.executablePath,
          sha256: entry.value.release.sha256,
          archiveSha256: entry.value.release.sha256,
          binarySha256: entry.value.binarySha256,
          release: entry.value.release,
          binaryVersion: entry.value.binaryVersion,
          error: entry.value.state.error,
        ),
      for (final entry in _linked.entries)
        EngineRegistration(
          id: entry.key,
          name: _names[entry.key]!,
          source: EngineSource.linked,
          status: entry.value.state.installation,
          version: entry.value.observedVersion,
          path: entry.value.linkedInstallation!.path,
          sha256: entry.value.linkedInstallation!.sha256,
          binarySha256: entry.value.binarySha256,
          binaryVersion: entry.value.binaryVersion,
          error: entry.value.state.error,
        ),
    ]),
  );
  Future<T> _serial<T>(Future<T> Function() work) {
    if (_shuttingDown) return Future.error(StateError('引擎管理器正在退出'));
    if (_recycling) {
      return Future.error(const LlamaEngineException('引擎管理器正在回收'));
    }
    final result = _operations.then((_) async {
      if (_shuttingDown) throw StateError('引擎管理器正在退出');
      _busy = true;
      _error = null;
      _publish();
      try {
        return await work();
      } catch (error) {
        _error = error.toString();
        rethrow;
      } finally {
        _busy = false;
        _publish();
      }
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> refresh() => _serial(() async {
    await _load();
    for (final provider in _providers) {
      await provider.refreshInstallation();
    }
  });
  Future<void> _load() async {
    if (_loaded) return;
    if (await registryFile.exists()) {
      final value = jsonDecode(await registryFile.readAsString());
      if (value is! Map || value['schema'] != 1 || value['linked'] is! List) {
        throw const LlamaEngineException('引擎登记文件无效');
      }
      for (final row in value['linked'] as List) {
        if (row is! Map ||
            row['id'] is! String ||
            row['name'] is! String ||
            row['path'] is! String ||
            row['version'] is! String ||
            row['fingerprints'] is! Map ||
            [officialId, standardId].contains(row['id']) ||
            _linked.containsKey(row['id'])) {
          throw const LlamaEngineException('关联引擎登记信息无效');
        }
        final fingerprints = Map<String, String>.from(
          row['fingerprints'] as Map,
        );
        if (!fingerprints.containsKey(row['path'])) {
          throw const LlamaEngineException('关联引擎内容指纹缺失');
        }
        _register(
          row['id'] as String,
          row['name'] as String,
          LinkedLlamaInstallation(
            path: row['path'] as String,
            version: row['version'] as String,
            fingerprints: fingerprints,
          ),
        );
      }
    }
    _loaded = true;
  }

  void _register(String id, String name, LinkedLlamaInstallation location) {
    final provider = LlamaEngine(
      library: library,
      installationDirectory: File(location.path).parent,
      io: io,
      useRegistry: useRegistry,
      linkedInstallation: location,
      installationId: id,
    );
    if (_shuttingDown) provider.beginShutdown();
    if (_recycling) {
      _admissionReleases[provider] = provider.holdStartAdmission();
    }
    _linked[id] = provider;
    _names[id] = name;
    _subscriptions.add(provider.changes.listen((_) => _publish()));
  }

  Future<void> _save({String? excluding}) async {
    await registryFile.parent.create(recursive: true);
    final temporary = File('${registryFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'linked': [
          for (final entry in _linked.entries)
            if (entry.key != excluding)
              {
                'id': entry.key,
                'name': _names[entry.key],
                'path': entry.value.linkedInstallation!.path,
                'version': entry.value.linkedInstallation!.version,
                'fingerprints': entry.value.linkedInstallation!.fingerprints,
              },
        ],
      }),
      flush: true,
    );
    await temporary.rename(registryFile.path);
  }

  Future<void> installOfficial({File? verifiedArchive}) =>
      installManaged(officialId, verifiedArchive: verifiedArchive);
  Future<void> installManaged(String id, {File? verifiedArchive}) =>
      _serial(() async {
        await _load();
        final provider = _managed[id];
        if (provider == null) throw const LlamaEngineException('请选择受管引擎安装');
        await provider.install(verifiedArchive: verifiedArchive);
      });
  Future<EngineRegistration> link(String path) => _serial(() async {
    await _load();
    final type = await FileSystemEntity.type(path);
    final binary = type == FileSystemEntityType.directory
        ? File('$path/llama-server')
        : File(path);
    final location = await inspectLinkedLlama(binary, io);
    for (final provider in _managed.values) {
      final managed = File(
        '${provider.installationDirectory.path}/${provider.release.tag}/llama-server',
      );
      if (await managed.exists() &&
          await managed.resolveSymbolicLinks() == location.path) {
        throw const LlamaEngineException('该引擎已由本应用管理');
      }
    }
    if (_linked.values.any(
          (provider) => provider.linkedInstallation!.path == location.path,
        ) ||
        _managed.values.any(
          (provider) => provider.executablePath == location.path,
        )) {
      throw const LlamaEngineException('该引擎已登记');
    }
    final id = List.generate(
      20,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _register(
      id,
      'llama.cpp · ${File(location.path).parent.uri.pathSegments.where((value) => value.isNotEmpty).last}',
      location,
    );
    try {
      await _save();
      await _linked[id]!.refreshInstallation();
    } catch (_) {
      _linked.remove(id)?.close();
      _names.remove(id);
      rethrow;
    }
    return state.entries.singleWhere((entry) => entry.id == id);
  });
  Future<EngineRemovalPlan> prepareRemoval(String id) => _serial(() async {
    final entry = state.entries.singleWhere((value) => value.id == id);
    if (providerFor(id).hasLiveInstances) {
      throw const LlamaEngineException('请先停止该引擎的模型实例');
    }
    if (entry.source == EngineSource.managed) {
      final plan = await providerFor(id).prepareRemoval();
      return EngineRemovalPlan._(
        this,
        entry: entry,
        paths: plan.files,
        sizeBytes: plan.sizeBytes,
        managed: plan,
      );
    }
    return EngineRemovalPlan._(
      this,
      entry: entry,
      paths: const [],
      sizeBytes: 0,
    );
  });
  Future<void> remove(EngineRemovalPlan plan, {required bool confirmed}) =>
      _serial(() async {
        if (!confirmed) return;
        if (!identical(plan._owner, this)) {
          throw const LlamaEngineException('删除计划不属于当前引擎管理器');
        }
        final provider = providerFor(plan.entry.id);
        if (plan.entry.source == EngineSource.managed) {
          await provider.removeInstallation(plan._managed!, confirmed: true);
          return;
        }
        await provider.detachLinked();
        await _save(excluding: plan.entry.id);
        _linked.remove(plan.entry.id);
        _names.remove(plan.entry.id);
        provider.close();
      });
  EngineRuntime runtimeFor(String id) => providerFor(id);

  LlamaEngine providerFor(String id) {
    final provider = _managed[id] ?? _linked[id];
    if (provider == null) throw const LlamaEngineException('引擎登记已变化');
    return provider;
  }

  List<EngineRun> runsFor(Iterable<String> artifactIds) {
    final ids = artifactIds.toSet();
    return [
      for (final entry in state.entries)
        for (final instance in runtimeFor(entry.id).runtimeInstances)
          if (ids.contains(instance.artifactId)) EngineRun(entry, instance),
    ];
  }

  Future<void> stopManaged() {
    if (_recycle != null) return _recycle!;
    _recycling = true;
    final initial = _providers.toSet();
    for (final provider in initial) {
      _admissionReleases[provider] = provider.holdStartAdmission();
    }
    final errors = <Object>[];
    Future<void> stop(LlamaEngine provider) async {
      try {
        await provider.stopManaged();
      } catch (error) {
        errors.add(error);
      }
    }

    // Cancel accepted starts immediately, but keep admission held after each
    // provider finishes. Drain preaccepted catalog work before late enrollment.
    final stops = initial.map(stop).toList();
    final accepted = _operations;
    final operation = () async {
      await accepted;
      stops.addAll(_providers.where((p) => !initial.contains(p)).map(stop));
      await Future.wait(stops);
      if (errors.isNotEmpty) {
        throw LlamaEngineException('引擎回收未完成：${errors.join('; ')}');
      }
    }();
    _recycle = operation.whenComplete(() {
      for (final release in _admissionReleases.values) {
        release();
      }
      _admissionReleases.clear();
      _recycling = false;
      _recycle = null;
    });
    return _recycle!;
  }

  void beginShutdown() {
    _shuttingDown = true;
    for (final provider in _providers) {
      provider.beginShutdown();
    }
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    beginShutdown();
    return _shutdown = _drainAndStop();
  }

  Future<void> _drainAndStop() async {
    await _operations;
    final errors = <Object>[];
    for (final provider in _providers) {
      try {
        await provider.shutdown();
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isNotEmpty) throw StateError('引擎管理器退出未完成：${errors.join('; ')}');
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }

  void close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final provider in _linked.values) {
      provider.close();
    }
    _changes.close();
  }
}
