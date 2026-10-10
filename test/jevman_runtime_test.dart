import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';

void main() {
  test(
    'fixed official archive installs exactly Node and LICENSE and is reused',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-jevman-install-');
      addTearDown(() => root.delete(recursive: true));
      final archive = File(
        '.tooling/playground-source-preflight-20261009/node-v24.21.0-darwin-arm64.tar.gz',
      );
      var calls = 0;
      final runtime = JevmanRuntime(
        root,
        createHttpClient: () {
          calls += 1;
          // Existing SHA-verified host input is optional reuse. Clean machines
          // fetch the same complete official archive through ordinary HTTPS.
          return archive.existsSync() ? _ArchiveClient(archive) : HttpClient();
        },
      );
      addTearDown(runtime.close);
      final prepared = await runtime.prepare(DecisionCancellation());
      expect(runtime.status, JevmanRuntimeStatus.ready);
      expect(
        prepared.nodePath,
        endsWith('/node-v24.21.0-darwin-arm64/bin/node'),
      );
      expect(await File(prepared.nodePath).exists(), isTrue);
      expect(await File(prepared.licensePath).readAsString(), contains('Node'));
      final files = await prepared.directory.list(recursive: true).toList();
      expect(
        files.whereType<File>().map(
          (entry) => entry.path.substring(prepared.directory.path.length + 1),
        ),
        unorderedEquals(['bin/node', 'LICENSE']),
      );
      expect(files.whereType<Link>(), isEmpty);
      final version = await Process.run(prepared.nodePath, ['--version']);
      expect(version.exitCode, 0);
      expect((version.stdout as String).trim(), 'v24.21.0');
      final reused = await runtime.prepare(DecisionCancellation());
      expect(reused.nodePath, prepared.nodePath);
      expect(calls, 1);
      expect(runtime.progress?.phase, 'reused');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'pre-cancelled preparation preserves unrelated files and never downloads',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-jevman-cancel-');
      addTearDown(() => root.delete(recursive: true));
      final user = File('${root.path}/keep.txt');
      await user.writeAsString('keep');
      var calls = 0;
      final runtime = JevmanRuntime(
        root,
        createHttpClient: () {
          calls += 1;
          return _CorruptClient();
        },
      );
      addTearDown(runtime.close);
      final cancellation = DecisionCancellation()..cancel();
      await expectLater(
        runtime.prepare(cancellation),
        throwsA(isA<JevmanRuntimeCancelled>()),
      );
      expect(runtime.status, JevmanRuntimeStatus.cancelled);
      expect(runtime.prepared, isNull);
      expect(calls, 0);
      expect(await user.readAsString(), 'keep');
    },
  );

  test(
    'a symbolic runtime cache is rejected without touching its target',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-jevman-link-');
      final external = await Directory.systemTemp.createTemp(
        'gmd-jevman-external-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => external.delete(recursive: true));
      final keep = File('${external.path}/keep.txt');
      await keep.writeAsString('outside runtime ownership');
      await Link('${root.path}/node-v24.21.0-darwin-arm64')
          .create(external.path);
      final client = _CorruptClient();
      final runtime = JevmanRuntime(root, createHttpClient: () => client);
      addTearDown(runtime.close);
      await expectLater(
        runtime.prepare(DecisionCancellation()),
        throwsA(isA<FormatException>()),
      );
      expect(runtime.status, JevmanRuntimeStatus.failed);
      expect(client.requested, isEmpty);
      expect(await keep.readAsString(), 'outside runtime ownership');
      expect(
        await Link('${root.path}/node-v24.21.0-darwin-arm64').exists(),
        isTrue,
      );
    },
  );

  test(
    'corrupt Node download cannot become ready or delete unrelated data',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-jevman-runtime-');
      addTearDown(() => root.delete(recursive: true));
      final unrelated = File('${root.path}/retain.txt');
      await unrelated.writeAsString('unrelated user data');
      final client = _CorruptClient();
      final runtime = JevmanRuntime(root, createHttpClient: () => client);
      addTearDown(runtime.close);

      await expectLater(
        runtime.prepare(DecisionCancellation()),
        throwsA(isA<FormatException>()),
      );
      expect(runtime.status, JevmanRuntimeStatus.failed);
      expect(runtime.lastError, contains('SHA256'));
      expect(runtime.prepared, isNull);
      expect(client.requested, [
        Uri.parse(
          'https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz',
        ),
      ]);
      expect(client.closed, isTrue);
      expect(await unrelated.readAsString(), 'unrelated user data');
      expect(
        await root.list().map((entry) => entry.path.split('/').last).toList(),
        ['retain.txt'],
      );
    },
  );
}

class _ArchiveClient implements HttpClient {
  _ArchiveClient(this.archive);
  final File archive;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ArchiveRequest(archive);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ArchiveRequest implements HttpClientRequest {
  _ArchiveRequest(this.archive);
  final File archive;
  @override
  Future<HttpClientResponse> close() async => _ArchiveResponse(archive);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ArchiveResponse extends Stream<List<int>> implements HttpClientResponse {
  _ArchiveResponse(this.archive);
  final File archive;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => archive.lengthSync();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => archive.openRead().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CorruptClient implements HttpClient {
  final requested = <Uri>[];
  bool closed = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    return _CorruptRequest();
  }

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CorruptRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _CorruptResponse();

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CorruptResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => 4;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value([0, 1, 2, 3]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
