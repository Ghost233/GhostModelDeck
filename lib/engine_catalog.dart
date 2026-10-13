import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'llama_engine.dart';
import 'engine_source_build.dart';
import 'engine_runtime.dart';
import 'engine_launch_configuration.dart';
import 'engine_parameter_recognition.dart';
import 'model_library.dart';
import 'omlx_engine.dart';
import 'model_use_registry.dart';
import 'splash_engine.dart';

enum EngineSource { managed, linked }

class UnlinkedLaunchConfiguration {
  UnlinkedLaunchConfiguration({
    required this.registrationId,
    required this.name,
    required this.family,
    required this.path,
    this.version,
    this.fingerprint,
    this.defaults,
    Map<String, ModelLaunchOverrides> models = const {},
  }) : models = Map.unmodifiable(models);

  final String registrationId;
  final String name;
  final EngineFamily family;
  final String path;
  final String? version;
  final String? fingerprint;
  final EngineLaunchConfiguration? defaults;
  final Map<String, ModelLaunchOverrides> models;

  factory UnlinkedLaunchConfiguration.fromJson(String id, Object? value) {
    if (id.isEmpty ||
        value is! Map ||
        value['name'] is! String ||
        value['path'] is! String ||
        !['llamaCpp', 'omlx', 'splash'].contains(value['family']) ||
        value['version'] != null && value['version'] is! String ||
        value['fingerprint'] != null && value['fingerprint'] is! String ||
        !value.containsKey('defaults') ||
        value['models'] is! Map) {
      throw const FormatException('未关联启动配置无效');
    }
    final models = <String, ModelLaunchOverrides>{};
    for (final model in (value['models'] as Map).entries) {
      if (model.key is! String || (model.key as String).isEmpty) {
        throw const FormatException('未关联模型配置无效');
      }
      models[model.key as String] = ModelLaunchOverrides.fromJson(model.value);
    }
    final family = EngineFamily.values.byName(value['family'] as String);
    final defaults = value['defaults'] == null
        ? null
        : EngineLaunchConfiguration.fromJson(value['defaults']);
    if (defaults != null && defaults.family != family ||
        models.values.any(
          (selection) =>
              selection.configuration != null &&
              selection.configuration!.family != family,
        )) {
      throw const FormatException('未关联启动配置与引擎家族不一致');
    }
    return UnlinkedLaunchConfiguration(
      registrationId: id,
      name: value['name'] as String,
      family: family,
      path: value['path'] as String,
      version: value['version'] as String?,
      fingerprint: value['fingerprint'] as String?,
      defaults: defaults,
      models: models,
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'family': family.name,
    'path': path,
    'version': version,
    'fingerprint': fingerprint,
    'defaults': defaults?.toJson(),
    'models': {
      for (final model in models.entries) model.key: model.value.toJson(),
    },
  };
}

class ModelLaunchOverrides {
  const ModelLaunchOverrides({this.enabled = false, this.configuration});
  final bool enabled;
  final EngineLaunchConfiguration? configuration;

