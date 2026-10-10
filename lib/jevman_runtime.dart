import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'engine_runtime.dart' show DecisionCancellation;

enum JevmanRuntimeStatus { idle, preparing, ready, cancelled, failed }

class JevmanRuntimeCancelled implements Exception {
  const JevmanRuntimeCancelled();
  @override
  String toString() => 'Jevman runtime preparation cancelled';
}

class JevmanRuntimeProgress {
  const JevmanRuntimeProgress(this.phase, this.downloadedBytes);
  final String phase;
  final int downloadedBytes;
  int get totalBytes => JevmanRuntime.archiveBytes;
}

class JevmanPreparedRuntime {
  const JevmanPreparedRuntime(this.directory);
  final Directory directory;
  String get nodePath => '${directory.path}/bin/node';
  String get licensePath => '${directory.path}/LICENSE';
}

/// Owns only a checksum-pinned Node installation, never a model or user Node.
class JevmanRuntime {
  JevmanRuntime(this.cacheRoot, {HttpClient Function()? createHttpClient})
    : _createHttpClient = createHttpClient ?? HttpClient.new;

  final Directory cacheRoot;
  final HttpClient Function() _createHttpClient;
  static const version = 'v24.21.0';
  static const archiveRoot = 'node-v24.21.0-darwin-arm64';
  static const archiveBytes = 52909993;
  static const archiveSha256 =
      'bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057';
  static const nodeSha256 =
      'e4b5a3af0e05c75de2eae013904145f40fe7fc2a6e6f17510128bf45cca4e79b';
  static const licenseSha256 =
      '5888dbb9a1d2b18f2c3e6c5f6af1b39de658372b402a0577b002777f14c62ace';
  static final archiveUrl = Uri.parse(
    'https://nodejs.org/dist/v24.21.0/$archiveRoot.tar.gz',
  );

  JevmanRuntimeStatus get status => _status;
  String? get lastError => _lastError;
  JevmanPreparedRuntime? get prepared => _prepared;
  JevmanRuntimeProgress? get progress => _progress;
  Stream<JevmanRuntimeProgress> get changes => _changes.stream;
  final _changes = StreamController<JevmanRuntimeProgress>.broadcast();
  JevmanRuntimeStatus _status = JevmanRuntimeStatus.idle;
  String? _lastError;
  JevmanPreparedRuntime? _prepared;
  JevmanRuntimeProgress? _progress;
  DecisionCancellation? _active;
  Completer<void>? _operation;
  Future<void>? _closing;

  void cancelPreparation() => _active?.cancel();

