import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/manager_lifecycle.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_package.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'fixtures/council_runtime.dart';

Future<McpClient> _client(Uri endpoint) async {
  final client = McpClient(
    const Implementation(name: 'lifecycle-test', version: '1'),
  );
  await client.connect(StreamableHttpClientTransport(endpoint));
  return client;
}

void main() {
  test('a real installation rollback failure rejects exit after the remaining files and services are cleaned up', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await mcp.start();
    final models = Directory('${runtime.root.path}/pending-download');
    final formal = Directory('${models.path}/publisher/model');
    await formal.create(recursive: true);
    final shared = File('${formal.path}/Model-00001-of-00032.gguf');
    await shared.writeAsString('abc');
    final sharedModified = (await shared.stat()).modified;
    late File removedTemporary;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.pathSegments.last == 'Model-00032-of-00032.gguf') {
        removedTemporary =
            (await Directory('${models.path}/.ghostmodeldeck/downloads')
                        .list(recursive: true)
                        .where(
                          (entry) => entry.path.endsWith(
                            '/Model-00003-of-00032.gguf.part',
                          ),
                        )
                        .toList())
                    .single
                as File;
      }
      request.response.write('abc');
      await request.response.close();
    });
    final downloader = ModelDownloader(
      hfEndpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(() async {
      // A rejected terminal close is expected for this deliberately damaged FS.
      await downloader.close().then<void>((_) {}, onError: (Object _) {});
    });
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: downloader,
    );
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: '0123456789012345678901234567890123456789',
      requestedRevision: 'main',
      source: Uri.parse('http://127.0.0.1:${server.port}'),
      files: [
        for (var i = 1; i <= 32; i++)
          HfModelFile(
            path: 'Model-${i.toString().padLeft(5, '0')}-of-00032.gguf',
            sizeBytes: 3,
            sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          ),
      ],
    );
    final package = ModelPackage.discover(repository).single;
    final shutdownStarted = Completer<void>();
    Future<void>? shutdown;
    var activeAtExit = false;
    final changesFinished = Completer<void>();
    final changes = downloader.changes.listen(
      (_) {},
      onDone: changesFinished.complete,
    );
    addTearDown(changes.cancel);
    final blocked = File('${formal.path}/Model-00003-of-00032.gguf');
    final watch = formal.watch(events: FileSystemEvent.create).listen((event) {
      if (event.path == blocked.path && !shutdownStarted.isCompleted) {
        activeAtExit = downloader.state.isActive;
        // Interference at the real FS boundary makes rollback's identity check
        // fail. Other newly linked files must still be removed safely.
        removedTemporary.deleteSync();
        shutdown = manager.shutdown();
        shutdown!.ignore();
        shutdownStarted.complete();
      }
    });
    addTearDown(watch.cancel);
    final transfer = downloader
        .downloadPackage(
          selection: package.selectVariant(package.variants.single.id),
          currentRepository: repository,
          libraryDirectory: models,
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await shutdownStarted.future.timeout(const Duration(seconds: 5));
    await expectLater(
      shutdown!.timeout(const Duration(seconds: 5)),
      throwsStateError,
    );
    expect(activeAtExit, isTrue);
    expect(await transfer, isNotNull);
    expect(manager.state, ManagerLifecycleState.failed);
    expect(manager.error, contains('下载'));
    expect(manager.error, contains('Model-00003-of-00032.gguf.part'));
    expect(changesFinished.isCompleted, isTrue);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(runtime.io.killedChildren, 2);
    expect((await formal.list().toList()).map((file) => file.path).toSet(), {
      shared.path,
      blocked.path,
    });
    expect(await shared.readAsString(), 'abc');
    expect((await shared.stat()).modified, sharedModified);
    final receipts = Directory('${models.path}/.ghostmodeldeck/installations');
    expect(
      await receipts.exists()
          ? await receipts.list().toList()
          : <FileSystemEntity>[],
      isEmpty,
    );
    await expectLater(downloader.close(), throwsA(isA<Exception>()));
  });

  test('explicit exit during installation waits for rollback and preserves the identical shared file', () async {
    final runtime = await CouncilRuntime.create(modelCount: 0);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('abc');
      await request.response.close();
    });
    final downloader = ModelDownloader(
      hfEndpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(downloader.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: downloader,
    );
    final models = Directory('${runtime.root.path}/pending-download');
    final formal = Directory('${models.path}/publisher/model');
    await formal.create(recursive: true);
    final shared = File('${formal.path}/Model-00001-of-00032.gguf');
    await shared.writeAsString('abc');
    final sharedModified = (await shared.stat()).modified;
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: '0123456789012345678901234567890123456789',
      requestedRevision: 'main',
      source: Uri.parse('http://127.0.0.1:${server.port}'),
      files: [
        for (var i = 1; i <= 32; i++)
          HfModelFile(
            path: 'Model-${i.toString().padLeft(5, '0')}-of-00032.gguf',
            sizeBytes: 3,
            sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          ),
      ],
    );
    final package = ModelPackage.discover(repository).single;
    final shutdownStarted = Completer<void>();
    Future<void>? shutdown;
    var activeAtExit = false;
    var transferFinished = false;
    final watch = formal.watch(events: FileSystemEvent.create).listen((event) {
      if (event.path.endsWith('.gguf') && !shutdownStarted.isCompleted) {
        activeAtExit = downloader.state.isActive;
        shutdown = manager.shutdown();
        shutdownStarted.complete();
      }
    });
    addTearDown(watch.cancel);
    final transfer = downloader
        .downloadPackage(
          selection: package.selectVariant(package.variants.single.id),
          currentRepository: repository,
          libraryDirectory: models,
        )
        .whenComplete(() => transferFinished = true);
    await shutdownStarted.future.timeout(const Duration(seconds: 5));
    await shutdown!.timeout(const Duration(seconds: 5));
    expect(activeAtExit, isTrue);
    expect(transferFinished, isTrue);
    await transfer;
    expect(manager.state, ManagerLifecycleState.stopped);
    expect((await formal.list().toList()).map((file) => file.path), [
      shared.path,
    ]);
    expect(await shared.readAsString(), 'abc');
    expect((await shared.stat()).modified, sharedModified);
    final receipts = Directory('${models.path}/.ghostmodeldeck/installations');
    expect(
      await receipts.exists()
          ? await receipts.list().toList()
          : <FileSystemEntity>[],
      isEmpty,
    );
  });

  test('explicit shutdown drains desktop and two MCP callers, rejects new work and preserves a foreign endpoint', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    await council.models.save(
      JevModelDefinition.council(
        name: 'test-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await mcp.start();
    final first = await _client(mcp.endpoint!),
        second = await _client(mcp.endpoint!);
    addTearDown(first.close);
    addTearDown(second.close);
    final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => foreign.close(force: true));
    foreign.listen((request) async {
      request.response.write('foreign still running');
      await request.response.close();
    });
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: ModelDownloader(),
    );
    runtime.io.holdConsultation();
    final desktop = council.consult(
      state: 'desktop-inflight',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    Map<String, dynamic> args(String state) => {
      'model': 'test-council',
      'state': state,
      'options': [
        {'id': 'accept', 'text': '接受'},
        {'id': 'reject', 'text': '拒绝'},
      ],
    };
    final firstCall = first
        .callTool(
          CallToolRequest(name: 'decide_jev', arguments: args('mcp-first')),
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    final secondCall = second
        .callTool(
          CallToolRequest(name: 'decide_jev', arguments: args('mcp-second')),
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    final watch = Stopwatch()..start();
    while (runtime.io.requests.length < 6 || mcp.state.activeRequests < 2) {
      if (watch.elapsed > const Duration(seconds: 3)) {
        throw StateError('Callers did not reach external decision I/O');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final shutdown = manager.shutdown();
    final repeated = manager.shutdown();
    shutdown.ignore();
    repeated.ignore();
    expect(identical(shutdown, repeated), isTrue);
    await expectLater(
      council.consult(state: 'new', options: {'accept': '接受', 'reject': '拒绝'}),
      throwsStateError,
    );
    await expectLater(
      runtime.catalog
          .providerFor(EngineCatalog.officialId)
          .start(runtime.library.state.artifacts.first.id),
      throwsStateError,
    );
    await shutdown.timeout(const Duration(seconds: 3));
    final cancelled = await desktop;
    expect(
      cancelled.seats.every(
        (seat) => seat.status == CouncilSeatStatus.cancelled,
      ),
      isTrue,
    );
    await Future.wait([firstCall, secondCall]);
    expect(council.state.busy, isFalse);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(mcp.state.activeRequests, 0);
    expect(runtime.io.killedChildren, 2);
    expect(manager.state, ManagerLifecycleState.stopped);
    final client = HttpClient();
    try {
      expect(
        await utf8.decoder
            .bind(
              await (await client.getUrl(
                Uri.parse('http://127.0.0.1:${foreign.port}'),
              )).close(),
            )
            .join(),
        'foreign still running',
      );
    } finally {
      client.close(force: true);
    }
  });

  test('shutdown awaits an in-flight spawn handle then stops its late child without waiting for cold load', () async {
    final io = _HeldSpawnIO();
    final runtime = await CouncilRuntime.create(modelCount: 1, processIO: io);
    addTearDown(runtime.close);
    await runtime.catalog.stopManaged();
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: ModelDownloader(),
    );
    io.hold = true;
    final starting = runtime.engine
        .start(runtime.library.state.artifacts.single.id)
        .then<Object>((value) => value, onError: (Object error) => error);
    await io.spawned.future.timeout(const Duration(seconds: 2));
    var finished = false;
    final shutdown = manager.shutdown();
    shutdown.ignore();
    shutdown.then((_) => finished = true, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(finished, isFalse);
    io.releaseHandle.complete();

    await shutdown.timeout(const Duration(milliseconds: 700));

    expect(await starting, isA<Exception>());
    expect(io.killedChildren, 2);
    expect(runtime.engine.hasLiveInstances, isFalse);
    expect(manager.state, ManagerLifecycleState.stopped);
  });

  test('queued MCP start and direct service restart are rejected once explicit exit begins', () async {
    final runtime = await CouncilRuntime.create(modelCount: 0);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: ModelDownloader(),
    );
    final queued = mcp.start();
    queued.ignore();
    final shutdown = manager.shutdown();
    await expectLater(queued, throwsStateError);
    await expectLater(mcp.start(), throwsStateError);
    await expectLater(runtime.catalog.refresh(), throwsStateError);
    await shutdown;
    expect(mcp.endpoint, isNull);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(manager.state, ManagerLifecycleState.stopped);
  });

  test('a child cleanup failure is reported after the remaining owned child and MCP have been stopped', () async {
    final io = _KillFailureIO();
    final runtime = await CouncilRuntime.create(processIO: io);
    addTearDown(() async {
      io.failKills = false;
      await runtime.close();
    });
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    await mcp.start();
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: ModelDownloader(),
    );

    final attempt = manager.shutdown();
    await expectLater(attempt, throwsStateError);

    expect(manager.state, ManagerLifecycleState.failed);
    expect(manager.error, contains('simulated OS refusal'));
    expect(runtime.io.killedChildren, 1);
    expect(runtime.engine.hasLiveInstances, isTrue);
    expect(mcp.state.status, CouncilMcpStatus.stopped);
    expect(council.state.busy, isFalse);
    expect(identical(manager.shutdown(), attempt), isTrue);
    await expectLater(manager.shutdown(), throwsStateError);
  });

  test('exit during real model verification drains the file work and never creates a new child', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    await runtime.catalog.stopManaged();
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    addTearDown(mcp.close);
    final manager = ManagerLifecycle(
      council: council,
      mcp: mcp,
      engines: runtime.catalog,
      downloader: ModelDownloader(),
    );
    final exiting = Completer<Future<void>>();
    final subscription = runtime.library.changes.listen((state) {
      if (state.scanning && !exiting.isCompleted) {
        exiting.complete(manager.shutdown());
      }
    });
    addTearDown(subscription.cancel);
    final starting = runtime.engine
        .start(runtime.library.state.artifacts.single.id)
        .then<Object>((value) => value, onError: (Object error) => error);

    final shutdown = await exiting.future.timeout(const Duration(seconds: 2));
    await shutdown.timeout(const Duration(seconds: 2));

    expect(await starting, isA<LlamaEngineException>());
    expect(runtime.io.killedChildren, 1);
    expect(runtime.engine.hasLiveInstances, isFalse);
    expect(runtime.library.state.scanning, isFalse);
    expect(manager.state, ManagerLifecycleState.stopped);
  });
}

class _HeldSpawnIO extends CouncilRuntimeIO {
  bool hold = false;
  final spawned = Completer<void>();
  final releaseHandle = Completer<void>();
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    final child = await super.start(executable, arguments);
    if (hold) {
      spawned.complete();
      await releaseHandle.future;
      final alias = arguments[arguments.indexOf('--alias') + 1];
      await closeEndpoint(alias);
    }
    return child;
  }
}

class _KillFailureIO extends CouncilRuntimeIO {
  bool failKills = true;
  int children = 0;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    final child = await super.start(executable, arguments);
    return ++children == 1 ? _KillFailureChild(child, this) : child;
  }
}

class _KillFailureChild implements EngineChild {
  _KillFailureChild(this.child, this.owner);
  final EngineChild child;
  final _KillFailureIO owner;
  @override
  int get pid => child.pid;
  @override
  Future<int> get exitCode => child.exitCode;
  @override
  Stream<List<int>> get stdout => child.stdout;
  @override
  Stream<List<int>> get stderr => child.stderr;
  @override
  bool kill(ProcessSignal signal) {
    if (owner.failKills) {
      throw const ProcessException('kill', [], 'simulated OS refusal');
    }
    return child.kill(signal);
  }
}
