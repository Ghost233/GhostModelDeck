import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'engine_parameter_recognition.dart';
import 'engine_runtime.dart';
import 'engine_launch_configuration.dart';
import 'llama_engine.dart';
import 'model_library.dart';
import 'model_use_registry.dart';
import 'chat_protocol.dart';

class SplashEngineException implements Exception {
  const SplashEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SplashRequestException extends SplashEngineException {
  const SplashRequestException(
    super.message, {
    required this.kind,
    this.rawResponse,
  });
  final DecisionFailureKind kind;
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
    'help': help,
    'help_error': helpError,
    'fingerprints': fingerprints,
  };

  factory SplashInstallation.fromJson(Object? value) {
    final row = _object(value, 'Splash installation');
    final kind = switch (row['kind']) {
      'source' => SplashInstallationKind.source,
      'packaged' => SplashInstallationKind.packaged,
      _ => throw const FormatException('Splash installation kind无效'),
    };
    final hashes = _hashes(row['fingerprints']);
    final root = _path(row['root']);
    final python = _path(row['python']);
    final native = _path(row['native_binary']);
    if (_path(row['module_root']) != root ||
        python !=
            '$root/${kind == SplashInstallationKind.source ? '.venv/bin/python' : 'python/bin/python3'}' ||
        native !=
            '$root/${kind == SplashInstallationKind.source ? 'build/splash' : 'engine/splash'}' ||
        [
          python,
          native,
          '$root/server/server.py',
          '$root/install/launcher.py',
        ].any((path) => !hashes.containsKey(path))) {
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
        !roles.containsKey('draft/config.json') ||
        !roles.keys.any(
          (p) =>
              p.startsWith('draft/') &&
              (p.endsWith('.safetensors') || p.endsWith('.gguf')),
        ) ||
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
  );
  final String id;
  final SplashModelBinding binding;
  final EngineLaunchCommand command;
  final int generation;
  final Uri endpoint;
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
    capabilities: status == RuntimeInstanceStatus.ready
        ? {RuntimeCapability.textGeneration}
        : {},
    error: error,
  );
}

class _SplashPermit {
  final cancellation = DecisionCancellation();
  final done = Completer<void>();
  void Function()? remove;
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

class SplashEngine implements EngineRuntime {
  SplashEngine({
    required SplashInstallation installation,
    required this.library,
    required this.useRegistry,
    required this.runtimeDirectory,
    required this.configurationFor,
    required this.saveBinding,
    Iterable<SplashModelBinding> bindings = const [],
    SplashProcessIO? io,
  }) : _installation = installation,
       _installationVerified = installation.verified,
       io = io ?? NativeSplashProcessIO(),
       _bindings = {
         for (final binding in bindings) binding.artifactId: binding,
       };

  final SplashInstallation _installation;
  bool _installationVerified;
  SplashInstallation get installation => _installation;
  final ModelLibrary library;
  final ModelUseRegistry useRegistry;
  final Directory runtimeDirectory;
  final EngineLaunchConfiguration Function(String artifactId) configurationFor;
  final Future<void> Function(SplashModelBinding binding) saveBinding;
  final SplashProcessIO io;
  final Map<String, SplashModelBinding> _bindings;
  Future<void> _operations = Future.value();
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
  bool get hasLiveInstances => _runs.values.any(
    (run) => run.groupLive || run.status == RuntimeInstanceStatus.starting,
  );
  int? pidFor(String id) => _runs[id]?.child?.pid;
  Uri? endpointFor(String id) => _runs[id]?.endpoint;
  EngineLaunchCommand? actualCommandFor(String id) => _runs[id]?.command;
  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }

