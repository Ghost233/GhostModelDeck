import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'chat_protocol.dart';
import 'decision_protocol.dart';
import 'model_library.dart';
import 'model_use_registry.dart';

class LlamaRelease {
  const LlamaRelease({
    required this.tag,
    required this.commit,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    this.artifactTag,
    this.expectedBuild,
    this.supportsSystemone = true,
    this.expectedBinaryVersion,
    this.expectedPlatform = 'Darwin arm64',
    this.installationVersionTimeout = const Duration(seconds: 10),
  });

  /// Curated release label, not an observed binary semantic version.
  final String tag;
  final String? artifactTag;
  final int? expectedBuild;

  /// Expected protocol compatibility only; never evidence of readiness.
  final bool supportsSystemone;
  final String? expectedBinaryVersion;
  final String expectedPlatform;

  /// Budget only for the managed installation's native identity command.
  /// Not a model startup, capability, request, or cancellation budget.
  final Duration installationVersionTimeout;
  String get archiveRoot => 'llama-${artifactTag ?? tag}';
  int get buildNumber {
    if (expectedBuild != null) return expectedBuild!;
    final legacy = RegExp(r'^b([0-9]+)$').firstMatch(tag);
    if (legacy == null) {
      throw const LlamaEngineException('语义发行标签必须声明实际构建号');
    }
    return int.parse(legacy.group(1)!);
  }

  final String commit;
  final Uri url;

  /// Curated managed archive digest, never the linked/extracted executable hash.
  final String sha256;
  String get targetPlatform => 'Darwin arm64';
  final int sizeBytes;
}

class LinkedLlamaInstallation {
  LinkedLlamaInstallation({
    required this.path,
    required this.version,
    required Map<String, String> fingerprints,
  }) : fingerprints = Map.unmodifiable(fingerprints);
  final String path;
  final String version;
  final Map<String, String> fingerprints;
  String get sha256 => fingerprints[path]!;
}

class LlamaRemovalPlan {
  LlamaRemovalPlan._(
    this._owner,
    this.rootPath,
    this._inventory,
    this._markerSha256,
    List<String> files,
    this.sizeBytes,
  ) : files = List.unmodifiable(files);
  final Object _owner;
  final String rootPath;
  final String _inventory;
  final String _markerSha256;
  final List<String> files;
  final int sizeBytes;
}

Future<LinkedLlamaInstallation> inspectLinkedLlama(
  File executable,
  EngineProcessIO io,
) async {
  final path = await executable.resolveSymbolicLinks();
  final file = File(path);
  if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file ||
      (await file.stat()).mode & 0x49 == 0) {
    throw const LlamaEngineException('请选择可执行的本机 llama-server');
  }
  Future<Map<String, String>> fingerprint() async {
    final parent = file.parent.path;
    final files = <String>{path};
    final values = <String, String>{};
    await for (final entity in file.parent.list(followLinks: false)) {
      if (!entity.path.endsWith('.dylib') &&
          !entity.path.endsWith('.metallib')) {
        continue;
      }
      final canonical = await entity.resolveSymbolicLinks();
      if (!canonical.startsWith('$parent/') ||
          await FileSystemEntity.type(canonical, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const LlamaEngineException('关联引擎依赖超出所在目录');
      }
      files.add(canonical);
      if (entity is Link) {
        values[entity.path] = sha256
            .convert(utf8.encode('link:${await entity.target()}'))
            .toString();
      }
    }
    final paths = files.toList()..sort();
    for (final path in paths) {
      values[path] = (await sha256.bind(File(path).openRead()).first)
          .toString();
    }
    final keys = values.keys.toList()..sort();
    return {for (final key in keys) key: values[key]!};
  }

  final before = await fingerprint();
  final architecture = await io.run('/usr/bin/file', [
    '-b',
    path,
  ], timeout: const Duration(seconds: 10));
  if (architecture.exitCode != 0 ||
      !architecture.stdout.contains('Mach-O') ||
      !architecture.stdout.contains('arm64')) {
    throw const LlamaEngineException('关联引擎需要 macOS arm64 executable');
  }
  final version = await io.run(path, [
    '--version',
  ], timeout: const Duration(seconds: 10));
  final observed = '${version.stdout}\n${version.stderr}'.trim();
  if (version.exitCode != 0 ||
      !observed.contains('version:') ||
      !observed.contains('Darwin arm64')) {
    throw const LlamaEngineException('无法核验关联引擎实际版本');
  }
  final help = await io.run(path, [
    '--help',
  ], timeout: const Duration(seconds: 10));
  final flags = '${help.stdout}\n${help.stderr}';
  if (help.exitCode != 0 ||
      [
        '--model',
        '--alias',
        '--host',
        '--port',
        '--ctx-size',
        '--batch-size',
        '--ubatch-size',
        '--parallel',
        '--n-gpu-layers',
        '--device',
      ].any((flag) => !flags.contains(flag))) {
    throw const LlamaEngineException('此关联引擎缺少标准启动参数');
  }
  final after = await fingerprint();
  if (jsonEncode(before) != jsonEncode(after)) {
    throw const LlamaEngineException('关联引擎在检查时变化');
  }
  return LinkedLlamaInstallation(
    path: path,
    version: observed,
    fingerprints: after,
  );
}

final officialLlamaRelease = LlamaRelease(
  tag: 'b11381',
  artifactTag: 'b11381',
  expectedBuild: 11381,
  expectedBinaryVersion: '0.5.0-dev',
  commit: '836d57176dc699a726c55418e4f96b8ca628e1bf',
  url: Uri.parse(
    'https://github.com/ggml-org/llama.cpp/releases/download/b11381/llama-b11381-bin-macos-arm64.tar.gz',
  ),
  sha256: 'ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341',
  sizeBytes: 11925693,
);

final standardLlamaRelease = LlamaRelease(
  tag: 'v0.5.0',
  artifactTag: 'b11146',
  expectedBuild: 11146,
  expectedBinaryVersion: '0.5.0-dev',
  supportsSystemone: false,
  installationVersionTimeout: const Duration(seconds: 60),
  commit: '7fe450e19305b828c199d602c23a8337aaa1f03b',
  url: Uri.parse(
    'https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-bin-macos-arm64.tar.gz',
  ),
  sha256: '1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711',
  sizeBytes: 11189714,
);

/// Facts parsed from successful native output; never inferred from a tag.
class LlamaBinaryVersion {
  const LlamaBinaryVersion(
    this.semanticVersion,
    this.build,
    this.commit,
    this.platform,
  );
  final String semanticVersion;
  final int build;
  final String commit;
  final String platform;
  static LlamaBinaryVersion? parse(String? output) {
    if (output == null) return null;
    final match = RegExp(
      r'version: ([^\s]+) \(build ([0-9]+), commit ([0-9a-f]+)\)',
    ).firstMatch(output);
    final platform = RegExp(r'for (Darwin arm64)\b').firstMatch(output);
    if (match == null || platform == null) return null;
    return LlamaBinaryVersion(
      match.group(1)!,
      int.parse(match.group(2)!),
      match.group(3)!,
      platform.group(1)!,
    );
  }
}

class EngineCommandResult {
  const EngineCommandResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class EngineProcessIO {
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  });
  Future<EngineChild> start(String executable, List<String> arguments);
}

abstract interface class EngineChild {
  int get pid;
  Future<int> get exitCode;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  bool kill(ProcessSignal signal);
}

class NativeEngineProcessIO implements EngineProcessIO {
  Map<String, String> get _environment => {
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    for (final key in ['HOME', 'TMPDIR'])
      if (Platform.environment[key] != null) key: Platform.environment[key]!,
  };
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    final environment = Map<String, String>.unmodifiable(_environment);
    return _NativeChild(
      await Process.start(
        executable,
        arguments,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
      ),
      environment,
    );
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    final child = await start(executable, arguments);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    try {
      return EngineCommandResult(
        await child.exitCode.timeout(timeout),
        await output,
        await errors,
      );
    } on TimeoutException {
      child.kill(ProcessSignal.sigterm);
      try {
        await child.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
      await Future.wait([output, errors]);
      rethrow;
    }
  }
}

