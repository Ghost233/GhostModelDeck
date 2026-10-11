import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'benchmark_game_record.dart';
import 'jev_playground.dart';
import 'jevman_benchmark.dart';
import 'jevman_runtime.dart';
import 'jevman_viewing.dart';

enum BenchmarkGamePreparationStatus {
  idle,
  preparing,
  ready,
  cancelled,
  failed,
}

/// App-owned game assets and runtime; admission and profile locks belong to the
/// existing BenchmarkRunner. Pages observe this owner without disposing it.
class BenchmarkGameWork {
  BenchmarkGameWork(
    this.cacheRoot, {
    Future<ByteData> Function(String)? loadAsset,
  }) : _loadAsset = loadAsset ?? rootBundle.load,
       _runtime = JevmanRuntime(Directory('${cacheRoot.path}/node')) {
    _runtimeEvents = _runtime.changes.listen((event) {
      _changes.add({
        'type': 'preparation',
        'phase': event.phase,
        'downloadedBytes': event.downloadedBytes,
        'totalBytes': event.totalBytes,
      });
    });
  }

  static const pin = '1c8b77ac61bafa10956c601b1c9b339dcd277836';
  static const bundleAsset = 'benchmarks/adapters/jevman/bridge.mjs';
  static const manifestAsset = 'benchmarks/manifests/jevman.json';
  final Directory cacheRoot;
  final Future<ByteData> Function(String) _loadAsset;
  final JevmanRuntime _runtime;
  final _changes = StreamController<Map<String, Object?>>.broadcast();
  late final StreamSubscription<JevmanRuntimeProgress> _runtimeEvents;
  StreamSubscription<Map<String, Object?>>? _gameEvents;
  JevmanGameBridge? _bridge;
  final _viewers = <JevmanReplaySession>{};
  final _openingViewers = <Future<JevmanReplaySession>>{};
  List<int> get activeViewerProcessIds => [
    for (final viewer in _viewers)
      if (viewer.activeProcessId != null) viewer.activeProcessId!,
  ];

  Future<void> waitForViewersClosed() async {
    await Future.wait(
      _openingViewers.toList().map(
        (opening) => opening.then<void>((_) {}, onError: (Object _) {}),
      ),
    );
    await Future.wait(
      _viewers.toList().map((viewer) => viewer.closing ?? Future<void>.value()),
    );
  }

  Map<String, Object?>? _identity;
  Completer<void>? _preparing;
  DecisionCancellation? _activePreparation;
  Future<void>? _closing;
  bool _closed = false;
  BenchmarkGamePreparationStatus _status = BenchmarkGamePreparationStatus.idle;
  String? _lastError;

  BenchmarkGamePreparationStatus get status => _status;
  String? get lastError => _lastError;
  JevmanRuntimeProgress? get progress => _runtime.progress;
  Map<String, Object?> get identity =>
      _identity ?? (throw StateError('游戏资源尚未准备'));
  Stream<Map<String, Object?>> get changes => _changes.stream;
  Map<String, Object?>? get latestFrame => _bridge?.latestFrame;
  Map<String, Object?>? get activeTarget => _bridge?.activeTarget;
  int? get activeProcessId => _bridge?.activeProcessId;
  void cancelPreparation() => _activePreparation?.cancel();

