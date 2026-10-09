import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owns external storage/network boundaries for the unchanged production app.
class ActualAppEnvironment {
  ActualAppEnvironment._(this._root, this._previous, this._io);
  final Directory _root;
  final IOOverrides? _previous;
  final _ActualAppIO _io;

  static Future<ActualAppEnvironment> create() async {
    final root = await Directory.systemTemp.createTemp('gmd-actual-app-');
    final previous = IOOverrides.current;
    final io = _ActualAppIO(root.path);
    IOOverrides.global = io;
    return ActualAppEnvironment._(root, previous, io);
  }

  Future<void> close() async {
    IOOverrides.global = _previous;
    ({Object error, StackTrace stack})? failure;
    try {
      expect(_io.sharedConnections, isEmpty);
      expect(_io.sdkConnections, isNotEmpty);
      expect(_io.listenerPorts, hasLength(2));
      expect(_io.storagePaths, isNotEmpty);
      expect(
        _io.storagePaths.every((path) => path.startsWith('${_root.path}/')),
        isTrue,
      );
      expect(
        _io.sdkConnections.every((path) => path == '${_root.path}/sdk.sock'),
        isTrue,
      );
      expect(
        _io.listenerPorts.every((port) => port != 54841 && port != 54842),
        isTrue,
      );
    } catch (error, stack) {
      failure = (error: error, stack: stack);
    }
    try {
      await _root.delete(recursive: true);
    } catch (error, stack) {
      if (failure == null) {
        Error.throwWithStackTrace(error, stack);
      }
      stderr.writeln('Actual app fixture cleanup also failed: $error\n$stack');
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }
}

/// Route only external user storage and sockets; the real app graph is intact.
final class _ActualAppIO extends IOOverrides {
  _ActualAppIO(this.root);
  final String root;
  final sharedConnections = <int>[];
  final sdkConnections = <String>[];
  final listenerPorts = <int>[];
  final storagePaths = <String>[];

  String _path(String path) {
    final home = Platform.environment['HOME']!;
    for (final prefix in [
      '$home/Library/Application Support/GhostModelDeck',
      '$home/Library/Application Support/MacLauncher',
      '$home/Models/GhostModelDeck',
      '$home/.lmstudio/models',
      '$home/.cache/lm-studio/models',
    ]) {
      if (path == prefix || path.startsWith('$prefix/')) {
        final redirected = '$root${path.substring(home.length)}';
        storagePaths.add(redirected);
        return redirected;
      }
    }
    return path;
  }

  @override
  File createFile(String path) => super.createFile(_path(path));
  @override
  Directory createDirectory(String path) => super.createDirectory(_path(path));

  Object? _host(Object? host, int port) {
    if (port == 54841 || port == 54842) {
      sharedConnections.add(port);
      throw StateError('导航 fixture 不得连接其他会话的公开服务');
    }
    if (host is InternetAddress && host.type == InternetAddressType.unix) {
      final mapped = '$root/sdk.sock';
      sdkConnections.add(mapped);
      host = InternetAddress(mapped, type: InternetAddressType.unix);
    }
    return host;
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    Object? host,
    int port, {
    Object? sourceAddress,
    int sourcePort = 0,
  }) => super.socketStartConnect(
    _host(host, port),
    port,
    sourceAddress: sourceAddress,
    sourcePort: sourcePort,
  );

  @override
  Future<Socket> socketConnect(
    Object? host,
    int port, {
    Object? sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) => super.socketConnect(
    _host(host, port),
    port,
    sourceAddress: sourceAddress,
    sourcePort: sourcePort,
    timeout: timeout,
  );

  @override
  Future<ServerSocket> serverSocketBind(
    Object? address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) async {
    final listener = await super.serverSocketBind(
      address,
      port == 54841 || port == 54842 ? 0 : port,
      backlog: backlog,
      v6Only: v6Only,
      shared: shared,
    );
    listenerPorts.add(listener.port);
    return listener;
  }
}