class _NativeChild implements EngineChild {
  _NativeChild(this.process, this.environment);
  final Process process;
  final Map<String, String> environment;
  @override
  int get pid => process.pid;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  bool kill(ProcessSignal signal) => process.kill(signal);
}

/// Each capability is earned by a request, never by asset metadata or health.
/// Choice does not imply score/noul support.
enum LlamaCapability {
  choiceProbability,
  scoreProbability,
  noulScalar,
  textGeneration,
}

LlamaCapability capabilityForPrimitive(DecisionPrimitive type) =>
    switch (type) {
      DecisionPrimitive.choice => LlamaCapability.choiceProbability,
      DecisionPrimitive.score => LlamaCapability.scoreProbability,
      DecisionPrimitive.noul => LlamaCapability.noulScalar,
    };

enum LlamaInstanceStatus { starting, ready, stopping, stopped, failed }

class LlamaInstance {
  const LlamaInstance({
    required this.id,
    required this.asset,
    required this.endpoint,
    required this.status,
    this.pid,
    this.installationId,
    this.engineServiceId,
    this.processEnvironment,
    this.binaryVersion,
    this.binarySha256,
    this.generation = 0,
    this.activeRequests = 0,
    this.acceptingRequests = false,
    this.hasLiveProcess = false,
    this.properties = const {},
    this.lastResult,
    this.lastTextResult,
    this.lastBatchResult,
    this.typedEvidence = const {},
    this.capabilities = const {},
    this.error,
  });
  final String id;
  final LibraryArtifact asset;
  final Uri endpoint;
  final int? pid;
  final String? installationId;

  /// Assigned only after our process starts. Not a PID or model identifier.
  final String? engineServiceId;

  /// Exact restricted native launch environment; unknown for other I/O seams.
  final Map<String, String>? processEnvironment;

  /// Validated launch snapshots; not claims about a later on-disk replacement.
  final LlamaBinaryVersion? binaryVersion;
  final String? binarySha256;
  String get modelInferenceInstanceId => id;

  /// Observed, identity-checked native alias; null before props succeeds.
  String? get nativeAlias =>
      status == LlamaInstanceStatus.ready && properties['model_alias'] == id
      ? id
      : null;
  final int generation;
  final int activeRequests;
  final bool acceptingRequests;
  final bool hasLiveProcess;
  final LlamaInstanceStatus status;
  final Map<String, dynamic> properties;
  final DecisionResult? lastResult;
  final TextResult? lastTextResult;
  final DecisionBatchResult? lastBatchResult;
  final Map<DecisionPrimitive, DecisionBatchResult> typedEvidence;
  final Set<LlamaCapability> capabilities;
  final String? error;
}

class _Running {
  _Running(this.instance, this.child, this.startupCancellation);
  LlamaInstance instance;
  final EngineChild child;
  int? exitCode;
  bool stopping = false;
  String log = '';
  final active = <_RequestPermit>{};
  final DecisionCancellation startupCancellation;
}

class _RequestPermit {
  _RequestPermit(DecisionCancellation? external) {
    removeExternal = external?.listen(cancellation.cancel);
  }
  final cancellation = DecisionCancellation();
  final drained = Completer<void>();
  void Function()? removeExternal;
}

enum LlamaInstallationStatus { absent, installing, installed, failed }

class LlamaEngineState {
  const LlamaEngineState({
    this.installation = LlamaInstallationStatus.absent,
    this.version,
    this.error,
    this.instances = const [],
  });
  final LlamaInstallationStatus installation;
  final String? version;
  final String? error;
  final List<LlamaInstance> instances;
}

class LlamaEngineException implements Exception {
  const LlamaEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum DecisionFailureKind {
  notReady,
  timedOut,
  cancelled,
  invalidResponse,
  failed,
}

class LlamaRequestException extends LlamaEngineException {
  const LlamaRequestException(
    super.message, {
    required this.kind,
    this.rawResponse,
  });
  final DecisionFailureKind kind;
  final String? rawResponse;
}

class DecisionCancellation {
  final _cancelled = Completer<void>();
  final _listeners = <Object, void Function()>{};
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    final callbacks = _listeners.values.toList();
    _listeners.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void Function() listen(void Function() callback) {
    if (isCancelled) {
      callback();
      return () {};
    }
    final key = Object();
    _listeners[key] = callback;
    return () => _listeners.remove(key);
  }
}

class _InstanceIdentityException extends LlamaEngineException {
  const _InstanceIdentityException(super.message);
}

class LlamaEngine {
  LlamaEngine({
    required this.library,
    required this.installationDirectory,
    EngineProcessIO? io,
    LlamaRelease? release,
    ModelUseRegistry? useRegistry,
    this.loadTimeout = const Duration(seconds: 120),
    this.linkedInstallation,
    String? installationId,
  }) : installationId =
           installationId ??
           (linkedInstallation == null
               ? 'official-llama-${(release ?? officialLlamaRelease).tag}'
               : null),
       release = release ?? officialLlamaRelease,
       io = io ?? NativeEngineProcessIO(),
       useRegistry = useRegistry ?? ModelUseRegistry(library);
  final ModelLibrary library;
  final Directory installationDirectory;
  final EngineProcessIO io;
  final LlamaRelease release;
  final ModelUseRegistry useRegistry;
  final Duration loadTimeout;
  final LinkedLlamaInstallation? linkedInstallation;
  final String? installationId;
  final _changes = StreamController<LlamaEngineState>.broadcast();
  LlamaEngineState _state = const LlamaEngineState();
  LlamaEngineState get state => _state;
  Stream<LlamaEngineState> get changes => _changes.stream;
  Future<void> _operations = Future.value();
  String? executablePath;
  String? observedVersion;
  String? _binarySha256;
  String? get binarySha256 => executablePath == null ? null : _binarySha256;
  LlamaBinaryVersion? get binaryVersion =>
      LlamaBinaryVersion.parse(observedVersion);
  final _running = <String, _Running>{};
  final _instances = <String, LlamaInstance>{};
  final _reserved = <String, Set<String>>{};
  bool _detached = false;
  bool _shuttingDown = false;
  final _shutdownCancellation = DecisionCancellation();
  Future<void>? _shutdown;

  int _generation = 0;
  int _nextInstanceGeneration = 0;
  final _pendingStarts = <String, DecisionCancellation>{};
  bool _recycling = false;
  Future<void>? _recycle;

  int _startAdmissionHolds = 0;

  /// Hold new starts during an owning catalog's aggregate recycle.
  /// Already accepted starts remain owned by [stopManaged].
  void Function() holdStartAdmission() {
    _startAdmissionHolds++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _startAdmissionHolds--;
    };
  }