  factory ModelLaunchOverrides.fromJson(Object? value) {
    if (value is! Map ||
        value['enabled'] is! bool ||
        !value.containsKey('configuration')) {
      throw const FormatException('模型启动配置无效');
    }
    final configuration = value['configuration'] == null
        ? null
        : EngineLaunchConfiguration.fromJson(value['configuration']);
    if (value['enabled'] == true && configuration == null) {
      throw const FormatException('模型独立启动配置缺失');
    }
    return ModelLaunchOverrides(
      enabled: value['enabled'] as bool,
      configuration: configuration,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'configuration': configuration?.toJson(),
  };
}

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
    this.sourceBuild,
    this.splashInstallation,
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
  final Map<String, Object?>? sourceBuild;
  final SplashInstallation? splashInstallation;
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
    this.embeddingEngine,
    this.omlxEngine,
    this.startStartluxReadout,
    this.sourceBuilder,
    this.splashIO,
    required this.useRegistry,
    required this.registryFile,
    EngineProcessIO? io,
  }) : io = io ?? NativeEngineProcessIO() {
    for (final entry in _managed.entries) {
      entry.value.readLaunchConfigurationFrom(
        (artifactId) => launchConfigurationFor(entry.key, artifactId),
      );
      _subscriptions.add(entry.value.changes.listen((_) => _publish()));
    }
    _omlxSubscription = omlxEngine?.changes.listen((_) => _publish());
    _sourceSubscription = sourceBuilder?.changes.listen((progress) {
      if (_sourceOperation == null) return;
      _sourceProgress = progress.phase == EngineSourceBuildPhase.complete
          ? const EngineSourceBuildProgress(
              EngineSourceBuildPhase.inspecting,
              '登记编译结果…',
            )
          : progress;
      _publish();
    });
  }
  static const omlxId = 'official-omlx-v0.7.0';
  static const officialId = 'official-llama-b11381';
  static const standardId = 'official-llama-v0.5.0';
  static const embeddingId = 'official-llama-b11457';
  Map<String, LlamaEngine> get _managed => {
    officialId: officialEngine,
    standardId: ?standardEngine,
    embeddingId: ?embeddingEngine,
  };
  Iterable<LlamaEngine> get _providers => [
    ..._managed.values,
    ..._linked.values,
  ];
  final ModelLibrary library;
  final LlamaEngine officialEngine;
  final LlamaEngine? standardEngine;
  final LlamaEngine? embeddingEngine;
  final OmlxEngine? omlxEngine;
  final StartluxReadoutStarter? startStartluxReadout;
  final EngineSourceBuilder? sourceBuilder;
  Iterable<EngineRuntime> get runtimes => {
    ..._providers,
    ..._splash.values,
    ?omlxEngine,
  };
  final SplashProcessIO? splashIO;
  final _splash = <String, SplashEngine>{};
  final _splashSubscriptions = <StreamSubscription<SplashEngineState>>[];
  final _splashAdmissions = <SplashEngine, void Function()>{};
  StreamSubscription<OmlxState>? _omlxSubscription;
  final _linkedOmlx = <String, _LinkedOmlx>{};
  final ModelUseRegistry useRegistry;
  final File registryFile;
  final EngineProcessIO io;
  final _changes = StreamController<EngineCatalogState>.broadcast();
  final _linked = <String, LlamaEngine>{};
  final _names = <String, String>{};
  final _sourceBuilds = <String, Map<String, Object?>>{};
  final _preferredModelEngines = <String, String>{};
  String? preferredEngineFor(String artifactId) =>
      _preferredModelEngines[artifactId];

  final _launchDefaults = <String, EngineLaunchConfiguration>{};
  final _modelLaunchOverrides = <String, Map<String, ModelLaunchOverrides>>{};
  final _unlinkedConfigurations = <String, UnlinkedLaunchConfiguration>{};
  final _configurationVersions = <String, String?>{};
  List<UnlinkedLaunchConfiguration> get unlinkedConfigurations =>
      List.unmodifiable(_unlinkedConfigurations.values);
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
  final _installations = <String, Future<void>>{};
  StreamSubscription<EngineSourceBuildProgress>? _sourceSubscription;
  Future<EngineRegistration>? _sourceOperation;
  EngineSourceBuildRequest? _sourceRequest;
  EngineSourceBuildProgress? _sourceProgress;
  DecisionCancellation? _sourceCancellation;
  String? _sourceLogPath;
  EngineSourceBuildRequest? get sourceBuildRequest => _sourceRequest;
  EngineSourceBuildProgress? get sourceBuildProgress => _sourceProgress;
  String? get sourceBuildLogPath => _sourceLogPath;
  bool get sourceBuildActive => _sourceOperation != null;
  void cancelSourceBuild() => _sourceCancellation?.cancel();

  Map<String, EngineInstallProgress> get installationTasks => {
    if (omlxEngine?.installationProgress != null)
      omlxId: omlxEngine!.installationProgress!,
    for (final entry in _managed.entries)
      if (entry.value.installationProgress != null)
        entry.key: entry.value.installationProgress!,
  };
  void cancelInstallation(String id) {
    if (id == omlxId) {
      omlxEngine?.cancelInstallation();
    } else {
      _managed[id]?.cancelInstallation();
    }
  }

  Stream<EngineCatalogState> get changes => _changes.stream;
  EngineCatalogState get state => EngineCatalogState(
    busy: _busy,
    error: _error,
    entries: List.unmodifiable([
      if (omlxEngine != null)
        EngineRegistration(
          id: omlxId,
          name: 'oMLX · 0.7.0',
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
          version: omlxEngine!.state.status == OmlxInstallationStatus.installed
              ? omlxEngine!.state.receipt?.parameterRecognition?.version
              : null,
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
          version: row.value.error == null
              ? row.value.receipt.parameterRecognition?.version
              : null,
          omlxReceipt: row.value.receipt,
          error: row.value.error,
        ),
      for (final entry in _managed.entries)
        EngineRegistration(
          id: entry.key,
          name: entry.key == officialId
              ? 'llama.cpp · JEV b11381'
              : entry.key == embeddingId
              ? 'llama.cpp · 嵌入 b11457'
              : 'llama.cpp · b11146',
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
          sourceBuild: _sourceBuilds[entry.key],
          error: entry.value.state.error,
        ),
      for (final entry in _splash.entries)
        EngineRegistration(
          id: entry.key,
          name: 'Splash',
          family: EngineFamily.splash,
          source: EngineSource.linked,
          status: entry.value.state.installation,
          path: entry.value.installation.root.path,
          version: entry.value.installation.observedVersion,
          splashInstallation: entry.value.installation,
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
    final beforeLinked = jsonEncode([
      for (final provider in _linked.values)
        {
          'path': provider.linkedInstallation!.path,
          'version': provider.linkedInstallation!.version,
          'fingerprints': provider.linkedInstallation!.fingerprints,
        },
    ]);
    for (final provider in _providers) {
      if (provider.state.installation != LlamaInstallationStatus.installing) {
        await provider.refreshInstallation();
      }
    }
    final afterLinked = jsonEncode([
      for (final provider in _linked.values)
        {
          'path': provider.linkedInstallation!.path,
          'version': provider.linkedInstallation!.version,
          'fingerprints': provider.linkedInstallation!.fingerprints,
        },
    ]);
    if (beforeLinked != afterLinked) await _save();
    for (final provider in _splash.values) {
      await provider.refreshInstallation();
    }
    if (omlxEngine?.state.status != OmlxInstallationStatus.installing) {
      await omlxEngine?.refreshInstallation();
    }
    for (final row in _linkedOmlx.entries.toList()) {
      try {
        final receipt = await omlxEngine!.inspectLinked(
          Directory(row.value.path),
          previousReceipt: row.value.receipt,
        );
        _linkedOmlx[row.key] = _LinkedOmlx(row.value.path, receipt);
      } catch (_) {
        _linkedOmlx[row.key] = _LinkedOmlx(
          row.value.path,
          row.value.receipt,
          error: 'oMLX 关联 app 重新验证失败',
        );
      }
    }
    if (_splash.isNotEmpty || _linkedOmlx.isNotEmpty) await _save();
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
          ![1, 2, 3, 4, 5].contains(value['schema']) ||
          value['linked'] is! List) {
        throw const LlamaEngineException('引擎登记文件无效');
      }
      final preferred = value['preferredModelEngines'] ?? <String, String>{};
      if (preferred is! Map ||
          preferred.entries.any(
            (e) => e.key is! String || e.value is! String,
          )) {
        throw const LlamaEngineException('模型引擎选择登记无效');
      }
      // Parse completely before mutating ownership; malformed mixed-family rows
      // must leave both the existing schema-1 file and catalog unchanged.
      final cppRows = <String, (String, LinkedLlamaInstallation)>{};
      final nativeRows = <String, _LinkedOmlx>{};
      final splashRows =
          <String, (SplashInstallation, List<SplashModelBinding>)>{};
      final sourceRows = <String, Map<String, Object?>>{};
      final launchDefaults = <String, EngineLaunchConfiguration>{};
      if ([3, 4, 5].contains(value['schema'])) {
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
      final modelOverrides = <String, Map<String, ModelLaunchOverrides>>{};
      if ([4, 5].contains(value['schema'])) {
        final rows = value['modelLaunchOverrides'];
        if (rows is! Map) {
          throw const LlamaEngineException('模型启动配置登记无效');
        }
        for (final engine in rows.entries) {
          if (engine.key is! String ||
              (engine.key as String).isEmpty ||
              engine.value is! Map) {
            throw const LlamaEngineException('模型启动配置登记无效');
          }
          final selections = <String, ModelLaunchOverrides>{};
          for (final artifact in (engine.value as Map).entries) {
            if (artifact.key is! String || (artifact.key as String).isEmpty) {
              throw const LlamaEngineException('模型启动配置登记无效');
            }
            try {
              selections[artifact.key as String] =
                  ModelLaunchOverrides.fromJson(artifact.value);
            } on FormatException {
              throw const LlamaEngineException('模型启动配置登记无效');
            }
          }
          modelOverrides[engine.key as String] = Map.unmodifiable(selections);
        }
      }
      final unlinked = <String, UnlinkedLaunchConfiguration>{};
      if (value['schema'] == 5) {
        final histories = value['unlinkedConfigurations'];
        if (histories is! Map) throw const LlamaEngineException('未关联启动配置登记无效');
        for (final history in histories.entries) {
          if (history.key is! String) {
            throw const LlamaEngineException('未关联启动配置登记无效');
          }
          try {
            unlinked[history.key
                as String] = UnlinkedLaunchConfiguration.fromJson(
              history.key as String,
              history.value,
            );
          } on FormatException {
            throw const LlamaEngineException('未关联启动配置登记无效');
          }
        }
      }
      final ids = <String>{officialId, standardId, embeddingId, omlxId};
      final configurationVersions = <String, String?>{};
      final versions = value['configurationVersions'];
      if (versions != null) {
        if (versions is! Map) {
          throw const LlamaEngineException('启动配置来源版本无效');
        }
        for (final entry in versions.entries) {
          if (entry.key is! String ||
              (entry.key as String).isEmpty ||
              entry.value != null &&
                  (entry.value is! String || (entry.value as String).isEmpty)) {
            throw const LlamaEngineException('启动配置来源版本无效');
          }
          configurationVersions[entry.key as String] = entry.value as String?;
        }
      }
      for (final row in value['linked'] as List) {
        if (row is! Map ||
            row['id'] is! String ||
            !ids.add(row['id'] as String)) {
          throw const LlamaEngineException('关联引擎登记信息无效');
        }
        if (row['family'] == 'omlx') {
          if (![2, 3, 4, 5].contains(value['schema']) ||
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
        if (row['family'] == 'splash') {
          if (row['bindings'] is! List) {
            throw const LlamaEngineException('Splash 模型绑定登记无效');
          }
          final installation = SplashInstallation.fromJson(row['installation']);
          splashRows[row['id'] as String] = (
            installation,
            (row['bindings'] as List).map(SplashModelBinding.fromJson).toList(),
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
            [officialId, standardId, embeddingId].contains(row['id']) ||
            _linked.containsKey(row['id'])) {
          throw const LlamaEngineException('关联引擎登记信息无效');
        }
        if (row['sourceBuild'] != null) {
          final data = row['sourceBuild'];
          if (data is! Map<String, Object?> ||
              data['source'] is! String ||
              data['commit'] is! String ||
              !RegExp(r'^[a-f0-9]{40}$').hasMatch(data['commit'] as String) ||
              data['executable'] != row['path'] ||
              (data.containsKey('supports_systemone') &&
                  data['supports_systemone'] is! bool)) {
            throw const LlamaEngineException('源码构建登记来源无效');
          }
          sourceRows[row['id'] as String] = Map.unmodifiable(data);
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
      final families = <String, EngineFamily>{
        for (final history in unlinked.values)
          history.registrationId: history.family,
        for (final id in _managed.keys) id: EngineFamily.llamaCpp,
        if (omlxEngine != null) omlxId: EngineFamily.omlx,
        for (final id in cppRows.keys) id: EngineFamily.llamaCpp,
        for (final id in nativeRows.keys) id: EngineFamily.omlx,
        for (final id in splashRows.keys) id: EngineFamily.splash,
      };
      for (final entry in launchDefaults.entries) {
        final family = families[entry.key];
        if (family != null && entry.value.family != family) {
          throw const LlamaEngineException('引擎启动配置与登记家族不一致');
        }
      }
      for (final entry in modelOverrides.entries) {
        final family = families[entry.key];
        if (family != null &&
            entry.value.values.any(
              (selection) =>
                  selection.configuration != null &&
                  selection.configuration!.family != family,
            )) {
          throw const LlamaEngineException('模型启动配置与登记家族不一致');
        }
      }
      for (final row in cppRows.entries) {
        _register(
          row.key,
          row.value.$1,
          row.value.$2,
          sourceBuild: sourceRows[row.key],
        );
      }
      _linkedOmlx.addAll(nativeRows);
      for (final row in splashRows.entries) {
        _registerSplash(row.key, row.value.$1, row.value.$2);
      }
      _sourceBuilds.addAll(sourceRows);
      _preferredModelEngines.addAll(preferred.cast<String, String>());
      _launchDefaults.addAll(launchDefaults);
      _modelLaunchOverrides.addAll(modelOverrides);
      _unlinkedConfigurations.addAll(unlinked);
      _configurationVersions.addAll(configurationVersions);
    }
    _loaded = true;
  }

  void _register(
    String id,
    String name,
    LinkedLlamaInstallation location, {
    Map<String, Object?>? sourceBuild,
  }) {
    final provider = LlamaEngine(
      startStartluxReadout: startStartluxReadout,
      library: library,
      installationDirectory: File(location.path).parent,
      io: io,
      useRegistry: useRegistry,
      linkedInstallation: location,
      installationId: id,
      sourceBuild: sourceBuild,
    );
    provider.readLaunchConfigurationFrom(
      (artifactId) => launchConfigurationFor(id, artifactId),
    );
    if (_shuttingDown) provider.beginShutdown();
    if (_recycling) {
      _admissionReleases[provider] = provider.holdStartAdmission();
    }
    _linked[id] = provider;
    _names[id] = name;
    _subscriptions.add(provider.changes.listen((_) => _publish()));
  }

  void _registerSplash(
    String id,
    SplashInstallation installation,
    List<SplashModelBinding> bindings,
  ) {
    final provider = SplashEngine(
      installation: installation,
      library: library,
      useRegistry: useRegistry,
      runtimeDirectory: Directory(
        '${registryFile.parent.path}/splash-runtime/$id',
      ),
      io: splashIO,
      configurationFor: (artifact) => launchConfigurationFor(id, artifact),
      bindings: bindings,
      saveBinding: (binding) => _save(splashBinding: (id, binding)),
    );
    _splash[id] = provider;
    if (_shuttingDown) provider.beginShutdown();
    if (_recycling) _splashAdmissions[provider] = provider.holdStartAdmission();
    _splashSubscriptions.add(provider.changes.listen((_) => _publish()));
  }

  Future<void> _save({
    String? excluding,
    Map<String, EngineLaunchConfiguration>? launchDefaults,
    Map<String, Map<String, ModelLaunchOverrides>>? modelLaunchOverrides,
    Map<String, UnlinkedLaunchConfiguration>? unlinkedConfigurations,
    Map<String, String?>? configurationVersions,
    (String, SplashModelBinding)? splashBinding,
    Map<String, String>? preferredModelEngines,
  }) async {
    final configurations = launchDefaults ?? _launchDefaults;
    final modelConfigurations = modelLaunchOverrides ?? _modelLaunchOverrides;
    final histories = unlinkedConfigurations ?? _unlinkedConfigurations;
    final versions = configurationVersions ?? _configurationVersions;
    await registryFile.parent.create(recursive: true);
    final temporary = File('${registryFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': histories.isNotEmpty || versions.isNotEmpty
            ? 5
            : modelConfigurations.isNotEmpty
            ? 4
            : configurations.isNotEmpty
            ? 3
            : _linkedOmlx.keys.any((id) => id != excluding)
            ? 2
            : 1,
        if (configurations.isNotEmpty ||
            modelConfigurations.isNotEmpty ||
            histories.isNotEmpty ||
            versions.isNotEmpty)
          'launchDefaults': {
            for (final entry in configurations.entries)
              entry.key: entry.value.toJson(),
          },
        if (modelConfigurations.isNotEmpty ||
            histories.isNotEmpty ||
            versions.isNotEmpty)
          'modelLaunchOverrides': {
            for (final engine in modelConfigurations.entries)
              engine.key: {
                for (final artifact in engine.value.entries)
                  artifact.key: artifact.value.toJson(),
              },
          },
        if (histories.isNotEmpty || versions.isNotEmpty)
          'unlinkedConfigurations': {
            for (final history in histories.entries)
              history.key: history.value.toJson(),
          },
        if (versions.isNotEmpty) 'configurationVersions': versions,
        if ((preferredModelEngines ?? _preferredModelEngines).isNotEmpty)
          'preferredModelEngines':
              preferredModelEngines ?? _preferredModelEngines,
        'linked': [
          for (final entry in _splash.entries)
            if (entry.key != excluding)
              {
                'id': entry.key,
                'family': 'splash',
                'installation': entry.value.installation.toJson(),
                'bindings': [
                  for (final binding in entry.value.bindings)
                    if (splashBinding?.$1 != entry.key ||
                        splashBinding?.$2.artifactId != binding.artifactId)
                      binding.toJson(),
                  if (splashBinding?.$1 == entry.key)
                    splashBinding!.$2.toJson(),
                ],
              },
          for (final entry in _linked.entries)
            if (entry.key != excluding)
              {
                'id': entry.key,
                'name': _names[entry.key],
                'path': entry.value.linkedInstallation!.path,
                'version': entry.value.linkedInstallation!.version,
                'fingerprints': entry.value.linkedInstallation!.fingerprints,
                if (_sourceBuilds.containsKey(entry.key))
                  'sourceBuild': _sourceBuilds[entry.key],
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

  EngineRegistration _configurationRegistration(String id) {
    final entry = state.entries.where((entry) => entry.id == id).singleOrNull;
    if (entry == null) throw const LlamaEngineException('引擎登记已变化');
    return entry;
  }

  EngineParameterRecognition parameterRecognitionFor(String id) {
    final entry = _configurationRegistration(id);
    if (entry.family == EngineFamily.llamaCpp) {
      return providerFor(id).parameterRecognition;
    }
    if (entry.family == EngineFamily.splash) {
      return _splash[id]!.state.recognition;
    }
    final receipt = entry.omlxReceipt;
    final current = receipt?.parameterRecognition;
    if (entry.status == LlamaInstallationStatus.installed &&
        receipt != null &&
        current != null &&
        current.family == entry.family &&
        current.executablePath == '${entry.path}/Contents/MacOS/omlx-cli' &&
        current.contentFingerprint == receipt.bundleManifestSha256) {
      return current;
    }
    return EngineParameterRecognition.builtIn(
      family: entry.family,
      notice: '当前 oMLX 帮助不可用；使用内置规则，未知参数保留并交由引擎处理。',
    );
  }

  Map<String, Map<String, ModelLaunchOverrides>>
  get configuredLaunchOverrides => Map.unmodifiable(_modelLaunchOverrides);

  EngineLaunchConfiguration launchDefaultsFor(String id) {
    final entry = _configurationRegistration(id);
    return _launchDefaults[id] ??
        EngineLaunchConfiguration(family: entry.family);
  }

  String? configurationVersionNoticeFor(String id) {
    final entry = _configurationRegistration(id);
    final source = _configurationVersions[id];
    final current = entry.version;
    if (source == null || current == null) return null;
    final previous = LlamaBinaryVersion.parse(source);
    final observed = LlamaBinaryVersion.parse(current);
    final unchanged =
        entry.family == EngineFamily.llamaCpp &&
            previous != null &&
            observed != null
        ? previous.semanticVersion == observed.semanticVersion &&
              previous.build == observed.build &&
              previous.commit == observed.commit &&
              previous.platform == observed.platform
        : source == current;
    return unchanged ? null : '参数来源版本已变化；已保留原表单与参数文本，请核对当前帮助。';
  }

  Map<String, String?> _versionsForSave(String id) {
    final versions = {..._configurationVersions};
    final current = _configurationRegistration(id).version;
    versions.putIfAbsent(id, () => current);
    return versions;
  }

  void _requireConfigurationFamily(
    String id,
    EngineLaunchConfiguration configuration,
  ) {
    if (_configurationRegistration(id).family != configuration.family) {
      throw const LlamaEngineException('启动配置与引擎家族不一致');
    }
  }

  Future<void> saveLaunchDefaults(
    String id,
    EngineLaunchConfiguration configuration,
  ) => _serial(() async {
    await _load();
    _requireConfigurationFamily(id, configuration);
    final versions = _versionsForSave(id);
    await _save(
      launchDefaults: {..._launchDefaults, id: configuration},
      configurationVersions: versions,
    );
    _launchDefaults[id] = configuration;
    _configurationVersions.addAll(versions);
  });

  ModelLaunchOverrides modelLaunchOverridesFor(String id, String artifactId) {
    _configurationRegistration(id);
    return _modelLaunchOverrides[id]?[artifactId] ??
        const ModelLaunchOverrides();
  }

  EngineLaunchConfiguration launchConfigurationFor(
    String id,
    String artifactId,
  ) {
    final selection = modelLaunchOverridesFor(id, artifactId);
    return selection.enabled ? selection.configuration! : launchDefaultsFor(id);
  }

  Future<void> setModelLaunchMode(
    String id,
    String artifactId, {
    required bool independent,
    bool preferEngine = false,
  }) => _serial(() async {
    await _load();
    _requireModelConfigurationTarget(id, artifactId);
    final previous = modelLaunchOverridesFor(id, artifactId);
    await _saveModelSelection(
      id,
      artifactId,
      ModelLaunchOverrides(
        enabled: independent,
        configuration:
            previous.configuration ??
            (independent ? launchDefaultsFor(id) : null),
      ),
      preferEngine: preferEngine,
    );
  });

  Future<void> saveModelLaunchOverrides(
    String id,
    String artifactId,
    EngineLaunchConfiguration configuration, {
    bool preferEngine = false,
  }) => _serial(() async {
    await _load();
    _requireModelConfigurationTarget(id, artifactId);
    _requireConfigurationFamily(id, configuration);
    await _saveModelSelection(
      id,
      artifactId,
      ModelLaunchOverrides(enabled: true, configuration: configuration),
      preferEngine: preferEngine,
    );
  });

  void _requireModelConfigurationTarget(String id, String artifactId) {
    final family = _configurationRegistration(id).family;
    if (!library.state.artifacts.any(
      (asset) =>
          asset.id == artifactId &&
          (family == EngineFamily.llamaCpp
              ? asset.format == 'GGUF' &&
                    [
                      AssetKind.decision,
                      AssetKind.chat,
                      AssetKind.embedding,
                    ].contains(asset.kind)
              : family == EngineFamily.splash
              ? ['GGUF', 'Safetensors'].contains(asset.format) &&
                    asset.kind == AssetKind.chat
              : asset.format == 'Safetensors' && asset.kind == AssetKind.chat),
    )) {
      throw LlamaEngineException(
        family == EngineFamily.llamaCpp
            ? '请选择当前模型库中的文本、决策或嵌入 GGUF 变体'
            : '请选择当前模型库中的聊天 Safetensors 变体；仅保存配置',
      );
    }
  }

  Future<void> _saveModelSelection(
    String id,
    String artifactId,
    ModelLaunchOverrides selection, {
    bool preferEngine = false,
  }) async {
    final selections = {...?_modelLaunchOverrides[id], artifactId: selection};
    final versions = _versionsForSave(id);
    await _save(
      modelLaunchOverrides: {..._modelLaunchOverrides, id: selections},
      preferredModelEngines: preferEngine
          ? {..._preferredModelEngines, artifactId: id}
          : null,
      configurationVersions: versions,
    );
    if (preferEngine) _preferredModelEngines[artifactId] = id;
    _modelLaunchOverrides[id] = Map.unmodifiable(selections);
    _configurationVersions.addAll(versions);
  }

  Future<EngineRegistration> buildFromSource(
    EngineSourceBuildRequest request, {
    DecisionCancellation? cancellation,
  }) {
    final existing = _sourceOperation;
    final current = _sourceRequest;
    if (existing != null) {
      if (current != null &&
          current.source == request.source &&
          current.ref == request.ref &&
          current.name == request.name &&
          current.cmakePath == request.cmakePath &&
          current.supportsSystemone == request.supportsSystemone) {
        return existing;
      }
      return Future.error(
        const EngineSourceBuildException('已有源码构建，请在下载页等待或取消'),
      );
    }
    final token = cancellation ?? DecisionCancellation();
    _sourceRequest = request;
    _sourceCancellation = token;
    _sourceLogPath = null;
    _sourceProgress = const EngineSourceBuildProgress(
      EngineSourceBuildPhase.validating,
      '准备源码构建…',
    );
    final operation =
        _serial(() async {
          await _load();
          final builder = sourceBuilder;
          if (builder == null) throw const LlamaEngineException('源码构建模块未配置');
          return builder;
        }).then((builder) async {
          if (token.isCancelled) throw const EngineSourceBuildCancelled();
          final result = await builder.build(request, token);
          _sourceLogPath = result.logPath;
          if (_shuttingDown || token.isCancelled) {
            throw const EngineSourceBuildCancelled();
          }
          return _serial(() async {
            final id =
                'source-${List.generate(20, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
            _register(
              id,
              request.name,
              result.installation,
              sourceBuild: result.provenance,
            );
            _sourceBuilds[id] = result.provenance;
            var saved = false;
            try {
              await _linked[id]!.refreshInstallation();
              if (_shuttingDown || token.isCancelled) {
                throw const EngineSourceBuildCancelled();
              }
              if (_linked[id]!.state.installation !=
                  LlamaInstallationStatus.installed) {
                throw LlamaEngineException(
                  _linked[id]!.state.error ?? '源码构建产物核验失败',
                );
              }
              await _save();
              saved = true;
              if (_shuttingDown || token.isCancelled) {
                throw const EngineSourceBuildCancelled();
              }
            } catch (error, stack) {
              Object? rollbackError;
              if (saved) {
                try {
                  await _save(excluding: id);
                } catch (failure) {
                  rollbackError = failure;
                }
              }
              _linked.remove(id)?.close();
              _names.remove(id);
              _sourceBuilds.remove(id);
              if (rollbackError != null) {
                Error.throwWithStackTrace(
                  EngineSourceBuildException(
                    '$error；源码引擎登记回滚失败：$rollbackError',
                    logPath: result.logPath,
                  ),
                  stack,
                );
              }
              rethrow;
            }
            return state.entries.singleWhere((entry) => entry.id == id);
          });
        });
    final tracked = operation
        .then(
          (entry) {
            _sourceProgress = const EngineSourceBuildProgress(
              EngineSourceBuildPhase.complete,
              '引擎已登记',
            );
            return entry;
          },
          onError: (Object error, StackTrace stack) {
            if (error is EngineSourceBuildException) {
              _sourceLogPath = error.logPath;
            }
            _sourceProgress = EngineSourceBuildProgress(
              error is EngineSourceBuildCancelled
                  ? EngineSourceBuildPhase.cancelled
                  : EngineSourceBuildPhase.failed,
              error.toString(),
            );
            Error.throwWithStackTrace(error, stack);
          },
        )
        .whenComplete(() {
          _sourceOperation = null;
          _sourceCancellation = null;
          _publish();
        });
    _sourceOperation = tracked;
    _publish();
    return tracked;
  }

  Future<void> installOfficial({File? verifiedArchive}) =>
      installManaged(officialId, verifiedArchive: verifiedArchive);
  Future<void> installManaged(String id, {File? verifiedArchive}) {
    if (_installations.containsKey(id)) return _installations[id]!;
    final operation =
        _serial(() async {
          await _load();
          if (id == omlxId && omlxEngine != null) {
            return () => omlxEngine!.install(verifiedArtifact: verifiedArchive);
          }
          final provider = _managed[id];
          if (provider == null) throw const LlamaEngineException('请选择受管引擎安装');
          return () => provider.install(verifiedArchive: verifiedArchive);
        }).then((install) {
          if (_shuttingDown || _recycling) {
            if (id == omlxId) throw const OmlxException('oMLX 安装准入已关闭');
            throw const LlamaEngineException('引擎安装准入已关闭');
          }
          return install();
        });
    final tracked = operation.whenComplete(() {
      _installations.remove(id);
    });
    _installations[id] = tracked;
    return tracked;
  }

  Future<EngineRegistration> link(String path) => _serial(() async {
    await _load();
    if (await File('$path/server/server.py').exists() &&
        await File('$path/install/launcher.py').exists()) {
      final installation = await SplashEngine.inspectInstallation(
        Directory(path),
        io: splashIO,
      );
      if (_shuttingDown || _recycling) {
        throw const SplashEngineException('Splash 关联已取消');
      }
      if (_splash.values.any(
        (engine) => engine.installation.root.path == installation.root.path,
      )) {
        throw const SplashEngineException('该 Splash 仓库已关联');
      }
      final id =
          'splash-${List.generate(20, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      _registerSplash(id, installation, const []);
      try {
        await _save();
      } catch (_) {
        await _splash.remove(id)!.close();
        rethrow;
      }
      return state.entries.singleWhere((entry) => entry.id == id);
    }
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
    if (entry.family == EngineFamily.splash) {
      if (_splash[id]!.hasLiveInstances) {
        throw const SplashEngineException('请先停止该引擎的模型实例');
      }
      return EngineRemovalPlan._(
        this,
        entry: entry,
        paths: const [],
        sizeBytes: 0,
      );
    }
    if (entry.family == EngineFamily.omlx) {
      omlxEngine!.assertRemovable();
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
        if (plan.entry.family == EngineFamily.splash) {
          final provider = _splash[plan.entry.id];
          if (provider == null ||
              provider.installation.root.path != plan.entry.path) {
            throw const SplashEngineException('Splash 解除关联计划已失效');
          }
          final history = _unlinkedSnapshot(plan.entry);
          final release = provider.holdStartAdmission();
          try {
            await provider.detachLinked(
              persistRemoval: () => _save(
                excluding: plan.entry.id,
                unlinkedConfigurations: {
                  ..._unlinkedConfigurations,
                  plan.entry.id: history,
                },
              ),
            );
            _unlinkedConfigurations[plan.entry.id] = history;
            _splash.remove(plan.entry.id);
            await provider.close();
          } finally {
            release();
          }
          return;
        }
        if (plan.entry.family == EngineFamily.omlx) {
          final release = omlxEngine!.holdStartAdmission();
          try {
            omlxEngine!.assertRemovable();
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
              await omlxEngine!.removeInstallation(
                plan._omlx!,
                confirmed: true,
              );
            } else {
              if (await omlxEngine!.linkedDigest(Directory(current.path!)) !=
                  plan._linkedDigest) {
                throw const OmlxException('oMLX 解除关联前内容变化');
              }
              final history = _unlinkedSnapshot(current);
              await _save(
                excluding: current.id,
                unlinkedConfigurations: {
                  ..._unlinkedConfigurations,
                  current.id: history,
                },
              );
              _unlinkedConfigurations[current.id] = history;
              _linkedOmlx.remove(current.id);
            }
            return;
          } finally {
            release();
          }
        }
        final provider = providerFor(plan.entry.id);
        if (plan.entry.source == EngineSource.managed) {
          await provider.removeInstallation(plan._managed!, confirmed: true);
          return;
        }
        final releaseAdmission = provider.holdStartAdmission();
        try {
          final history = _unlinkedSnapshot(plan.entry);
          await provider.detachLinked(
            persistRemoval: () => _save(
              excluding: plan.entry.id,
              unlinkedConfigurations: {
                ..._unlinkedConfigurations,
                plan.entry.id: history,
              },
            ),
          );
          _unlinkedConfigurations[plan.entry.id] = history;
          _linked.remove(plan.entry.id);
          _sourceBuilds.remove(plan.entry.id);
          _names.remove(plan.entry.id);
          provider.close();
        } finally {
          releaseAdmission();
        }
      });

  UnlinkedLaunchConfiguration _unlinkedSnapshot(EngineRegistration entry) =>
      UnlinkedLaunchConfiguration(
        registrationId: entry.id,
        name: entry.name,
        family: entry.family,
        path: entry.path!,
        version:
            entry.version ??
            _linked[entry.id]?.linkedInstallation?.version ??
            entry.omlxReceipt?.releaseLabel,
        fingerprint:
            entry.binarySha256 ??
            entry.omlxReceipt?.bundleManifestSha256 ??
            entry.sha256,
        defaults: _launchDefaults[entry.id],
        models: _modelLaunchOverrides[entry.id] ?? const {},
      );

  Future<void> restoreUnlinkedConfiguration(String sourceId, String targetId) =>
      _serial(() async {
        await _load();
        final source = _unlinkedConfigurations[sourceId];
        final target = state.entries
            .where((entry) => entry.id == targetId)
            .firstOrNull;
        if (source == null || target == null || sourceId == targetId) {
          throw const LlamaEngineException('请选择未关联配置与当前恢复目标');
        }
        if (source.family != target.family) {
          throw const LlamaEngineException('来源与目标引擎家族不同，不能恢复');
        }
        if (target.family == EngineFamily.llamaCpp) {
          final provider = providerFor(targetId);
          await provider.refreshInstallation();
          if (provider.state.installation !=
              LlamaInstallationStatus.installed) {
            throw const LlamaEngineException('恢复目标未通过当前安装或关联核验');
          }
        } else if (target.family == EngineFamily.splash) {
          await _splash[targetId]!.refreshInstallation();
          if (_splash[targetId]!.state.installation !=
              LlamaInstallationStatus.installed) {
            throw const SplashEngineException('恢复目标未通过 Splash 安装核验');
          }
        } else if (target.source == EngineSource.managed) {
          await omlxEngine!.refreshInstallation();
          if (omlxEngine!.state.status != OmlxInstallationStatus.installed) {
            throw const OmlxException('恢复目标未通过当前 oMLX 安装核验');
          }
        } else {
          final previous = _linkedOmlx[targetId]!;
          try {
            final receipt = await omlxEngine!.inspectLinked(
              Directory(previous.path),
              previousReceipt: previous.receipt,
            );
            if (receipt.bundleManifestSha256 !=
                previous.receipt.bundleManifestSha256) {
              throw const OmlxException('恢复目标 oMLX 内容变化');
            }
            _linkedOmlx[targetId] = _LinkedOmlx(previous.path, receipt);
          } catch (_) {
            _linkedOmlx[targetId] = _LinkedOmlx(
              previous.path,
              previous.receipt,
              error: 'oMLX 关联 app 重新验证失败',
            );
            rethrow;
          }
        }
        final defaults = {..._launchDefaults};
        if (source.defaults == null) {
          defaults.remove(targetId);
        } else {
          defaults[targetId] = source.defaults!;
        }
        final models = {..._modelLaunchOverrides, targetId: source.models};
        final versions = {..._configurationVersions};
        final sourceVersion = versions.containsKey(sourceId)
            ? versions[sourceId]
            : source.version;
        versions[targetId] = sourceVersion;
        await _save(
          launchDefaults: defaults,
          modelLaunchOverrides: models,
          configurationVersions: versions,
        );
        _launchDefaults
          ..clear()
          ..addAll(defaults);
        _modelLaunchOverrides[targetId] = source.models;
        _configurationVersions
          ..clear()
          ..addAll(versions);
      });
  EngineRuntime runtimeFor(String id) {
    if (_splash.containsKey(id)) return _splash[id]!;
    if (id == omlxId || _linkedOmlx.containsKey(id)) {
      final pool = omlxEngine;
      if (pool == null) {
        throw const OmlxException('oMLX 未安装或未登记，没有可调用模型能力');
      }
      return pool;
    }
    return providerFor(id);
  }

  Future<SplashModelBinding> bindSplashModel(
    String id,
    String artifactId,
    Directory assembly,
  ) => _serial(() async {
    final provider = _splash[id];
    if (provider == null) throw const SplashEngineException('Splash 登记已变化');
    return provider.bindModel(artifactId, assembly);
  });

  LlamaEngine providerFor(String id) {
    final provider = _managed[id] ?? _linked[id];
    if (provider == null) throw const LlamaEngineException('引擎登记已变化');
    return provider;
  }

  List<EngineRun> runsFor(Iterable<String> artifactIds) {
    final ids = artifactIds.toSet();
    return [
      for (final entry in state.entries)
        if (entry.family != EngineFamily.omlx)
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
    final initialSplash = _splash.values.toSet();
    for (final provider in initialSplash) {
      _splashAdmissions[provider] = provider.holdStartAdmission();
      stops.add(
        provider.stopManaged().catchError((Object error) {
          errors.add(error);
        }),
      );
    }
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
      for (final provider in _splash.values.where(
        (p) => !initialSplash.contains(p),
      )) {
        stops.add(
          provider.stopManaged().catchError((Object error) {
            errors.add(error);
          }),
        );
      }
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
      for (final release in _splashAdmissions.values) {
        release();
      }
      _splashAdmissions.clear();
      _recycling = false;
      _recycle = null;
    });
    return _recycle!;
  }

  void beginShutdown() {
    _shuttingDown = true;
    cancelSourceBuild();
    sourceBuilder?.cancelBuild();
    omlxEngine?.beginShutdown();
    for (final provider in _splash.values) {
      provider.beginShutdown();
    }
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
    final errors = <Object>[];
    try {
      await sourceBuilder?.close();
    } catch (error) {
      errors.add(error);
    }
    await _sourceOperation?.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await _operations;
    for (final provider in _splash.values) {
      try {
        await provider.shutdown();
      } catch (error) {
        errors.add(error);
      }
    }
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
    unawaited(_sourceSubscription?.cancel());
    for (final subscription in _splashSubscriptions) {
      unawaited(subscription.cancel());
    }
    for (final provider in _splash.values) {
      unawaited(provider.close());
    }
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
