import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'engine_parameter_recognition.dart';
import 'engine_runtime.dart';
import 'engine_launch_configuration.dart';
import 'launch_argument_text.dart';
import 'llama_engine.dart';
import 'model_library.dart';
import 'model_use_registry.dart';
import 'splash_preparation.dart';
import 'chat_protocol.dart';
import 'decision_protocol.dart';
import 'decision_runtime.dart';
import 'jev_debug.dart';
import 'runtime_monitor.dart';

class SplashEngineException implements Exception {
  const SplashEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SplashRequestException extends SplashEngineException
    implements DecisionCallFailure {
  const SplashRequestException(
    super.message, {
    required this.kind,
    this.rawResponse,
  });
  @override
  final DecisionFailureKind kind;
  @override
  final String? rawResponse;
}

enum SplashInstallationKind { source, packaged }

class SplashInstallation {
  SplashInstallation({
    required this.kind,
    required this.root,
    required this.python,
    required this.moduleRoot,
    required this.nativeBinary,
    required this.observedVersion,
    required this.pythonVersion,
    required this.pythonPrefix,
    required this.help,
    this.helpError,
    this.verified = false,
    this.supportsSystemone = false,
    required Map<String, String> fingerprints,
  }) : fingerprints = Map.unmodifiable(fingerprints);

  final SplashInstallationKind kind;
  final Directory root;
  final File python;
  final Directory moduleRoot;
  final File nativeBinary;
  final String observedVersion;
  final String pythonVersion;
  final String pythonPrefix;
  final bool supportsSystemone;
  final String help;
  final String? helpError;
  // Current I/O observation only; never restored from JSON.
  final bool verified;
  final Map<String, String> fingerprints;

  EngineParameterRecognition get recognition => helpError != null
      ? EngineParameterRecognition.builtIn(
          family: EngineFamily.splash,
          version: observedVersion,
          executablePath: python.path,
          contentFingerprint: sha256
              .convert(utf8.encode(jsonEncode(fingerprints)))
              .toString(),
          notice: helpError,
        )
      : EngineParameterRecognition.fromHelp(
          help,
          family: EngineFamily.splash,
          version: observedVersion,
          executablePath: python.path,
          contentFingerprint: sha256
              .convert(utf8.encode(jsonEncode(fingerprints)))
              .toString(),
        );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'root': root.path,
    'python': python.path,
    'module_root': moduleRoot.path,
    'native_binary': nativeBinary.path,
    'observed_version': observedVersion,
    'python_version': pythonVersion,
    'python_prefix': pythonPrefix,
    'supports_systemone': supportsSystemone,
    'help': help,
    'help_error': helpError,
    'fingerprints': fingerprints,
  };

  factory SplashInstallation.fromJson(Object? value) {
    final row = _object(value, 'Splash installation');
    if (row.containsKey('supports_systemone') &&
        row['supports_systemone'] is! bool) {
      throw const FormatException('Splash 原生接口声明无效');
    }
    final kind = switch (row['kind']) {
      'source' => SplashInstallationKind.source,
      'packaged' => SplashInstallationKind.packaged,
      _ => throw const FormatException('Splash installation kind无效'),
    };
    final hashes = _hashes(row['fingerprints'], allowEmpty: true);
    final root = _path(row['root']);
    final python = _path(row['python']);
    final native = _path(row['native_binary']);
    if (_path(row['module_root']) != root ||
        python !=
            '$root/${kind == SplashInstallationKind.source ? '.venv/bin/python' : 'python/bin/python3'}' ||
        native !=
            '$root/${kind == SplashInstallationKind.source ? 'build/splash' : 'engine/splash'}') {
      throw const FormatException('Splash source/Python/native身份不完整或路径不符');
    }
    return SplashInstallation(
      kind: kind,
      root: Directory(_path(row['root'])),
      python: File(_path(row['python'])),
      moduleRoot: Directory(_path(row['module_root'])),
      nativeBinary: File(native),
      observedVersion: _string(row['observed_version']),
      pythonVersion: _string(row['python_version']),
      pythonPrefix: _path(row['python_prefix']),
      supportsSystemone: row['supports_systemone'] == true,
      help: _string(row['help'], empty: true),
      helpError: row['help_error'] == null ? null : _string(row['help_error']),
      fingerprints: hashes,
    );
  }
}

class SplashModelBinding {
  SplashModelBinding({
    required this.artifactId,
    required this.assembly,
    required this.tokenizer,
    required this.nativeModel,
    required this.family,
    required this.targetFormat,
    required Map<String, String> sourceHashes,
    required Map<String, int> sourceSizes,
    required Map<String, String> roles,
  }) : sourceHashes = Map.unmodifiable(sourceHashes),
       sourceSizes = Map.unmodifiable(sourceSizes),
       roles = Map.unmodifiable(roles);

  final String artifactId;
  final Directory assembly;
  final Directory tokenizer;
  final String nativeModel;
  final String family;
  final String targetFormat;
  final Map<String, String> sourceHashes;
  final Map<String, int> sourceSizes;
  final Map<String, String> roles;

  Map<String, Object?> toJson() => {
    'artifact_id': artifactId,
    'assembly': assembly.path,
    'tokenizer': tokenizer.path,
    'native_model': nativeModel,
    'family': family,
    'target_format': targetFormat,
    'source_hashes': sourceHashes,
    'source_sizes': sourceSizes,
    'roles': roles,
  };

  factory SplashModelBinding.fromJson(Object? value) {
    final row = _object(value, 'Splash binding');
    final format = _string(row['target_format']);
    if (!['gguf', 'mlx-affine'].contains(format)) {
      throw const FormatException('Splash target format无效');
    }
    final hashes = _hashes(row['source_hashes']);
    final sizes = <String, int>{};
    for (final entry in _object(row['source_sizes'], 'Splash sizes').entries) {
      if (!hashes.containsKey(entry.key) ||
          entry.value is! int ||
          (entry.value as int) < 0) {
        throw const FormatException('Splash source size无效');
      }
      sizes[entry.key] = entry.value as int;
    }
    if (sizes.length != hashes.length) {
      throw const FormatException('Splash source sizes不完整');
    }
    final roles = <String, String>{};
    for (final entry in _object(row['roles'], 'Splash roles').entries) {
      if (entry.key.startsWith('/') || entry.key.split('/').contains('..')) {
        throw const FormatException('Splash role无效');
      }
      final path = _path(entry.value);
      if (!hashes.containsKey(path)) {
        throw const FormatException('Splash role身份缺失');
      }
      roles[entry.key] = path;
    }
    if (!roles.containsKey('model.json') ||
        (roles.keys.any((p) => p.startsWith('draft/')) &&
            (!roles.containsKey('draft/config.json') ||
                !roles.keys.any(
                  (p) =>
                      p.startsWith('draft/') &&
                      (p.endsWith('.safetensors') || p.endsWith('.gguf')),
                ))) ||
        !roles.containsKey('config.json') ||
        !roles.keys.any((p) => p.startsWith('target/')) ||
        !roles.keys.any((p) => p.startsWith('tokenizer/'))) {
      throw const FormatException('Splash binding不完整');
    }
    return SplashModelBinding(
      artifactId: _string(row['artifact_id']),
      assembly: Directory(_path(row['assembly'])),
      tokenizer: Directory(_path(row['tokenizer'])),
      nativeModel: _string(row['native_model']),
      family: _string(row['family']),
      targetFormat: format,
      sourceHashes: hashes,
      sourceSizes: sizes,
      roles: roles,
    );
  }
}

