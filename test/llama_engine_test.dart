import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';

import 'fixtures/decision_gguf.dart';

void main() {
  test('single instance stop seals an accepted spawn and cleans its late child without touching the peer', () async {
    final fixture = await _Fixture.create(ordinaryChat: true);
    addTearDown(fixture.close);
    final peer = await fixture.engine.start(fixture.asset.id);
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    fixture.io.holdSpawn = () async {
      arrived.complete();
      await release.future;
    };
    final starting = fixture.engine
        .start(fixture.asset.id)
        .then<Object>((value) => value, onError: (Object error) => error);
    await arrived.future;
    final pending = fixture.engine.state.instances.last;
    expect(pending.status, LlamaInstanceStatus.starting);
    expect(pending.hasLiveProcess, isFalse);
    final stopping = fixture.engine
        .stop(pending.id)
        .then<Object>((_) => 'stopped', onError: (Object error) => error);
    expect(
      fixture.engine.state.instances.last.status,
      LlamaInstanceStatus.stopping,
    );
    release.complete();
    expect(
      await starting,
      isA<LlamaEngineException>().having(
        (e) => e.message,
        'message',
        contains('取消'),
      ),
    );
    expect(await stopping, 'stopped');
    expect(fixture.io.children.last.exited.isCompleted, isTrue);
    expect(fixture.io.textRequests, 1);
    final stopped = fixture.engine.state.instances.firstWhere(
      (i) => i.id == pending.id,
    );
    expect(stopped.status, LlamaInstanceStatus.stopped);
    expect(stopped.capabilities, isEmpty);
    expect(stopped.hasLiveProcess, isFalse);
    expect(
      fixture.engine.state.instances.first.status,
      LlamaInstanceStatus.ready,
    );
    expect(fixture.engine.state.instances.first.pid, peer.pid);
    expect(fixture.io.children.first.exited.isCompleted, isFalse);
    expect(
      (await fixture.engine.generateText(
        peer.id,
        TextRequest(prompt: 'peer'),
      )).text,
      'Hello.',
    );
    await expectLater(
      fixture.library.prepareDeletion([fixture.asset.id]),
      throwsA(isA<LibraryException>()),
    );
    fixture.io.holdSpawn = null;
    final restarted = await fixture.engine.start(fixture.asset.id);
    expect(restarted.id, isNot(pending.id));
    expect(pending.generation, greaterThan(peer.generation));
    expect(restarted.generation, greaterThan(pending.generation));
    expect(stopped.generation, pending.generation);
    expect(restarted.status, LlamaInstanceStatus.ready);
  });

  test('stopManaged cancels an active readiness probe without waiting for its response', () async {
    final fixture = await _Fixture.create(ordinaryChat: true);
    addTearDown(fixture.close);
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    fixture.io.holdText = (_) async {
      arrived.complete();
      await release.future;
    };
    final starting = fixture.engine
        .start(fixture.asset.id)
        .then<Object>((value) => value, onError: (Object error) => error);
    await arrived.future;
    final stopping = fixture.engine.stopManaged();
    final result = await starting;
    expect(
      result,
      isA<LlamaEngineException>().having(
        (e) => e.message,
        'message',
        contains('取消'),
      ),
    );
    await stopping;
    expect(fixture.io.children.single.exited.isCompleted, isTrue);
    release.complete();
    expect(fixture.engine.state.instances.single.capabilities, isEmpty);
  });
  test(
    'stopManaged seals accepted starts and cleans a late spawn before restart',
    () async {
      final fixture = await _Fixture.create(ordinaryChat: true);
      addTearDown(fixture.close);
      final spawned = Completer<void>();
      final release = Completer<void>();
      fixture.io.holdSpawn = () async {
        spawned.complete();
        await release.future;
      };
      final starting = fixture.engine
          .start(fixture.asset.id)
          .then<Object>((value) => value, onError: (Object error) => error);
      await spawned.future;
      final stopping = fixture.engine.stopManaged();
      final refused = fixture.engine
          .start(fixture.asset.id)
          .then<Object>((value) => value, onError: (Object error) => error);
      release.complete();
      expect(await starting, isA<LlamaEngineException>());
      await stopping;
      expect(await refused, isA<LlamaEngineException>());
      expect(
        fixture.engine.state.instances.every(
          (i) => i.status != LlamaInstanceStatus.ready,
        ),
        isTrue,
      );
      expect(fixture.io.children.single.exited.isCompleted, isTrue);
      expect(fixture.io.textRequests, 0);
      fixture.io.holdSpawn = null;
      final restarted = await fixture.engine.start(fixture.asset.id);
      expect(restarted.status, LlamaInstanceStatus.ready);
      expect(fixture.io.children.last.exited.isCompleted, isFalse);
    },
  );
  test('stopping one instance drains its request before kill and preserves its peer', () async {
    final fixture = await _Fixture.create(ordinaryChat: true);
    addTearDown(fixture.close);
    final first = await fixture.engine.start(fixture.asset.id);
    final peer = await fixture.engine.start(fixture.asset.id);
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    fixture.io.holdText = (body) async {
      if ((body['messages'] as List).single['content'] == 'held') {
        arrived.complete();
        await release.future;
      }
    };
    var settled = false;
    var drainedAtKill = false;
    fixture.io.children.first.onKill = () {
      drainedAtKill = settled;
    };
    final pending = fixture.engine.generateText(
      first.id,
      TextRequest(prompt: 'held'),
    );
    final outcome = pending.then<Object>(
      (value) {
        settled = true;
        return value;
      },
      onError: (Object error) {
        settled = true;
        return error;
      },
    );
    await arrived.future;
    await fixture.engine.stop(first.id);
    release.complete();
    final result = await outcome;
    expect(
      result,
      isA<LlamaRequestException>().having(
        (e) => e.kind,
        'kind',
        DecisionFailureKind.cancelled,
      ),
    );
    expect(drainedAtKill, isTrue);
    await expectLater(
      fixture.engine.generateText(first.id, TextRequest(prompt: 'rejected')),
      throwsA(isA<LlamaRequestException>()),
    );
    expect(
      (await fixture.engine.generateText(
        peer.id,
        TextRequest(prompt: 'peer'),
      )).text,
      'Hello.',
    );
    expect(fixture.engine.state.instances.last.pid, peer.pid);
    expect(
      fixture.engine.state.instances.last.status,
      LlamaInstanceStatus.ready,
    );
    expect(fixture.io.children.last.exited.isCompleted, isFalse);
    expect(fixture.io.textRequests, 4);
    await expectLater(
      fixture.library.prepareDeletion([fixture.asset.id]),
      throwsA(isA<LibraryException>()),
    );
  });
  test('a healthy text endpoint with an unbound or non-generation response never earns readiness', () async {
    for (final raw in [
      '{"model":"foreign","choices":[{"index":0,"message":{"role":"assistant","content":"Hello."},"finish_reason":"stop"}],"usage":{"completion_tokens":2}}',
      '{"model":"ALIAS","choices":[{"index":0,"message":{"role":"assistant","content":"Hello."},"finish_reason":"stop"}],"usage":{"completion_tokens":0}}',
      '{"model":"ALIAS","answers":{"council_choice":{"type":"choice","choice":"yes","probabilities":{"yes":0.5,"no":0.5}}},"usage":{"output_tokens":0}}',
    ]) {
      final fixture = await _Fixture.create(ordinaryChat: true);
      addTearDown(fixture.close);
      fixture.io.textResponseOverride = raw;
      await expectLater(
        fixture.engine.start(fixture.asset.id),
        throwsA(isA<LlamaEngineException>()),
      );
      final instance = fixture.engine.state.instances.single;
      expect(instance.status, LlamaInstanceStatus.failed);
      expect(instance.capabilities, isEmpty);
      expect(instance.lastTextResult, isNull);
      expect(await fixture.io.child!.exitCode, 0);
      expect(
        (await fixture.library.prepareDeletion([fixture.asset.id]))
            .files
            .single
            .path,
        fixture.asset.files.single.path,
      );
      expect(await File(fixture.asset.files.single.path).exists(), isTrue);
    }
  });
  test('a resident text instance serves explicit text requests but never becomes a council seat', () async {
    final fixture = await _Fixture.create(ordinaryChat: true);
    addTearDown(fixture.close);
    final catalog = EngineCatalog(
      library: fixture.library,
      officialEngine: fixture.engine,
      useRegistry: fixture.engine.useRegistry,
      registryFile: File('${fixture.root.path}/registry.json'),
    );
    addTearDown(catalog.close);
    final council = CouncilController(catalog: catalog);
    addTearDown(council.close);
    final instance = await fixture.engine.start(fixture.asset.id);
    expect(council.availableSeats, isEmpty);
    expect(
      () => council.selectSeats(['${EngineCatalog.officialId}/${instance.id}']),
      throwsA(isA<DecisionProtocolException>()),
    );
    final text = await fixture.engine.generateText(
      instance.id,
      TextRequest(prompt: 'Hello'),
    );
    expect(text.text, 'Hello.');
    expect(text.outputTokens, 2);
    expect(text.model, instance.id);
    expect(text.rawResponse, contains('completion_tokens'));
    expect(fixture.io.textRequests, 2);
    expect(fixture.io.decisionRequests, 0);
    await fixture.engine.stop(instance.id);
    await expectLater(
      fixture.engine.generateText(instance.id, TextRequest(prompt: 'Hello')),
      throwsA(isA<LlamaRequestException>()),
    );
    expect(fixture.io.textRequests, 2);
  });
  test('ordinary GGUF becomes ready through actual bound text generation but cannot answer probability decisions', () async {
    final fixture = await _Fixture.create(ordinaryChat: true);
    addTearDown(fixture.close);
    expect(fixture.asset.kind, AssetKind.chat);
    final instance = await fixture.engine.start(fixture.asset.id);
    expect(instance.status, LlamaInstanceStatus.ready);
    expect(instance.lastResult, isNull);
    expect(fixture.io.textRequests, 1);
    expect(fixture.io.decisionRequests, 0);
    await expectLater(
      fixture.engine.decide(
        instance.id,
        DecisionRequest(
          state: '',
          instructions: 'Choose',
          options: {'yes': 'Yes', 'no': 'No'},
        ),
      ),
      throwsA(isA<LlamaRequestException>()),
    );
    expect(fixture.io.decisionRequests, 0);
  });
  test('verified release publishes a version checked installation and refuses a corrupt replacement', () async {
    final root = await Directory.systemTemp.createTemp('jev-llama-install-');
    addTearDown(() => root.delete(recursive: true));
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(_archive());
    final release = LlamaRelease(
      tag: 'b11381',
      commit: '836d57176',
      url: Uri.parse(
        'https://github.com/ggml-org/llama.cpp/releases/download/b11381/fixture.tar.gz',
      ),
      sha256: sha256.convert(await archive.readAsBytes()).toString(),
      sizeBytes: await archive.length(),
    );
    final library = ModelLibrary();
    addTearDown(library.close);
    final io = _InstallIO();
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      release: release,
    );

    await engine.install(verifiedArchive: archive);
    expect(engine.observedVersion, contains('build 11381, commit 836d57176'));
    final binary = File(engine.executablePath!);
    expect(await binary.readAsString(), 'server fixture');
    final previous = engine.executablePath;
    final corrupted = await archive.readAsBytes();
    corrupted[5] ^= 1;
    await archive.writeAsBytes(corrupted);
    await expectLater(
      engine.install(verifiedArchive: archive),
      throwsA(isA<Exception>()),
    );
    expect(engine.executablePath, previous);
    expect(await binary.readAsString(), 'server fixture');
    expect(io.versions, 1);
  });

  test('a verified model becomes ready only after a bound typed response and remains protected until its owned child stops', () async {
    final root = await Directory.systemTemp.createTemp('jev-llama-start-');
    addTearDown(() => root.delete(recursive: true));
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models);
    final library = ModelLibrary();
    addTearDown(library.close);
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(_archive());
    final io = _InstallIO();
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
        sizeBytes: await archive.length(),
      ),
    );
    addTearDown(engine.close);
    await engine.install(verifiedArchive: archive);

    final instance = await engine.start(asset.id);
    expect(instance.status, LlamaInstanceStatus.ready);
    expect(instance.pid, 12345);
    expect(instance.properties['model_path'], asset.files.single.path);
    expect(instance.lastResult!.probabilities, {'keep': 0.25, 'change': 0.75});
    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    final result = await engine.decide(
      instance.id,
      DecisionRequest(
        state: '中文上下文',
        instructions: '遵循规则',
        options: {'yes': '执行', 'no': '拒绝'},
      ),
    );
    expect(result.probabilities, {'yes': 0.25, 'no': 0.75});
    await engine.stop(instance.id);
    expect(engine.state.instances.single.status, LlamaInstanceStatus.stopped);
    expect(await io.child!.exitCode, 0);
    expect(
      (await library.prepareDeletion([asset.id])).files.single.path,
      asset.files.single.path,
    );
  });

  test('spawn failure leaves a failed launch and releases the model without claiming readiness', () async {
    final root = await Directory.systemTemp.createTemp('jev-llama-spawn-');
    addTearDown(() => root.delete(recursive: true));
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models);
    final library = ModelLibrary();
    addTearDown(library.close);
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(_archive());
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: _InstallIO()..failSpawn = true,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
        sizeBytes: await archive.length(),
      ),
    );
    addTearDown(engine.close);
    await engine.install(verifiedArchive: archive);

    await expectLater(
      engine.start(asset.id),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(engine.state.instances.single.status, LlamaInstanceStatus.failed);
    expect(engine.state.instances.single.pid, isNull);
    expect(
      (await library.prepareDeletion([asset.id])).files.single.path,
      asset.files.single.path,
    );
  });

  test('invalid probabilities fail only that request and preserve the resident model', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final instance = await fixture.engine.start(fixture.asset.id);
    fixture.io.invalidProbabilities = true;
    await expectLater(
      fixture.engine.decide(
        instance.id,
        DecisionRequest(
          state: '',
          instructions: 'Choose',
          options: {'yes': 'Yes', 'no': 'No'},
        ),
      ),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(
      fixture.engine.state.instances.single.status,
      LlamaInstanceStatus.ready,
    );
    expect(fixture.io.child!.exited.isCompleted, isFalse);
    expect(fixture.engine.state.instances.single.pid, instance.pid);
    await expectLater(
      fixture.library.prepareDeletion([fixture.asset.id]),
      throwsA(isA<Exception>()),
    );
    fixture.io.invalidProbabilities = false;
    final next = await fixture.engine.decide(
      instance.id,
      DecisionRequest(
        state: '',
        instructions: 'Choose',
        options: {'yes': 'Yes', 'no': 'No'},
      ),
    );
    expect(next.choice, 'no');
    await fixture.engine.stop(instance.id);
    expect(
      (await fixture.library.prepareDeletion([fixture.asset.id])).files,
      hasLength(1),
    );
  });

  test(
    'a changed instance identity invalidates and stops only the owned child',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final instance = await fixture.engine.start(fixture.asset.id);
      fixture.io.foreignEndpoint = true;
      await expectLater(
        fixture.engine.decide(
          instance.id,
          DecisionRequest(
            state: '',
            instructions: 'Choose',
            options: {'yes': 'Yes', 'no': 'No'},
          ),
        ),
        throwsA(isA<LlamaEngineException>()),
      );
      expect(
        fixture.engine.state.instances.single.status,
        LlamaInstanceStatus.failed,
      );
      expect(fixture.engine.state.instances.single.error, contains('alias'));
      expect(await fixture.io.child!.exitCode, 0);
      expect(
        (await fixture.library.prepareDeletion([fixture.asset.id])).files,
        hasLength(1),
      );
    },
  );

  test('healthy foreign endpoint cannot become owned ready and is not stopped by failed launch cleanup', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    fixture.io.foreignEndpoint = true;
    await expectLater(
      fixture.engine.start(fixture.asset.id),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(
      fixture.engine.state.instances.single.status,
      LlamaInstanceStatus.failed,
    );
    expect(fixture.engine.state.instances.single.error, '引擎实际 alias 或模型路径不匹配');
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${fixture.io.child!.server.port}/health'),
      )).close();
      expect(response.statusCode, 200);
      expect(await utf8.decoder.bind(response).join(), '{"status":"ok"}');
    } finally {
      client.close(force: true);
    }
    expect(
      (await fixture.library.prepareDeletion([fixture.asset.id])).files,
      hasLength(1),
    );
  });

  test(
    'failed owned stop preserves the residual and peer until explicit retry',
    () async {
      final fixture = await _Fixture.create(ordinaryChat: true);
      addTearDown(fixture.close);
      final a = await fixture.engine.start(fixture.asset.id);
      final b = await fixture.engine.start(fixture.asset.id);
      expect(a.pid, isNot(b.pid));
      fixture.io.children.first.onKill = () =>
          throw StateError('owned stop refused');
      await expectLater(fixture.engine.stop(a.id), throwsA(isA<StateError>()));
      final residual = fixture.engine.state.instances.firstWhere(
        (i) => i.id == a.id,
      );
      expect(residual.status, LlamaInstanceStatus.failed);
      expect(residual.hasLiveProcess, isTrue);
      expect(residual.pid, a.pid);
      expect(residual.capabilities, isEmpty);
      expect(residual.acceptingRequests, isFalse);
      expect(residual.activeRequests, 0);
      expect(residual.error, contains('owned stop refused'));
      expect(fixture.io.children.first.exited.isCompleted, isFalse);
      expect(fixture.io.children.last.exited.isCompleted, isFalse);
      await expectLater(
        fixture.engine.generateText(a.id, TextRequest(prompt: 'rejected')),
        throwsA(
          isA<LlamaRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.notReady,
          ),
        ),
      );
      await expectLater(
        fixture.library.prepareDeletion([fixture.asset.id]),
        throwsA(isA<LibraryException>()),
      );
      expect(
        (await fixture.engine.generateText(
          b.id,
          TextRequest(prompt: 'peer'),
        )).text,
        'Hello.',
      );
      fixture.io.children.first.onKill = null;
      await fixture.engine.stop(a.id);
      final stopped = fixture.engine.state.instances.firstWhere(
        (i) => i.id == a.id,
      );
      expect(stopped.status, LlamaInstanceStatus.stopped);
      expect(stopped.hasLiveProcess, isFalse);
      expect(stopped.capabilities, isEmpty);
      final peer = fixture.engine.state.instances.firstWhere(
        (i) => i.id == b.id,
      );
      expect(peer.status, LlamaInstanceStatus.ready);
      expect(peer.pid, b.pid);
      expect(peer.hasLiveProcess, isTrue);
      expect(fixture.io.children.last.exited.isCompleted, isFalse);
      await expectLater(
        fixture.library.prepareDeletion([fixture.asset.id]),
        throwsA(isA<LibraryException>()),
      );
      await fixture.engine.stop(b.id);
      expect(
        (await fixture.library.prepareDeletion([fixture.asset.id])).files,
        hasLength(1),
      );
    },
  );

  test(
    'unexpected exit cancels active work and revokes only the exited instance',
    () async {
      final fixture = await _Fixture.create(ordinaryChat: true);
      addTearDown(fixture.close);
      final a = await fixture.engine.start(fixture.asset.id);
      final b = await fixture.engine.start(fixture.asset.id);
      expect(a.pid, isNot(b.pid));
      final arrived = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.io.holdText = (body) async {
        if (body['model'] == a.id) {
          arrived.complete();
          await release.future;
        }
      };
      final pending = fixture.engine
          .generateText(
            a.id,
            TextRequest(prompt: 'held'),
            timeout: const Duration(seconds: 1),
          )
          .then<Object>((value) => value, onError: (Object error) => error);
      await arrived.future;
      final failed = fixture.engine.changes.firstWhere(
        (s) =>
            s.instances.firstWhere((i) => i.id == a.id).status ==
            LlamaInstanceStatus.failed,
      );
      fixture.io.children.first.exited.complete(17);
      await failed;
      expect(
        await pending,
        isA<LlamaRequestException>().having(
          (e) => e.kind,
          'kind',
          DecisionFailureKind.cancelled,
        ),
      );
      final dead = fixture.engine.state.instances.firstWhere(
        (i) => i.id == a.id,
      );
      expect(dead.error, '受管引擎已退出 (17)');
      expect(dead.capabilities, isEmpty);
      expect(dead.acceptingRequests, isFalse);
      expect(dead.hasLiveProcess, isFalse);
      expect(dead.activeRequests, 0);
      final peer = fixture.engine.state.instances.firstWhere(
        (i) => i.id == b.id,
      );
      expect(peer.status, LlamaInstanceStatus.ready);
      expect(peer.pid, b.pid);
      expect(peer.hasLiveProcess, isTrue);
      expect(fixture.io.children.last.exited.isCompleted, isFalse);
      expect(
        (await fixture.engine.generateText(
          b.id,
          TextRequest(prompt: 'peer'),
        )).text,
        'Hello.',
      );
      await expectLater(
        fixture.library.prepareDeletion([fixture.asset.id]),
        throwsA(isA<LibraryException>()),
      );
      release.complete();
      await fixture.engine.stop(b.id);
      expect(
        (await fixture.library.prepareDeletion([fixture.asset.id])).files,
        hasLength(1),
      );
      expect(
        fixture.engine.state.instances.firstWhere((i) => i.id == a.id).status,
        LlamaInstanceStatus.failed,
      );
    },
  );

  test('unexpected child exit immediately invalidates readiness and the next decision', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final instance = await fixture.engine.start(fixture.asset.id);
    final failed = fixture.engine.changes.firstWhere(
      (state) => state.instances.single.status == LlamaInstanceStatus.failed,
    );
    fixture.io.child!.exited.complete(17);
    expect((await failed).instances.single.error, '受管引擎已退出 (17)');
    await expectLater(
      fixture.engine.decide(
        instance.id,
        DecisionRequest(
          state: '',
          instructions: 'Choose',
          options: {'yes': 'Yes', 'no': 'No'},
        ),
      ),
      throwsA(isA<LlamaEngineException>()),
    );
  });

  test('reopening verifies installed bytes instead of trusting a directory or a forged version string', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final reopened = LlamaEngine(
      library: fixture.library,
      installationDirectory: fixture.engine.installationDirectory,
      io: fixture.io,
      release: fixture.engine.release,
    );
    addTearDown(reopened.close);
    await reopened.refreshInstallation();
    expect(reopened.state.installation, LlamaInstallationStatus.installed);
    await File(fixture.engine.executablePath!).writeAsString('modified engine');
    await reopened.refreshInstallation();
    expect(reopened.state.installation, LlamaInstallationStatus.failed);
    expect(reopened.executablePath, isNull);
    expect(
      await File(fixture.engine.executablePath!).readAsString(),
      'modified engine',
    );
  });

  test('HTTP installation verifies the downloaded release before publishing and retains it on HTTP failure', () async {
    final root = await Directory.systemTemp.createTemp('jev-llama-download-');
    addTearDown(() => root.delete(recursive: true));
    final archive = _archive();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var status = 200;
    server.listen((request) async {
      request.response.statusCode = status;
      if (status == 200) request.response.add(archive);
      await request.response.close();
    });
    final library = ModelLibrary();
    addTearDown(library.close);
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: _InstallIO(),
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('http://127.0.0.1:${server.port}/official.tar.gz'),
        sha256: sha256.convert(archive).toString(),
        sizeBytes: archive.length,
      ),
    );
    addTearDown(engine.close);
    await engine.install();
    expect(engine.state.installation, LlamaInstallationStatus.installed);
    final binary = File(engine.executablePath!);
    expect(await binary.readAsString(), 'server fixture');
    status = 503;
    await expectLater(engine.install(), throwsA(isA<LlamaEngineException>()));
    expect(engine.state.error, '引擎下载 HTTP 503');
    expect(await binary.readAsString(), 'server fixture');
  });
}