  Future<LlamaInstance> start(String artifactId) {
    if (_recycling || _startAdmissionHolds > 0) {
      return Future.error(const LlamaEngineException('受管引擎正在回收'));
    }
    final generation = _generation;
    final instanceGeneration = ++_nextInstanceGeneration;
    final startupCancellation = DecisionCancellation();
    void checkStartup() {
      _checkStartup();
      if (startupCancellation.isCancelled) {
        throw const LlamaEngineException('已取消所选实例的引擎启动');
      }
      if (generation != _generation) {
        throw const LlamaEngineException('受管引擎回收，已取消引擎启动');
      }
    }

    return _serial(() async {
      checkStartup();
      if (_detached) throw const LlamaEngineException('该引擎关联已解除');
      if (state.installation != LlamaInstallationStatus.installed ||
          executablePath == null ||
          !(linkedInstallation != null
              ? await _checkLinked()
              : await _checkInstallation(File(executablePath!).parent))) {
        throw const LlamaEngineException('请先安装或关联并核验引擎');
      }
      checkStartup();
      final assets = library.state.artifacts
          .where((value) => value.id == artifactId)
          .toList();
      if (assets.length != 1 ||
          assets.single.format != 'GGUF' ||
          ![AssetKind.decision, AssetKind.chat].contains(assets.single.kind) ||
          assets.single.integrity != AssetIntegrity.complete ||
          !assets.single.fingerprintsVerified ||
          (assets.single.kind == AssetKind.decision &&
              !['kev', 'laya'].contains(assets.single.decisionType))) {
        throw const LlamaEngineException('请选择完整且已核验的普通文本或 Kev/Laya GGUF 模型变体');
      }
      final asset = assets.single;
      if (asset.kind == AssetKind.decision && !release.supportsSystemone) {
        throw const LlamaEngineException('此固定标准发行不支持 /v1/systemone；请选择 JEV 引擎');
      }
      final alias =
          'jev-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      _reserved[alias] = asset.files.map((value) => value.path).toSet();
      _Running? running;
      try {
        await _protect();
        final verified = (await library.verify([asset.id])).single;
        if (verified.integrity != AssetIntegrity.complete ||
            verified.kind != asset.kind ||
            verified.files.length != asset.files.length ||
            verified.files.any(
              (file) => !asset.files.any(
                (old) =>
                    old.path == file.path &&
                    old.sha256 == file.sha256 &&
                    old.sizeBytes == file.sizeBytes,
              ),
            ) ||
            asset.sourceVerified && !verified.sourceVerified) {
          throw const LlamaEngineException('模型在启动前变化，请重新核验');
        }
        checkStartup();
        final files = asset.files.toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        final path = await File(files.first.path).resolveSymbolicLinks();
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        final endpoint = Uri.parse('http://127.0.0.1:$port');
        var instance = LlamaInstance(
          id: alias,
          generation: instanceGeneration,
          installationId: installationId,
          binaryVersion: binaryVersion,
          binarySha256: binarySha256,
          asset: asset,
          endpoint: endpoint,
          status: LlamaInstanceStatus.starting,
        );
        _pendingStarts[alias] = startupCancellation;
        _instances[alias] = instance;
        _publishInstances();
        checkStartup();
        final child = await io.start(executablePath!, [
          '--model',
          path,
          '--alias',
          alias,
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
          '--ctx-size',
          '4096',
          '--batch-size',
          '4096',
          '--ubatch-size',
          '4096',
          '--parallel',
          '1',
          '--n-gpu-layers',
          '99',
          '--device',
          'MTL0',
        ]);
        instance = _copy(
          instance,
          pid: child.pid,
          engineServiceId: 'llama-service-$alias',
          processEnvironment: child is _NativeChild ? child.environment : null,
          hasLiveProcess: true,
          status: startupCancellation.isCancelled
              ? LlamaInstanceStatus.stopping
              : LlamaInstanceStatus.starting,
        );
        running = _Running(instance, child, startupCancellation);
        _running[alias] = running;
        _instances[alias] = instance;
        _publishInstances();
        child.stdout.listen((_) {});
        final owned = running;
        child.stderr.listen((bytes) {
          final next = owned.log + utf8.decode(bytes, allowMalformed: true);
          owned.log = next.length > 4096
              ? next.substring(next.length - 4096)
              : next;
        });
        child.exitCode.then((code) async {
          owned.exitCode = code;
          // An in-flight stop owns its terminal publication. A failed stop,
          // however, leaves a sealed live residual whose later exit we own.
          final residual =
              owned.stopping &&
              owned.instance.status == LlamaInstanceStatus.failed;
          if ((!owned.stopping || residual) && _isCurrent(owned)) {
            final stopError = residual ? owned.instance.error : null;
            if (!residual) _seal(owned);
            owned.instance = _copy(
              owned.instance,
              status: LlamaInstanceStatus.failed,
              hasLiveProcess: false,
              acceptingRequests: false,
              error: stopError == null
                  ? '受管引擎已退出 ($code)'
                  : '$stopError；受管引擎已退出 ($code)',
            );
            _instances[alias] = owned.instance;
            _publishInstances();
            await Future.wait(
              owned.active.map((p) => p.drained.future).toList(),
            );
            if (!_isCurrent(owned)) return;
            if (residual) {
              if (owned.instance.status != LlamaInstanceStatus.failed) return;
              _running.remove(alias);
            }
            _reserved.remove(alias);
            await _protect();
          }
        });
        checkStartup();
        final watch = Stopwatch()..start();
        var healthy = false;
        while (watch.elapsed < loadTimeout &&
            owned.exitCode == null &&
            !_shuttingDown &&
            !owned.stopping) {
          try {
            final health = jsonDecode(
              await _request(
                endpoint.resolve('/health'),
                timeout: const Duration(seconds: 1),
                cancellation: owned.startupCancellation,
              ),
            );
            if (health is Map && health['status'] == 'ok') {
              healthy = true;
              break;
            }
          } catch (_) {
            /* Cold loading may return 503 or refuse the socket. */
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        checkStartup();
        if (!healthy || owned.exitCode != null) {
          throw LlamaEngineException(
            '引擎未完成冷加载${owned.log.isEmpty ? '' : ': ${_failureReason(owned.log)}'}',
          );
        }
        final properties = await _identity(
          owned,
          const Duration(seconds: 5),
          cancellation: owned.startupCancellation,
        );
        owned.instance = _copy(owned.instance, properties: properties);
        DecisionResult? result;
        TextResult? text;
        final evidence = <DecisionPrimitive, DecisionBatchResult>{};
        final capabilities = <LlamaCapability>{};
        if (asset.kind == AssetKind.chat) {
          text = await _text(
            owned,
            TextRequest(prompt: 'Say hello.', maxTokens: 8),
            const Duration(seconds: 10),
            cancellation: owned.startupCancellation,
          );
        } else {
          result = await _decision(
            owned,
            DecisionRequest(
              state: 'A change has been requested.',
              instructions: 'Choose an action.',
              options: {
                'keep': 'Keep the current state.',
                'change': 'Apply the requested change.',
              },
            ),
            const Duration(seconds: 10),
            cancellation: owned.startupCancellation,
          );
        }
        if (text != null) capabilities.add(LlamaCapability.textGeneration);
        if (result != null) {
          capabilities.add(LlamaCapability.choiceProbability);
          // Independent real owned calls: metadata or choice never earns these.
          for (final question in <DecisionQuestion>[
            ScoreQuestion(
              instructions: 'Rate the requested change.',
              levels: ['Not applicable', 'Applicable'],
            ),
            NoulQuestion(
              instructions: 'Is a change requested?',
              falseText: 'No change requested.',
              trueText: 'A change requested.',
            ),
          ]) {
            checkStartup();
            try {
              await _identity(
                owned,
                const Duration(seconds: 5),
                cancellation: owned.startupCancellation,
              );
              final proof = await _batchDecision(
                owned,
                DecisionBatchRequest(
                  state: 'A change has been requested.',
                  questions: {'capability_probe': question},
                ),
                const Duration(seconds: 10),
                cancellation: owned.startupCancellation,
              );
              evidence[question.type] = proof;
              capabilities.add(capabilityForPrimitive(question.type));
            } on _InstanceIdentityException {
              rethrow;
            } on LlamaRequestException catch (error) {
              if (error.kind == DecisionFailureKind.cancelled) rethrow;
              // Failed probe does not imply support or revoke proven choice.
            }
          }
        }
        checkStartup();
        owned.instance = _copy(
          owned.instance,
          status: LlamaInstanceStatus.ready,
          acceptingRequests: true,
          lastResult: result,
          lastTextResult: text,
          typedEvidence: Map.unmodifiable(evidence),
          capabilities: Set.unmodifiable(capabilities),
        );
        _instances[alias] = owned.instance;
        _publishInstances();
        return owned.instance;
      } catch (error) {
        final reason = error is LlamaEngineException
            ? error.message
            : error is DecisionProtocolException
            ? error.message
            : '引擎启动失败：${error.runtimeType}';
        if (running != null) {
          await _fail(running, reason);
        } else {
          _reserved.remove(alias);
          await _protect();
          final instance = _instances[alias];
          if (instance != null) {
            _instances[alias] = _copy(
              instance,
              status: LlamaInstanceStatus.failed,
              error: reason,
            );
            _publishInstances();
          }
        }
        throw LlamaEngineException(reason);
      } finally {
        _pendingStarts.remove(alias);
      }
    });
  }

  void _checkStartup() {
    if (_shuttingDown) throw const LlamaEngineException('应用退出，已取消引擎启动');
  }

  Future<DecisionResult> decide(
    String instanceId,
    DecisionRequest request, {
    Duration timeout = const Duration(seconds: 10),
    DecisionCancellation? cancellation,
  }) async {
    if (_shuttingDown) {
      throw const LlamaRequestException(
        '引擎正在退出',
        kind: DecisionFailureKind.notReady,
      );
    }
    final running = _running[instanceId];
    if (running == null ||
        running.instance.status != LlamaInstanceStatus.ready ||
        !running.instance.capabilities.contains(
          LlamaCapability.choiceProbability,
        ) ||
        running.stopping ||
        running.exitCode != null) {
      throw const LlamaRequestException(
        '所选受管实例尚未就绪',
        kind: DecisionFailureKind.notReady,
      );
    }
    final permit = _admit(running, cancellation);
    try {
      final watch = Stopwatch()..start();
      await _identity(running, timeout, cancellation: permit.cancellation);
      final result = await _decision(
        running,
        request,
        timeout - watch.elapsed,
        cancellation: permit.cancellation,
      );
      _checkTerminal(running, permit.cancellation);
      running.instance = _copy(running.instance, lastResult: result);
      _instances[instanceId] = running.instance;
      _publishInstances();
      return result;
    } catch (error) {
      final reason = error is LlamaEngineException
          ? error.message
          : error is DecisionProtocolException
          ? error.message
          : error is TimeoutException
          ? '决策已超时'
          : '决策失败：${error.runtimeType}';
      _release(running, permit);
      if (error is _InstanceIdentityException) {
        await _fail(running, reason);
      }
      if (error is LlamaRequestException) rethrow;
      throw LlamaRequestException(
        reason,
        kind: error is TimeoutException
            ? DecisionFailureKind.timedOut
            : error is DecisionProtocolException
            ? DecisionFailureKind.invalidResponse
            : DecisionFailureKind.failed,
      );
    } finally {
      _release(running, permit);
    }
  }

  Future<DecisionBatchResult> decideBatch(
    String instanceId,
    DecisionBatchRequest request, {
    Duration timeout = const Duration(seconds: 10),
    DecisionCancellation? cancellation,
  }) async {
    final running = _running[instanceId];
    if (_shuttingDown ||
        running == null ||
        !_isCurrent(running) ||
        running.instance.status != LlamaInstanceStatus.ready ||
        running.stopping ||
        running.exitCode != null ||
        request.questions.values.any(
          (q) => !running.instance.capabilities.contains(
            capabilityForPrimitive(q.type),
          ),
        )) {
      throw const LlamaRequestException(
        '所选受管实例没有已验证的 typed 能力',
        kind: DecisionFailureKind.notReady,
      );
    }
    final permit = _admit(running, cancellation);
    try {
      final watch = Stopwatch()..start();
      await _identity(running, timeout, cancellation: permit.cancellation);
      final result = await _batchDecision(
        running,
        request,
        timeout - watch.elapsed,
        cancellation: permit.cancellation,
      );
      _checkTerminal(running, permit.cancellation);
      running.instance = _copy(running.instance, lastBatchResult: result);
      _publishRun(running);
      return result;
    } on _InstanceIdentityException catch (error) {
      _release(running, permit);
      await _fail(running, error.message);
      rethrow;
    } finally {
      _release(running, permit);
    }
  }

  void _checkTerminal(_Running running, DecisionCancellation? cancellation) {
    if (cancellation?.isCancelled == true ||
        _shutdownCancellation.isCancelled ||
        running.exitCode != null ||
        running.stopping ||
        !_isCurrent(running)) {
      throw const LlamaRequestException(
        '决策已取消或运行代次失效',
        kind: DecisionFailureKind.cancelled,
      );
    }
  }

  Future<DecisionBatchResult> _batchDecision(
    _Running running,
    DecisionBatchRequest request,
    Duration timeout, {
    DecisionCancellation? cancellation,
  }) async {
    final watch = Stopwatch()..start();
    final raw = await _request(
      running.instance.endpoint.resolve('/v1/systemone'),
      timeout: timeout,
      body: request.toSystemone(model: running.instance.id),
      cancellation: cancellation,
      maxResponseBytes: decisionMaxResponseBytes,
    );
    try {
      final result = DecisionBatchResult.parse(
        raw,
        request,
        expectedModel: running.instance.id,
        elapsed: watch.elapsed,
      );
      _checkTerminal(running, cancellation);
      return result;
    } on DecisionProtocolException catch (error) {
      throw LlamaRequestException(
        error.message,
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: raw,
      );
    }
  }

  String _failureReason(String log) {
    final lines = log
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    for (final line in lines.reversed) {
      final start = line.indexOf('LMSTUDIO_STARTUP_ERROR:');
      if (start < 0) continue;
      try {
        final value = jsonDecode(
          line.substring(start + 'LMSTUDIO_STARTUP_ERROR:'.length).trim(),
        );
        if (value is Map && value['message'] is String) {
          final message = (value['message'] as String).replaceAll(
            RegExp(r'[\x00-\x1f\x7f]'),
            ' ',
          );
          return message.length > 512
              ? '${message.substring(0, 512)}…'
              : message;
        }
      } on FormatException {
        /* Ordinary llama-server diagnostics remain available. */
      }
    }
    final errors = lines
        .where(
          (line) => RegExp(
            r'error loading model|wrong number|wrong shape|error|failed',
            caseSensitive: false,
          ).hasMatch(line),
        )
        .toList();
    final value = (errors.isNotEmpty ? errors.first : lines.last).replaceAll(
      RegExp(r'[\x00-\x1f\x7f]'),
      ' ',
    );
    return value.length > 512 ? '${value.substring(0, 512)}…' : value;
  }

  Future<Map<String, dynamic>> _identity(
    _Running running,
    Duration timeout, {
    DecisionCancellation? cancellation,
  }) async {
    if (running.exitCode != null || running.stopping || !_isCurrent(running)) {
      throw const LlamaEngineException('受管进程已停止');
    }
    final value = jsonDecode(
      await _request(
        running.instance.endpoint.resolve('/props'),
        timeout: timeout,
        cancellation: cancellation,
      ),
    );
    final paths =
        running.instance.asset.files.map((value) => value.path).toList()
          ..sort();
    if (value is! Map<String, dynamic> ||
        value['model_alias'] != running.instance.id ||
        value['model_path'] != paths.first ||
        running.exitCode != null ||
        running.stopping ||
        !_isCurrent(running)) {
      throw const _InstanceIdentityException('引擎实际 alias 或模型路径不匹配');
    }
    return Map.unmodifiable(value);
  }

  Future<DecisionResult> _decision(
    _Running running,
    DecisionRequest request,
    Duration timeout, {
    DecisionCancellation? cancellation,
  }) async {
    final watch = Stopwatch()..start();
    final raw = await _request(
      running.instance.endpoint.resolve('/v1/systemone'),
      timeout: timeout,
      body: request.toSystemone(model: running.instance.id),
      cancellation: cancellation,
      maxResponseBytes: decisionMaxResponseBytes,
    );
    final DecisionResult result;
    try {
      result = DecisionResult.parse(
        raw,
        request,
        expectedModel: running.instance.id,
        elapsed: watch.elapsed,
      );
    } on DecisionProtocolException catch (error) {
      throw LlamaRequestException(
        error.message,
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: raw,
      );
    }
    if (running.exitCode != null || running.stopping || !_isCurrent(running)) {
      throw const LlamaEngineException('决策期间受管进程停止');
    }
    return result;
  }

  Future<TextResult> generateText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  }) async {
    final running = _running[instanceId];
    if (_shuttingDown ||
        running == null ||
        running.instance.status != LlamaInstanceStatus.ready ||
        !running.instance.capabilities.contains(
          LlamaCapability.textGeneration,
        ) ||
        running.stopping ||
        running.exitCode != null) {
      throw const LlamaRequestException(
        '所选实例没有已验证的文本生成能力',
        kind: DecisionFailureKind.notReady,
      );
    }
    final permit = _admit(running, cancellation);
    try {
      final watch = Stopwatch()..start();
      await _identity(running, timeout, cancellation: permit.cancellation);
      final result = await _text(
        running,
        request,
        timeout - watch.elapsed,
        cancellation: permit.cancellation,
      );
      running.instance = _copy(running.instance, lastTextResult: result);
      _instances[instanceId] = running.instance;
      _publishInstances();
      return result;
    } on _InstanceIdentityException catch (error) {
      _release(running, permit);
      await _fail(running, error.message);
      rethrow;
    } finally {
      _release(running, permit);
    }
  }

