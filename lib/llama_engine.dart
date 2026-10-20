import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'engine_redownload.dart';

import 'package:crypto/crypto.dart';

import 'chat_protocol.dart';
import 'engine_install_progress.dart';
export 'engine_install_progress.dart';
import 'decision_protocol.dart';
import 'decision_runtime.dart';
import 'embedding_protocol.dart';
import 'startlux_readout.dart';
import 'startlux_runtime.dart' show StartluxRuntimeCleanupException;
import 'engine_runtime.dart';
import 'engine_launch_configuration.dart';
import 'engine_parameter_recognition.dart';
import 'jev_debug.dart';

export 'engine_runtime.dart' show DecisionCancellation, DecisionFailureKind;
import 'model_library.dart';
import 'model_use_registry.dart';
import 'runtime_monitor.dart';

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
    this.helpOutput,
  }) : fingerprints = Map.unmodifiable(fingerprints);
  final String path;
  final String version;
  final Map<String, String> fingerprints;
  final String? helpOutput;
  String? get sha256 => fingerprints[path];
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
  await for (final dependency in file.parent.list(followLinks: false)) {
    if (!dependency.path.endsWith('.dylib') &&
        !dependency.path.endsWith('.metallib')) {
      continue;
    }
    final canonical = await dependency.resolveSymbolicLinks();
    if (!canonical.startsWith('${file.parent.path}/') ||
        !await File(canonical).exists()) {
      throw const LlamaEngineException('关联引擎依赖路径越界或失效');
    }
  }

  final architecture = await io.run('/usr/bin/file', [
    '-b',
    path,
  ], timeout: const Duration(seconds: 10));
  if (architecture.exitCode != 0 ||
      !architecture.stdout.contains('Mach-O') ||
      !architecture.stdout.contains('arm64')) {
    throw const LlamaEngineException('关联引擎需要 macOS arm64 executable');
  }
  var observed = '未知版本';
  var flags = '';
  try {
    final version = await io.run(path, [
      '--version',
    ], timeout: const Duration(seconds: 10));
    if (version.exitCode == 0) {
      observed = '${version.stdout}\n${version.stderr}'.trim();
    }
    final help = await io.run(path, [
      '--help',
    ], timeout: const Duration(seconds: 10));
    if (help.exitCode == 0) flags = '${help.stdout}\n${help.stderr}';
  } catch (_) {
    // Version/help are optional metadata; the real launch reports failures.
  }
  return LinkedLlamaInstallation(
    path: path,
    version: observed,
    fingerprints: const {},
    helpOutput: flags,
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

final embeddingLlamaRelease = LlamaRelease(
  tag: 'b11457',
  artifactTag: 'b11457',
  expectedBuild: 11457,
  expectedBinaryVersion: '0.6.0-dev',
  supportsSystemone: false,
  installationVersionTimeout: const Duration(seconds: 60),
  commit: '5ad1c5da0ad7f6176256b823925aad19134f0263',
  url: Uri.parse(
    'https://github.com/ggml-org/llama.cpp/releases/download/b11457/llama-b11457-bin-macos-arm64.tar.gz',
  ),
  sha256: 'e234070cbde0c8b0d30f79fa08ff8246abe22c72acb752619349b8d9c46f7839',
  sizeBytes: 12007659,
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

/// Legacy installations earn capabilities by requests. Source installations use
/// their declared protocol support; every actual response remains validated.
enum LlamaCapability {
  choiceProbability,
  scoreProbability,
  noulScalar,
  textGeneration,
  embeddings,
}

LlamaCapability capabilityForPrimitive(DecisionPrimitive type) =>
    switch (type) {
      DecisionPrimitive.choice => LlamaCapability.choiceProbability,
      DecisionPrimitive.score => LlamaCapability.scoreProbability,
      DecisionPrimitive.noul => LlamaCapability.noulScalar,
    };

enum LlamaInstanceStatus { starting, ready, stopping, stopped, failed }

class LlamaInstance implements DecisionInstance {
  const LlamaInstance({
    required this.id,
    required this.asset,
    required this.endpoint,
    required this.status,
    this.pid,
    this.installationId,
    this.engineServiceId,
    this.processEnvironment,
    this.launchCommand,
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
    this.decisionEndpoint,
    this.decisionSourceIdentity,
    this.decisionPid,
  });
  @override
  final String id;
  @override
  final LibraryArtifact asset;
  @override
  final Uri endpoint;
  final Uri? decisionEndpoint;
  @override
  final Map<String, Object?>? decisionSourceIdentity;
  final int? decisionPid;
  @override
  int? get maxDecisionConcurrentRequests =>
      decisionSourceIdentity?['kind'] == 'startlux_author_readout'
      ? 1
      : RuntimeCapacity.fromLlamaProperties(properties)?.slotCount;
  @override
  final int? pid;
  final String? installationId;

  /// Assigned only after our process starts. Not a PID or model identifier.
  final String? engineServiceId;

  /// Exact restricted native launch environment; unknown for other I/O seams.
  final Map<String, String>? processEnvironment;

  /// Immutable command passed to this instance's successfully created process.
  @override
  final EngineLaunchCommand? launchCommand;

  /// Validated launch snapshots; not claims about a later on-disk replacement.
  final LlamaBinaryVersion? binaryVersion;
  @override
  final String? binarySha256;
  String get modelInferenceInstanceId => id;

  /// Observed, identity-checked native alias; null before props succeeds.
  @override
  String? get nativeAlias =>
      status == LlamaInstanceStatus.ready && properties['model_alias'] == id
      ? id
      : null;
  @override
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
  @override
  bool get decisionReady =>
      status == LlamaInstanceStatus.ready &&
      acceptingRequests &&
      hasLiveProcess;
  @override
  RuntimeCapacity? get capacity =>
      RuntimeCapacity.fromLlamaProperties(properties);
  @override
  Set<RuntimeCapability> get decisionCapabilities => {
    if (capabilities.contains(LlamaCapability.choiceProbability))
      RuntimeCapability.choiceProbability,
    if (capabilities.contains(LlamaCapability.scoreProbability))
      RuntimeCapability.scoreProbability,
    if (capabilities.contains(LlamaCapability.noulScalar))
      RuntimeCapability.noulScalar,
  };
  final String? error;
}

Future<List<String>> _llamaApiKeys(List<String> arguments) async {
  final keys = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    final separator = argument.indexOf('=');
    final name = (separator < 0 ? argument : argument.substring(0, separator))
        .replaceAll('_', '-');
    if (name != '--api-key' && name != '--api-key-file') continue;
    final String value;
    if (separator >= 0) {
      value = argument.substring(separator + 1);
    } else if (index + 1 < arguments.length) {
      value = arguments[++index];
    } else {
      continue; // Native argument validation reports the missing value.
    }
    if (name == '--api-key-file') {
      keys.addAll(
        (await File(value).readAsString())
            .split('\n')
            .where((line) => line.isNotEmpty && !line.startsWith('#')),
      );
      continue;
    }
    // Match llama.cpp's CSV contract, including quoted commas and doubled quotes.
    var field = '';
    var quoted = false;
    for (var offset = 0; offset < value.length; offset++) {
      final character = value[offset];
      if (character == '"') {
        if (!quoted) {
          if (field.isEmpty) {
            quoted = true;
          } else {
            field += character;
          }
        } else if (offset + 1 < value.length && value[offset + 1] == '"') {
          field += '"';
          offset++;
        } else {
          quoted = false;
        }
      } else if (character == ',' && !quoted) {
        if (field.isNotEmpty) keys.add(field);
        field = '';
      } else {
        field += character;
      }
    }
    if (field.isNotEmpty) keys.add(field);
  }
  return keys;
}

String _safeLlama(String value, List<String> apiKeys) =>
    sealDebugJson({
          'credentials': [
            for (final key in apiKeys) {'api_key': key},
          ],
          'message': value,
        })['message']
        as String;

class _Running {
  _Running(
    this.instance,
    this.child,
    this.startupCancellation,
    List<String> apiKeys,
  ) : apiKeys = List.unmodifiable(apiKeys);
  final List<String> apiKeys;
  Map<String, String> get headers => {
    if (apiKeys.isNotEmpty)
      HttpHeaders.authorizationHeader: 'Bearer ${apiKeys.first}',
  };
  String safe(String value) => _safeLlama(value, apiKeys);
  LlamaInstance instance;
  DrafterCheck? actualDrafter;
  final EngineChild child;
  int? exitCode;
  StartluxReadout? readout;
  int? readoutExitCode;
  bool get hasLiveOwnedProcess =>
      exitCode == null || readout?.hasLiveProcess == true;
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

class LlamaRequestException extends LlamaEngineException
    implements DecisionCallFailure {
  const LlamaRequestException(
    super.message, {
    required this.kind,
    this.rawResponse,
  });
  @override
  final DecisionFailureKind kind;
  @override
  final String? rawResponse;
}

class _InstanceIdentityException extends LlamaEngineException {
  const _InstanceIdentityException(super.message);
}

typedef StartluxReadoutStarter = Future<StartluxReadout?> Function(
  LibraryArtifact asset,
  Uri nativeEndpoint,
  String alias,
  int generation,
  DecisionCancellation cancellation,
);

class LlamaEngine
    implements EmbeddingRuntime, DecisionRuntime, RuntimeMonitorSource {
  LlamaEngine({
    required this.library,
    required this.installationDirectory,
    EngineProcessIO? io,
    LlamaRelease? release,
    ModelUseRegistry? useRegistry,
    this.loadTimeout = const Duration(seconds: 120),
    this.linkedInstallation,
    this.startStartluxReadout,
    Map<String, Object?>? sourceBuild,
    String? installationId,
  }) : sourceBuild = sourceBuild == null ? null : Map.unmodifiable(sourceBuild),
       installationId =
           installationId ??
           (linkedInstallation == null
               ? 'official-llama-${(release ?? officialLlamaRelease).tag}'
               : null),
       release = release ?? officialLlamaRelease,
       io = io ?? NativeEngineProcessIO(),
       useRegistry = useRegistry ?? ModelUseRegistry(library),
       _parameterRecognition = linkedInstallation?.helpOutput == null
           ? EngineParameterRecognition.builtIn()
           : EngineParameterRecognition.fromHelp(
               linkedInstallation!.helpOutput!,
               version: linkedInstallation.version,
               executablePath: linkedInstallation.path,
               contentFingerprint: linkedInstallation.sha256,
             );
  final ModelLibrary library;
  final Directory installationDirectory;
  final EngineProcessIO io;
  final LlamaRelease release;
  EngineParameterRecognition _parameterRecognition;
  EngineParameterRecognition get parameterRecognition => _parameterRecognition;
  EngineLaunchConfiguration Function(String artifactId)?
  _readLaunchConfiguration;
  void readLaunchConfigurationFrom(
    EngineLaunchConfiguration Function(String artifactId) readConfiguration,
  ) => _readLaunchConfiguration = readConfiguration;
  final ModelUseRegistry useRegistry;
  final Duration loadTimeout;
  LinkedLlamaInstallation? linkedInstallation;
  final String? installationId;
  final StartluxReadoutStarter? startStartluxReadout;
  final Map<String, Object?>? sourceBuild;

  /// Capability declaration of the selected repository/ref, not a model allowlist.
  /// Earlier source registrations predate the explicit toggle and declare JEV.
  bool get declaresSystemone =>
      sourceBuild != null &&
      (sourceBuild!['supports_systemone'] ?? true) == true;
  @override
  bool get supportsSystemone =>
      sourceBuild == null ? release.supportsSystemone : declaresSystemone;
  final _changes = StreamController<LlamaEngineState>.broadcast();
  LlamaEngineState _state = const LlamaEngineState();
  LlamaEngineState get state => _state;
  Stream<LlamaEngineState> get changes => _changes.stream;
  EngineInstallProgress? installationProgress;
  DecisionCancellation? _installCancellation;
  HttpClient? _installClient;
  void cancelInstallation() {
    _installCancellation?.cancel();
    _installClient?.close(force: true);
  }

  void _installProgress(
    EngineInstallPhase phase,
    int received, {
    double bytesPerSecond = 0,
    String? error,
  }) {
    installationProgress = EngineInstallProgress(
      phase,
      received: received,
      total: release.sizeBytes,
      bytesPerSecond: bytesPerSecond,
      error: error,
    );
    if (!_changes.isClosed) _changes.add(_state);
  }

  @override
  List<RuntimeInstance> get runtimeInstances =>
      List.unmodifiable(state.instances.map(_runtimeInstance));
  @override
  List<DecisionInstance> get decisionInstances =>
      state.instances.where((run) => !isTemporaryTest(run.id)).toList();

  @override
  Future<RuntimeTelemetry> readTelemetry(
    String instanceId, {
    required DecisionCancellation cancellation,
  }) async {
    final run = _running[instanceId];
    if (run == null ||
        run.exitCode != null ||
        run.stopping ||
        !_isCurrent(run)) {
      throw StateError('实例已停止');
    }
    Future<String?> read(String path) async {
      try {
        return await readMonitorHttp(
          run.instance.endpoint.resolve(path),
          cancellation: cancellation,
          headers: run.headers,
        );
      } on HttpException {
        return null;
      }
    }

    await _identity(
      run,
      const Duration(seconds: 2),
      cancellation: cancellation,
    );
    final values = await Future.wait([read('/slots'), read('/metrics')]);
    if (cancellation.isCancelled ||
        run.exitCode != null ||
        run.stopping ||
        !_isCurrent(run)) {
      throw StateError('实例已变化');
    }
    return RuntimeTelemetry.llama(
      slots: values[0] == null ? null : jsonDecode(values[0]!),
      metrics: values[1],
      capacity: RuntimeCapacity.fromLlamaProperties(run.instance.properties)
          ?.slotCount,
    );
  }

  RuntimeInstance _runtimeInstance(LlamaInstance instance) => RuntimeInstance(
    id: instance.id,
    artifactId: instance.asset.id,
    status: switch (instance.status) {
      LlamaInstanceStatus.starting => RuntimeInstanceStatus.starting,
      LlamaInstanceStatus.ready => RuntimeInstanceStatus.ready,
      LlamaInstanceStatus.stopping => RuntimeInstanceStatus.stopping,
      LlamaInstanceStatus.stopped => RuntimeInstanceStatus.stopped,
      LlamaInstanceStatus.failed => RuntimeInstanceStatus.failed,
    },
    generation: instance.generation,
    activeRequests: instance.activeRequests,
    acceptingRequests: instance.acceptingRequests,
    hasLiveProcess: instance.hasLiveProcess,
    temporaryTest: _temporaryTestIds.contains(instance.id),
    launchInstanceId: _launchIdentities[instance.id]?.$1,
    launchRevision: _launchIdentities[instance.id]?.$2,
    inferenceConcurrency: RuntimeCapacity.fromLlamaProperties(
      instance.properties,
    )?.slotCount,
    capabilities: {
      for (final capability in instance.capabilities)
        switch (capability) {
          LlamaCapability.choiceProbability =>
            RuntimeCapability.choiceProbability,
          LlamaCapability.scoreProbability =>
            RuntimeCapability.scoreProbability,
          LlamaCapability.noulScalar => RuntimeCapability.noulScalar,
          LlamaCapability.textGeneration => RuntimeCapability.textGeneration,
          LlamaCapability.embeddings => RuntimeCapability.embeddings,
        },
    },
    error: instance.error,
    capacity:
        instance.status == LlamaInstanceStatus.ready &&
            instance.acceptingRequests &&
            instance.hasLiveProcess
        ? RuntimeCapacity.fromLlamaProperties(instance.properties)
        : null,
  );

  @override
  Future<RuntimeInstance> startRuntime(String artifactId) async =>
      _runtimeInstance(await start(artifactId));

  Future<void> _operations = Future.value();
  String? executablePath;
  String? observedVersion;
  String? _binarySha256;
  String? get binarySha256 => executablePath == null ? null : _binarySha256;
  LlamaBinaryVersion? get binaryVersion =>
      LlamaBinaryVersion.parse(observedVersion);
  final _launchIdentities = <String, (String, int)>{};
  final _temporaryTestIds = <String>{};
  bool isTemporaryTest(String instanceId) =>
      _temporaryTestIds.contains(instanceId);
  final _running = <String, _Running>{};
  final _instances = <String, LlamaInstance>{};
  final _reserved = <String, Set<String>>{};
  final _drafterChecks = <String, DrafterCheck>{};
  String _drafterKey(
    String artifactId,
    EngineLaunchConfiguration configuration,
  ) => jsonEncode([artifactId, configuration.loadingIdentity]);
  DrafterCheck? drafterCheckFor(
    String artifactId,
    EngineLaunchConfiguration configuration,
  ) => _drafterChecks[_drafterKey(artifactId, configuration)];

  DrafterCheck? actualDrafterFor(String launchId) => _running.entries
      .where(
        (entry) =>
            _launchIdentities[entry.key]?.$1 == launchId &&
            entry.value.instance.status == LlamaInstanceStatus.ready &&
            entry.value.exitCode == null,
      )
      .map((entry) => entry.value.actualDrafter)
      .singleOrNull;

  Future<List<String>> checkDrafterFiles(
    String artifactId,
    EngineLaunchConfiguration configuration,
  ) async {
    final key = _drafterKey(artifactId, configuration);
    _drafterChecks[key] = const DrafterCheck();
    _publishInstances();
    try {
      if (configuration.legacyLlamaDrafter != null) {
        throw const FormatException('旧草稿参数待修复：请在实例中明确选择草稿模式与来源，或关闭草稿模型');
      }
      final artifact = library.state.artifacts
          .where((a) => a.id == artifactId)
          .singleOrNull;
      if (artifact == null) throw const FormatException('目标模型不在当前模型库中');
      final paths = await checkLlamaDrafterFiles(configuration.drafter);
      _drafterChecks[key] = DrafterCheck(
        stage: configuration.drafter?.enabled == true
            ? DrafterStage.filesReady
            : DrafterStage.disabled,
        source:
            paths.firstOrNull ??
            (configuration.drafter?.enabled == true
                ? artifact.files.firstOrNull?.path
                : null),
        type: configuration.drafter?.enabled != true
            ? null
            : '${DrafterConfiguration.modes[configuration.drafter?.mode]} · '
                  '${configuration.drafter!.usesEmbeddedTarget ? '目标模型内嵌' : '独立 GGUF'}',
      );
      return paths;
    } catch (error) {
      _drafterChecks[key] = DrafterCheck(
        source: configuration.drafter?.path,
        error: error.toString(),
      );
      rethrow;
    } finally {
      _publishInstances();
    }
  }

  bool _detached = false;
  bool _shuttingDown = false;
  final _shutdownCancellation = DecisionCancellation();
  Future<void>? _shutdown;

  int _generation = 0;
  int _nextInstanceGeneration = 0;
  final _pendingStarts = <String, DecisionCancellation>{};
  final _startupJobs = <Future<LlamaInstance>>{};
  final _startupByAlias = <String, Future<LlamaInstance>>{};
  bool _recycling = false;
  bool _redownloading = false;
  Future<void>? _recycle;

  int _startAdmissionHolds = 0;

  /// Hold new starts during an owning catalog's aggregate recycle.
  /// Already accepted starts remain owned by [stopManaged].
  @override
  void Function() holdStartAdmission() {
    _startAdmissionHolds++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _startAdmissionHolds--;
    };
  }

  Future<EngineLaunchCommand> previewLaunch(
    String artifactId, {
    EngineLaunchConfiguration? configuration,
  }) async {
    final executable = executablePath;
    if (executable == null) {
      throw const LlamaEngineException('请先安装或关联并核验引擎');
    }
    final assets = library.state.artifacts
        .where((asset) => asset.id == artifactId)
        .toList();
    if (assets.length != 1 || assets.single.files.isEmpty) {
      throw const LlamaEngineException('请选择完整模型变体');
    }
    final files = assets.single.files.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final selectedConfiguration =
        configuration ??
        _readLaunchConfiguration?.call(artifactId) ??
        EngineLaunchConfiguration();
    return selectedConfiguration.command(
      executable: executable,
      // The library snapshot already stores canonical real-file paths. Preview
      // reads that snapshot; start still verifies the current file before use.
      modelPath: files.first.path,
      recognition: _parameterRecognition,
      executableArguments: assets.single.kind == AssetKind.embedding
          ? const ['--embedding']
          : const [],
    );
  }

  Future<LlamaInstance> start(
    String artifactId, {
    EngineLaunchConfiguration? configuration,
    DecisionCancellation? cancellation,
    bool temporaryTest = false,
    String? launchInstanceId,
    int? launchRevision,
  }) {
    if (_shuttingDown) return Future.error(StateError('引擎正在退出'));
    if (_recycling || _redownloading || _startAdmissionHolds > 0) {
      return Future.error(const LlamaEngineException('受管引擎正在回收'));
    }
    final generation = _generation;
    final instanceGeneration = ++_nextInstanceGeneration;
    final startupCancellation = cancellation ?? DecisionCancellation();
    void checkStartup() {
      _checkStartup();
      if (startupCancellation.isCancelled) {
        throw const LlamaEngineException('已取消所选实例的引擎启动');
      }
      if (generation != _generation) {
        throw const LlamaEngineException('受管引擎回收，已取消引擎启动');
      }
    }

    late final Future<LlamaInstance> operation;
    operation = _operations.then((_) async {
      // Freeze at operation admission, before any installation/model I/O.
      final selectedConfiguration =
          configuration ??
          _readLaunchConfiguration?.call(artifactId) ??
          EngineLaunchConfiguration();
      checkStartup();
      if (_detached) throw const LlamaEngineException('该引擎关联已解除');
      final recognition = _parameterRecognition;
      if (selectedConfiguration.family != EngineFamily.llamaCpp) {
        throw const LlamaEngineException('启动配置与引擎家族不一致');
      }
      selectedConfiguration.validateArgumentText();
      if (state.installation != LlamaInstallationStatus.installed ||
          executablePath == null) {
        throw const LlamaEngineException('请先安装或关联引擎');
      }
      checkStartup();
      final assets = library.state.artifacts
          .where((value) => value.id == artifactId)
          .toList();
      if (assets.length != 1 ||
          assets.single.format != 'GGUF' ||
          ![
            AssetIntegrity.complete,
            AssetIntegrity.unknown,
          ].contains(assets.single.integrity)) {
        throw const LlamaEngineException('请选择 GGUF 模型变体');
      }
      final asset = assets.single;
      final alias =
          'jev-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      if (temporaryTest) _temporaryTestIds.add(alias);
      if (launchInstanceId != null) {
        _launchIdentities[alias] = (launchInstanceId, launchRevision ?? 1);
      }
      _reserved[alias] = {
        ...asset.files.map((value) => value.path),
        if (selectedConfiguration.drafter?.enabled == true &&
            selectedConfiguration.drafter?.path != null)
          selectedConfiguration.drafter!.path!,
      };
      _Running? running;
      var apiKeys = const <String>[];
      var unexpectedStartupExit = false;
      try {
        await _protect();
        checkStartup();
        final draftFiles = await checkDrafterFiles(
          artifactId,
          selectedConfiguration,
        );
        _reserved[alias]!.addAll(draftFiles);
        await _protect();
        checkStartup();
        final files = asset.files.toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        final path = await File(files.first.path).resolveSymbolicLinks();
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        final endpoint = Uri.parse('http://127.0.0.1:$port');
        final command = selectedConfiguration.command(
          executable: executablePath!,
          modelPath: path,
          alias: alias,
          port: port,
          recognition: recognition,
          managedArguments: {
            if (draftFiles.isNotEmpty) '--spec-draft-model': draftFiles.first,
          },
          executableArguments: asset.kind == AssetKind.embedding
              ? const ['--embedding']
              : const [],
        );
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
        _startupByAlias[alias] = operation;
        _instances[alias] = instance;
        _publishInstances();
        checkStartup();
        apiKeys = await _llamaApiKeys(command.arguments);
        checkStartup();
        final child = await io.start(command.executable, command.arguments);
        instance = _copy(
          instance,
          pid: child.pid,
          engineServiceId: 'llama-service-$alias',
          processEnvironment: child is _NativeChild ? child.environment : null,
          launchCommand: command,
          hasLiveProcess: true,
          status: startupCancellation.isCancelled
              ? LlamaInstanceStatus.stopping
              : LlamaInstanceStatus.starting,
        );
        running = _Running(instance, child, startupCancellation, apiKeys);
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
          // A native argument rejection seals admission too. Remember whether
          // it preceded a user stop so its stderr is not reported as cancellation.
          unexpectedStartupExit =
              !owned.stopping && !owned.startupCancellation.isCancelled;
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
              hasLiveProcess:
                  owned.readout != null && owned.readoutExitCode == null,
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
            try {
              await owned.readout?.stop();
            } catch (error) {
              owned.instance = _copy(
                owned.instance,
                error: '${owned.instance.error}；概率读出停止未完成：$error',
              );
              _publishRun(owned);
              return;
            }
            _publishRun(owned);
            // Startup may still be awaiting an external readout owner. Its
            // unified failure path must drain that owner before releasing files.
            if (_pendingStarts.containsKey(alias)) return;
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
            !startupCancellation.isCancelled &&
            owned.exitCode == null &&
            !_shuttingDown &&
            !owned.stopping) {
          try {
            final health = jsonDecode(
              await _request(
                owned,
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
        if (selectedConfiguration.drafter?.enabled == true) {
          final key = _drafterKey(artifactId, selectedConfiguration);
          final checked = _drafterChecks[key];
          _drafterChecks[key] = DrafterCheck(
            stage: DrafterStage.unverified,
            source: draftFiles.firstOrNull ?? path,
            type: checked?.type,
          );
        }
        owned.actualDrafter = selectedConfiguration.drafter?.enabled == true
            ? _drafterChecks[_drafterKey(artifactId, selectedConfiguration)]
            : const DrafterCheck(stage: DrafterStage.disabled);
        // Startup advertises selected engine interfaces, never model scores.
        // Model support and inference results come from explicit user requests.
        final capabilities = <LlamaCapability>{
          if (asset.kind == AssetKind.embedding)
            LlamaCapability.embeddings
          else
            LlamaCapability.textGeneration,
        };
        if (supportsSystemone && asset.kind != AssetKind.embedding) {
          capabilities.addAll({
            LlamaCapability.choiceProbability,
            LlamaCapability.scoreProbability,
            LlamaCapability.noulScalar,
          });
          owned.instance = _copy(
            owned.instance,
            decisionEndpoint: endpoint,
            decisionPid: owned.child.pid,
            decisionSourceIdentity: {
              'kind': 'engine_declared_systemone',
              'capability_origin': sourceBuild == null
                  ? 'engine_release'
                  : 'source_declaration',
              'source': sourceBuild?['source'] ?? release.url.toString(),
              'requested_ref': sourceBuild?['requested_ref'],
              'commit': sourceBuild?['commit'] ?? release.commit,
              'binary_sha256': owned.instance.binarySha256,
              'native_endpoint': endpoint.toString(),
              'generation': instanceGeneration,
              'model': alias,
            },
          );
        }
        checkStartup();
        owned.instance = _copy(
          owned.instance,
          status: LlamaInstanceStatus.ready,
          acceptingRequests: true,
          lastResult: null,
          lastTextResult: null,
          typedEvidence: const {},
          capabilities: Set.unmodifiable(capabilities),
        );
        _instances[alias] = owned.instance;
        _publishInstances();
        return owned.instance;
      } catch (error) {
        _drafterChecks[_drafterKey(
          artifactId,
          selectedConfiguration,
        )] = DrafterCheck(
          source: selectedConfiguration.drafter?.path,
          error: _safeLlama(error.toString(), apiKeys),
        );
        final cancelled =
            startupCancellation.isCancelled && !unexpectedStartupExit;
        final rawReason =
            unexpectedStartupExit &&
                running != null &&
                !_shuttingDown &&
                generation == _generation
            ? '引擎启动时退出 (${running.exitCode})'
                  '${running.log.isEmpty ? '' : ': ${_failureReason(running.log)}'}'
            : error is StartluxReadoutStartException ||
                  error is StartluxRuntimeCleanupException
            ? error.toString()
            : error is LlamaEngineException
            ? error.message
            : error is DecisionProtocolException
            ? error.message
            : '引擎启动失败：$error';
        final reason = _safeLlama(rawReason, apiKeys);
        if (running != null) {
          await _fail(running, reason, cancelled: cancelled);
        } else {
          _reserved.remove(alias);
          await _protect();
          final instance = _instances[alias];
          if (instance != null) {
            _instances[alias] = _copy(
              instance,
              status: cancelled
                  ? LlamaInstanceStatus.stopped
                  : LlamaInstanceStatus.failed,
              error: reason,
            );
            _publishInstances();
          }
        }
        throw LlamaEngineException(reason);
      } finally {
        _pendingStarts.remove(alias);
        _startupByAlias.remove(alias);
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

  Future<void> _awaitStartupJobs() => Future.wait(
    _startupJobs.toList().map(
      (job) => job.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ),
  );

  void _checkStartup() {
    if (_shuttingDown) throw const LlamaEngineException('应用退出，已取消引擎启动');
  }

  @override
  Future<DecisionResult> decide(
    String instanceId,
    DecisionRequest request, {
    Duration timeout = const Duration(seconds: 60),
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

  @override
  Future<DecisionBatchResult> decideBatch(
    String instanceId,
    DecisionBatchRequest request, {
    Duration timeout = const Duration(seconds: 60),
    DecisionCancellation? cancellation,
    DecisionIOTrace? ioTrace,
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
      ioTrace?.seal();
      throw const LlamaRequestException(
        '所选受管实例没有可用的 typed 能力',
        kind: DecisionFailureKind.notReady,
      );
    }
    final permit = _admit(running, cancellation);
    ioTrace?.bindOwnerCredentials(running.apiKeys);
    try {
      final watch = Stopwatch()..start();
      await _identity(running, timeout, cancellation: permit.cancellation);
      final result = await _batchDecision(
        running,
        request,
        timeout - watch.elapsed,
        cancellation: permit.cancellation,
        ioTrace: ioTrace,
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
      ioTrace?.seal();
      _release(running, permit);
    }
  }

  void _checkTerminal(_Running running, DecisionCancellation? cancellation) {
    if (cancellation?.isCancelled == true ||
        _shutdownCancellation.isCancelled ||
        running.exitCode != null ||
        running.readoutExitCode != null ||
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
    DecisionIOTrace? ioTrace,
  }) async {
    final watch = Stopwatch()..start();
    final raw = await _request(
      running,
      (running.instance.decisionEndpoint ?? running.instance.endpoint).resolve(
        '/v1/systemone',
      ),
      timeout: timeout,
      body: request.toSystemone(model: running.instance.id),
      cancellation: cancellation,
      maxResponseBytes: decisionMaxResponseBytes,
      ioTrace: ioTrace,
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
        rawResponse: running.safe(raw),
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
        running,
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
      running,
      (running.instance.decisionEndpoint ?? running.instance.endpoint).resolve(
        '/v1/systemone',
      ),
      timeout: timeout,
      body: request.toSystemone(model: running.instance.id),
      cancellation: cancellation,
      maxResponseBytes: decisionMaxResponseBytes,
    );
    final DecisionResult result;
    try {
      if (running.readout != null) {
        DecisionBatchResult.parse(
          raw,
          DecisionBatchRequest(
            state: request.state,
            questions: {
              'council_choice': ChoiceQuestion(
                instructions: request.instructions,
                options: request.options,
              ),
            },
          ),
          expectedModel: running.instance.id,
        );
      }
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
        rawResponse: running.safe(raw),
      );
    }
    if (running.exitCode != null || running.stopping || !_isCurrent(running)) {
      throw const LlamaEngineException('决策期间受管进程停止');
    }
    return result;
  }

  @override
  Future<EmbeddingResult> generateEmbeddings(
    String instanceId,
    EmbeddingRequest request, {
    Duration timeout = const Duration(seconds: 120),
    DecisionCancellation? cancellation,
  }) async {
    final running = _running[instanceId];
    if (_shuttingDown ||
        running == null ||
        running.instance.status != LlamaInstanceStatus.ready ||
        !running.instance.capabilities.contains(LlamaCapability.embeddings) ||
        running.stopping ||
        running.exitCode != null) {
      throw const LlamaRequestException(
        '所选实例没有已验证的嵌入能力',
        kind: DecisionFailureKind.notReady,
      );
    }
    final permit = _admit(running, cancellation);
    try {
      final watch = Stopwatch()..start();
      await _identity(running, timeout, cancellation: permit.cancellation);
      final result = await _embedding(
        running,
        request,
        timeout - watch.elapsed,
        cancellation: permit.cancellation,
      );
      _checkTerminal(running, permit.cancellation);
      return result;
    } on _InstanceIdentityException catch (error) {
      _release(running, permit);
      await _fail(running, error.message);
      rethrow;
    } finally {
      _release(running, permit);
    }
  }

  Future<EmbeddingResult> _embedding(
    _Running running,
    EmbeddingRequest request,
    Duration timeout, {
    DecisionCancellation? cancellation,
  }) async {
    final raw = await _request(
      running,
      running.instance.endpoint.resolve('/v1/embeddings'),
      timeout: timeout,
      body: request.toJson(model: running.instance.id),
      cancellation: cancellation,
      maxResponseBytes: 16 * 1024 * 1024,
    );
    try {
      final result = EmbeddingResult.parse(
        raw,
        request: request,
        expectedModel: running.instance.id,
      );
      _checkTerminal(running, cancellation);
      return result;
    } on EmbeddingProtocolException catch (error) {
      throw LlamaRequestException(
        error.message,
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: running.safe(raw),
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
  @override
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
            running.headers.forEach(upstream.headers.set);
            upstream.headers.contentType = ContentType.json;
            upstream.write(
              jsonEncode(
                request.toChat(
                  model: running.instance.id,
                  stream: true,
                  unlimitedAsNegativeOne: true,
                ),
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
        rawResponse: running.safe(decoder.rawResponse),
      );
    } on FormatException {
      throw LlamaRequestException(
        '文本流不是有效 UTF-8',
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: running.safe(decoder.rawResponse),
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
          rawResponse: running.safe(decoder.rawResponse),
        );
      }
      throw LlamaRequestException(
        '文本流连接失败：$error',
        kind: DecisionFailureKind.failed,
        rawResponse: running.safe(decoder.rawResponse),
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
      running,
      running.instance.endpoint.resolve('/v1/chat/completions'),
      timeout: timeout,
      body: request.toChat(
        model: running.instance.id,
        unlimitedAsNegativeOne: true,
      ),
      cancellation: cancellation,
    );
    final TextResult result;
    try {
      result = TextResult.parse(raw, expectedModel: running.instance.id);
    } on TextProtocolException catch (error) {
      throw LlamaRequestException(
        error.message,
        kind: DecisionFailureKind.invalidResponse,
        rawResponse: running.safe(raw),
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
    _Running running,
    Uri uri, {
    required Duration timeout,
    Map<String, Object?>? body,
    DecisionCancellation? cancellation,
    int? maxResponseBytes,
    DecisionIOTrace? ioTrace,
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
            if (uri.origin == running.instance.endpoint.origin) {
              running.headers.forEach(request.headers.set);
            }
            if (body != null) {
              request.headers.contentType = ContentType.json;
              final encoded = jsonEncode(body);
              final bodyBytes = utf8.encode(encoded);
              request.contentLength = bodyBytes.length;
              request.add(bodyBytes);
              ioTrace?.sent(encoded);
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
            ioTrace?.received(raw, response.statusCode);
            if (response.statusCode != 200) {
              throw LlamaRequestException(
                running.safe(
                  '引擎 HTTP ${response.statusCode}: ${raw.length > 1024 ? raw.substring(0, 1024) : raw}',
                ),
                kind: DecisionFailureKind.failed,
                rawResponse: running.safe(raw),
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
      ioTrace?.seal();
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
    final error = running.instance.error;
    if (error != null) {
      running.instance = _copy(running.instance, error: running.safe(error));
    }
    if (!_isCurrent(running)) return;
    running.instance = _copy(
      running.instance,
      activeRequests: running.active.length,
      hasLiveProcess: running.hasLiveOwnedProcess,
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
      Object? readoutFailure;
      try {
        if (running.readoutExitCode == null) await running.readout?.stop();
      } catch (error) {
        readoutFailure = error;
      }
      if (running.exitCode == null) {
        running.child.kill(ProcessSignal.sigterm);
        try {
          await running.child.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          running.child.kill(ProcessSignal.sigkill);
          await running.child.exitCode.timeout(const Duration(seconds: 5));
        }
      }
      if (readoutFailure != null) throw readoutFailure;
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

  Future<void> _fail(
    _Running running,
    String reason, {
    bool cancelled = false,
  }) async {
    reason = running.safe(reason);
    try {
      await _stopChild(running);
    } catch (cleanupError, stack) {
      final failure = LlamaEngineException(
        running.safe('$reason；受管资源收尾失败：$cleanupError'),
      );
      running.instance = _copy(
        running.instance,
        status: LlamaInstanceStatus.failed,
        capabilities: const {},
        error: failure.message,
      );
      _publishRun(running);
      Error.throwWithStackTrace(failure, stack);
    }
    running.instance = _copy(
      running.instance,
      status: cancelled
          ? LlamaInstanceStatus.stopped
          : LlamaInstanceStatus.failed,
      error: reason,
    );
    _publishRun(running);
  }

  @override
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
      final startup = _startupByAlias[instanceId];
      return _serial(() async {
        await startup?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
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
    final startup = _startupByAlias[instanceId];
    return _serial(() async {
      await startup?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      await _stopChild(running);
      running.instance = _copy(
        running.instance,
        status: LlamaInstanceStatus.stopped,
      );
      _publishRun(running);
    }, cleanup: true);
  }

  @override
  Future<void> stopManaged() {
    if (_recycle != null) return _recycle!;
    cancelInstallation();
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
      await _awaitStartupJobs();
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
    Uri? decisionEndpoint,
    Map<String, Object?>? decisionSourceIdentity,
    int? decisionPid,
    Map<String, String>? processEnvironment,
    EngineLaunchCommand? launchCommand,
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
    launchCommand: launchCommand ?? value.launchCommand,
    binaryVersion: value.binaryVersion,
    binarySha256: value.binarySha256,
    asset: value.asset,
    endpoint: value.endpoint,
    decisionEndpoint: decisionEndpoint ?? value.decisionEndpoint,
    decisionSourceIdentity:
        decisionSourceIdentity ?? value.decisionSourceIdentity,
    decisionPid: decisionPid ?? value.decisionPid,
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
    cancelInstallation();
    _shutdownCancellation.cancel();
  }

  @override
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    beginShutdown();
    return _shutdown = _drainAndStop();
  }

  Future<void> _drainAndStop() async {
    await _operations;
    await _awaitStartupJobs();
    final errors = <Object>[];
    for (final running in _running.values.toList()) {
      if (!running.hasLiveOwnedProcess) continue;
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

  Future<void> redownload({File? verifiedArchive}) async {
    if (linkedInstallation != null) {
      throw const LlamaEngineException('关联引擎由外部维护');
    }
    if (hasLiveInstances || _redownloading) {
      throw const LlamaEngineException('请先停止该引擎的模型实例');
    }
    _redownloading = true;
    try {
      await installationDirectory.create(recursive: true);
      final root = await installationDirectory.resolveSymbolicLinks();
      if (await Directory('$root/${release.tag}').exists()) {
        await prepareRemoval();
      }
      await redownloadEngine(
        Directory('$root/${release.tag}'),
        () => install(verifiedArchive: verifiedArchive),
      );
    } catch (_) {
      await refreshInstallation();
      rethrow;
    } finally {
      _redownloading = false;
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
    final cancellation = DecisionCancellation();
    _installCancellation = cancellation;
    void checkCancelled() {
      if (_shuttingDown || cancellation.isCancelled) {
        throw const LlamaEngineException('引擎安装已取消');
      }
    }

    var received = 0;
    final progressClock = Stopwatch()..start();
    final downloadClock = Stopwatch();
    _installProgress(EngineInstallPhase.downloading, received);
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
        received = release.sizeBytes;
      } else {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30);
        _installClient = client;
        try {
          checkCancelled();
          downloadClock.start();
          final response = await (await client.getUrl(release.url))
              .close()
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200) {
            throw LlamaEngineException('引擎下载 HTTP ${response.statusCode}');
          }
          final sink = archive.openWrite();
          try {
            await for (final bytes in response.timeout(
              const Duration(seconds: 30),
            )) {
              checkCancelled();
              received += bytes.length;
              if (received > release.sizeBytes) {
                throw const LlamaEngineException('引擎 archive 超出发布尺寸');
              }
              sink.add(bytes);
              if (received == bytes.length ||
                  progressClock.elapsedMilliseconds >= 100) {
                _installProgress(
                  EngineInstallPhase.downloading,
                  received,
                  bytesPerSecond:
                      received *
                      Duration.microsecondsPerSecond /
                      max(1, downloadClock.elapsedMicroseconds),
                );
                progressClock.reset();
              }
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
        } finally {
          client.close(force: true);
          _installClient = null;
        }
      }
      checkCancelled();
      _installProgress(EngineInstallPhase.verifying, received);
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
          await _refreshParameterRecognition();
          _publish(
            LlamaEngineState(
              installation: LlamaInstallationStatus.installed,
              version: observedVersion,
            ),
          );
          _installProgress(EngineInstallPhase.complete, received);
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
      checkCancelled();
      _installProgress(EngineInstallPhase.unpacking, received);
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
      checkCancelled();
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
      checkCancelled();
      await extracted.rename(target.path);
      _binarySha256 = null;
      executablePath = '${target.path}/llama-server';
      observedVersion = version;
      await _refreshParameterRecognition();
      _publish(
        LlamaEngineState(
          installation: LlamaInstallationStatus.installed,
          version: version,
        ),
      );
      _installProgress(EngineInstallPhase.complete, received);
    } catch (error) {
      final reason = cancellation.isCancelled || _shuttingDown
          ? '引擎安装已取消'
          : error is LlamaEngineException
          ? error.message
          : '引擎安装失败：${error.runtimeType}';
      _publish(
        LlamaEngineState(
          installation: LlamaInstallationStatus.failed,
          version: observedVersion,
          error: reason,
        ),
      );
      _installProgress(
        cancellation.isCancelled || _shuttingDown
            ? EngineInstallPhase.cancelled
            : EngineInstallPhase.failed,
        received,
        error: reason,
      );
      throw LlamaEngineException(reason);
    } finally {
      try {
        if (staging != null) await staging.delete(recursive: true);
      } catch (error) {
        _installProgress(
          EngineInstallPhase.failed,
          received,
          error: '安装临时目录清理失败：${error.runtimeType}',
        );
        rethrow;
      } finally {
        _installCancellation = null;
        _installClient = null;
      }
    }
  });

  Future<void> readParameters() => _serial(() async {
    final generation = _generation;
    if (executablePath == null) return;
    if (linkedInstallation != null) {
      final current = await inspectLinkedLlama(
        File(linkedInstallation!.path),
        io,
      );
      if (_shuttingDown || _detached || generation != _generation) return;
      linkedInstallation = current;
      executablePath = current.path;
      observedVersion = current.version;
      _parameterRecognition = EngineParameterRecognition.fromHelp(
        current.helpOutput ?? '',
        version: current.version,
        executablePath: current.path,
        previous: _parameterRecognition,
      );
    } else {
      await _refreshParameterRecognition();
    }
  });

  Future<void> _refreshParameterRecognition() async {
    final executable = executablePath!;
    final observed = observedVersion;
    final version = observed ?? '未知版本';
    final fingerprint = _binarySha256;
    final generation = _generation;
    final previous = _parameterRecognition;
    bool current() =>
        !_shuttingDown &&
        !_recycling &&
        !_detached &&
        !_changes.isClosed &&
        generation == _generation &&
        executablePath == executable &&
        observedVersion == observed &&
        _binarySha256 == fingerprint;
    EngineCommandResult? result;
    try {
      result = await io.run(executable, [
        '--help',
      ], timeout: const Duration(seconds: 10));
    } catch (_) {
      // The command I/O owns timeout/kill/drain; optional help is not an install gate.
    }
    if (!current()) return;
    if (result != null && result.exitCode == 0) {
      _parameterRecognition = EngineParameterRecognition.fromHelp(
        '${result.stdout}\n${result.stderr}',
        version: version,
        executablePath: executable,
        contentFingerprint: fingerprint,
        previous: previous,
      );
    } else if (previous.hasObservedHelp &&
        previous.executablePath == executable &&
        previous.contentFingerprint == fingerprint) {
      _parameterRecognition = previous.withReadFailure(
        version: version,
        notice: '本次帮助读取失败，沿用同一路径上次读取的识别规则；参数仍交由引擎判断。',
      );
    } else {
      _parameterRecognition = EngineParameterRecognition.builtIn(
        version: version,
        executablePath: executable,
        contentFingerprint: fingerprint,
        notice: '当前版本帮助读取失败，继续使用内置识别规则。',
      );
    }
  }

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
    _discardUnverifiedParameters();
    executablePath = null;
    observedVersion = null;
    _binarySha256 = null;
  }

  bool _discardUnverifiedParameters() {
    if (!_shuttingDown && !_changes.isClosed) {
      _parameterRecognition = EngineParameterRecognition.builtIn(
        notice: '引擎身份核验未通过，当前帮助规则不可用；保留内置规则与原配置。',
      );
    }
    return false;
  }

  Future<bool> _checkInstallation(Directory target) async {
    final executable = File('${target.path}/llama-server');
    if (!await executable.exists()) return _discardUnverifiedParameters();
    executablePath = executable.path;
    observedVersion = '未知版本';
    _binarySha256 = null;
    try {
      final metadata = jsonDecode(
        await File('${target.path}/installation.json').readAsString(),
      );
      if (metadata is Map && metadata['version'] is String) {
        observedVersion = metadata['version'];
      }
    } catch (_) {
      // A missing/stale receipt does not decide whether the executable can run.
    }
    return true;
  }

  Future<bool> _checkLinked() async {
    final current = linkedInstallation!;
    if (!await File(current.path).exists()) {
      return _discardUnverifiedParameters();
    }
    final parent = File(current.path).parent;
    await for (final dependency in parent.list(followLinks: false)) {
      if (!dependency.path.endsWith('.dylib') &&
          !dependency.path.endsWith('.metallib')) {
        continue;
      }
      final path = await dependency.resolveSymbolicLinks();
      if (!path.startsWith('${parent.path}/') || !await File(path).exists()) {
        return _discardUnverifiedParameters();
      }
    }
    executablePath = current.path;
    observedVersion = current.version;
    _binarySha256 = null;
    return true;
  }

  bool get hasLiveInstances =>
      _startupJobs.isNotEmpty ||
      _reserved.isNotEmpty ||
      _running.values.any((running) => running.hasLiveOwnedProcess);
  Future<void> detachLinked({Future<void> Function()? persistRemoval}) =>
      _serial(() async {
        if (linkedInstallation == null) {
          throw const LlamaEngineException('仅可解除外部引擎关联');
        }
        if (hasLiveInstances) throw const LlamaEngineException('请先停止该引擎的模型实例');
        await persistRemoval?.call();
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
    final marker = jsonDecode(
      await File('${target.path}/installation.json').readAsString(),
    );
    if (marker is! Map ||
        marker['files'] is! Map ||
        (jsonDecode(inventory) as Map).keys.any(
          (name) => !(marker['files'] as Map).containsKey(name),
        )) {
      throw const LlamaEngineException('受管目录包含未登记文件，保留原目录');
    }
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
          'size': (await entity.stat()).size,
          'modified': (await entity.stat()).modified.microsecondsSinceEpoch,
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
    EngineCommandResult result;
    try {
      result = await io.run(binary.path, [
        '--version',
      ], timeout: release.installationVersionTimeout);
    } catch (_) {
      return '未知版本';
    }
    final version = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != 0 || version.isEmpty) return '未知版本';
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