abstract interface class SplashProcessIO implements EngineProcessIO {
  Future<bool> groupAlive(int ownedParentPid);
  Future<void> signalOwnedGroup(int ownedParentPid, ProcessSignal signal);
}

class NativeSplashProcessIO extends NativeEngineProcessIO
    implements SplashProcessIO {
  final _groups = <int>{};

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    final child = await super.start(executable, arguments);
    if (arguments.any(
      (argument) =>
          argument.startsWith('# Ghost Model Deck Splash owned group\n'),
    )) {
      _groups.add(child.pid);
    }
    return child;
  }

  void _requireOwned(int pid) {
    if (!_groups.contains(pid)) {
      throw const SplashEngineException('不是本模块创建的Splash进程组');
    }
  }

  @override
  Future<bool> groupAlive(int ownedParentPid) async {
    _requireOwned(ownedParentPid);
    final result = await super.run('/bin/kill', [
      '-0',
      '--',
      '-$ownedParentPid',
    ], timeout: const Duration(seconds: 5));
    if (result.exitCode == 0) return true;
    if (result.stderr.toLowerCase().contains('no such process')) {
      _groups.remove(ownedParentPid);
      return false;
    }
    throw SplashEngineException('Splash进程组状态未知：${result.stderr}');
  }

  @override
  Future<void> signalOwnedGroup(
    int ownedParentPid,
    ProcessSignal signal,
  ) async {
    _requireOwned(ownedParentPid);
    final result = await super.run('/bin/kill', [
      '-${signal.signalNumber}',
      '--',
      '-$ownedParentPid',
    ], timeout: const Duration(seconds: 5));
    if (result.exitCode != 0 &&
        !result.stderr.toLowerCase().contains('no such process')) {
      throw SplashEngineException('Splash进程组停止失败：${result.stderr}');
    }
  }
}

class SplashEngineState {
  SplashEngineState({
    required this.installation,
    required this.recognition,
    required List<RuntimeInstance> instances,
    this.error,
  }) : instances = List.unmodifiable(instances);
  final LlamaInstallationStatus installation;
  final EngineParameterRecognition recognition;
  final List<RuntimeInstance> instances;
  final String? error;
}

class _SplashRun {
  _SplashRun(
    this.id,
    this.binding,
    this.command,
    this.generation,
    this.endpoint,
    this.version,
    this.asset,
    this.supportsSystemone,
    this.binarySha256,
  );
  bool temporaryTest = false;
  String? launchInstanceId;
  int? launchRevision;
  final String id;
  final LibraryArtifact asset;
  final bool supportsSystemone;
  final String? binarySha256;
  RuntimeCapacity? capacity;
  final SplashModelBinding binding;
  final EngineLaunchCommand command;
  final int generation;
  final Uri endpoint;
  final String version;
  EngineChild? child;
  int? exit;
  String? serverId;
  int? transportEpoch;
  String? responseModel;
  String? error;
  RuntimeInstanceStatus status = RuntimeInstanceStatus.starting;
  bool groupLive = false;
  final cancellation = DecisionCancellation();
  final requests = <_SplashPermit>{};
  final stderr = StringBuffer();
  RuntimeInstance snapshot() => RuntimeInstance(
    id: id,
    artifactId: binding.artifactId,
    status: status,
    generation: generation,
    activeRequests: requests.length,
    acceptingRequests:
        status == RuntimeInstanceStatus.ready && !cancellation.isCancelled,
    hasLiveProcess: groupLive,
    temporaryTest: temporaryTest,
    launchInstanceId: launchInstanceId,
    launchRevision: launchRevision,
    capabilities: status == RuntimeInstanceStatus.ready
        ? {
            RuntimeCapability.textGeneration,
            if (supportsSystemone) ...{
              RuntimeCapability.choiceProbability,
              RuntimeCapability.scoreProbability,
              RuntimeCapability.noulScalar,
            },
          }
        : {},
    error: error,
  );
}

class _SplashPermit {
  final cancellation = DecisionCancellation();
  final done = Completer<void>();
  void Function()? remove;
}

class _SplashDecisionInstance implements DecisionInstance {
  _SplashDecisionInstance(this.run);
  final _SplashRun run;
  @override
  String get id => run.id;
  @override
  LibraryArtifact get asset => run.asset;
  @override
  Uri get endpoint => run.endpoint;
  @override
  int? get pid => run.child?.pid;
  @override
  int get generation => run.generation;
  @override
  bool get decisionReady =>
      run.snapshot().acceptingRequests &&
      run.supportsSystemone &&
      run.groupLive;
  @override
  Set<RuntimeCapability> get decisionCapabilities =>
      run.snapshot().capabilities;
  @override
  RuntimeCapacity? get capacity => run.capacity;
  @override
  int? get maxDecisionConcurrentRequests => run.capacity?.slotCount;
  @override
  String? get binarySha256 => run.binarySha256;
  @override
  String? get nativeAlias => run.responseModel;
  @override
  Map<String, Object?> get decisionSourceIdentity => {
    'kind': 'native_systemone',
    'family': 'splash',
    'native_model': run.binding.nativeModel,
    'endpoint': run.endpoint.resolve('/v1/systemone').toString(),
  };
  @override
  EngineLaunchCommand get launchCommand => run.command;
}

class _SplashBudget {
  _SplashBudget(this.limit, this.cancellation) {
    _timer = Timer(limit > Duration.zero ? limit : Duration.zero, () {
      if (!cancellation.isCancelled) {
        timedOut = true;
        cancellation.cancel();
      }
    });
  }
  final Duration limit;
  final DecisionCancellation cancellation;
  final watch = Stopwatch()..start();
  late final Timer _timer;
  bool timedOut = false;
  Duration get remaining {
    if (!cancellation.isCancelled && watch.elapsed >= limit) {
      timedOut = true;
      cancellation.cancel();
    }
    if (cancellation.isCancelled) throw terminal;
    return limit - watch.elapsed;
  }

  SplashRequestException get terminal => SplashRequestException(
    timedOut ? 'Splash请求超时' : 'Splash请求已取消',
    kind: timedOut
        ? DecisionFailureKind.timedOut
        : DecisionFailureKind.cancelled,
  );
  Future<T> wait<T>(Future<T> Function() operation) async {
    final left = remaining;
    try {
      return await Future.any<T>([
        operation().timeout(left),
        cancellation.whenCancelled.then<T>((_) => throw terminal),
      ]);
    } on TimeoutException {
      timedOut = true;
      cancellation.cancel();
      throw terminal;
    } catch (error) {
      if (cancellation.isCancelled) throw terminal;
      rethrow;
    }
  }

  void close() => _timer.cancel();
}

class _SplashLoading implements Exception {
  const _SplashLoading();
}

