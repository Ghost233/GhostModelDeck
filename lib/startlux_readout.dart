import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'engine_runtime.dart' show DecisionCancellation;
import 'jev_debug.dart' show freezeDebugJson;
import 'startlux_runtime.dart' show StartluxPreparedRuntime;

abstract interface class StartluxReadoutProcess {
  int get pid;
  Future<int> get exited;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  bool kill(ProcessSignal signal);
}

typedef StartluxReadoutSpawn = Future<StartluxReadoutProcess> Function(
  String executable,
  List<String> arguments,
);

/// Startup failed, and cleanup also failed. The caller must retain this owner
/// until the child actually exits or a later explicit stop finishes cleanup.
class StartluxReadoutStartException implements Exception {
  const StartluxReadoutStartException({
    required this.readout,
    required this.originalError,
    required this.cleanupError,
  });
  final StartluxReadout readout;
  final Object originalError;
  final Object cleanupError;
  @override
  String toString() => '$originalError; StartLux cleanup: $cleanupError';
}

class StartluxReadoutFactory {
  StartluxReadoutFactory(
    this.runtime, {
    required this.cacheRoot,
    required this.assets,
    StartluxReadoutSpawn? spawn,
  }) : _spawn = spawn ?? _spawnNative;

  final StartluxPreparedRuntime runtime;
  final Directory cacheRoot;
  final Future<Uint8List> Function(String) assets;
  final StartluxReadoutSpawn _spawn;
  Future<_ReadoutBundle>? _preparing;
  static const authorPin = '07e13ea49c67f41da795c28abb4590347e745b7a';
  static const supportedModelSha256 =
      '36c2aec2c3741f0602b0d931273c1f55a7a8650bdb0be8d4adc9848a19b34b30';
  static const manifestSha256 =
      '7d43e755cf553656d1d1e8b5f0334dd13d792ac69a2d4b06804be5ebf778bc10';

  Future<StartluxReadout> start({
    required Uri nativeEndpoint,
    required String alias,
    required int generation,
    required DecisionCancellation cancellation,
  }) async {
    _checkCancelled(cancellation);
    if (nativeEndpoint.scheme != 'http' ||
        nativeEndpoint.host != '127.0.0.1' ||
        !nativeEndpoint.hasPort ||
        nativeEndpoint.userInfo.isNotEmpty ||
        (nativeEndpoint.path.isNotEmpty && nativeEndpoint.path != '/') ||
        nativeEndpoint.hasQuery ||
        nativeEndpoint.hasFragment) {
      throw const FormatException('StartLux requires a loopback llama origin');
    }
    if (alias.isEmpty || generation < 0) {
      throw const FormatException('StartLux requires an alias and generation');
    }
    final bundle = await (_preparing ??= _exportBundle());
    await _verifyBundle(
      bundle.directory,
      bundle.manifest['files'] as Map<String, dynamic>,
    );
    _checkCancelled(cancellation);
    final identity = freezeDebugJson({
      'kind': 'startlux_author_readout',
      'author_pin': authorPin,
      'model_sha256': supportedModelSha256,
      'bundle_sha256': manifestSha256,
      'code_fingerprint': bundle.manifest['code_fingerprint'],
      'tokenizer_fingerprint': bundle.manifest['tokenizer_fingerprint'],
      'temperature_sha256': bundle.manifest['temperature_sha256'],
      'runtime_fingerprint': runtime.fingerprint,
      'runtime': runtime.provenance,
      'model': alias,
      'generation': generation,
      'native_endpoint': nativeEndpoint.toString(),
      'native_budget_ms': 10000,
    }) as Map<String, Object?>;
    final child = await _spawn(runtime.pythonPath, [
      '-I',
      '-B',
      '${bundle.directory.path}/managed_transport.py',
      '--model-dir',
      '${bundle.directory.path}/author',
      '--receipt',
      '${bundle.directory.path}/receipt.json',
      '--llama',
      nativeEndpoint.toString(),
      '--name',
      alias,
      '--generation',
      '$generation',
      '--port',
      '0',
    ]);
    final readout = StartluxReadout._(child, identity, alias, generation);
    final unlink = cancellation.listen(() {
      readout._cancelStartup();
    });
    try {
      await readout._ready.future.timeout(const Duration(seconds: 30));
      _checkCancelled(cancellation);
      if (readout._ended) {
        throw StateError('StartLux sidecar exited during startup');
      }
      return readout;
    } catch (error, stack) {
      try {
        await readout.stop();
      } catch (cleanupError) {
        Error.throwWithStackTrace(
          StartluxReadoutStartException(
            readout: readout,
            originalError: error,
            cleanupError: cleanupError,
          ),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      unlink();
    }
  }

  Future<_ReadoutBundle> _exportBundle() async {
    final bytes = await assets('assets/startlux_readout/manifest.json');
    if (sha256.convert(bytes).toString() != manifestSha256) {
      throw const FormatException('StartLux bundled manifest SHA256 mismatch');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['author_pin'] != authorPin ||
        decoded['model_sha256'] != supportedModelSha256 ||
        decoded['files'] is! Map<String, dynamic>) {
      throw const FormatException('StartLux bundled manifest is invalid');
    }
    final entries = decoded['files'] as Map<String, dynamic>;
    await cacheRoot.create(recursive: true);
    await _realDirectory(cacheRoot);
    final target = Directory('${cacheRoot.path}/$manifestSha256');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await _verifyBundle(target, entries);
      return _ReadoutBundle(target, decoded);
    }
    final staging = await cacheRoot.createTemp('.startlux-readout-');
    try {
      for (final entry in entries.entries) {
        _checkRelativeName(entry.key);
        final expected = _entry(entry.value);
        final data = await assets('assets/startlux_readout/${entry.key}');
        if (data.length != expected.$1 ||
            sha256.convert(data).toString() != expected.$2) {
          throw FormatException(
            'StartLux bundled asset mismatch: ${entry.key}',
          );
        }
        final file = File('${staging.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data, flush: true);
      }
      await _verifyBundle(staging, entries);
      await staging.rename(target.path);
      return _ReadoutBundle(target, decoded);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> _verifyBundle(
    Directory directory,
    Map<String, dynamic> entries,
  ) async {
    await _realDirectory(directory);
    final allowed = entries.keys.toSet();
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = entity.path.substring(directory.path.length + 1);
      if (entity is Link || (entity is File && !allowed.contains(relative))) {
        throw const FormatException('StartLux cache contains unverified files');
      }
    }
    for (final entry in entries.entries) {
      _checkRelativeName(entry.key);
      final expected = _entry(entry.value);
      final file = File('${directory.path}/${entry.key}');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != expected.$1 ||
          (await sha256.bind(file.openRead()).first).toString() !=
              expected.$2) {
        throw FormatException('StartLux cached asset mismatch: ${entry.key}');
      }
    }
  }

  static (int, String) _entry(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['bytes'] is! int ||
        value['sha256'] is! String) {
      throw const FormatException('StartLux asset manifest entry is invalid');
    }
    return (value['bytes'] as int, value['sha256'] as String);
  }

  static void _checkRelativeName(String name) {
    if (name.startsWith('/') ||
        name
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('StartLux asset path is not relative');
    }
  }

  static Future<void> _realDirectory(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('StartLux cache must be a real directory');
    }
  }