  SplashModelBinding? bindingFor(String artifactId) => _bindings[artifactId];
  EngineLaunchCommand composeLaunch(
    EngineLaunchConfiguration configuration, {
    SplashModelBinding? binding,
    String? alias,
    int? port,
  }) {
    if (configuration.family != EngineFamily.splash) {
      throw const SplashEngineException('Splash配置family不符');
    }
    final assembly = binding?.assembly.path ?? '<绑定的本地 assembly 目录>';
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
        '--cache-dir': '${runtimeDirectory.path}/cache',
      },
    );
  }

  Future<EngineLaunchCommand> previewLaunch(String artifactId) async {
    await _assertInstallation();
    return composeLaunch(
      configurationFor(artifactId),
      binding: _bindings[artifactId],
    );
  }

  @override
  Future<RuntimeInstance> startRuntime(String artifactId) {
    if (_shuttingDown || _admissionHolds > 0) {
      return Future.error(const SplashEngineException('Splash启动准入已关闭'));
    }
    final configuration = configurationFor(artifactId);
    final epoch = _startEpoch;
    return _serial(() async {
      if (_shuttingDown) throw const SplashEngineException('Splash正在退出');
      final binding = _bindings[artifactId];
      if (binding == null) {
        throw const SplashEngineException('请先绑定所选模型的完整Splash assembly');
      }
      _preparing.add(binding);
      try {
        await _syncUses();
        await _verifyBinding(binding);
        await _checkModel(binding);
        if (_shuttingDown || epoch != _startEpoch) {
          throw const SplashEngineException('Splash启动已取消');
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
        );
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
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          final probe = await _text(
            run,
            TextRequest(prompt: 'Reply with OK.'),
            const Duration(seconds: 30),
            null,
          );
          if (probe.text.trim().isEmpty) {
            throw const SplashEngineException('Splash没有实际文本生成');
          }
          if (run.exit != null ||
              run.cancellation.isCancelled ||
              _shuttingDown ||
              epoch != _startEpoch) {
            throw const SplashEngineException('Splash启动已取消或进程退出');
          }
          run.status = RuntimeInstanceStatus.ready;
          _publish();
          return run.snapshot();
        } catch (error) {
          run.status = RuntimeInstanceStatus.failed;
          run.error = '$error';
          try {
            await _stopRun(run);
          } catch (cleanup) {
            run.error = '$error；收尾：$cleanup';
          }
          _publish();
          throw SplashEngineException(run.error!);
        }
      } finally {
        _preparing.remove(binding);
        await _syncUses();
      }
    });
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
      http.write(jsonEncode(request.toChat(model: run.id, stream: true)));
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
    return _serial(_drainRuns).whenComplete(release);
  }

  @override
  Future<void> shutdown() {
    beginShutdown();
    return _serial(_drainRuns);
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
      _error = null;
    } catch (error) {
      _error = '$error';
      for (final run in _runs.values) {
        if (run.status == RuntimeInstanceStatus.ready) {
          run.status = RuntimeInstanceStatus.failed;
          run.error = _error;
          run.cancellation.cancel();
        }
      }
    }
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
        current.sourceHashes.length != binding.sourceHashes.length ||
        binding.roles.entries.any((e) => current.roles[e.key] != e.value) ||
        binding.sourceHashes.entries.any(
          (e) =>
              current.sourceHashes[e.key] != e.value ||
              current.sourceSizes[e.key] != binding.sourceSizes[e.key],
        )) {
      throw const SplashEngineException('Splash绑定内容或canonical链接已变化');
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
    if (budget == null) {
      await _assertInstallation();
    } else {
      await budget.wait(_assertInstallation);
    }
    final ready = await _json(run, '/ready', budget: budget);
    if (ready['status'] != 'ready') throw const _SplashLoading();
    final status = await _json(run, '/status', budget: budget);
    final instance = _object(status['instance'], 'Splash instance');
    final transport = _object(status['transport'], 'Splash transport');
    if (status['ready'] != true ||
        transport['ready'] != true ||
        transport['recovering'] != false ||
        transport['stopped'] != false) {
      throw const _SplashLoading();
    }
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
      http.write(jsonEncode(request.toChat(model: run.id)));
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
      await _checkModel(binding);
      await saveBinding(binding);
      _bindings[artifactId] = binding;
      return binding;
    } finally {
      _preparing.remove(binding);
      await _syncUses();
    }
  });

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
      final hash = (await sha256.bind(source.openRead()).first).toString();
      final declaredHash = declared.length == 64
          ? hash
          : (await sha1
                    .bind(
                      (() async* {
                        yield utf8.encode('blob $size\u0000');
                        yield* source.openRead();
                      })(),
                    )
                    .first)
                .toString();
      if (size != metadata['bytes'] || declaredHash != declared) {
        throw const SplashEngineException('Splash assembly内容与声明的内容身份不符');
      }
      roles[entry.key] = path;
      hashes[path] = hash;
      sizes[path] = size;
    }
    roles['model.json'] = manifest.path;
    hashes[manifest.path] = manifestHash;
    sizes[manifest.path] = manifestBytes.length;
    if ((await sha256.bind(manifest.openRead()).first).toString() !=
        manifestHash) {
      throw const SplashEngineException('Splash assembly在核验期间变化');
    }
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
        assets.single.kind != AssetKind.chat ||
        assets.single.integrity != AssetIntegrity.complete) {
      throw const SplashEngineException('请选择已完整验证的chat模型资产');
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
        weights.any(
          (file) =>
              !targets.contains(file.path) ||
              file.sha256 == null ||
              hashes[file.path] != file.sha256,
        )) {
      throw const SplashEngineException(
        'Splash assembly target不是所选模型的canonical文件和完整SHA',
      );
    }
    return binding;
  }

  Future<void> _assertInstallation() async {
    try {
      final current = await _installationFiles(
        _installation.root,
        _installation.python,
        _installation.nativeBinary,
      );
      if (current.length != _installation.fingerprints.length ||
          current.entries.any(
            (entry) => _installation.fingerprints[entry.key] != entry.value,
          )) {
        throw const SplashEngineException('Splash关联内容已变化，请重新核验');
      }
      _installationVerified = true;
      _error = null;
    } catch (error) {
      _installationVerified = false;
      _error = '$error';
      for (final run in _runs.values) {
        if (run.status == RuntimeInstanceStatus.ready) {
          run.status = RuntimeInstanceStatus.failed;
          run.error = _error;
          run.cancellation.cancel();
        }
      }
      _publish();
      throw SplashEngineException(_error!);
    }
  }

  Future<void> _checkModel(SplashModelBinding binding) async {
    await _assertInstallation();
    await runtimeDirectory.create(recursive: true);
    final temporary = await runtimeDirectory.createTemp('model-check-');
    try {
      var scalarPath = '-';
      if (binding.targetFormat == 'gguf') {
        final target = binding.roles.entries
            .firstWhere(
              (entry) =>
                  entry.key.startsWith('target/') &&
                  entry.key.endsWith('.gguf'),
            )
            .value;
        final code =
            'import json,sys; sys.path.insert(0,${jsonEncode(_installation.moduleRoot.path)}); '
            'from install.gguf import Metadata,scalar_metadata; '
            'print(json.dumps(scalar_metadata(Metadata(sys.argv[1],tensors=False))))';
        final metadata = await io.run(_installation.python.path, [
          '-B',
          '-P',
          '-c',
          code,
          target,
        ], timeout: const Duration(seconds: 30));
        if (metadata.exitCode != 0) {
          throw SplashEngineException(
            'Splash GGUF metadata读取失败：${metadata.stderr}',
          );
        }
        _object(jsonDecode(metadata.stdout), 'Splash GGUF scalars');
        final file = File('${temporary.path}/scalars.json');
        await file.writeAsString(metadata.stdout, flush: true);
        scalarPath = file.path;
      }
      final result = await io.run(_installation.nativeBinary.path, [
        'model-check',
        binding.targetFormat,
        'none',
        binding.roles['config.json']!,
        scalarPath,
        binding.roles['draft/config.json'] ?? '-',
      ], timeout: const Duration(seconds: 30));
      if (result.exitCode != 0) {
        throw SplashEngineException('Splash model-check失败：${result.stderr}');
      }
      final observed = _object(jsonDecode(result.stdout), 'Splash model-check');
      if (observed['family'] != binding.family) {
        throw const SplashEngineException(
          'Splash model-check family与assembly不符',
        );
      }
      await _assertInstallation();
      await _verifyBinding(binding);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  static Future<SplashInstallation> inspectInstallation(
    Directory candidate, {
    SplashProcessIO? io,
  }) async {
    final processIO = io ?? NativeSplashProcessIO();
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
    final before = await _installationFiles(root, python, native);
    final py = await processIO.run(python.path, [
      '-B',
      '--version',
    ], timeout: const Duration(seconds: 10));
    final prefix = await processIO.run(python.path, [
      '-B',
      '-P',
      '-c',
      'import json,sys; print(json.dumps({"prefix":sys.prefix,"executable":sys.executable}))',
    ], timeout: const Duration(seconds: 10));
    if (prefix.exitCode != 0) {
      throw SplashEngineException('Splash Python环境读取失败：${prefix.stderr}');
    }
    final prefixValue = _path(
      _object(jsonDecode(prefix.stdout), 'Python prefix')['prefix'],
    );
    final expectedPrefix = await Directory(
      '${root.path}/${packaged ? 'python' : '.venv'}',
    ).resolveSymbolicLinks();
    if (prefixValue != expectedPrefix) {
      throw const SplashEngineException('Splash Python没有使用所关联的venv/packaged环境');
    }
    final version = await processIO.run(
      python.path,
      _module(root.path, 'install.launcher', ['--version']),
      timeout: const Duration(seconds: 10),
    );
    if (py.exitCode != 0 || version.exitCode != 0) {
      throw SplashEngineException(
        'Splash版本读取失败：${py.stderr}\n${version.stderr}',
      );
    }
    var helpText = '';
    String? helpError;
    try {
      final help = await processIO.run(
        python.path,
        _module(root.path, 'server.server', ['--help']),
        timeout: const Duration(seconds: 10),
      );
      if (help.exitCode == 0) {
        helpText = '${help.stdout}\n${help.stderr}';
      } else {
        helpError = 'Splash帮助读取失败(${help.exitCode})：${help.stderr}';
      }
    } catch (error) {
      helpError = 'Splash帮助读取失败：$error';
    }
    final after = await _installationFiles(root, python, native);
    if (before.length != after.length ||
        before.entries.any((entry) => after[entry.key] != entry.value)) {
      throw const SplashEngineException('Splash内容在版本/帮助观察期间变化，请重新核验');
    }
    return SplashInstallation(
      kind: packaged
          ? SplashInstallationKind.packaged
          : SplashInstallationKind.source,
      root: root,
      python: python,
      moduleRoot: root,
      nativeBinary: native,
      observedVersion: '${version.stdout}\n${version.stderr}'.trim(),
      pythonVersion: '${py.stdout}\n${py.stderr}'.trim(),
      pythonPrefix: prefixValue,
      help: helpText,
      helpError: helpError,
      verified: true,
      fingerprints: after,
    );
  }
}

List<String> _module(String root, String module, List<String> arguments) => [
  '-B',
  '-P',
  '-c',
  'import runpy,sys; sys.path.insert(0,${jsonEncode(root)}); runpy.run_module(${jsonEncode(module)},run_name="__main__")',
  ...arguments,
];

Future<Map<String, String>> _installationFiles(
  Directory root,
  File python,
  File native,
) async {
  final paths = <String>{
    python.path,
    await python.resolveSymbolicLinks(),
    native.path,
    await native.resolveSymbolicLinks(),
  };
  for (final name in ['server', 'install']) {
    await for (final entry in Directory(
      '${root.path}/$name',
    ).list(recursive: true, followLinks: false)) {
      if (entry is File && entry.path.endsWith('.py')) paths.add(entry.path);
    }
  }
  for (final name in ['release.json', '.venv/pyvenv.cfg']) {
    if (await File('${root.path}/$name').exists()) {
      paths.add('${root.path}/$name');
    }
  }
  final sorted = paths.toList()..sort();
  return {
    for (final path in sorted)
      path: (await sha256.bind(File(path).openRead()).first).toString(),
  };
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

Map<String, String> _hashes(Object? value) {
  final result = <String, String>{};
  for (final entry in _object(value, 'Splash hashes').entries) {
    final hash = _string(entry.value);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Splash内容指纹无效');
    }
    result[_path(entry.key)] = hash;
  }
  if (result.isEmpty) throw const FormatException('Splash身份为空');
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
    kind: error is TextProtocolException
        ? DecisionFailureKind.invalidResponse
        : DecisionFailureKind.failed,
  );
}