class _Fixture {
  _Fixture(this.root, this.library, this.asset, this.io, this.engine);
  final Directory root;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final _InstallIO io;
  final LlamaEngine engine;
  static Future<_Fixture> create({bool ordinaryChat = false}) async {
    final root = await Directory.systemTemp.createTemp('jev-llama-boundary-');
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: ordinaryChat);
    final library = ModelLibrary();
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(_archive());
    final io = _InstallIO();
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
        sizeBytes: await archive.length(),
      ),
    );
    await engine.install(verifiedArchive: archive);
    return _Fixture(root, library, asset, io, engine);
  }

  Future<void> close() async {
    if (io.child != null) await io.child!.server.close(force: true);
    await engine.stopManaged();
    engine.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class _InstallIO implements EngineProcessIO {
  int versions = 0;
  int textRequests = 0;
  String? textResponseOverride;
  int decisionRequests = 0;
  _Child? child;
  final children = <_Child>[];
  Future<void> Function(Map body)? holdText;
  Future<void> Function()? holdSpawn;
  bool failSpawn = false;
  bool invalidProbabilities = false;
  bool foreignEndpoint = false;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    if (failSpawn) {
      throw const ProcessException('llama-server', [], 'native spawn refused');
    }
    await holdSpawn?.call();
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    child = _Child(
      server,
      pid: 12345 + children.length,
      stopServer: !foreignEndpoint,
    );
    children.add(child!);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': foreignEndpoint ? 'foreign-alias' : arg('--alias'),
            'model_path': arg('--model'),
          }),
        );
      } else if (request.uri.path == '/v1/chat/completions') {
        textRequests++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], arg('--alias'));
        expect(body['stream'], false);
        await holdText?.call(body);
        request.response.write(
          textResponseOverride?.replaceAll('ALIAS', arg('--alias')) ??
              jsonEncode({
                'model': arg('--alias'),
                'choices': [
                  {
                    'index': 0,
                    'message': {'role': 'assistant', 'content': 'Hello.'},
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {
                  'prompt_tokens': 4,
                  'completion_tokens': 2,
                  'total_tokens': 6,
                },
              }),
        );
      } else {
        decisionRequests++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final options =
            (body['questions'] as Map)['council_choice']['criteria'] as Map;
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'answers': {
              'council_choice': {
                'type': 'choice',
                'choice': options.keys.last,
                'probabilities': {
                  options.keys.first: 0.25,
                  options.keys.last: invalidProbabilities ? 0.25 : 0.75,
                },
              },
            },
            'usage': {'input_tokens': 10, 'output_tokens': 0},
          }),
        );
      }
      await request.response.close();
    });
    return child!;
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      versions++;
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt with AppleClang for Darwin arm64',
        '',
      );
    }
    final result = await Process.run(executable, arguments);
    return EngineCommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }
}

