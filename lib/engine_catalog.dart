import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'llama_engine.dart';
import 'engine_runtime.dart';
import 'engine_launch_configuration.dart';
import 'model_library.dart';
import 'omlx_engine.dart';
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
    this.omlxReceipt,
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
  final OmlxReceipt? omlxReceipt;
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
    this._omlx,
    this._linkedDigest,
  }) : paths = List.unmodifiable(paths);
  final Object _owner;
  final EngineRegistration entry;
  final List<String> paths;
  final int sizeBytes;
  final LlamaRemovalPlan? _managed;
  final OmlxRemovalPlan? _omlx;
  final String? _linkedDigest;
}

class _LinkedOmlx {
  const _LinkedOmlx(this.path, this.receipt, {this.error});
  final String path;
  final OmlxReceipt receipt;
  final String? error;
}

class EngineCatalog {
  EngineCatalog({
    required this.library,
    required this.officialEngine,
    this.standardEngine,
    this.omlxEngine,
    required this.useRegistry,
    required this.registryFile,
    EngineProcessIO? io,
  }) : io = io ?? NativeEngineProcessIO() {
    for (final entry in _managed.entries) {
      entry.value.readLaunchDefaultsFrom(() => launchDefaultsFor(entry.key));
      _subscriptions.add(entry.value.changes.listen((_) => _publish()));
    }
    _omlxSubscription = omlxEngine?.changes.listen((_) => _publish());
  }
  static const omlxId = 'official-omlx-v0.7.0';
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
  final OmlxEngine? omlxEngine;
  StreamSubscription<OmlxState>? _omlxSubscription;
  final _linkedOmlx = <String, _LinkedOmlx>{};
  final ModelUseRegistry useRegistry;
  final File registryFile;
  final EngineProcessIO io;
  final _changes = StreamController<EngineCatalogState>.broadcast();
  final _linked = <String, LlamaEngine>{};
  final _names = <String, String>{};
  final _launchDefaults = <String, EngineLaunchConfiguration>{};
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
      if (omlxEngine != null)
        EngineRegistration(
          id: omlxId,
          name: 'oMLX · 官方 0.7.0',
          source: EngineSource.managed,
          family: EngineFamily.omlx,
          status: switch (omlxEngine!.state.status) {
            OmlxInstallationStatus.notInstalled =>
              LlamaInstallationStatus.absent,
            OmlxInstallationStatus.installing =>
              LlamaInstallationStatus.installing,
            OmlxInstallationStatus.installed =>
              LlamaInstallationStatus.installed,
            OmlxInstallationStatus.failed => LlamaInstallationStatus.failed,
          },
          path: omlxEngine!.bundle.path,
          omlxReceipt: omlxEngine!.state.receipt,
          archiveSha256: omlxEngine!.state.receipt?.dmgSha256,
          error: omlxEngine!.state.error,
        ),
      for (final row in _linkedOmlx.entries)
        EngineRegistration(
          id: row.key,
          name: 'oMLX · 关联 0.7.0',
          source: EngineSource.linked,
          family: EngineFamily.omlx,
          status: row.value.error == null
              ? LlamaInstallationStatus.installed
              : LlamaInstallationStatus.failed,
          path: row.value.path,
          omlxReceipt: row.value.receipt,
          error: row.value.error,
        ),
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
    await omlxEngine?.refreshInstallation();
    for (final row in _linkedOmlx.entries.toList()) {
      try {
        final receipt = await omlxEngine!.inspectLinked(
          Directory(row.value.path),
        );
        if (receipt.bundleManifestSha256 !=
            row.value.receipt.bundleManifestSha256) {
          throw const OmlxException('oMLX 关联 app 内容变化');
        }
        _linkedOmlx[row.key] = _LinkedOmlx(row.value.path, receipt);
      } catch (_) {
        _linkedOmlx[row.key] = _LinkedOmlx(
          row.value.path,
          row.value.receipt,
          error: 'oMLX 关联 app 重新验证失败',
        );
      }
    }
  });
  Future<void> _load() async {
    if (_loaded) return;
    if (await registryFile.exists()) {
      Object? value;
      try {
        value = jsonDecode(await registryFile.readAsString());
      } catch (_) {
        // FormatException embeds raw persisted input; never send it to the UI.
        throw const LlamaEngineException('引擎登记文件无效');
      }
      if (value is! Map ||
          ![1, 2, 3].contains(value['schema']) ||
          value['linked'] is! List) {
        throw const LlamaEngineException('引擎登记文件无效');
      }
      // Parse completely before mutating ownership; malformed mixed-family rows
      // must leave both the existing schema-1 file and catalog unchanged.
      final cppRows = <String, (String, LinkedLlamaInstallation)>{};
      final nativeRows = <String, _LinkedOmlx>{};
      final launchDefaults = <String, EngineLaunchConfiguration>{};
      if (value['schema'] == 3) {
        final configurations = value['launchDefaults'];
        if (configurations is! Map) {
          throw const LlamaEngineException('引擎启动配置登记无效');
        }
        for (final entry in configurations.entries) {
          if (entry.key is! String || (entry.key as String).isEmpty) {
            throw const LlamaEngineException('引擎启动配置登记无效');
          }
          try {
            launchDefaults[entry.key as String] =
                EngineLaunchConfiguration.fromJson(entry.value);
          } on FormatException {
            throw const LlamaEngineException('引擎启动配置登记无效');
          }
        }
      }
      final ids = <String>{officialId, standardId, omlxId};
      for (final row in value['linked'] as List) {
        if (row is! Map ||
            row['id'] is! String ||
            !ids.add(row['id'] as String)) {
          throw const LlamaEngineException('关联引擎登记信息无效');
        }
        if (row['family'] == 'omlx') {
          if (![2, 3].contains(value['schema']) ||
              omlxEngine == null ||
              row['path'] is! String ||
              row['name'] is! String) {
            throw const OmlxException('oMLX 登记信息无效或安装模块不可用');
          }
          nativeRows[row['id'] as String] = _LinkedOmlx(
            row['path'] as String,
            OmlxReceipt.fromJson(row['receipt']),
          );
          continue;
        }
        if (row['family'] != null && row['family'] != 'llamaCpp') {
          throw const LlamaEngineException('引擎家族登记无效');
        }
        if (row['id'] is! String ||
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
        cppRows[row['id'] as String] = (
          row['name'] as String,
          LinkedLlamaInstallation(
            path: row['path'] as String,
            version: row['version'] as String,
            fingerprints: fingerprints,
          ),
        );
      }
      for (final row in cppRows.entries) {
        _register(row.key, row.value.$1, row.value.$2);
      }
      _linkedOmlx.addAll(nativeRows);
      _launchDefaults.addAll(launchDefaults);
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
    provider.readLaunchDefaultsFrom(() => launchDefaultsFor(id));
    if (_shuttingDown) provider.beginShutdown();
    if (_recycling) {
      _admissionReleases[provider] = provider.holdStartAdmission();
    }
    _linked[id] = provider;
    _names[id] = name;
    _subscriptions.add(provider.changes.listen((_) => _publish()));
  }

  Future<void> _save({
    String? excluding,
    Map<String, EngineLaunchConfiguration>? launchDefaults,
  }) async {
    final configurations = launchDefaults ?? _launchDefaults;
    await registryFile.parent.create(recursive: true);
    final temporary = File('${registryFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': configurations.isNotEmpty
            ? 3
            : _linkedOmlx.keys.any((id) => id != excluding)
            ? 2
            : 1,
        if (configurations.isNotEmpty)
          'launchDefaults': {
            for (final entry in configurations.entries)
              entry.key: entry.value.toJson(),
          },
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
          for (final row in _linkedOmlx.entries)
            if (row.key != excluding)
              {
                'id': row.key,
                'name': 'oMLX · 关联 0.7.0',
                'family': 'omlx',
                'path': row.value.path,
                'receipt': row.value.receipt.toJson(),
              },
        ],
      }),
      flush: true,
    );
    await temporary.rename(registryFile.path);
  }

  EngineLaunchConfiguration launchDefaultsFor(String id) {
    providerFor(id);
    return _launchDefaults[id] ?? EngineLaunchConfiguration();
  }

  Future<void> saveLaunchDefaults(
    String id,
    EngineLaunchConfiguration configuration,
  ) => _serial(() async {
    await _load();
    providerFor(id);
    await _save(launchDefaults: {..._launchDefaults, id: configuration});
    _launchDefaults[id] = configuration;
  });

  Future<void> installOfficial({File? verifiedArchive}) =>
      installManaged(officialId, verifiedArchive: verifiedArchive);
  Future<void> installManaged(String id, {File? verifiedArchive}) =>
      _serial(() async {
        await _load();
        if (id == omlxId && omlxEngine != null) {
          await omlxEngine!.install(verifiedArtifact: verifiedArchive);
          return;
        }
        final provider = _managed[id];
        if (provider == null) throw const LlamaEngineException('请选择受管引擎安装');
        await provider.install(verifiedArchive: verifiedArchive);
      });
  Future<EngineRegistration> link(String path) => _serial(() async {
    await _load();
    final type = await FileSystemEntity.type(path);
    if (path.endsWith('.app') ||
        await File('$path/Contents/Info.plist').exists()) {
      final inspector = omlxEngine;
      if (inspector == null) throw const OmlxException('oMLX 安装模块未配置');
      final app = Directory(await Directory(path).resolveSymbolicLinks());
      if (app.path == inspector.bundle.path ||
          _linkedOmlx.values.any((row) => row.path == app.path)) {
        throw const OmlxException('该 oMLX app 已登记或由本应用管理');
      }
      final receipt = await inspector.inspectLinked(app);
      if (_shuttingDown || _recycling) throw const OmlxException('oMLX 关联已取消');
      final id =
          'omlx-${List.generate(20, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      _linkedOmlx[id] = _LinkedOmlx(app.path, receipt);
      try {
        await _save();
      } catch (_) {
        _linkedOmlx.remove(id);
        rethrow;
      }
      return state.entries.singleWhere((entry) => entry.id == id);
    }
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
    if (entry.family == EngineFamily.omlx) {
      if (entry.source == EngineSource.managed) {
        final plan = await omlxEngine!.prepareRemoval();
        return EngineRemovalPlan._(
          this,
          entry: entry,
          paths: [plan.bundlePath],
          sizeBytes: plan.sizeBytes,
          omlx: plan,
        );
      }
      final digest = await omlxEngine!.linkedDigest(Directory(entry.path!));
      return EngineRemovalPlan._(
        this,
        entry: entry,
        paths: const [],
        sizeBytes: 0,
        linkedDigest: digest,
      );
    }
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
        if (plan.entry.family == EngineFamily.omlx) {
          final current = state.entries
              .where((e) => e.id == plan.entry.id)
              .firstOrNull;
          if (current == null ||
              current.path != plan.entry.path ||
              current.omlxReceipt?.bundleManifestSha256 !=
                  plan.entry.omlxReceipt?.bundleManifestSha256) {
            throw const OmlxException('oMLX 删除计划已失效');
          }
          if (plan.entry.source == EngineSource.managed) {
            await omlxEngine!.removeInstallation(plan._omlx!, confirmed: true);
          } else {
            if (await omlxEngine!.linkedDigest(Directory(current.path!)) !=
                plan._linkedDigest) {
              throw const OmlxException('oMLX 解除关联前内容变化');
            }
            await _save(excluding: current.id);
            _linkedOmlx.remove(current.id);
          }
          return;
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
  EngineRuntime runtimeFor(String id) {
    if (id == omlxId || _linkedOmlx.containsKey(id)) {
      final pool = omlxEngine;
      if (pool == null) {
        throw const OmlxException('oMLX 未安装或未登记，没有可调用模型能力');
      }
      return pool;
    }
    return providerFor(id);
  }

  LlamaEngine providerFor(String id) {
    final provider = _managed[id] ?? _linked[id];
    if (provider == null) throw const LlamaEngineException('引擎登记已变化');
    return provider;
  }

  List<EngineRun> runsFor(Iterable<String> artifactIds) {
    final ids = artifactIds.toSet();
    return [
      for (final entry in state.entries)
        if (entry.family == EngineFamily.llamaCpp)
          for (final instance in runtimeFor(entry.id).runtimeInstances)
            if (ids.contains(instance.artifactId)) EngineRun(entry, instance),
    ];
  }

  Future<void> stopManaged() {
    if (_recycle != null) return _recycle!;
    _recycling = true;
    final releaseOmlx = omlxEngine?.holdInstallationAdmission();
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
    if (omlxEngine != null) {
      stops.add(
        omlxEngine!.stopManaged().catchError((Object error) {
          errors.add(error);
        }),
      );
    }
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
      releaseOmlx?.call();
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
    omlxEngine?.beginShutdown();
    for (final provider in _providers) {
      provider.beginShutdown();
    }
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    beginShutdown();
    final operation = _drainAndStop();
    _shutdown = operation;
    // Keep admission permanently closed, but let failed owned cleanup retry.
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_shutdown, operation)) _shutdown = null;
        },
      ),
    );
    return operation;
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
    try {
      await omlxEngine?.shutdown();
    } catch (error) {
      errors.add(error);
    }
    if (errors.isNotEmpty) throw StateError('引擎管理器退出未完成：${errors.join('; ')}');
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }

  void close() {
    _omlxSubscription?.cancel();
    omlxEngine?.close();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final provider in _linked.values) {
      provider.close();
    }
    _changes.close();
  }
}