  Future<void> prepare(DecisionCancellation cancellation) async {
    if (_closed) throw StateError('游戏资源已关闭');
    if (_preparing != null || activeProcessId != null) {
      throw StateError('游戏资源正在使用');
    }
    final done = Completer<void>();
    _preparing = done;
    final token = DecisionCancellation();
    _activePreparation = token;
    final remove = cancellation.listen(token.cancel);
    _status = BenchmarkGamePreparationStatus.preparing;
    _lastError = null;
    try {
      _check(token);
      await _directory(cacheRoot, recursive: true);
      final manifestData = await _loadAsset(manifestAsset);
      final manifestBytes = manifestData.buffer.asUint8List(
        manifestData.offsetInBytes,
        manifestData.lengthInBytes,
      );
      final decoded = jsonDecode(utf8.decode(manifestBytes));
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('游戏资源 manifest 无效');
      }
      _validateManifest(decoded);
      _check(token);
      final asset = await _loadAsset(bundleAsset);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final expectedHash = decoded['bundleSha256'] as String;
      if (bytes.length != decoded['bundleBytes'] ||
          sha256.convert(bytes).toString() != expectedHash) {
        throw const FormatException('打包游戏桥接字节或 SHA256 不一致');
      }
      final bundle = await _materialize(bytes, expectedHash, token);
      _check(token);
      await _runtime.prepare(token);
      _check(token);
      _bridge ??= JevmanGameBridge(
        runtime: _runtime,
        bundle: bundle,
        bundleSha256: expectedHash,
      );
      _gameEvents ??= _bridge!.changes.listen(_changes.add);
      _identity = _seal({
        ...decoded,
        'manifestSha256': sha256.convert(manifestBytes).toString(),
      }) as Map<String, Object?>;
      _status = BenchmarkGamePreparationStatus.ready;
      _changes.add({'type': 'prepared', 'identity': identity});
    } catch (error) {
      _status = token.isCancelled
          ? BenchmarkGamePreparationStatus.cancelled
          : BenchmarkGamePreparationStatus.failed;
      _lastError = error.toString();
      rethrow;
    } finally {
      remove();
      _activePreparation = null;
      _preparing = null;
      done.complete();
    }
  }

  Future<Map<String, Object?>> play({
    required JevPlayground client,
    required String model,
    required JevPlaygroundMode channel,
    required DecisionCancellation cancellation,
    required bool Function() isCurrent,
    FutureOr<void> Function(Map<String, Object?> game)? onGameCommitted,
  }) {
    _requireReady();
    return _bridge!.play(
      client: client,
      model: model,
      channel: channel,
      cancellation: cancellation,
      isCurrent: isCurrent,
      onGameCommitted: (game) => onGameCommitted?.call(
        BenchmarkGameRecord.parse(
          game,
          model: model,
          channel: channel,
        ).toJson(),
      ),
    );
  }

  Future<Map<String, Object?>> replay(JevmanRecording recording) {
    _requireReady();
    return _bridge!.replay(recording);
  }

  Future<JevmanReplaySession> openReplay(
    JevmanRecording recording, {
    required Map<String, Object?> identity,
  }) {
    final opening = _openReplay(recording, identity: identity);
    _openingViewers.add(opening);
    unawaited(
      opening.then<void>(
        (_) => _openingViewers.remove(opening),
        onError: (Object _) {
          _openingViewers.remove(opening);
        },
      ),
    );
    return opening;
  }

  Future<JevmanReplaySession> _openReplay(
    JevmanRecording recording, {
    required Map<String, Object?> identity,
  }) async {
    if (_closed) {
      throw StateError('游戏资源已关闭');
    }
    if (_status != BenchmarkGamePreparationStatus.ready) {
      await prepare(DecisionCancellation());
    }
    // The adapter may gain read-only viewing commands. The actual game modules
    // and trace schema must still match the historical game's fixed version.
    if (identity['pin'] != pin || identity['benchVersion'] != 1) {
      throw const FormatException('录像对应的游戏版本不匹配');
    }
    final oldNode = identity['node'];
    final node = this.identity['node'] as Map;
    if (oldNode is! Map ||
        const [
          'version',
          'platform',
          'executableSha256',
          'licenseSha256',
        ].any((key) => oldNode[key] != node[key])) {
      throw const FormatException('录像对应的原游戏运行时版本不匹配');
    }
    final oldInputs = identity['bundleInputs'];
    final inputs = this.identity['bundleInputs'] as List;
    if (oldInputs is! List ||
        inputs
            .where(
              (input) =>
                  (input as Map)['path'] !=
                  'benchmarks/adapters/jevman/entry.ts',
            )
            .any(
              (input) => !oldInputs.any(
                (old) =>
                    old is Map &&
                    old['path'] == (input as Map)['path'] &&
                    old['sha256'] == input['sha256'],
              ),
            )) {
      throw const FormatException('录像对应的原游戏源码摘要不匹配');
    }
    final viewer = await JevmanReplaySession.open(
      runtime: _runtime,
      bundle: _bridge!.bundle,
      bundleSha256: _bridge!.bundleSha256,
      recording: recording,
    );
    if (_closed) {
      await viewer.close();
      throw StateError('游戏资源已关闭');
    }
    _viewers.add(viewer);
    _changes.add({'type': 'viewerOpened', 'pid': viewer.activeProcessId});
    viewer.onClosed = () {
      _viewers.remove(viewer);
      _changes.add({'type': 'viewerClosed'});
    };
    return viewer;
  }

  void _requireReady() {
    if (_closed ||
        _status != BenchmarkGamePreparationStatus.ready ||
        _bridge == null) {
      throw StateError('游戏资源尚未就绪或已关闭');
    }
  }

  static void _validateManifest(Map<String, Object?> value) {
    for (final entry in const {
      'id': 'jevman',
      'pin': pin,
      'bundle': bundleAsset,
      'games': 100,
      'benchVersion': 1,
      'maxPlayingSeconds': 300,
      'decisionTimeoutMs': 2000,
      'warmupTimeoutMs': 30000,
      'warmupMaxMs': 300000,
      'warmupAcceptMs': 1800,
      'ghosts': 'scripted',
    }.entries) {
      if (value[entry.key] != entry.value) {
        throw FormatException('游戏固定版本或原调度不一致：${entry.key}');
      }
    }
    final node = value['node'];
    if (node is! Map ||
        node['platform'] != 'darwin-arm64' ||
        node['version'] != JevmanRuntime.version ||
        node['sha256'] != JevmanRuntime.archiveSha256 ||
        node['executableSha256'] != JevmanRuntime.nodeSha256 ||
        node['licenseSha256'] != JevmanRuntime.licenseSha256 ||
        node['bytes'] != JevmanRuntime.archiveBytes ||
        node['url'] != JevmanRuntime.archiveUrl.toString() ||
        value['bundleBytes'] is! int ||
        (value['bundleBytes'] as int) <= 0 ||
        value['bundleSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['bundleSha256'] as String)) {
      throw const FormatException('游戏 Mac arm64 运行时或桥接摘要无效');
    }
  }

  Future<File> _materialize(
    Uint8List bytes,
    String hash,
    DecisionCancellation token,
  ) async {
    final base = Directory('${cacheRoot.path}/bundles');
    final directory = Directory('${base.path}/$hash');
    await _directory(base);
    await _directory(directory);
    final bundle = File('${directory.path}/bridge.mjs');
    final type = await FileSystemEntity.type(bundle.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      if (await bundle.length() != bytes.length ||
          (await sha256.bind(bundle.openRead()).first).toString() != hash) {
        throw const FormatException('已缓存游戏桥接 SHA256 不一致');
      }
      return bundle;
    }
    if (type != FileSystemEntityType.notFound) {
      throw const FormatException('游戏桥接缓存不是普通文件');
    }
    final staging = await directory.createTemp('.bridge-');
    try {
      final partial = File('${staging.path}/bridge.mjs');
      await partial.writeAsBytes(bytes, flush: true);
      _check(token);
      if (await FileSystemEntity.type(bundle.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FormatException('游戏桥接缓存归属已变化');
      }
      await partial.rename(bundle.path);
      return bundle;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  static Future<void> _directory(
    Directory value, {
    bool recursive = false,
  }) async {
    if (await FileSystemEntity.type(value.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await value.create(recursive: recursive);
    }
    if (await FileSystemEntity.type(value.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('游戏缓存不是普通目录');
    }
  }

  void _check(DecisionCancellation token) {
    if (token.isCancelled || _closed) throw const JevmanRuntimeCancelled();
  }

  static Object? _seal(Object? value) => jsonDecode(
    jsonEncode(value),
    reviver: (key, item) {
      if (item is Map<String, Object?>) {
        return Map<String, Object?>.unmodifiable(item);
      }
      if (item is List) return List<Object?>.unmodifiable(item);
      return item;
    },
  );

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    cancelPreparation();
    try {
      await Future.wait(
        _openingViewers.toList().map(
          (opening) => opening.then<void>((_) {}, onError: (Object _) {}),
        ),
      );
      await Future.wait([
        for (final viewer in _viewers.toList()) viewer.close(),
        _bridge?.close() ?? Future<void>.value(),
        _runtime.close(),
        if (_preparing != null) _preparing!.future,
      ]);
    } finally {
      await _gameEvents?.cancel();
      await _runtimeEvents.cancel();
      await _changes.close();
    }
  }
}