class SplashEngine implements DecisionRuntime, RuntimeMonitorSource {
  SplashEngine({
    required SplashInstallation installation,
    required this.library,
    required this.useRegistry,
    required this.runtimeDirectory,
    Directory? modelDirectory,
    required this.configurationFor,
    required this.saveBinding,
    Iterable<SplashModelBinding> bindings = const [],
    SplashProcessIO? io,
  }) : modelDirectory =
           modelDirectory ?? Directory('${runtimeDirectory.path}/models'),
       _installation = installation,
       _installationVerified = installation.verified,
       io = io ?? NativeSplashProcessIO(),
       _bindings = {
         for (final binding in bindings) binding.artifactId: binding,
       };

  SplashInstallation _installation;
  bool _installationVerified;
  SplashInstallation get installation => _installation;
  final ModelLibrary library;
  final ModelUseRegistry useRegistry;
  final Directory runtimeDirectory;
  final Directory modelDirectory;
  final EngineLaunchConfiguration Function(String artifactId) configurationFor;
  final Future<void> Function(SplashModelBinding binding) saveBinding;
  final SplashProcessIO io;
  final Map<String, SplashModelBinding> _bindings;
  Future<void> _operations = Future.value();
  final _startupJobs = <Future<RuntimeInstance>>{};
  final _modelPreparations = <String, Future<SplashModelBinding>>{};
  final _runs = <String, _SplashRun>{};
  final _preparing = <SplashModelBinding>{};
  final _changes = StreamController<SplashEngineState>.broadcast();
  int _generation = 0;
  bool _shuttingDown = false;
  int _startEpoch = 0;
  int _admissionHolds = 0;
  String? _error;
  SplashEngineState get state => SplashEngineState(
    installation: _error == null && _installationVerified
        ? LlamaInstallationStatus.installed
        : LlamaInstallationStatus.failed,
    recognition: _installation.recognition,
    instances: runtimeInstances,
    error: _error ?? (_installationVerified ? null : 'Splash关联记录尚未重新核验'),
  );
  Stream<SplashEngineState> get changes => _changes.stream;
  @override
  List<RuntimeInstance> get runtimeInstances =>
      List.unmodifiable(_runs.values.map((run) => run.snapshot()));
  bool get hasLiveInstances =>
      _startupJobs.isNotEmpty ||
      _runs.values.any(
        (run) => run.groupLive || run.status == RuntimeInstanceStatus.starting,
      );
  int? pidFor(String id) => _runs[id]?.child?.pid;
  Uri? endpointFor(String id) => _runs[id]?.endpoint;
  @override
  bool get supportsSystemone => _installation.supportsSystemone;
  @override
  List<DecisionInstance> get decisionInstances => [
    for (final run in _runs.values)
      if (!run.temporaryTest) _SplashDecisionInstance(run),
  ];
  @override
  Future<RuntimeTelemetry> readTelemetry(
    String instanceId, {
    required DecisionCancellation cancellation,
  }) async {
    final run = _runs[instanceId];
    if (run == null ||
        run.exit != null ||
        run.status != RuntimeInstanceStatus.ready) {
      throw StateError('实例未就绪');
    }
    final row = _object(
      jsonDecode(
        await readMonitorHttp(
          run.endpoint.resolve('/status'),
          cancellation: cancellation,
        ),
      ),
      'Splash status',
    );
    final instance = _object(row['instance'], 'Splash instance');
    final transport = _object(row['transport'], 'Splash transport');
    if (cancellation.isCancelled ||
        !identical(_runs[instanceId], run) ||
        run.exit != null ||
        run.status != RuntimeInstanceStatus.ready ||
        instance['pid'] != run.child?.pid ||
        instance['id'] != run.serverId ||
        instance['model'] != run.binding.nativeModel ||
        transport['restarts'] != run.transportEpoch ||
        transport['ready'] != true ||
        row['ready'] != true) {
      throw StateError('实例身份已变化');
    }
    return RuntimeTelemetry.splash(row);
  }

