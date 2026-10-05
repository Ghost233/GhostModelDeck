import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'llama_engine.dart';
import 'model_library.dart';
import 'model_use_registry.dart';

enum EngineSource { managed, linked }

class EngineRegistration {
  const EngineRegistration({
    required this.id,
    required this.name,
    required this.source,
    required this.status,
    this.version,
    this.path,
    this.sha256,
    this.error,
  });
  final String id;
  final String name;
  final EngineSource source;
  final LlamaInstallationStatus status;
  final String? version;
  final String? path;
  final String? sha256;
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
  final LlamaInstance instance;
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
    required this.useRegistry,
    required this.registryFile,
    EngineProcessIO? io,
  }) : io = io ?? NativeEngineProcessIO() {
    _subscriptions.add(officialEngine.changes.listen((_) => _publish()));
  }
  static const officialId = 'official-llama-b11381';
  final ModelLibrary library;
  final LlamaEngine officialEngine;
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
  bool _busy = false;
  String? _error;
  Stream<EngineCatalogState> get changes => _changes.stream;
  EngineCatalogState get state => EngineCatalogState(
    busy: _busy,
    error: _error,
    entries: List.unmodifiable([
      EngineRegistration(
        id: officialId,
        name: 'llama.cpp',
        source: EngineSource.managed,
        status: officialEngine.state.installation,
        version: officialEngine.observedVersion,
        path: officialEngine.executablePath,
        sha256: officialEngine.release.sha256,
        error: officialEngine.state.error,
      ),
      for (final entry in _linked.entries)
        EngineRegistration(
          id: entry.key,
          name: _names[entry.key]!,
          source: EngineSource.linked,
          status: entry.value.state.installation,
          version: entry.value.linkedInstallation!.version,
          path: entry.value.linkedInstallation!.path,
          sha256: entry.value.linkedInstallation!.sha256,
          error: entry.value.state.error,
        ),
    ]),
  );
  Future<T> _serial<T>(Future<T> Function() work) {
    if (_shuttingDown) return Future.error(StateError('引擎管理器正在退出'));
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
    await officialEngine.refreshInstallation();
    for (final provider in _linked.values) {
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
            row['id'] == officialId ||
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
    );
    if (_shuttingDown) provider.beginShutdown();
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

  Future<void> installOfficial({File? verifiedArchive}) => _serial(() async {
    await _load();
    await officialEngine.install(verifiedArchive: verifiedArchive);
  });
  Future<EngineRegistration> link(String path) => _serial(() async {
    await _load();
    final type = await FileSystemEntity.type(path);
    final binary = type == FileSystemEntityType.directory
        ? File('$path/llama-server')
        : File(path);
    final location = await inspectLinkedLlama(binary, io);
    final managed = File(
      '${officialEngine.installationDirectory.path}/${officialEngine.release.tag}/llama-server',
    );
    if (await managed.exists() &&
        await managed.resolveSymbolicLinks() == location.path) {
      throw const LlamaEngineException('该引擎已由本应用管理');
    }
    if (_linked.values.any(
          (provider) => provider.linkedInstallation!.path == location.path,
        ) ||
        officialEngine.executablePath == location.path) {
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
      final plan = await officialEngine.prepareRemoval();
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
          await officialEngine.removeInstallation(
            plan._managed!,
            confirmed: true,
          );
          return;
        }
        await provider.detachLinked();
        await _save(excluding: plan.entry.id);
        _linked.remove(plan.entry.id);
        _names.remove(plan.entry.id);
        provider.close();
      });
  LlamaEngine providerFor(String id) {
    if (id == officialId) return officialEngine;
    final provider = _linked[id];
    if (provider == null) throw const LlamaEngineException('引擎登记已变化');
    return provider;
  }

  List<EngineRun> runsFor(Iterable<String> artifactIds) {
    final ids = artifactIds.toSet();
    return [
      for (final entry in state.entries)
        for (final instance in providerFor(entry.id).state.instances)
          if (ids.contains(instance.asset.id)) EngineRun(entry, instance),
    ];
  }

  Future<void> stopManaged() async {
    await officialEngine.stopManaged();
    for (final provider in _linked.values) {
      await provider.stopManaged();
    }
  }

  void beginShutdown() {
    _shuttingDown = true;
    officialEngine.beginShutdown();
    for (final provider in _linked.values) {
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
    for (final provider in [officialEngine, ..._linked.values]) {
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