  Future<JevmanPreparedRuntime> prepare(
    DecisionCancellation cancellation,
  ) async {
    if (_closing != null) throw StateError('Jevman runtime is closed');
    if (_operation != null) throw StateError('Runtime preparation is active');
    final done = Completer<void>();
    _operation = done;
    final token = DecisionCancellation();
    _active = token;
    final unlink = cancellation.listen(token.cancel);
    Directory? staging;
    HttpClient? client;
    _status = JevmanRuntimeStatus.preparing;
    _lastError = null;
    _prepared = null;
    try {
      _checkCancelled(token);
      if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
        throw UnsupportedError('Jevman supports macOS arm64 only');
      }
      await cacheRoot.create(recursive: true);
      await _regularDirectory(cacheRoot);
      final target = Directory('${cacheRoot.path}/$archiveRoot');
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        await _regularDirectory(target);
        if (await _verified(target)) {
          _checkCancelled(token);
          _prepared = JevmanPreparedRuntime(target);
          _status = JevmanRuntimeStatus.ready;
          _report('reused', archiveBytes);
          return _prepared!;
        }
        // An unverified existing directory may belong to another operation.
        // Do not recursively erase it or load its executable.
        throw const FormatException('Cached Node SHA256 mismatch');
      }
      staging = await cacheRoot.createTemp('.jevman-node-');
      final archive = File('${staging.path}/node.tar.gz');
      client = _createHttpClient();
      final abortClient = token.listen(() => client?.close(force: true));
      try {
        final request = await client.getUrl(archiveUrl);
        final abortRequest = token.listen(request.abort);
        try {
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException('Node download HTTP ${response.statusCode}');
          }
          final sink = archive.openWrite();
          var bytes = 0;
          try {
            await for (final chunk in response) {
              _checkCancelled(token);
              bytes += chunk.length;
              if (bytes > archiveBytes) {
                throw const FormatException(
                  'Node archive SHA256/size mismatch',
                );
              }
              sink.add(chunk);
              _report('downloading', bytes);
            }
          } finally {
            await sink.close();
          }
          _checkCancelled(token);
          final digest = await sha256.bind(archive.openRead()).first;
          if (bytes != archiveBytes || digest.toString() != archiveSha256) {
            throw const FormatException('Node archive SHA256/size mismatch');
          }
        } finally {
          abortRequest();
        }
      } finally {
        abortClient();
        client.close(force: true);
      }
      _checkCancelled(token);
      _report('extracting', archiveBytes);
      // Extract exactly the two known regular members. npm's links, other
      // archive members and user-installed tools never participate.
      for (final member in ['bin/node', 'LICENSE']) {
        final listing = await Process.run('/usr/bin/tar', [
          '-tvzf',
          archive.path,
          '$archiveRoot/$member',
        ]);
        final lines = (listing.stdout as String).trim().split('\n');
        if (listing.exitCode != 0 ||
            lines.length != 1 ||
            !lines.single.startsWith('-')) {
          throw const FormatException(
            'Node archive member is not a regular file',
          );
        }
        _checkCancelled(token);
      }
      final extraction = await Process.run('/usr/bin/tar', [
        '-xzf',
        archive.path,
        '-C',
        staging.path,
        '$archiveRoot/bin/node',
        '$archiveRoot/LICENSE',
      ]);
      if (extraction.exitCode != 0) {
        throw ProcessException(
          '/usr/bin/tar',
          [],
          '${extraction.stderr}',
          extraction.exitCode,
        );
      }
      _checkCancelled(token);
      final installation = Directory('${staging.path}/$archiveRoot');
      if (!await _verified(installation)) {
        throw const FormatException('Extracted Node SHA256 mismatch');
      }
      _checkCancelled(token);
      await installation.rename(target.path);
      _prepared = JevmanPreparedRuntime(target);
      _status = JevmanRuntimeStatus.ready;
      _report('ready', archiveBytes);
      return _prepared!;
    } catch (error) {
      _prepared = null;
      if (token.isCancelled) {
        _status = JevmanRuntimeStatus.cancelled;
        _lastError = const JevmanRuntimeCancelled().toString();
        throw const JevmanRuntimeCancelled();
      }
      _status = JevmanRuntimeStatus.failed;
      _lastError = error.toString();
      rethrow;
    } finally {
      client?.close(force: true);
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      unlink();
      _active = null;
      _operation = null;
      done.complete();
    }
  }

  Future<bool> _verified(Directory directory) async {
    final bin = Directory('${directory.path}/bin');
    await _regularDirectory(bin);
    for (final entry in {
      'bin/node': nodeSha256,
      'LICENSE': licenseSha256,
    }.entries) {
      final file = File('${directory.path}/${entry.key}');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      if ((await sha256.bind(file.openRead()).first).toString() !=
          entry.value) {
        return false;
      }
    }
    return true;
  }

  Future<void> _regularDirectory(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Runtime cache must be a real directory');
    }
  }

  void _checkCancelled(DecisionCancellation token) {
    if (token.isCancelled) throw const JevmanRuntimeCancelled();
  }

  void _report(String phase, int bytes) {
    _progress = JevmanRuntimeProgress(phase, bytes);
    _changes.add(_progress!);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _active?.cancel();
    await _operation?.future;
    await _changes.close();
  }
}