class _Child implements EngineChild {
  _Child(this.server, {required this.pid, this.stopServer = true});
  final HttpServer server;
  final bool stopServer;
  final exited = Completer<int>();
  void Function()? onKill;
  @override
  final int pid;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    onKill?.call();
    final finished = stopServer
        ? server.close(force: true)
        : Future<void>.value();
    finished.then((_) {
      if (!exited.isCompleted) exited.complete(0);
    });
    return true;
  }
}

List<int> _archive() {
  final body = utf8.encode('server fixture');
  final header = Uint8List(512);
  void field(int offset, int length, String value) =>
      header.setRange(offset, offset + value.length, ascii.encode(value));
  field(0, 100, 'llama-b11381/llama-server');
  field(100, 8, '0000755\x00');
  field(108, 8, '0000000\x00');
  field(116, 8, '0000000\x00');
  field(124, 12, '${body.length.toRadixString(8).padLeft(11, '0')}\x00');
  field(136, 12, '00000000000\x00');
  header.fillRange(148, 156, 32);
  header[156] = 48;
  field(257, 6, 'ustar\x00');
  field(263, 2, '00');
  field(
    148,
    8,
    '${header.fold(0, (a, b) => a + b).toRadixString(8).padLeft(6, '0')}\x00 ',
  );
  return gzip.encode([
    ...header,
    ...body,
    ...List.filled((512 - body.length % 512) % 512 + 1024, 0),
  ]);
}