  /// Resident-only SSE. Cancellation drains this request, never its peers.
  Stream<TextStreamEvent> streamText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  }) {
    late final StreamController<TextStreamEvent> controller;
    _RequestPermit? permit;
    Future<void> execute() async {
      final running = _running[instanceId];
      try {
        if (_shuttingDown ||
            running == null ||
            !_isCurrent(running) ||
            running.instance.status != LlamaInstanceStatus.ready ||
            !running.instance.capabilities.contains(
              LlamaCapability.textGeneration,
            ) ||
            running.stopping ||
            running.exitCode != null) {
          throw const LlamaRequestException(
            '所选实例没有已验证的文本生成能力',
            kind: DecisionFailureKind.notReady,
          );
        }
        final active = _admit(running, cancellation);
        permit = active;
        final watch = Stopwatch()..start();
        await _identity(running, timeout, cancellation: active.cancellation);
        final result = await _streamText(
          running,
          request,
          timeout - watch.elapsed,
          active.cancellation,
          (event) => controller.add(event),
        );
        // Recheck after the future race, before any terminal publication.
        if (active.cancellation.isCancelled ||
            _shutdownCancellation.isCancelled ||
            running.stopping ||
            running.exitCode != null ||
            !_isCurrent(running)) {
          throw const LlamaRequestException(
            '文本流已取消',
            kind: DecisionFailureKind.cancelled,
          );
        }
        running.instance = _copy(running.instance, lastTextResult: result);
        _publishRun(running);
        controller.add(TextStreamEvent.complete(result));
      } on _InstanceIdentityException catch (error, stack) {
        if (running != null && permit != null) {
          _release(running, permit!);
          try {
            await _fail(running, error.message);
          } catch (failure, failureStack) {
            controller.addError(failure, failureStack);
            return;
          }
        }
        controller.addError(error, stack);
      } catch (error, stack) {
        controller.addError(error, stack);
      } finally {
        if (running != null && permit != null) _release(running, permit!);
        unawaited(controller.close());
      }
    }

    controller = StreamController<TextStreamEvent>(
      onListen: () => unawaited(execute()),
      onCancel: () {
        final active = permit;
        active?.cancellation.cancel();
        return active?.drained.future ?? Future<void>.value();
      },
    );
    return controller.stream;
  }

  Future<TextResult> _streamText(
    _Running running,
    TextRequest request,
    Duration timeout,
    DecisionCancellation cancellation,
    void Function(TextStreamEvent) emit,
  ) async {
    if (timeout <= Duration.zero) {
      throw const LlamaRequestException(
        '文本流已超时',
        kind: DecisionFailureKind.timedOut,
      );
    }
    if (cancellation.isCancelled || _shutdownCancellation.isCancelled) {
      throw const LlamaRequestException(
        '文本流已取消',
        kind: DecisionFailureKind.cancelled,
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    final cancelled = Completer<TextResult>();
    final decoder = TextStreamDecoder(expectedModel: running.instance.id);
    void cancel() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(
          const LlamaRequestException(
            '文本流已取消',
            kind: DecisionFailureKind.cancelled,
          ),
        );
        client.close(force: true);
      }
    }

    final removeShutdown = _shutdownCancellation.listen(cancel);
    final removeExternal = cancellation.listen(cancel);
    try {
      final response =
          (() async {
            final upstream = await client.postUrl(
              running.instance.endpoint.resolve('/v1/chat/completions'),
            );
            upstream.headers.contentType = ContentType.json;
            upstream.write(
              jsonEncode(
                request.toChat(model: running.instance.id, stream: true),
              ),
            );
            final response = await upstream.close();
            if (response.statusCode != 200) {
              throw LlamaRequestException(
                '引擎 HTTP ${response.statusCode}',
                kind: DecisionFailureKind.failed,
              );
            }
            if (response.headers.contentType?.mimeType != 'text/event-stream') {
              throw const TextProtocolException('文本流响应不是 SSE');
            }
            var bytes = 0;
            final lines = response
                .map((chunk) {
                  bytes += chunk.length;
                  if (bytes > 4 * 1024 * 1024) {
                    throw const TextProtocolException('文本流超过 4 MiB 上限');
                  }
                  return chunk;
                })
                .transform(utf8.decoder)
                .transform(const LineSplitter());
            final data = <String>[];
            await for (final line in lines) {
              if (cancellation.isCancelled ||
                  running.stopping ||
                  running.exitCode != null ||
                  !_isCurrent(running)) {
                throw const LlamaRequestException(
                  '文本流已取消',
                  kind: DecisionFailureKind.cancelled,
                );
              }
              if (line.isEmpty) {
                if (data.isNotEmpty) {
                  final event = decoder.add(data.join('\n'));
                  data.clear();
                  if (event != null) emit(event);
                }
              } else if (line == 'data' || line.startsWith('data:')) {
                var value = line == 'data' ? '' : line.substring(5);
                if (value.startsWith(' ')) value = value.substring(1);
                data.add(value);
              }
            }
            if (data.isNotEmpty) {
              throw const TextProtocolException('文本流事件未完整结束');
            }
            if (cancellation.isCancelled ||
                running.stopping ||
                running.exitCode != null ||
                !_isCurrent(running)) {
              throw const LlamaRequestException(
                '文本流已取消',
                kind: DecisionFailureKind.cancelled,
              );
            }
            return decoder.finish();
          })().timeout(
            timeout,
            onTimeout: () => throw const LlamaRequestException(
              '文本流已超时',
              kind: DecisionFailureKind.timedOut,
            ),
          );
      return await Future.any<TextResult>([response, cancelled.future]);
    } on TextProtocolException catch (error) {
      throw LlamaRequestException(
        error.message,
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: decoder.rawResponse,
      );
    } on FormatException {
      throw LlamaRequestException(
        '文本流不是有效 UTF-8',
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: decoder.rawResponse,
      );
    } on IOException catch (error) {
      // Closing the owned socket can beat the cancellation future to the race.
      // Classify using the actual token/generation, not the network exception.
      if (cancellation.isCancelled ||
          _shutdownCancellation.isCancelled ||
          running.stopping ||
          running.exitCode != null ||
          !_isCurrent(running)) {
        throw LlamaRequestException(
          '文本流已取消',
          kind: DecisionFailureKind.cancelled,
          rawResponse: decoder.rawResponse,
        );
      }
      throw LlamaRequestException(
        '文本流连接失败：$error',
        kind: DecisionFailureKind.failed,
        rawResponse: decoder.rawResponse,
      );
    } finally {
      removeShutdown();
      removeExternal();
      client.close(force: true);
    }
  }

  Future<TextResult> _text(
    _Running running,
    TextRequest request,
    Duration timeout, {
    DecisionCancellation? cancellation,
  }) async {
    final raw = await _request(
      running.instance.endpoint.resolve('/v1/chat/completions'),
      timeout: timeout,
      body: request.toChat(model: running.instance.id),
      cancellation: cancellation,
    );
    final TextResult result;
    try {
      result = TextResult.parse(raw, expectedModel: running.instance.id);
    } on TextProtocolException catch (error) {
      throw LlamaRequestException(
        error.message,
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: raw,
      );
    }
    if (running.exitCode != null || running.stopping || !_isCurrent(running)) {
      throw const LlamaRequestException(
        '文本生成期间受管进程停止',
        kind: DecisionFailureKind.notReady,
      );
    }
    return result;
  }

  Future<String> _request(
    Uri uri, {
    required Duration timeout,
    Map<String, Object>? body,
    DecisionCancellation? cancellation,
    int? maxResponseBytes,
  }) async {
    if (timeout <= Duration.zero) {
      throw const LlamaRequestException(
        '决策已超时',
        kind: DecisionFailureKind.timedOut,
      );
    }
    if (cancellation?.isCancelled == true ||
        _shutdownCancellation.isCancelled) {
      throw const LlamaRequestException(
        '决策已取消',
        kind: DecisionFailureKind.cancelled,
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    final cancelled = Completer<String>();
    void cancel() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(
          const LlamaRequestException(
            '决策已取消',
            kind: DecisionFailureKind.cancelled,
          ),
        );
      }
    }

    final removeShutdown = _shutdownCancellation.listen(cancel);
    final removeExternal = cancellation?.listen(cancel);
    try {
      final response =
          (() async {
            final request = body == null
                ? await client.getUrl(uri)
                : await client.postUrl(uri);
            if (body != null) {
              request.headers.contentType = ContentType.json;
              request.write(jsonEncode(body));
            }
            final response = await request.close();
            final bytes = <int>[];
            await for (final chunk in response) {
              if (maxResponseBytes != null &&
                  bytes.length + chunk.length > maxResponseBytes) {
                throw const LlamaRequestException(
                  'typed 响应超出字节上限',
                  kind: DecisionFailureKind.invalidResponse,
                );
              }
              bytes.addAll(chunk);
            }
            final String raw;
            try {
              raw = utf8.decode(bytes);
            } on FormatException {
              throw const LlamaRequestException(
                '引擎响应不是有效 UTF8',
                kind: DecisionFailureKind.invalidResponse,
              );
            }
            if (response.statusCode != 200) {
              throw LlamaRequestException(
                '引擎 HTTP ${response.statusCode}: ${raw.length > 1024 ? raw.substring(0, 1024) : raw}',
                kind: DecisionFailureKind.failed,
                rawResponse: raw,
              );
            }
            return raw;
          })().timeout(
            timeout,
            onTimeout: () => throw const LlamaRequestException(
              '决策已超时',
              kind: DecisionFailureKind.timedOut,
            ),
          );
      return await Future.any<String>([response, cancelled.future]);
    } finally {
      removeShutdown();
      removeExternal?.call();
      client.close(force: true);
    }
  }

  _RequestPermit _admit(_Running running, DecisionCancellation? external) {
    final permit = _RequestPermit(external);
    running.active.add(permit);
    _publishRun(running);
    return permit;
  }

  void _release(_Running running, _RequestPermit permit) {
    if (!running.active.remove(permit)) return;
    permit.removeExternal?.call();
    permit.drained.complete();
    _publishRun(running);
  }

  bool _isCurrent(_Running running) =>
      identical(_running[running.instance.id], running) &&
      _instances[running.instance.id]?.generation ==
          running.instance.generation;

  void _publishRun(_Running running) {
    if (!_isCurrent(running)) return;
    running.instance = _copy(
      running.instance,
      activeRequests: running.active.length,
      hasLiveProcess: running.exitCode == null,
      acceptingRequests:
          !running.stopping &&
          running.exitCode == null &&
          running.instance.status == LlamaInstanceStatus.ready,
      error: running.instance.error,
    );
    _instances[running.instance.id] = running.instance;
    _publishInstances();
  }

  void _seal(_Running running) {
    running.stopping = true;
    running.startupCancellation.cancel();
    running.instance = _copy(
      running.instance,
      status: LlamaInstanceStatus.stopping,
      capabilities: const {},
    );
    for (final permit in running.active.toList()) {
      permit.cancellation.cancel();
    }
    _publishRun(running);
  }

  Future<void> _stopChild(_Running running) async {
    _seal(running);
    await Future.wait(running.active.map((p) => p.drained.future).toList());
    try {
      if (running.exitCode == null) {
        running.child.kill(ProcessSignal.sigterm);
        try {
          await running.child.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          running.child.kill(ProcessSignal.sigkill);
          await running.child.exitCode.timeout(const Duration(seconds: 5));
        }
      }
      _reserved.remove(running.instance.id);
      await _protect();
    } catch (error) {
      running.instance = _copy(
        running.instance,
        status: LlamaInstanceStatus.failed,
        error: '受管进程停止未完成：$error',
      );
      _publishRun(running);
      rethrow;
    }
  }

  Future<void> _fail(_Running running, String reason) async {
    await _stopChild(running);
    running.instance = _copy(
      running.instance,
      status: LlamaInstanceStatus.failed,
      error: reason,
    );
    _publishRun(running);
  }

  Future<void> stop(String instanceId) {
    final running = _running[instanceId];
    if (running == null) {
      final pending = _pendingStarts[instanceId];
      if (pending == null) {
        return Future.error(const LlamaEngineException('仅可停止本应用创建的引擎进程'));
      }
      pending.cancel();
      _instances[instanceId] = _copy(
        _instances[instanceId]!,
        status: LlamaInstanceStatus.stopping,
        capabilities: const {},
        acceptingRequests: false,
      );
      _publishInstances();
      return _serial(() async {
        final late = _running[instanceId];
        if (late != null) {
          await _stopChild(late);
          late.instance = _copy(
            late.instance,
            status: LlamaInstanceStatus.stopped,
          );
          _publishRun(late);
        } else {
          _instances[instanceId] = _copy(
            _instances[instanceId]!,
            status: LlamaInstanceStatus.stopped,
          );
          _publishInstances();
        }
      }, cleanup: true);
    }
    if (running.instance.status == LlamaInstanceStatus.stopped) {
      return Future.value();
    }
    _seal(running);
    return _serial(() async {
      await _stopChild(running);
      running.instance = _copy(
        running.instance,
        status: LlamaInstanceStatus.stopped,
      );
      _publishRun(running);
    }, cleanup: true);
  }

  Future<void> stopManaged() {
    if (_recycle != null) return _recycle!;
    _recycling = true;
    _generation++;
    for (final entry in _pendingStarts.entries.toList()) {
      entry.value.cancel();
      final instance = _instances[entry.key]!;
      _instances[entry.key] = _copy(
        instance,
        status: LlamaInstanceStatus.stopping,
        capabilities: const {},
        acceptingRequests: false,
      );
    }
    _publishInstances();
    for (final running in _running.values.toList()) {
      _seal(running);
    }
    final operation = _serial(() async {
      final failures = <Object>[];
      for (final running in _running.values.toList()) {
        try {
          await _stopChild(running);
          running.instance = _copy(
            running.instance,
            status: LlamaInstanceStatus.stopped,
          );
          _publishRun(running);
        } catch (error) {
          failures.add(error);
        }
      }
      if (failures.isNotEmpty) {
        throw LlamaEngineException('受管引擎回收未完成：$failures');
      }
    }, cleanup: true);
    _recycle = operation.whenComplete(() {
      _recycling = false;
      _recycle = null;
    });
    return _recycle!;
  }

  Future<void> _protect() =>
      useRegistry.update(this, _reserved.values.expand((value) => value));
  void _publishInstances() => _publish(
    LlamaEngineState(
      installation: state.installation,
      version: state.version,
      error: state.error,
      instances: List.unmodifiable(_instances.values),
    ),
  );
  LlamaInstance _copy(
    LlamaInstance value, {
    LlamaInstanceStatus? status,
    int? pid,
    String? engineServiceId,
    Map<String, String>? processEnvironment,
    int? activeRequests,
    bool? acceptingRequests,
    bool? hasLiveProcess,
    Map<String, dynamic>? properties,
    DecisionResult? lastResult,
    TextResult? lastTextResult,
    DecisionBatchResult? lastBatchResult,
    Map<DecisionPrimitive, DecisionBatchResult>? typedEvidence,
    Set<LlamaCapability>? capabilities,
    String? error,
  }) => LlamaInstance(
    id: value.id,
    generation: value.generation,
    installationId: value.installationId,
    engineServiceId: engineServiceId ?? value.engineServiceId,
    processEnvironment: processEnvironment ?? value.processEnvironment,
    binaryVersion: value.binaryVersion,
    binarySha256: value.binarySha256,
    asset: value.asset,
    endpoint: value.endpoint,
    status: status ?? value.status,
    pid: pid ?? value.pid,
    activeRequests: activeRequests ?? value.activeRequests,
    acceptingRequests: acceptingRequests ?? value.acceptingRequests,
    hasLiveProcess: hasLiveProcess ?? value.hasLiveProcess,
    properties: properties ?? value.properties,
    lastResult: lastResult ?? value.lastResult,
    lastTextResult: lastTextResult ?? value.lastTextResult,
    lastBatchResult: lastBatchResult ?? value.lastBatchResult,
    typedEvidence: typedEvidence ?? value.typedEvidence,
    capabilities: capabilities ?? value.capabilities,
    error: error,
  );
  Future<T> _serial<T>(Future<T> Function() work, {bool cleanup = false}) {
    if (_shuttingDown && !cleanup) return Future.error(StateError('引擎正在退出'));
    final result = _operations.then((_) {
      if (_shuttingDown && !cleanup) throw StateError('引擎正在退出');
      return work();
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void beginShutdown() {
    _shuttingDown = true;
    _shutdownCancellation.cancel();
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    beginShutdown();
    return _shutdown = _drainAndStop();
  }

  Future<void> _drainAndStop() async {
    await _operations;
    final errors = <Object>[];
    for (final running in _running.values.toList()) {
      if (running.exitCode != null) continue;
      try {
        await stop(running.instance.id);
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isNotEmpty || hasLiveInstances) {
      throw StateError('引擎退出未完成：${errors.join('; ')}');
    }
  }

  Future<void> install({File? verifiedArchive}) => _serial(() async {
    if (linkedInstallation != null) {
      throw const LlamaEngineException('关联引擎由外部应用管理');
    }
    _publish(
      LlamaEngineState(
        installation: LlamaInstallationStatus.installing,
        version: observedVersion,
      ),
    );
    Directory? staging;
    try {
      await installationDirectory.create(recursive: true);
      final root = await installationDirectory.resolveSymbolicLinks();
      staging = await Directory(root).createTemp('.install-');
      final archive = File('${staging.path}/release.tar.gz');
      if (verifiedArchive != null) {
        if (await verifiedArchive.length() != release.sizeBytes) {
          throw const LlamaEngineException('引擎 archive 尺寸不匹配');
        }
        await verifiedArchive.openRead().pipe(archive.openWrite());
      } else {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30);
        try {
          final response = await (await client.getUrl(release.url))
              .close()
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200) {
            throw LlamaEngineException('引擎下载 HTTP ${response.statusCode}');
          }
          final sink = archive.openWrite();
          var received = 0;
          try {
            await for (final bytes in response.timeout(
              const Duration(seconds: 30),
            )) {
              received += bytes.length;
              if (received > release.sizeBytes) {
                throw const LlamaEngineException('引擎 archive 超出发布尺寸');
              }
              sink.add(bytes);
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
        } finally {
          client.close(force: true);
        }
      }
      if (await archive.length() != release.sizeBytes) {
        throw const LlamaEngineException('引擎 archive 尺寸不匹配');
      }
      if ((await sha256.bind(archive.openRead()).first).toString() !=
          release.sha256) {
        throw const LlamaEngineException('引擎 archive 完整 SHA-256 不匹配');
      }
      final target = Directory('$root/${release.tag}');
      if (await target.exists()) {
        if (await _checkInstallation(target)) {
          _publish(
            LlamaEngineState(
              installation: LlamaInstallationStatus.installed,
              version: observedVersion,
            ),
          );
          return;
        }
        throw const LlamaEngineException('已有引擎安装校验失败，未覆盖原目录');
      }
      final listing = await io.run('/usr/bin/tar', [
        '-tzf',
        archive.path,
      ], timeout: const Duration(seconds: 30));
      final names = listing.stdout
          .split('\n')
          .where((value) => value.isNotEmpty)
          .toList();
      if (listing.exitCode != 0 ||
          names.isEmpty ||
          names.any(
            (name) =>
                !name.startsWith('${release.archiveRoot}/') ||
                name.startsWith('/') ||
                name.split('/').contains('..'),
          )) {
        throw const LlamaEngineException('引擎 archive 目录不匹配');
      }
      final unpack = Directory('${staging.path}/unpack');
      await unpack.create();
      final result = await io.run('/usr/bin/tar', [
        '-xzf',
        archive.path,
        '-C',
        unpack.path,
      ], timeout: const Duration(seconds: 30));
      if (result.exitCode != 0) throw const LlamaEngineException('引擎解包失败');
      final extracted = Directory('${unpack.path}/${release.archiveRoot}');
      final binary = File('${extracted.path}/llama-server');
      final inventory = await _inventory(extracted);
      final version = await _version(binary);
      await File('${extracted.path}/installation.json').writeAsString(
        jsonEncode({
          'tag': release.tag,
          'artifactRoot': release.archiveRoot,
          'expectedBuild': release.buildNumber,
          'commit': release.commit,
          'source': release.url.toString(),
          'archiveSha256': release.sha256,
          'platform': release.targetPlatform,
          'version': version,
          'files': inventory,
        }),
        flush: true,
      );
      await extracted.rename(target.path);
      _binarySha256 = (inventory['llama-server'] as Map)['sha256'] as String;
      executablePath = '${target.path}/llama-server';
      observedVersion = version;
      _publish(
        LlamaEngineState(
          installation: LlamaInstallationStatus.installed,
          version: version,
        ),
      );
    } catch (error) {
      final reason = error is LlamaEngineException
          ? error.message
          : '引擎安装失败：${error.runtimeType}';
      _publish(
        LlamaEngineState(
          installation: LlamaInstallationStatus.failed,
          version: observedVersion,
          error: reason,
        ),
      );
      throw LlamaEngineException(reason);
    } finally {
      if (staging != null) await staging.delete(recursive: true);
    }
  });

  Future<void> refreshInstallation() => _serial(() async {
    executablePath = null;
    observedVersion = null;
    if (_detached) {
      _publish(const LlamaEngineState());
      return;
    }
    try {
      if (linkedInstallation != null) {
        if (!await _checkLinked()) {
          throw const LlamaEngineException('关联引擎内容或版本变化，请重新关联');
        }
        _publish(
          LlamaEngineState(
            installation: LlamaInstallationStatus.installed,
            version: observedVersion,
          ),
        );
        return;
      }
      final root = await installationDirectory.resolveSymbolicLinks();
      final target = Directory('$root/${release.tag}');
      if (!await target.exists()) {
        _invalidateInstallationEvidence('受管安装已消失，请重新安装并启动模型');
        _publish(const LlamaEngineState());
        return;
      }
      if (!await _checkInstallation(target)) {
        throw const LlamaEngineException('引擎安装内容校验失败');
      }
      _publish(
        LlamaEngineState(
          installation: LlamaInstallationStatus.installed,
          version: observedVersion,
        ),
      );
    } on FileSystemException {
      _invalidateInstallationEvidence('引擎安装无法读取，请检查文件并重新启动模型');
      _publish(const LlamaEngineState());
    } catch (error) {
      _invalidateInstallationEvidence('$error');
      _publish(
        LlamaEngineState(
          installation: LlamaInstallationStatus.failed,
          error: '$error',
        ),
      );
    }
  });

  void _invalidateInstallationEvidence(String reason) {
    executablePath = null;
    observedVersion = null;
    _binarySha256 = null;
    for (final running in _running.values.toList()) {
      if (running.exitCode != null) continue;
      _seal(running);
      running.instance = _copy(
        running.instance,
        status: LlamaInstanceStatus.failed,
        properties: const {},
        capabilities: const {},
        error: '$reason；请停止旧实例后重新启动',
      );
      _publishRun(running);
    }
  }

  Future<bool> _checkInstallation(Directory target) async {
    try {
      final marker = File('${target.path}/installation.json');
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map ||
          value['tag'] != release.tag ||
          (value['artifactRoot'] != null &&
              value['artifactRoot'] != release.archiveRoot) ||
          (value['expectedBuild'] != null &&
              value['expectedBuild'] != release.buildNumber) ||
          (release.tag.startsWith('v') &&
              (value['artifactRoot'] != release.archiveRoot ||
                  value['expectedBuild'] != release.buildNumber)) ||
          value['commit'] != release.commit ||
          value['source'] != release.url.toString() ||
          value['archiveSha256'] != release.sha256 ||
          value['platform'] != release.targetPlatform ||
          value['files'] is! Map) {
        return false;
      }
      final actual = await _inventory(target);
      if (jsonEncode(actual) != jsonEncode(value['files'])) return false;
      final version = await _version(File('${target.path}/llama-server'));
      if (value['version'] is! String) return false;
      final recorded = LlamaBinaryVersion.parse(value['version'] as String);
      final observed = LlamaBinaryVersion.parse(version);
      if (recorded == null ||
          observed == null ||
          recorded.semanticVersion != observed.semanticVersion ||
          recorded.build != observed.build ||
          recorded.commit != observed.commit ||
          recorded.platform != observed.platform) {
        return false;
      }
      _binarySha256 = (actual['llama-server'] as Map)['sha256'] as String;
      executablePath = '${target.path}/llama-server';
      observedVersion = version;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkLinked() async {
    try {
      final expected = linkedInstallation!;
      final actual = await inspectLinkedLlama(File(expected.path), io);
      if (actual.version != expected.version ||
          jsonEncode(actual.fingerprints) !=
              jsonEncode(expected.fingerprints)) {
        return false;
      }
      executablePath = actual.path;
      _binarySha256 = actual.sha256;
      observedVersion = actual.version;
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get hasLiveInstances =>
      _reserved.isNotEmpty ||
      _running.values.any((running) => running.exitCode == null);
  Future<void> detachLinked() => _serial(() async {
    if (linkedInstallation == null) {
      throw const LlamaEngineException('仅可解除外部引擎关联');
    }
    if (hasLiveInstances) throw const LlamaEngineException('请先停止该引擎的模型实例');
    _detached = true;
    executablePath = null;
    observedVersion = null;
    _publish(const LlamaEngineState());
  });
  Future<LlamaRemovalPlan> prepareRemoval() => _serial(() async {
    if (linkedInstallation != null) {
      throw const LlamaEngineException('外部引擎只能解除关联');
    }
    if (hasLiveInstances) throw const LlamaEngineException('请先停止该引擎的模型实例');
    final parent = await installationDirectory.resolveSymbolicLinks();
    final target = Directory('$parent/${release.tag}');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await target.resolveSymbolicLinks() != target.path ||
        !await _checkInstallation(target)) {
      throw const LlamaEngineException('受管安装内容无法确认，未删除任何文件');
    }
    final inventory = jsonEncode(await _inventory(target));
    final markerSha256 =
        (await sha256
                .bind(File('${target.path}/installation.json').openRead())
                .first)
            .toString();
    final files = <String>[];
    var size = 0;
    await for (final entity in target.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        files.add(entity.path);
        size += await entity.length();
      } else if (entity is Link) {
        files.add(entity.path);
        size += utf8.encode(await entity.target()).length;
      } else if (entity is! Directory) {
        throw const LlamaEngineException('受管安装包含未知文件类型');
      }
    }
    files.sort();
    return LlamaRemovalPlan._(
      this,
      target.path,
      inventory,
      markerSha256,
      files,
      size,
    );
  });
  Future<void> removeInstallation(
    LlamaRemovalPlan plan, {
    required bool confirmed,
  }) => _serial(() async {
    if (!confirmed) return;
    if (!identical(plan._owner, this) || linkedInstallation != null) {
      throw const LlamaEngineException('删除计划不属于该受管引擎');
    }
    if (hasLiveInstances) throw const LlamaEngineException('请先停止该引擎的模型实例');
    final parent = await installationDirectory.resolveSymbolicLinks();
    final target = Directory('$parent/${release.tag}');
    if (plan.rootPath != target.path ||
        await target.resolveSymbolicLinks() != target.path ||
        await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        jsonEncode(await _inventory(target)) != plan._inventory ||
        (await sha256
                    .bind(File('${target.path}/installation.json').openRead())
                    .first)
                .toString() !=
            plan._markerSha256) {
      throw const LlamaEngineException('受管安装在确认期间变化，请重新检查');
    }
    final directories =
        await target
              .list(recursive: true, followLinks: false)
              .where((entity) => entity is Directory)
              .toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length));
    final files =
        plan.files
            .where((path) => path != '${target.path}/installation.json')
            .toList()
          ..add('${target.path}/installation.json');
    try {
      for (final path in files) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          await Link(path).delete();
        } else if (type == FileSystemEntityType.file) {
          await File(path).delete();
        } else {
          throw const LlamaEngineException('受管文件类型在删除期间变化');
        }
      }
      for (final directory in directories) {
        await directory.delete();
      }
      await target.delete();
      executablePath = null;
      observedVersion = null;
      _publish(const LlamaEngineState());
    } catch (error) {
      executablePath = null;
      observedVersion = null;
      _publish(
        const LlamaEngineState(
          installation: LlamaInstallationStatus.failed,
          error: '引擎删除未完成，请检查剩余安装文件',
        ),
      );
      rethrow;
    }
  });

  Future<Map<String, Object>> _inventory(Directory directory) async {
    final root = await directory.resolveSymbolicLinks();
    final entities =
        await directory.list(recursive: true, followLinks: false).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final result = <String, Object>{};
    for (final entity in entities) {
      final name = entity.path.substring(directory.path.length + 1);
      if (name == 'installation.json') continue;
      if (entity is Link) {
        final destination = await entity.resolveSymbolicLinks();
        if (!destination.startsWith('$root/')) {
          throw const LlamaEngineException('引擎链接超出安装目录');
        }
        result[name] = {'link': await entity.target()};
      } else if (entity is File) {
        result[name] = {
          'sha256': (await sha256.bind(entity.openRead()).first).toString(),
        };
      } else if (entity is! Directory) {
        throw const LlamaEngineException('引擎包含不支持的文件类型');
      }
    }
    if (!result.containsKey('llama-server')) {
      throw const LlamaEngineException('引擎缺少 llama-server');
    }
    return result;
  }

  Future<String> _version(File binary) async {
    if (release.installationVersionTimeout <= Duration.zero) {
      throw const LlamaEngineException('安装版本命令预算必须为正时长');
    }
    if (await FileSystemEntity.type(binary.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const LlamaEngineException('引擎 executable 类型不符');
    }
    final result = await io.run(binary.path, [
      '--version',
    ], timeout: release.installationVersionTimeout);
    final version = '${result.stdout}\n${result.stderr}'.trim();
    final commit = release.commit.substring(0, min(9, release.commit.length));
    final observed = LlamaBinaryVersion.parse(version);
    if (result.exitCode != 0 ||
        observed == null ||
        observed.build != release.buildNumber ||
        observed.commit != commit ||
        observed.platform != release.expectedPlatform ||
        (release.expectedBinaryVersion != null &&
            observed.semanticVersion != release.expectedBinaryVersion)) {
      throw const LlamaEngineException('引擎实际版本或架构不匹配');
    }
    return version;
  }

  void _publish(LlamaEngineState value) {
    _state = LlamaEngineState(
      installation: value.installation,
      version: value.version,
      error: value.error,
      instances: List.unmodifiable(_instances.values),
    );
    if (!_changes.isClosed) _changes.add(_state);
  }

  void close() => _changes.close();
}