  EngineLaunchCommand? actualCommandFor(String id) => _runs[id]?.command;
  String? actualVersionFor(String id) => _runs[id]?.version;
  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }

  SplashModelBinding? bindingFor(String artifactId) => _bindings[artifactId];
  Iterable<SplashModelBinding> get bindings =>
      List.unmodifiable(_bindings.values);
  EngineLaunchCommand composeLaunch(
    EngineLaunchConfiguration configuration, {
    SplashModelBinding? binding,
    String? alias,
    int? port,
  }) {
    if (configuration.family != EngineFamily.splash) {
      throw const SplashEngineException('Splash配置family不符');
    }
    final assembly = binding?.assembly.path ?? '<由 GMD 自动准备的模型运行目录>';
    final persistentCache = parseLaunchArgumentText(configuration.argumentText)
        .any(
          (token) =>
              !token.hasLiteralPrefix && token.value == '--persistent-cache',
        );
    final bootstrap =
        '# Ghost Model Deck Splash owned group\n'
        'import os,fcntl,runpy,sys; os.setsid(); '
        'sys.path.insert(0,${jsonEncode(_installation.moduleRoot.path)}); '
        'lock=open(${jsonEncode('$assembly/model.json')},"rb"); fcntl.flock(lock,fcntl.LOCK_SH); '
        'runpy.run_module("server.server",run_name="__main__")';
    return configuration.command(
      executable: _installation.python.path,
      modelPath: assembly,
      alias: alias,
      port: port,
      recognition: _installation.recognition,
      executableArguments: [
        '-B',
        '-P',
        '-c',
        bootstrap,
        assembly,
        '--default-reasoning-effort',
        'none',
      ],
      managedArguments: {
        '--model': binding?.nativeModel ?? '<绑定的 Splash 模型身份>',
        '--tokenizer': binding?.tokenizer.path ?? '<绑定的本地 tokenizer 目录>',
        '--binary': _installation.nativeBinary.path,
        if (persistentCache) '--cache-dir': '${runtimeDirectory.path}/cache',
      },
    );
  }

  Future<EngineLaunchCommand> previewLaunch(
    String artifactId, {
    EngineLaunchConfiguration? configuration,
  }) async {
    await _assertInstallation();
    return composeLaunch(
      configuration ?? configurationFor(artifactId),
      binding: _bindings[artifactId],
    );
  }

  @override
  Future<RuntimeInstance> startRuntime(String artifactId) =>
      startWithConfiguration(artifactId, configurationFor(artifactId));

  Future<RuntimeInstance> startWithConfiguration(
    String artifactId,
    EngineLaunchConfiguration configuration, {
    DecisionCancellation? cancellation,
    bool temporaryTest = false,
    String? launchInstanceId,
    int? launchRevision,
    Directory? assembly,
    Directory? preparationHint,
  }) {
    if (_shuttingDown || _admissionHolds > 0) {
      return Future.error(const SplashEngineException('Splash启动准入已关闭'));
    }
    final epoch = _startEpoch;
    final operation = _operations.then((_) async {
      if (_shuttingDown) throw const SplashEngineException('Splash正在退出');
      final binding = assembly == null
          ? await prepareModelBinding(
              artifactId,
              previous: preparationHint ?? _bindings[artifactId]?.assembly,
              cancellation: cancellation,
            )
          : await _readBinding(artifactId, assembly);
      _preparing.add(binding);
      try {
        await _syncUses();
        await _verifyBinding(binding);
        await _assertInstallation();
        if (_shuttingDown ||
            epoch != _startEpoch ||
            (cancellation?.isCancelled ?? false)) {
          throw const SplashEngineException('Splash启动已取消');
        }
        if (!temporaryTest) {
          _bindings[artifactId] = binding;
        }
        final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = reservation.port;
        await reservation.close();
        final id =
            'splash-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
        final run = _SplashRun(
          id,
          binding,
          composeLaunch(configuration, binding: binding, alias: id, port: port),
          ++_generation,
          Uri.parse('http://127.0.0.1:$port'),
          _installation.observedVersion,
          library.state.artifacts.singleWhere(
            (asset) => asset.id == artifactId,
          ),
          _installation.supportsSystemone,
          null,
        );
        run.temporaryTest = temporaryTest;
        run.launchInstanceId = launchInstanceId;
        run.launchRevision = launchRevision;
        _runs[id] = run;
        await _syncUses();
        _publish();
        try {
          run.child = await io.start(
            run.command.executable,
            run.command.arguments,
          );
          run.groupLive = true;
          run.child!.stdout.listen((_) {});
          run.child!.stderr.listen((bytes) {
            if (run.stderr.length < 65536) {
              run.stderr.write(utf8.decode(bytes, allowMalformed: true));
            }
          });
          unawaited(
            run.child!.exitCode.then((code) {
              run.exit = code;
              if (run.status == RuntimeInstanceStatus.ready) {
                run.status = RuntimeInstanceStatus.failed;
                run.error = 'Splash进程意外退出：$code ${run.stderr}';
                run.cancellation.cancel();
                _publish();
                unawaited(
                  _serial(() async {
                    try {
                      await _stopRun(run);
                    } catch (cleanup) {
                      run.error = '${run.error}；收尾：$cleanup';
                    }
                    _publish();
                  }),
                );
              }
            }),
          );
          final deadline = DateTime.now().add(const Duration(seconds: 600));
          for (;;) {
            if (run.exit != null ||
                _shuttingDown ||
                (cancellation?.isCancelled ?? false) ||
                run.cancellation.isCancelled) {
              throw SplashEngineException('Splash启动终止：${run.stderr}');
            }
            try {
              await _identity(run, initial: true);
              break;
            } on SocketException {
              if (DateTime.now().isAfter(deadline)) rethrow;
            } on _SplashLoading {
              if (DateTime.now().isAfter(deadline)) {
                throw const SplashEngineException('Splash启动超时');
              }
            } on SplashRequestException catch (error) {
              if (error.kind != DecisionFailureKind.timedOut ||
                  DateTime.now().isAfter(deadline)) {
                rethrow;
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (run.exit != null ||
              run.cancellation.isCancelled ||
              _shuttingDown ||
              (cancellation?.isCancelled ?? false) ||
              epoch != _startEpoch) {
            throw const SplashEngineException('Splash启动已取消或进程退出');
          }
          run.status = RuntimeInstanceStatus.ready;
          _publish();
          return run.snapshot();
        } catch (error) {
          run.status = RuntimeInstanceStatus.failed;
          final details = run.stderr.toString();
          run.error = details.isEmpty
              ? '$error'
              : '$error\n启动日志：${details.length > 4000 ? details.substring(details.length - 4000) : details}';
          try {
            await _stopRun(run);
          } catch (cleanup) {
            run.error = '${run.error}；收尾：$cleanup';
          }
          _publish();
          throw SplashEngineException(run.error!);
        }
      } finally {
        _preparing.remove(binding);
        await _syncUses();
      }
    });
    _startupJobs.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _startupJobs.remove(operation),
        onError: (Object _, StackTrace _) => _startupJobs.remove(operation),
      ),
    );
    return operation;
  }

  Future<void> _awaitStartupJobs() async {
    await Future.wait(
      _startupJobs.toList().map(
        (job) => job.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
  }

  _SplashRun _admit(String id) {
    final run = _runs[id];
    if (_shuttingDown ||
        run == null ||
        run.status != RuntimeInstanceStatus.ready ||
        run.cancellation.isCancelled) {
      throw const SplashRequestException(
        'Splash实例尚未Ready或已停止',
        kind: DecisionFailureKind.notReady,
      );
    }
    return run;
  }

  _SplashPermit _permit(_SplashRun run, DecisionCancellation? external) {
    final permit = _SplashPermit();
    permit.remove = external?.listen(permit.cancellation.cancel);
    if (permit.cancellation.isCancelled) {
      throw const SplashRequestException(
        'Splash请求已取消',
        kind: DecisionFailureKind.cancelled,
      );
    }
    run.requests.add(permit);
    _publish();
    return permit;
  }

  void _release(_SplashRun run, _SplashPermit permit) {
    permit.remove?.call();
    run.requests.remove(permit);
    permit.done.complete();
    _publish();
  }

  Future<void> _checkedIdentity(_SplashRun run, {_SplashBudget? budget}) async {
    try {
      await _identity(run, budget: budget);
    } catch (error) {
      if (budget?.cancellation.isCancelled == true) throw budget!.terminal;
      if (error is SplashRequestException &&
          [
            DecisionFailureKind.cancelled,
            DecisionFailureKind.timedOut,
          ].contains(error.kind)) {
        rethrow;
      }
      if (run.cancellation.isCancelled &&
          run.status != RuntimeInstanceStatus.failed) {
        throw const SplashRequestException(
          'Splash请求已取消',
          kind: DecisionFailureKind.cancelled,
        );
      }
      if (error is _SplashLoading) {
        throw const SplashRequestException(
          'Splash暂时未就绪，请稍后重试',
          kind: DecisionFailureKind.notReady,
        );
      }
      if (!run.cancellation.isCancelled) {
        run.status = RuntimeInstanceStatus.failed;
        run.error = 'Splash Ready身份失效：$error';
        run.cancellation.cancel();
        _publish();
      }
      throw SplashRequestException(
        'Splash Ready身份失效：$error',
        kind: DecisionFailureKind.notReady,
      );
    }
  }

  @override
  Future<TextResult> generateText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  }) async {
    final run = _admit(instanceId);
    final permit = _permit(run, cancellation);
    final budget = _SplashBudget(timeout, permit.cancellation);
    try {
      await _checkedIdentity(run, budget: budget);
      return await _text(
        run,
        request,
        budget.remaining,
        permit.cancellation,
        budget: budget,
      );
    } catch (error) {
      throw _requestError(
        error,
        timedOut: budget.timedOut,
        cancelled:
            run.cancellation.isCancelled || permit.cancellation.isCancelled,
      );
    } finally {
      budget.close();
      _release(run, permit);
    }
  }

  @override
  Future<DecisionResult> decide(
    String instanceId,
    DecisionRequest request, {
    Duration timeout = const Duration(seconds: 60),
    DecisionCancellation? cancellation,
  }) async {
    final result = await decideBatch(
      instanceId,
      DecisionBatchRequest(
        state: request.state,
        questions: {
          'council_choice': ChoiceQuestion(
            instructions: request.instructions,
            options: request.options,
          ),
        },
      ),
      timeout: timeout,
      cancellation: cancellation,
    );
    return DecisionResult.parse(
      result.rawResponse,
      request,
      expectedModel: result.model,
      elapsed: result.elapsed,
    );
  }

  @override
  Future<DecisionBatchResult> decideBatch(
    String instanceId,
    DecisionBatchRequest request, {
    Duration timeout = const Duration(seconds: 60),
    DecisionCancellation? cancellation,
    DecisionIOTrace? ioTrace,
  }) async {
    final run = _admit(instanceId);
    if (!run.supportsSystemone) {
      throw const SplashRequestException(
        '该 Splash 版本未声明原生决策接口',
        kind: DecisionFailureKind.notReady,
      );
    }
    final permit = _permit(run, cancellation);
    final budget = _SplashBudget(timeout, permit.cancellation);
    final watch = Stopwatch()..start();
    final client = HttpClient();
    final remove = permit.cancellation.listen(() => client.close(force: true));
    final removeStop = run.cancellation.listen(() => client.close(force: true));
    String? raw;
    try {
      client.connectionTimeout = budget.remaining;
      await _checkedIdentity(run, budget: budget);
      final http = await budget.wait(
        () => client.postUrl(run.endpoint.resolve('/v1/systemone')),
      );
      http.headers.contentType = ContentType.json;
      final body = jsonEncode(request.toSystemone(model: run.id));
      final bytes = utf8.encode(body);
      http.contentLength = bytes.length;
      http.add(bytes);
      ioTrace?.sent(body);
      final response = await budget.wait(http.close);
      raw = await budget.wait(() async {
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > decisionMaxResponseBytes) {
            throw const DecisionProtocolException('typed 响应超出字节上限');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      });
      ioTrace?.received(raw!, response.statusCode);
      if (response.statusCode != 200) {
        throw SplashRequestException(
          'Splash 原生决策 HTTP ${response.statusCode}',
          kind: DecisionFailureKind.failed,
          rawResponse: raw,
        );
      }
      final result = DecisionBatchResult.parse(
        raw!,
        request,
        expectedModel: run.responseModel!,
        elapsed: watch.elapsed,
      );
      await _checkedIdentity(run, budget: budget);
      budget.remaining;
      if (run.cancellation.isCancelled || permit.cancellation.isCancelled) {
        throw const SplashRequestException(
          'Splash决策已取消',
          kind: DecisionFailureKind.cancelled,
        );
      }
      return result;
    } catch (error) {
      final failure = _requestError(
        error,
        timedOut: budget.timedOut,
        cancelled:
            run.cancellation.isCancelled || permit.cancellation.isCancelled,
      );
      throw SplashRequestException(
        failure.message,
        kind: failure.kind,
        rawResponse: failure.rawResponse ?? raw,
      );
    } finally {
      remove();
      removeStop();
      client.close(force: true);
      budget.close();
      _release(run, permit);
    }
  }

  @override
  Stream<TextStreamEvent> streamText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  }) {
    final cancelled = DecisionCancellation();
    final work = Completer<void>();
    late StreamController<TextStreamEvent> events;
    events = StreamController<TextStreamEvent>(
      onListen: () {
        final remove = cancellation?.listen(cancelled.cancel);
        unawaited(
          _streamInto(instanceId, request, timeout, cancelled, events.add).then(
            (_) {
              remove?.call();
              work.complete();
              unawaited(events.close());
            },
            onError: (Object error, StackTrace stack) {
              remove?.call();
              if (events.hasListener) events.addError(error, stack);
              work.complete();
              unawaited(events.close());
            },
          ),
        );
      },
      onCancel: () {
        cancelled.cancel();
        return work.future;
      },
    );
    return events.stream;
  }

  Future<void> _streamInto(
    String instanceId,
    TextRequest request,
    Duration timeout,
    DecisionCancellation cancellation,
    void Function(TextStreamEvent) emit,
  ) async {
    final run = _admit(instanceId);
    final permit = _permit(run, cancellation);
    final budget = _SplashBudget(timeout, permit.cancellation);
    final client = HttpClient()..connectionTimeout = timeout;
    final remove = permit.cancellation.listen(() => client.close(force: true));
    final removeStop = run.cancellation.listen(() => client.close(force: true));
    try {
      await _checkedIdentity(run, budget: budget);
      if (permit.cancellation.isCancelled) {
        throw const SplashRequestException(
          'Splash请求已取消',
          kind: DecisionFailureKind.cancelled,
        );
      }
      final http = await budget.wait(
        () => client.postUrl(run.endpoint.resolve('/v1/chat/completions')),
      );
      http.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode(request.toChat(model: run.id, stream: true)),
      );
      http.contentLength = body.length;
      http.add(body);
      final response = await budget.wait(http.close);
      if (response.statusCode != 200) {
        throw SplashEngineException('Splash文本流失败：${response.statusCode}');
      }
      final result = await budget.wait(() async {
        final decoder = TextStreamDecoder(expectedModel: run.responseModel!);
        final data = <String>[];
        await for (final line
            in response
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          budget.remaining;
          if (run.cancellation.isCancelled || permit.cancellation.isCancelled) {
            throw const SplashEngineException('Splash请求已取消');
          }
          if (line.startsWith('data:')) data.add(line.substring(5).trimLeft());
          if (line.isEmpty && data.isNotEmpty) {
            final event = decoder.add(data.join('\n'));
            data.clear();
            if (event != null) emit(event);
          }
        }
        budget.remaining;
        if (run.cancellation.isCancelled || permit.cancellation.isCancelled) {
          throw const SplashEngineException('Splash请求已取消');
        }
        return decoder.finish();
      });
      await _checkedIdentity(run, budget: budget);
      if (budget.timedOut) {
        throw const SplashRequestException(
          'Splash请求超时',
          kind: DecisionFailureKind.timedOut,
        );
      }
      if (run.cancellation.isCancelled || permit.cancellation.isCancelled) {
        throw const SplashRequestException(
          'Splash请求已取消',
          kind: DecisionFailureKind.cancelled,
        );
      }
      emit(TextStreamEvent.complete(result));
    } catch (error) {
      throw _requestError(
        error,
        timedOut: budget.timedOut,
        cancelled:
            run.cancellation.isCancelled || permit.cancellation.isCancelled,
      );
    } finally {
      budget.close();
      remove();
      removeStop();
      client.close(force: true);
      _release(run, permit);
    }
  }

  @override
  Future<void> stop(String instanceId) {
    final run = _runs[instanceId];
    if (run == null) {
      return Future.error(const SplashEngineException('Splash实例不存在'));
    }
    run.cancellation.cancel();
    return _serial(() async {
      if (run.status == RuntimeInstanceStatus.stopped) return;
      run.status = RuntimeInstanceStatus.stopping;
      _publish();
      try {
        run.status = RuntimeInstanceStatus.stopping;
        await _stopRun(run);
        run.status = RuntimeInstanceStatus.stopped;
      } catch (error) {
        run.status = RuntimeInstanceStatus.failed;
        run.error = '$error';
        rethrow;
      } finally {
        _publish();
      }
    });
  }

  @override
  void Function() holdStartAdmission() {
    if (_shuttingDown) throw const SplashEngineException('Splash正在退出');
    _admissionHolds++;
    var released = false;
    return () {
      if (!released) {
        released = true;
        _admissionHolds--;
      }
    };
  }

  void beginShutdown() {
    _shuttingDown = true;
    _startEpoch++;
    for (final run in _runs.values) {
      run.cancellation.cancel();
    }
  }

  Future<void> _drainRuns() async {
    Object? first;
    for (final run in _runs.values) {
      if (run.status == RuntimeInstanceStatus.stopped) continue;
      try {
        run.status = RuntimeInstanceStatus.stopping;
        await _stopRun(run);
        run.status = RuntimeInstanceStatus.stopped;
      } catch (error) {
        run.status = RuntimeInstanceStatus.failed;
        run.error = '$error';
        first ??= error;
      }
    }
    _publish();
    if (first != null) throw first;
  }

  @override
  Future<void> stopManaged() {
    final release = holdStartAdmission();
    _startEpoch++;
    for (final run in _runs.values) {
      run.cancellation.cancel();
    }
    return _serial(() async {
      await _awaitStartupJobs();
      await _drainRuns();
    }).whenComplete(release);
  }

  @override
  Future<void> shutdown() {
    beginShutdown();
    return _serial(() async {
      await _awaitStartupJobs();
      await _drainRuns();
    });
  }

  Future<void> detachLinked({required Future<void> Function() persistRemoval}) {
    final release = holdStartAdmission();
    return _serial(() async {
      if (hasLiveInstances ||
          _runs.values.any((run) => run.requests.isNotEmpty)) {
        throw const SplashEngineException('Splash仍有启动/运行实例，不能解除关联');
      }
      await persistRemoval();
      beginShutdown();
    }).whenComplete(release);
  }

  Future<void> refreshInstallation() => _serial(() async {
    try {
      await _assertInstallation();
    } catch (_) {
      // Presence failures have already been recorded by the installation owner.
    }
    _publish();
  });

  Future<void> readParameters() => _serial(() async {
    final epoch = _startEpoch;
    final current = await inspectInstallation(
      _installation.root,
      io: io,
      readParameters: true,
    );
    if (_shuttingDown || epoch != _startEpoch) {
      throw const SplashEngineException('Splash 参数读取已取消');
    }
    _installation = current;
    _publish();
  });

  Future<void> close() => _changes.close();

  Future<void> _verifyBinding(SplashModelBinding binding) async {
    final current = await _readBinding(binding.artifactId, binding.assembly);
    if (current.nativeModel != binding.nativeModel ||
        current.family != binding.family ||
        current.targetFormat != binding.targetFormat ||
        current.tokenizer.path != binding.tokenizer.path ||
        current.roles.length != binding.roles.length ||
        binding.roles.entries.any((e) => current.roles[e.key] != e.value)) {
      throw const SplashEngineException('Splash 绑定路径或模型选择已变化');
    }
  }

  Future<Map<String, Object?>> _json(
    _SplashRun run,
    String path, {
    _SplashBudget? budget,
  }) async {
    final clock =
        budget ??
        _SplashBudget(const Duration(seconds: 5), DecisionCancellation());
    final client = HttpClient()..connectionTimeout = clock.remaining;
    final remove = run.cancellation.listen(() => client.close(force: true));
    final removeRequest = clock.cancellation.listen(
      () => client.close(force: true),
    );
    try {
      final request = await clock.wait(
        () => client.getUrl(run.endpoint.resolve(path)),
      );
      final response = await clock.wait(request.close);
      final raw = await clock.wait(
        () => response.cast<List<int>>().transform(utf8.decoder).join(),
      );
      if (response.statusCode == 503) throw const _SplashLoading();
      if (response.statusCode != 200) {
        throw SplashEngineException(
          'Splash $path失败：${response.statusCode} $raw',
        );
      }
      return _object(jsonDecode(raw), 'Splash $path');
    } on SplashRequestException catch (error) {
      if (error.kind == DecisionFailureKind.timedOut) {
        throw SplashRequestException('Splash $path 请求超时', kind: error.kind);
      }
      rethrow;
    } finally {
      remove();
      removeRequest();
      client.close(force: true);
      if (budget == null) clock.close();
    }
  }

  Future<void> _identity(
    _SplashRun run, {
    bool initial = false,
    _SplashBudget? budget,
  }) async {
    if (initial) {
      if (budget == null) {
        await _assertInstallation();
      } else {
        await budget.wait(_assertInstallation);
      }
    }
    final ready = await _json(run, '/ready', budget: budget);
    if (ready['status'] != 'ready') throw const _SplashLoading();
    final status = await _json(run, '/status', budget: budget);
    final instance = _object(status['instance'], 'Splash instance');
    final transport = _object(status['transport'], 'Splash transport');
    if (instance['pid'] != run.child!.pid ||
        instance['model'] != run.binding.nativeModel ||
        instance['host'] != '127.0.0.1' ||
        instance['port'] != run.endpoint.port ||
        instance['id'] is! String ||
        transport['restarts'] is! int) {
      throw const SplashEngineException('Splash响应无法绑定本应用所生模型/PID');
    }
    if (!initial &&
        (instance['id'] != run.serverId ||
            transport['restarts'] != run.transportEpoch)) {
      throw const SplashEngineException('Splash运行代次已变化');
    }
    if (status['ready'] != true ||
        transport['ready'] != true ||
        transport['recovering'] != false ||
        transport['stopped'] != false) {
      throw const _SplashLoading();
    }
    final models = await _json(run, '/v1/models', budget: budget);
    final data = models['data'];
    if (data is! List || data.isEmpty) {
      throw const SplashEngineException('Splash模型发现无效');
    }
    final ids = data.map((row) => _object(row, 'Splash model')['id']).toSet();
    final responseModel = _object(data.first, 'Splash response model')['id'];
    if (!ids.contains(run.id) ||
        !ids.contains(run.binding.nativeModel) ||
        ![run.id, run.binding.nativeModel].contains(responseModel)) {
      throw const SplashEngineException('Splash实际模型身份不符');
    }
    run.serverId ??= instance['id'] as String;
    run.transportEpoch ??= transport['restarts'] as int;
    run.responseModel ??= responseModel as String;
    final context = status['maximum_context_tokens'];
    final http = status['http'];
    final requests = http is Map ? http['requests'] : null;
    final slots = requests is Map ? requests['capacity'] : null;
    run.capacity = context is int && context > 0 && slots is int && slots > 0
        ? RuntimeCapacity(contextPerSlot: context, slotCount: slots)
        : null;
  }

  Future<TextResult> _text(
    _SplashRun run,
    TextRequest request,
    Duration timeout,
    DecisionCancellation? cancellation, {
    _SplashBudget? budget,
  }) async {
    final clock =
        budget ??
        _SplashBudget(timeout, cancellation ?? DecisionCancellation());
    final client = HttpClient()..connectionTimeout = clock.remaining;
    final remove = clock.cancellation.listen(() => client.close(force: true));
    final removeStop = run.cancellation.listen(() => client.close(force: true));
    try {
      if (clock.cancellation.isCancelled || run.cancellation.isCancelled) {
        throw const SplashEngineException('Splash请求已取消');
      }
      final http = await clock.wait(
        () => client.postUrl(run.endpoint.resolve('/v1/chat/completions')),
      );
      http.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode(request.toChat(model: run.id)));
      http.contentLength = body.length;
      http.add(body);
      final response = await clock.wait(http.close);
      final raw = await clock.wait(
        () => response.cast<List<int>>().transform(utf8.decoder).join(),
      );
      if (response.statusCode != 200) {
        throw SplashEngineException('Splash文本失败：${response.statusCode} $raw');
      }
      if (run.cancellation.isCancelled || clock.cancellation.isCancelled) {
        throw const SplashEngineException('Splash请求已取消');
      }
      final result = TextResult.parse(raw, expectedModel: run.responseModel!);
      await _checkedIdentity(run, budget: clock);
      if (clock.timedOut) {
        throw const SplashRequestException(
          'Splash请求超时',
          kind: DecisionFailureKind.timedOut,
        );
      }
      if (run.cancellation.isCancelled || clock.cancellation.isCancelled) {
        throw const SplashRequestException(
          'Splash请求已取消',
          kind: DecisionFailureKind.cancelled,
        );
      }
      return result;
    } catch (error) {
      throw _requestError(
        error,
        timedOut: clock.timedOut,
        cancelled:
            clock.cancellation.isCancelled || run.cancellation.isCancelled,
      );
    } finally {
      if (budget == null) clock.close();
      remove();
      removeStop();
      client.close(force: true);
    }
  }

  Future<bool> _groupGone(int pid, Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (await io.groupAlive(pid)) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return true;
  }

  Future<void> _stopRun(_SplashRun run) async {
    run.cancellation.cancel();
    for (final permit in run.requests) {
      permit.cancellation.cancel();
    }
    await Future.wait(run.requests.map((permit) => permit.done.future));
    final child = run.child;
    Object? failure;
    if (child != null && run.groupLive) {
      // A dead Python cannot run its native close handler. Reclaim its group.
      if (run.exit != null && run.status == RuntimeInstanceStatus.failed) {
        if (await io.groupAlive(child.pid)) {
          await io.signalOwnedGroup(child.pid, ProcessSignal.sigterm);
        } else {
          run.groupLive = false;
          await _syncUses();
          return;
        }
      } else if (run.exit == null) {
        child.kill(ProcessSignal.sigterm);
      }
      try {
        await child.exitCode.timeout(const Duration(seconds: 20));
      } catch (error) {
        failure = 'Splash父进程停止失败：$error';
        if (await io.groupAlive(child.pid)) {
          await io.signalOwnedGroup(child.pid, ProcessSignal.sigterm);
        } else {
          run.groupLive = false;
          await _syncUses();
          throw SplashEngineException('$failure');
        }
      }
      if (!await _groupGone(child.pid, const Duration(seconds: 20))) {
        failure ??= 'Splash子进程组未正常退出';
        await io.signalOwnedGroup(child.pid, ProcessSignal.sigterm);
        if (!await _groupGone(child.pid, const Duration(seconds: 20))) {
          await io.signalOwnedGroup(child.pid, ProcessSignal.sigkill);
          if (!await _groupGone(child.pid, const Duration(seconds: 5))) {
            throw SplashEngineException('$failure；强制回收后组状态仍不完整');
          }
          failure = '$failure；使用了SIGKILL强制回收';
        }
      }
    }
    run.groupLive = false;
    await _syncUses();
    if (failure != null) throw SplashEngineException('$failure');
  }

  Future<void> _syncUses() => useRegistry.update(this, [
    for (final binding in _preparing) ...binding.sourceHashes.keys,
    for (final run in _runs.values)
      if (run.groupLive || run.status == RuntimeInstanceStatus.starting)
        ...run.binding.sourceHashes.keys,
  ]);

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<SplashModelBinding> bindModel(
    String artifactId,
    Directory candidate,
  ) => _serial(() async {
    if (_shuttingDown) throw const SplashEngineException('Splash正在退出');
    final binding = await _readBinding(artifactId, candidate);
    _preparing.add(binding);
    try {
      await _syncUses();
      await _assertInstallation();
      await saveBinding(binding);
      _bindings[artifactId] = binding;
      return binding;
    } finally {
      _preparing.remove(binding);
      await _syncUses();
    }
  });

  Future<SplashModelBinding> prepareModelBinding(
    String artifactId, {
    Directory? previous,
    DecisionCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const SplashEngineException('Splash 模型准备已取消');
    }
    final recorded = _bindings[artifactId];
    if (recorded != null) {
      final manifest = File('${recorded.assembly.path}/model.json');
      if (await manifest.exists() &&
          _object(
                jsonDecode(await manifest.readAsString()),
                'Splash assembly',
              )['model'] !=
              recorded.nativeModel) {
        throw const SplashEngineException('Splash 模型身份已变化');
      }
      for (final role in recorded.roles.entries.where(
        (entry) => entry.key.startsWith('target/'),
      )) {
        final target = File('${recorded.assembly.path}/${role.key}');
        if (await target.exists() &&
            await target.resolveSymbolicLinks() != role.value) {
          throw const SplashEngineException('Splash 主模型引用已变化');
        }
      }
    }
    final pending = _modelPreparations.putIfAbsent(
      artifactId,
      () => _prepareModelBinding(artifactId, previous),
    );
    try {
      final binding = await pending;
      if (cancellation?.isCancelled ?? false) {
        throw const SplashEngineException('Splash 模型准备已取消');
      }
      // Concurrent starts share metadata work, but own separate file-use leases.
      return SplashModelBinding.fromJson(binding.toJson());
    } finally {
      if (identical(_modelPreparations[artifactId], pending)) {
        _modelPreparations.remove(artifactId);
      }
    }
  }

  Future<SplashModelBinding> _prepareModelBinding(
    String artifactId,
    Directory? previous,
  ) async {
    final asset = library.state.artifacts
        .where((asset) => asset.id == artifactId)
        .singleOrNull;
    if (asset == null) throw const SplashEngineException('模型不在当前模型库中');
    await _assertInstallation();
    final directory = await prepareSplashModel(
      io: io,
      python: _installation.python,
      engine: _installation.root,
      root: modelDirectory,
      artifact: asset,
      previous: previous,
    );
    return _readBinding(artifactId, directory);
  }

  Future<SplashModelBinding> _readBinding(
    String artifactId,
    Directory candidate,
  ) async {
    final assembly = Directory(await candidate.resolveSymbolicLinks());
    final manifest = File(
      await File('${assembly.path}/model.json').resolveSymbolicLinks(),
    );
    final manifestBytes = await manifest.readAsBytes();
    final manifestText = utf8.decode(manifestBytes);
    final manifestHash = sha256.convert(manifestBytes).toString();
    final row = _object(jsonDecode(manifestText), 'Splash assembly');
    if (row['vision_format'] != 'none') {
      throw const SplashEngineException('首期Splash仅支持纯文本assembly');
    }
    final roles = <String, String>{};
    final hashes = <String, String>{};
    final sizes = <String, int>{};
    for (final entry in _object(
      row['files'],
      'Splash assembly files',
    ).entries) {
      if (entry.key.startsWith('/') || entry.key.split('/').contains('..')) {
        throw const SplashEngineException('Splash assembly role路径无效');
      }
      final metadata = _object(entry.value, 'Splash assembly source');
      final path = await File('${assembly.path}/${entry.key}')
          .resolveSymbolicLinks();
      final recordedPath = await File(_path(metadata['path']))
          .resolveSymbolicLinks();
      if (path != recordedPath) {
        throw const SplashEngineException('Splash assembly链接与记录不符');
      }
      final source = File(path);
      final size = await source.length();
      final declared = _string(metadata['digest']);
      if (!RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(declared)) {
        throw const SplashEngineException('Splash source内容身份格式无效');
      }
      roles[entry.key] = path;
      // Keep the assembly author's declaration without rereading model bytes.
      hashes[path] = declared;
      sizes[path] = size;
    }
    roles['model.json'] = manifest.path;
    hashes[manifest.path] = manifestHash;
    sizes[manifest.path] = manifestBytes.length;
    final binding = SplashModelBinding.fromJson({
      'artifact_id': artifactId,
      'assembly': assembly.path,
      'tokenizer': await Directory('${assembly.path}/tokenizer')
          .resolveSymbolicLinks(),
      'native_model': row['model'],
      'family': row['family'],
      'target_format': row['target_format'],
      'source_hashes': hashes,
      'source_sizes': sizes,
      'roles': roles,
    });
    final assets = library.state.artifacts
        .where((asset) => asset.id == artifactId)
        .toList();
    if (assets.length != 1 ||
        ![AssetKind.chat, AssetKind.decision].contains(assets.single.kind) ||
        ![
          AssetIntegrity.complete,
          AssetIntegrity.unknown,
        ].contains(assets.single.integrity)) {
      throw const SplashEngineException('请选择已完整验证的文本或决策模型资产');
    }
    final weights = assets.single.files
        .where(
          (file) =>
              file.path.endsWith('.gguf') || file.path.endsWith('.safetensors'),
        )
        .toList();
    final targets = roles.entries
        .where(
          (entry) =>
              entry.key.startsWith('target/') &&
              (entry.key.endsWith('.gguf') ||
                  entry.key.endsWith('.safetensors')),
        )
        .map((entry) => entry.value)
        .toSet();
    if (weights.isEmpty ||
        targets.length != weights.length ||
        weights.any((file) => !targets.contains(file.realPath))) {
      throw const SplashEngineException('Splash assembly target不是所选模型文件');
    }
    return binding;
  }

  Future<void> _assertInstallation() async {
    try {
      for (final file in [
        _installation.python,
        _installation.nativeBinary,
        File('${_installation.root.path}/server/server.py'),
      ]) {
        if (!await file.exists()) {
          throw SplashEngineException('Splash 文件缺失：${file.path}');
        }
      }
      _installationVerified = true;
      _error = null;
    } catch (error) {
      _installationVerified = false;
      _error = '$error';
      _publish();
      rethrow;
    }
  }

  static Future<SplashInstallation> inspectInstallation(
    Directory candidate, {
    SplashProcessIO? io,
    bool readParameters = false,
  }) async {
    final root = Directory(await candidate.resolveSymbolicLinks());
    final packaged = await File('${root.path}/release.json').exists();
    final python = File(
      '${root.path}/${packaged ? 'python/bin/python3' : '.venv/bin/python'}',
    );
    final native = File(
      '${root.path}/${packaged ? 'engine/splash' : 'build/splash'}',
    );
    for (final file in [
      python,
      native,
      File('${root.path}/server/server.py'),
      File('${root.path}/install/launcher.py'),
    ]) {
      if (!await file.exists()) {
        throw SplashEngineException('Splash文件缺失：${file.path}');
      }
    }
    final expectedPrefix = await Directory(
      '${root.path}/${packaged ? 'python' : '.venv'}',
    ).resolveSymbolicLinks();
    final supportsSystemone = (await File(
      '${root.path}/server/server.py',
    ).readAsString()).contains('"/v1/systemone": PostRoute(');
    var help = '';
    String? helpError;
    if (readParameters) {
      try {
        final result = await (io ?? NativeSplashProcessIO()).run(python.path, [
          '-B',
          '-P',
          '-c',
          'import runpy,sys; sys.path.insert(0,${jsonEncode(root.path)}); runpy.run_module("server.server",run_name="__main__")',
          '--help',
        ], timeout: const Duration(seconds: 10));
        if (result.exitCode == 0 &&
            '${result.stdout}\n${result.stderr}'.length <= 512 * 1024) {
          help = '${result.stdout}\n${result.stderr}';
        } else {
          helpError = 'Splash 帮助读取失败：${result.stderr}';
        }
      } catch (error) {
        helpError = 'Splash 帮助读取失败：$error';
      }
    }
    return SplashInstallation(
      kind: packaged
          ? SplashInstallationKind.packaged
          : SplashInstallationKind.source,
      root: root,
      python: python,
      moduleRoot: root,
      nativeBinary: native,
      observedVersion: packaged ? 'Splash' : 'Splash (source checkout)',
      pythonVersion: '未读取',
      pythonPrefix: expectedPrefix,
      help: help,
      helpError: helpError,
      verified: true,
      supportsSystemone: supportsSystemone,
      fingerprints: const {},
    );
  }
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$label对象无效');
  }
  return Map<String, Object?>.from(value);
}