  static void _checkCancelled(DecisionCancellation cancellation) {
    if (cancellation.isCancelled) {
      throw StateError('StartLux readout startup cancelled');
    }
  }

  static Future<StartluxReadoutProcess> _spawnNative(
    String executable,
    List<String> arguments,
  ) async => _NativeReadoutProcess(
    await Process.start(
      executable,
      arguments,
      runInShell: false,
      includeParentEnvironment: false,
      environment: {
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        'PYTHONNOUSERSITE': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        for (final key in ['HOME', 'TMPDIR']) key: ?Platform.environment[key],
      },
    ),
  );
}

class StartluxReadout {
  StartluxReadout._(
    this._child,
    this.sourceIdentity,
    String alias,
    int generation,
  ) {
    _stdout = _child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (_ready.isCompleted) return;
            try {
              final message = jsonDecode(line);
              if (message is! Map<String, dynamic> ||
                  message['status'] != 'ready' ||
                  message['model'] != alias ||
                  message['pin'] != StartluxReadoutFactory.authorPin ||
                  message['generation'] != generation ||
                  message['port'] is! int ||
                  (message['port'] as int) <= 0 ||
                  (message['port'] as int) > 65535) {
                throw const FormatException(
                  'StartLux sidecar readiness identity mismatch',
                );
              }
              endpoint = Uri.parse('http://127.0.0.1:${message['port']}');
              _ready.complete();
            } catch (error, stack) {
              _ready.completeError(error, stack);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!_ready.isCompleted) _ready.completeError(error, stack);
          },
        );
    _stderr = _child.stderr
        .transform(utf8.decoder)
        .listen(
          (text) {
            if (_errors.length < 8192) {
              final remaining = 8192 - _errors.length;
              _errors.write(
                text.length > remaining ? text.substring(0, remaining) : text,
              );
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!_ready.isCompleted) _ready.completeError(error, stack);
          },
        );
    exited = _child.exited.then((code) async {
      _ended = true;
      if (!_ready.isCompleted) {
        _ready.completeError(
          StateError(
            'StartLux sidecar exited $code before readiness: $_errors',
          ),
        );
      }
      await _stdout.cancel();
      await _stderr.cancel();
      return code;
    });
  }

  final StartluxReadoutProcess _child;
  final Map<String, Object?> sourceIdentity;
  late final Uri endpoint;
  int get pid => _child.pid;
  late final Future<int> exited;
  final _ready = Completer<void>();
  final _errors = StringBuffer();
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  bool _ended = false;
  Future<void>? _stopping;
  bool get hasLiveProcess => !_ended;

  void _cancelStartup() {
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('StartLux readout startup cancelled'));
    }
    // start() awaits stop() in its failure path and preserves cleanup errors.
  }

  Future<void> stop() => _stopping ??= _stopAttempt();
  Future<void> _stopAttempt() async {
    try {
      await _stop();
    } catch (_) {
      // Preserve the failed attempt for its caller, but keep residual resources
      // reachable by a later explicit stop instead of caching failure forever.
      _stopping = null;
      rethrow;
    }
  }

  Future<void> _stop() async {
    if (!_ended) _child.kill(ProcessSignal.sigterm);
    try {
      await exited.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (!_ended) _child.kill(ProcessSignal.sigkill);
      await exited.timeout(const Duration(seconds: 5));
      throw StateError('StartLux sidecar required forced termination');
    }
  }
}

class _ReadoutBundle {
  const _ReadoutBundle(this.directory, this.manifest);
  final Directory directory;
  final Map<String, dynamic> manifest;
}

class _NativeReadoutProcess implements StartluxReadoutProcess {
  const _NativeReadoutProcess(this.process);
  final Process process;
  @override
  int get pid => process.pid;
  @override
  Future<int> get exited => process.exitCode;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  bool kill(ProcessSignal signal) => process.kill(signal);
}