String _string(Object? value, {bool empty = false}) {
  if (value is! String || (!empty && value.isEmpty)) {
    throw const FormatException('Splash字符串无效');
  }
  return value;
}

String _path(Object? value) {
  final path = _string(value);
  if (!path.startsWith('/') || path.contains('\u0000')) {
    throw const FormatException('Splash路径无效');
  }
  return path;
}

Map<String, String> _hashes(Object? value, {bool allowEmpty = false}) {
  final result = <String, String>{};
  for (final entry in _object(value, 'Splash hashes').entries) {
    final hash = _string(entry.value);
    if (!RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(hash)) {
      throw const FormatException('Splash内容指纹无效');
    }
    result[_path(entry.key)] = hash;
  }
  if (result.isEmpty && !allowEmpty) throw const FormatException('Splash身份为空');
  return result;
}

SplashRequestException _requestError(
  Object error, {
  bool timedOut = false,
  bool cancelled = false,
}) {
  if (error is SplashRequestException) return error;
  if (timedOut || error is TimeoutException) {
    return const SplashRequestException(
      'Splash请求超时',
      kind: DecisionFailureKind.timedOut,
    );
  }
  if (cancelled) {
    return const SplashRequestException(
      'Splash请求已取消',
      kind: DecisionFailureKind.cancelled,
    );
  }
  return SplashRequestException(
    '$error',
    kind:
        error is TextProtocolException ||
            error is DecisionProtocolException ||
            error is FormatException
        ? DecisionFailureKind.invalidResponse
        : DecisionFailureKind.failed,
  );
}
