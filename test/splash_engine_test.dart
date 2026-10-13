import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/chat_protocol.dart';

import 'fixtures/decision_gguf.dart';

void main() {
  test('Splash starts two instances concurrently and cancels only the selected startup', () async {
    final fixture = await SplashRuntimeFixture.create();
    final engine = fixture.engine();
    fixture.io.expectedStarts = 2;
    fixture.io.startsEntered = Completer<void>();
    fixture.io.releaseStart = Completer<void>();
    Future<Object?>? first;
    Future<RuntimeInstance>? second;
    try {
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final cancel = DecisionCancellation();
      first = engine
          .startWithConfiguration(
            fixture.asset.id,
            EngineLaunchConfiguration(family: EngineFamily.splash),
            cancellation: cancel,
            launchInstanceId: 'first',
          )
          .then<Object?>((value) => value, onError: (Object error) => error);
      second = engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(family: EngineFamily.splash),
        launchInstanceId: 'second',
      );
      await fixture.io.startsEntered!.future.timeout(
        const Duration(seconds: 2),
      );
      expect(
        engine.runtimeInstances.where(
          (run) => run.status == RuntimeInstanceStatus.starting,
        ),
        hasLength(2),
      );
      cancel.cancel();
      fixture.io.releaseStart!.complete();
      expect(await first, isA<SplashEngineException>());
      final ready = await second;
      expect(ready.status, RuntimeInstanceStatus.ready);
      expect(ready.launchInstanceId, 'second');
      expect(ready.hasLiveProcess, isTrue);
      expect(
        fixture.io.children.where((child) => !child.closing),
        hasLength(1),
      );
      await engine.stop(ready.id);
      expect(engine.hasLiveInstances, isFalse);
    } finally {
      if (!fixture.io.releaseStart!.isCompleted) {
        fixture.io.releaseStart!.complete();
      }
      if (first != null) await first;
      if (second != null) {
        await second.then<void>((_) {}, onError: (Object _) {});
      }
      await engine.shutdown();
      await engine.close();
      await fixture.close();
    }
  });
  test('decision GGUF binding uses the same assembly and native validation as chat', () async {
    final fixture = await SplashRuntimeFixture.create(ordinaryChat: false);
    addTearDown(fixture.close);
    expect(fixture.asset.kind, AssetKind.decision);
    final engine = fixture.engine();
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final binding = await engine.bindModel(fixture.asset.id, fixture.assembly);
    expect(
      binding.sourceHashes[fixture.asset.files.single.path],
      fixture.asset.files.single.sha256,
    );
    final run = await engine.startRuntime(fixture.asset.id);
    expect(run.status, RuntimeInstanceStatus.ready);
    expect(
      (await engine.generateText(
        run.id,
        TextRequest(prompt: 'Reply OK.'),
      )).text,
      isNotEmpty,
    );
    await engine.stop(run.id);
    expect(engine.hasLiveInstances, isFalse);
  });
  test(
    'source loss keeps the loaded Splash run callable until explicit stop',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(engine.close);
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      try {
        await fixture.installation.nativeBinary.delete();
        await engine.refreshInstallation();
        expect(engine.state.installation, LlamaInstallationStatus.failed);
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
        expect(
          (await engine.generateText(
            run.id,
            TextRequest(prompt: 'Hello'),
          )).text,
          isNotEmpty,
        );
      } finally {
        await engine.stop(run.id);
      }
      await expectLater(
        engine.startRuntime(fixture.asset.id),
        throwsA(isA<SplashEngineException>()),
      );
    },
  );

  test('normal Splash startup loads and binds identity without any inference request', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    try {
      final run = await engine.startRuntime(fixture.asset.id);
      expect(run.status, RuntimeInstanceStatus.ready);
      expect(run.hasLiveProcess, isTrue);
      expect(run.capabilities, {RuntimeCapability.textGeneration});
      expect(fixture.io.httpPaths, contains('/ready'));
      expect(fixture.io.httpPaths, contains('/status'));
      expect(fixture.io.chatModels, isEmpty);
      expect(fixture.io.sizedPosts, 0);
      await engine.stop(run.id);
      expect(engine.runtimeInstances.single.hasLiveProcess, isFalse);
    } finally {
      await engine.shutdown();
    }
  });
  test('Splash sends sized JSON for explicit text and streaming without startup inference', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.rejectTransferEncoding = true;
    final engine = fixture.engine();
    addTearDown(engine.close);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    try {
      final run = await engine.startRuntime(fixture.asset.id);
      final reply = await engine.generateText(
        run.id,
        TextRequest(prompt: 'Reply OK.'),
        timeout: const Duration(seconds: 2),
      );
      expect(reply.text, 'OK');
      final events = await engine
          .streamText(
            run.id,
            TextRequest(prompt: 'Reply OK.'),
            timeout: const Duration(seconds: 2),
          )
          .toList();
      expect(events.any((event) => event.result != null), isTrue);
      expect(fixture.io.sizedPosts, 2);
    } finally {
      await engine.shutdown();
    }
  });
  test('cold readiness timeout stays within the startup deadline without an automatic text probe', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.identityDelay = const Duration(seconds: 6);
    final engine = fixture.engine();
    addTearDown(engine.close);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    try {
      final run = await engine.startRuntime(fixture.asset.id);
      expect(run.status, RuntimeInstanceStatus.ready);
      expect(fixture.io.starts, 1);
      expect(
        fixture.io.httpPaths.where((path) => path == '/ready').length,
        greaterThan(1),
      );
      expect(fixture.io.httpPaths, isNot(contains('/v1/chat/completions')));
      final reply = await engine.generateText(
        run.id,
        TextRequest(prompt: 'Reply OK.'),
      );
      expect(reply.text, 'OK');
      expect(fixture.io.httpPaths, contains('/v1/chat/completions'));
    } finally {
      await engine.shutdown();
    }
  });
  test('Splash only supplies its private cache directory with an explicit persistent-cache option', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    for (final text in ['', '--future-option "--persistent-cache"']) {
      final command = engine.composeLaunch(
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          argumentText: text,
        ),
      );
      expect(command.arguments, isNot(contains('--cache-dir')));
    }
    final persistent = engine.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--persistent-cache --cache-dir /external',
      ),
    );
    expect(persistent.arguments, contains('--persistent-cache'));
    expect(
      persistent.arguments,
      containsAllInOrder([
        '--cache-dir',
        '${engine.runtimeDirectory.path}/cache',
      ]),
    );
    expect(persistent.arguments, isNot(contains('/external')));
  });
  test(
    'linked Splash discovers paths without executing help or hashing content',
    () async {
      final root = await Directory.systemTemp.createTemp('splash-observe-');
      addTearDown(() => root.delete(recursive: true));
      for (final path in [
        '.venv/bin/python',
        'build/splash',
        'server/server.py',
        'install/launcher.py',
        'install/gguf.py',
      ]) {
        final file = File('${root.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString('original $path');
      }
      final io = SplashTestProcessIO(root);
      final observed = await SplashEngine.inspectInstallation(root, io: io);
      expect(observed.python.path, '${root.path}/.venv/bin/python');
      expect(io.calls, isEmpty);
      expect(io.starts, 0);
      expect(io.calls.any((args) => args.contains('make')), isFalse);
    },
  );
  test('source registration does not execute Python prefix probes', () async {
    final root = await Directory.systemTemp.createTemp('splash-prefix-');
    addTearDown(() => root.delete(recursive: true));
    for (final path in [
      '.venv/bin/python',
      'build/splash',
      'server/server.py',
      'install/launcher.py',
      'install/gguf.py',
    ]) {
      final file = File('${root.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString('original $path');
    }
    final io = SplashTestProcessIO(root, mutate: false, wrongPrefix: true);
    final observed = await SplashEngine.inspectInstallation(root, io: io);
    expect(observed.python.path, '${root.path}/.venv/bin/python');
    expect(io.calls, isEmpty);
    expect(io.starts, 0);
  });
  test('binding rejects a different canonical target even with complete recorded SHA', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final other = await writeDecisionKev(
      Directory('${fixture.root.path}/other'),
      ordinaryChat: true,
    );
    await fixture.writeAssembly(other);
    var saved = 0;
    final engine = SplashEngine(
      installation: fixture.installation,
      library: fixture.library,
      useRegistry: ModelUseRegistry(fixture.library),
      runtimeDirectory: Directory('${fixture.root.path}/runtime'),
      io: fixture.io,
      configurationFor: (_) =>
          EngineLaunchConfiguration(family: EngineFamily.splash),
      saveBinding: (_) async {
        saved++;
      },
    );
    await expectLater(
      engine.bindModel(fixture.asset.id, fixture.assembly),
      throwsA(isA<SplashEngineException>()),
    );
    expect(saved, 0);
    expect(engine.bindingFor(fixture.asset.id), isNull);
    expect(fixture.io.starts, 0);
  });
  test(
    'binding saves a selected model without a native compatibility probe',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      fixture.io.modelCheckFailure = true;
      var saved = 0;
      final engine = SplashEngine(
        installation: fixture.installation,
        library: fixture.library,
        useRegistry: ModelUseRegistry(fixture.library),
        runtimeDirectory: Directory('${fixture.root.path}/runtime'),
        io: fixture.io,
        configurationFor: (_) =>
            EngineLaunchConfiguration(family: EngineFamily.splash),
        saveBinding: (_) async {
          saved++;
        },
      );
      final binding = await engine.bindModel(
        fixture.asset.id,
        fixture.assembly,
      );
      expect(saved, 1);
      expect(engine.bindingFor(fixture.asset.id), same(binding));
      expect(
        fixture.io.calls.where((args) => args.first == 'model-check'),
        isEmpty,
      );
      await engine.shutdown();
      await engine.close();
      expect(fixture.io.starts, 0);
    },
  );
  test('public start earns text Ready from owned status and native response identity', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = SplashEngine(
      installation: fixture.installation,
      library: fixture.library,
      useRegistry: ModelUseRegistry(fixture.library),
      runtimeDirectory: Directory('${fixture.root.path}/runtime'),
      io: fixture.io,
      configurationFor: (_) =>
          EngineLaunchConfiguration(family: EngineFamily.splash),
      saveBinding: (_) async {},
    );
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final started = await engine.startRuntime(fixture.asset.id);
    expect(started.status, RuntimeInstanceStatus.ready);
    expect(started.capabilities, {RuntimeCapability.textGeneration});
    expect(fixture.io.nativeResponseModel, 'fixture/target:Q8');
    expect(
      engine.actualCommandFor(started.id)!.arguments,
      contains('--default-reasoning-effort'),
    );
    final result = await engine.generateText(
      started.id,
      TextRequest(prompt: 'Say OK'),
    );
    expect(result.text, 'OK');
    final events = await engine
        .streamText(started.id, TextRequest(prompt: 'Say OK'))
        .toList();
    expect(
      events.where((event) => event.result != null).single.result!.text,
      'OK',
    );
    await engine.stop(started.id);
    expect(
      engine.runtimeInstances.single.status,
      RuntimeInstanceStatus.stopped,
    );
    expect(engine.hasLiveInstances, isFalse);
    expect(await fixture.io.groupAlive(engine.pidFor(started.id)!), isFalse);
  });
  test(
    'request cancellation drains its permit and leaves peer owner callable',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final first = await engine.startRuntime(fixture.asset.id);
      final peer = await engine.startRuntime(fixture.asset.id);
      final cancellation = DecisionCancellation();
      final pending = engine.generateText(
        first.id,
        TextRequest(prompt: 'hold'),
        cancellation: cancellation,
      );
      final failed = expectLater(
        pending,
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.cancelled,
          ),
        ),
      );
      await fixture.io.holdReached.future;
      expect(engine.runtimeInstances.first.activeRequests, 1);
      cancellation.cancel();
      await failed;
      expect(engine.runtimeInstances.first.activeRequests, 0);
      expect(
        (await engine.generateText(peer.id, TextRequest(prompt: 'OK'))).text,
        'OK',
      );
      await engine.stopManaged();
      expect(engine.hasLiveInstances, isFalse);
      final next = await engine.startRuntime(fixture.asset.id);
      expect(next.generation, greaterThan(peer.generation));
      await engine.shutdown();
      await engine.shutdown();
      await expectLater(
        engine.startRuntime(fixture.asset.id),
        throwsA(isA<SplashEngineException>()),
      );
      expect(engine.hasLiveInstances, isFalse);
      await engine.close();
    },
  );
  test(
    'stop drains a paused SSE consumer without a fabricated completion',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      final delta = Completer<void>();
      final results = <TextResult>[];
      late StreamSubscription<TextStreamEvent> subscription;
      subscription = engine
          .streamText(run.id, TextRequest(prompt: 'streamhold'))
          .listen((event) {
            if (event.result != null) results.add(event.result!);
            if (!delta.isCompleted) {
              subscription.pause();
              delta.complete();
            }
          }, onError: (Object _) {});
      try {
        await delta.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('SSE first delta not delivered'),
        );
        await engine
            .stop(run.id)
            .timeout(
              const Duration(seconds: 1),
              onTimeout: () =>
                  throw StateError('owned stop did not drain SSE permit'),
            );
        expect(engine.runtimeInstances.single.activeRequests, 0);
        expect(engine.hasLiveInstances, isFalse);
        expect(results, isEmpty);
      } finally {
        if (!fixture.io.releaseHeld.isCompleted) {
          fixture.io.releaseHeld.complete();
        }
        await subscription.cancel();
        await engine.shutdown();
        await engine.close();
      }
    },
  );
  test(
    'restored installation checks required paths without rehashing content',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final recorded = SplashInstallation.fromJson(
        fixture.installation.toJson(),
      );
      final engine = fixture.engine(installation: recorded);
      expect(
        engine.state.installation,
        isNot(LlamaInstallationStatus.installed),
      );
      await engine.refreshInstallation();
      expect(engine.state.installation, LlamaInstallationStatus.installed);
      await File('${fixture.source.path}/build/splash')
          .writeAsString('updated binary');
      await engine.refreshInstallation();
      expect(engine.state.installation, LlamaInstallationStatus.installed);
      expect(engine.installation.fingerprints, recorded.fingerprints);
      await fixture.installation.nativeBinary.delete();
      await engine.refreshInstallation();
      expect(engine.state.installation, LlamaInstallationStatus.failed);
      await expectLater(
        engine.previewLaunch(fixture.asset.id),
        throwsA(isA<SplashEngineException>()),
      );
      expect(fixture.io.starts, 0);
      await engine.close();
    },
  );
  test('actual help failure retains linked identity and built-in raw launch support', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.helpFailure = true;
    final installation = await SplashEngine.inspectInstallation(
      fixture.source,
      io: fixture.io,
      readParameters: true,
    );
    final engine = fixture.engine(installation: installation);
    final command = engine.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--future-option value --host external --max-context 1K',
      ),
    );
    expect(command.arguments, contains('--future-option'));
    expect(command.arguments, isNot(contains('external')));
    expect(installation.recognition.notices, isNotEmpty);
    expect(installation.toJson(), contains('help_error'));
    await engine.close();
  });
  test(
    'a restored binding rechecks the canonical assembly target before spawning',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      final binding = await engine.bindModel(
        fixture.asset.id,
        fixture.assembly,
      );
      final restored = SplashModelBinding.fromJson(binding.toJson());
      final other = await writeDecisionKev(
        Directory('${fixture.root.path}/other'),
        ordinaryChat: true,
      );
      await Link('${fixture.assembly.path}/target/model.gguf').delete();
      await Link('${fixture.assembly.path}/target/model.gguf')
          .create(other.path);
      final owner = SplashEngine(
        installation: fixture.installation,
        library: fixture.library,
        useRegistry: ModelUseRegistry(fixture.library),
        runtimeDirectory: Directory('${fixture.root.path}/restored-runtime'),
        io: fixture.io,
        configurationFor: (_) =>
            EngineLaunchConfiguration(family: EngineFamily.splash),
        saveBinding: (_) async {},
        bindings: [restored],
      );
      try {
        await expectLater(
          owner.startRuntime(fixture.asset.id),
          throwsA(isA<SplashEngineException>()),
        );
        expect(fixture.io.starts, 0);
      } finally {
        await owner.shutdown();
        await owner.close();
        await engine.close();
      }
    },
  );
  test('detach drains accepted starts and refuses live removal without implicit stop', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    fixture.io.releaseStart = Completer<void>();
    final accepted = engine.startRuntime(fixture.asset.id);
    await fixture.io.startEntered.future;
    final release = engine.holdStartAdmission();
    var removed = 0;
    final detaching = expectLater(
      engine.detachLinked(
        persistRemoval: () async {
          removed++;
        },
      ),
      throwsA(isA<SplashEngineException>()),
    );
    await expectLater(
      engine.startRuntime(fixture.asset.id),
      throwsA(isA<SplashEngineException>()),
    );
    fixture.io.releaseStart!.complete();
    final run = await accepted;
    await detaching;
    expect(removed, 0);
    expect(engine.runtimeInstances.single.status, RuntimeInstanceStatus.ready);
    await engine.stop(run.id);
    await engine.detachLinked(
      persistRemoval: () async {
        removed++;
      },
    );
    expect(removed, 1);
    release();
    await expectLater(
      engine.startRuntime(fixture.asset.id),
      throwsA(isA<SplashEngineException>()),
    );
    await engine.shutdown();
    await engine.close();
  });
  test('accepted spawn protects all model files and shutdown cleans the late child', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final deletion = await fixture.library.prepareDeletion([fixture.asset.id]);
    fixture.io.releaseStart = Completer<void>();
    final pending = engine.startRuntime(fixture.asset.id);
    final rejected = expectLater(
      pending,
      throwsA(isA<SplashEngineException>()),
    );
    await fixture.io.startEntered.future;
    try {
      await expectLater(
        fixture.library.delete(deletion, confirmed: true),
        throwsA(isA<LibraryException>()),
      );
    } finally {
      engine.beginShutdown();
      fixture.io.releaseStart!.complete();
      await rejected;
      await engine.shutdown();
      await engine.close();
    }
    expect(fixture.io.starts, 1);
    expect(engine.hasLiveInstances, isFalse);
    expect(await File(fixture.asset.files.single.path).exists(), isTrue);
    expect(
      await fixture.library.prepareDeletion([fixture.asset.id]),
      isA<DeletionPlan>(),
    );
  });
  test('source replacement retains loaded Splash runs and refreshes only future launches', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final first = await engine.startRuntime(fixture.asset.id);
    await engine.startRuntime(fixture.asset.id);
    await File('${fixture.source.path}/build/splash')
        .writeAsString('replacement');
    final oldVersion = engine.actualVersionFor(first.id);
    await engine.refreshInstallation();
    expect(engine.state.installation, LlamaInstallationStatus.installed);
    expect(
      (await engine.generateText(first.id, TextRequest(prompt: 'OK'))).text,
      isNotEmpty,
    );
    expect(
      engine.runtimeInstances.every(
        (run) =>
            run.status == RuntimeInstanceStatus.ready && run.hasLiveProcess,
      ),
      isTrue,
    );
    expect(engine.actualVersionFor(first.id), oldVersion);
    expect(engine.installation.fingerprints, fixture.installation.fingerprints);
    expect(fixture.io.starts, 2);
    await engine.shutdown();
    await engine.close();
  });
  test(
    'timeout and truncated SSE are failures, never terminal text successes',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      await expectLater(
        engine.generateText(
          run.id,
          TextRequest(prompt: 'hold'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.timedOut,
          ),
        ),
      );
      fixture.io.omitDone = true;
      final terminal = <TextResult>[];
      await expectLater(
        engine.streamText(run.id, TextRequest(prompt: 'OK')).forEach((event) {
          if (event.result != null) terminal.add(event.result!);
        }),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.invalidResponse,
          ),
        ),
      );
      expect(terminal, isEmpty);
      expect(engine.runtimeInstances.single.activeRequests, 0);
      expect(fixture.io.starts, 1);
      await engine.shutdown();
      await engine.close();
    },
  );
  for (final wrongPid in [true, false]) {
    test(
      wrongPid
          ? 'startup refuses unowned PID as Ready'
          : 'explicit generation refuses reasoning-only empty content',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        fixture.io.wrongPid = wrongPid;
        fixture.io.emptyText = !wrongPid;
        final engine = fixture.engine();
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        if (wrongPid) {
          await expectLater(
            engine.startRuntime(fixture.asset.id),
            throwsA(isA<SplashEngineException>()),
          );
        } else {
          final run = await engine.startRuntime(fixture.asset.id);
          expect(fixture.io.chatModels, isEmpty);
          expect(run.status, RuntimeInstanceStatus.ready);
          await expectLater(
            engine.generateText(run.id, TextRequest(prompt: 'Reply OK.')),
            throwsA(
              isA<SplashRequestException>().having(
                (error) => error.kind,
                'kind',
                DecisionFailureKind.invalidResponse,
              ),
            ),
          );
          await engine.stop(run.id);
        }
        expect(engine.runtimeInstances.single.capabilities, isEmpty);
        expect(engine.hasLiveInstances, isFalse);
        expect(fixture.io.starts, 1);
        await engine.shutdown();
        await engine.close();
      },
    );
  }
  test('configuration saves affect next start while captured live command and PID remain fixed', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    var configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--max-context': '1K'},
    );
    final engine = fixture.engine(configurationFor: (_) => configuration);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final first = await engine.startRuntime(fixture.asset.id);
    final command = engine.actualCommandFor(first.id)!;
    final pid = engine.pidFor(first.id);
    configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--max-context': '2K'},
    );
    expect(
      (await engine.previewLaunch(fixture.asset.id)).arguments,
      contains('2K'),
    );
    expect(engine.actualCommandFor(first.id), same(command));
    expect(engine.pidFor(first.id), pid);
    expect(command.arguments, contains('1K'));
    final next = await engine.startRuntime(fixture.asset.id);
    expect(engine.actualCommandFor(next.id)!.arguments, contains('2K'));
    expect(fixture.io.starts, 2);
    await engine.shutdown();
    await engine.close();
  });
  test('unknown group cleanup remains failed and in use until confirmed explicit recovery', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final run = await engine.startRuntime(fixture.asset.id);
    fixture.io.unknownGroup = true;
    await expectLater(
      engine.stop(run.id),
      throwsA(isA<SplashEngineException>()),
    );
    expect(engine.runtimeInstances.single.status, RuntimeInstanceStatus.failed);
    expect(engine.hasLiveInstances, isTrue);
    await expectLater(
      fixture.library.prepareDeletion([fixture.asset.id]),
      throwsA(isA<LibraryException>()),
    );
    fixture.io.unknownGroup = false;
    await engine.stop(run.id);
    expect(engine.hasLiveInstances, isFalse);
    await engine.shutdown();
    await engine.close();
  });
  test(
    'unexpected Python exit reclaims only its remaining owned child group',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      final cleaned = engine.changes.firstWhere(
        (state) =>
            state.instances.single.status == RuntimeInstanceStatus.failed &&
            !state.instances.single.hasLiveProcess,
      );
      fixture.io.children.single.crash();
      try {
        await cleaned.timeout(const Duration(seconds: 1));
        expect(fixture.io.groupSignals, contains(engine.pidFor(run.id)));
        expect(engine.runtimeInstances.single.error, contains('70'));
      } catch (error, stack) {
        try {
          await engine.shutdown();
        } catch (cleanup) {
          stderr.writeln('Secondary owned cleanup failure: $cleanup');
        }
        await engine.close();
        Error.throwWithStackTrace(error, stack);
      }
      await engine.shutdown();
      await engine.close();
    },
  );
  test('installation JSON cannot redirect bootstrap outside the recorded linked source', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final row = fixture.installation.toJson();
    expect(
      () => SplashInstallation.fromJson({
        ...row,
        'module_root': '${fixture.root.path}/other',
      }),
      throwsFormatException,
    );
    final restored = SplashInstallation.fromJson({
      ...row,
      'fingerprints': <String, Object?>{},
    });
    expect(restored.python.path, fixture.installation.python.path);
    expect(
      () => SplashInstallation.fromJson({...row, 'python': '/outside/python'}),
      throwsFormatException,
    );
    expect(
      () => SplashInstallation.fromJson({
        ...row,
        'native_binary': '/outside/engine',
      }),
      throwsFormatException,
    );
    expect(fixture.io.starts, 0);
  });
  test('binding canonicalizes logical snapshot identity and rejects its redirected source', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final role = File('${fixture.assembly.path}/draft/config.json');
    final bytes = await role.readAsBytes();
    final blob = File('${fixture.root.path}/hf/blobs/config');
    await blob.parent.create(recursive: true);
    await blob.writeAsBytes(bytes);
    final snapshot = Link('${fixture.root.path}/hf/snapshots/rev/config.json');
    await snapshot.parent.create(recursive: true);
    await snapshot.create(blob.path);
    await role.delete();
    await Link(role.path).create(blob.path);
    final manifest = File('${fixture.assembly.path}/model.json');
    final row = jsonDecode(await manifest.readAsString()) as Map;
    (row['files'] as Map)['draft/config.json']['path'] = snapshot.path;
    await manifest.writeAsString(jsonEncode(row));
    var saved = 0;
    final engine = fixture.engine(
      saveBinding: (_) async {
        saved++;
      },
    );
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final binding = await engine.bindModel(fixture.asset.id, fixture.assembly);
    expect(
      binding.roles['draft/config.json'],
      await blob.resolveSymbolicLinks(),
    );
    expect(binding.sourceHashes[blob.path], sha256.convert(bytes).toString());
    expect(
      await FileSystemEntity.type(snapshot.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await blob.readAsBytes(), bytes);
    expect(saved, 1);
    final redirected = File('${fixture.root.path}/hf/blobs/other');
    await redirected.writeAsBytes(bytes);
    await snapshot.delete();
    await snapshot.create(redirected.path);
    await expectLater(
      engine.bindModel(fixture.asset.id, fixture.assembly),
      throwsA(isA<SplashEngineException>()),
    );
    expect(saved, 1);
    expect(engine.bindingFor(fixture.asset.id), same(binding));
    expect(fixture.io.starts, 0);
  });
  test('binding records author blob declarations without reading whole model files', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final role = File('${fixture.assembly.path}/draft/config.json');
    await role.writeAsString('{"name":"草稿配置"}');
    final bytes = await role.readAsBytes();
    final blobHash = sha1.convert([
      ...utf8.encode('blob ${bytes.length} '),
      ...bytes,
    ]).toString();
    final manifest = File('${fixture.assembly.path}/model.json');
    final row = jsonDecode(await manifest.readAsString()) as Map;
    final entry = (row['files'] as Map)['draft/config.json'] as Map;
    entry['bytes'] = bytes.length;
    entry['digest'] = blobHash;
    await manifest.writeAsString(jsonEncode(row));
    var saved = 0;
    final engine = fixture.engine(
      saveBinding: (_) async {
        saved++;
      },
    );
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final binding = await engine.bindModel(fixture.asset.id, fixture.assembly);
    expect(binding.sourceHashes[await role.resolveSymbolicLinks()], blobHash);
    expect(
      binding.sourceHashes.values.every(
        (value) => RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(value),
      ),
      isTrue,
    );
    expect(
      binding.sourceHashes[fixture.asset.files.single.path],
      fixture.asset.files.single.sha256,
    );
    expect(saved, 1);
    for (final wrong in [
      sha1.convert(bytes).toString(),
      List.filled(40, '0').join(),
      List.filled(64, '0').join(),
      'unsupported',
    ]) {
      entry['digest'] = wrong;
      await manifest.writeAsString(jsonEncode(row));
      if (wrong == 'unsupported') {
        await expectLater(
          engine.bindModel(fixture.asset.id, fixture.assembly),
          throwsA(isA<SplashEngineException>()),
        );
      } else {
        final changed = await engine.bindModel(
          fixture.asset.id,
          fixture.assembly,
        );
        expect(changed.sourceHashes[await role.resolveSymbolicLinks()], wrong);
      }
    }
    expect(saved, 4);

    expect(fixture.io.starts, 0);
  });
  for (final failSave in [false, true]) {
    test(
      'binding persistence protects file use and releases after ${failSave ? 'failure' : 'success'}',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final entered = Completer<void>();
        final release = Completer<void>();
        var saved = 0;
        final engine = fixture.engine(
          saveBinding: (_) async {
            entered.complete();
            await release.future;
            if (failSave) {
              throw const FileSystemException('binding write failed');
            }
            saved++;
          },
        );
        addTearDown(() async {
          await engine.shutdown();
          await engine.close();
        });
        final plan = await fixture.library.prepareDeletion([fixture.asset.id]);
        final pending = engine.bindModel(fixture.asset.id, fixture.assembly);
        final completed = failSave
            ? expectLater(pending, throwsA(isA<FileSystemException>()))
            : pending.then<void>((_) {});
        await entered.future;
        try {
          await expectLater(
            fixture.library.delete(plan, confirmed: true),
            throwsA(isA<LibraryException>()),
          );
        } finally {
          release.complete();
          await completed;
        }
        expect(await File(fixture.asset.files.single.path).exists(), isTrue);
        expect(saved, failSave ? 0 : 1);
        expect(
          await fixture.library.prepareDeletion([fixture.asset.id]),
          isA<DeletionPlan>(),
        );
        expect(fixture.io.starts, 0);
      },
    );
  }
  for (final mutateManifest in [false, true]) {
    test(
      'binding persistence captures selected ${mutateManifest ? 'manifest' : 'source paths'} while file content is left to loading',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final entered = Completer<void>();
        final release = Completer<void>();
        var saved = 0;
        final engine = fixture.engine(
          saveBinding: (_) async {
            saved++;
            if (saved == 2) {
              entered.complete();
              await release.future;
            }
          },
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await engine.shutdown();
          await engine.close();
        });
        final old = await engine.bindModel(fixture.asset.id, fixture.assembly);
        final pending = engine.bindModel(fixture.asset.id, fixture.assembly);
        await entered.future;
        if (mutateManifest) {
          final file = File('${fixture.assembly.path}/model.json');
          final row = jsonDecode(await file.readAsString()) as Map;
          row['model'] = 'changed/model';
          await file.writeAsString(jsonEncode(row));
        } else {
          await File('${fixture.assembly.path}/draft/config.json')
              .writeAsString('{"fixture":"changed after save began"}');
        }
        release.complete();
        final captured = await pending;
        expect(captured.nativeModel, old.nativeModel);
        expect(captured.roles, old.roles);
        expect(saved, 2);
        expect(engine.bindingFor(fixture.asset.id), same(captured));
        expect(
          await fixture.library.prepareDeletion([fixture.asset.id]),
          isA<DeletionPlan>(),
        );
        expect(fixture.io.starts, 0);
        if (mutateManifest) {
          await expectLater(
            engine.startRuntime(fixture.asset.id),
            throwsA(isA<SplashEngineException>()),
          );
        } else {
          expect(
            (await engine.startRuntime(fixture.asset.id)).status,
            RuntimeInstanceStatus.ready,
          );
        }
      },
    );
  }
  test(
    'JSON request deadline starts before delayed identity and preserves Ready',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      fixture.io.identityDelay = const Duration(milliseconds: 200);
      await expectLater(
        engine.generateText(
          run.id,
          TextRequest(prompt: 'OK'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.timedOut,
          ),
        ),
      );
      expect(engine.runtimeInstances.single.activeRequests, 0);
      expect(
        engine.runtimeInstances.single.status,
        RuntimeInstanceStatus.ready,
      );
      fixture.io.identityDelay = Duration.zero;
      expect(
        (await engine.generateText(run.id, TextRequest(prompt: 'OK'))).text,
        'OK',
      );
      expect(fixture.io.starts, 1);
    },
  );
  test(
    'SSE deadline closes pending identity and drains without a terminal result',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      fixture.io.identityEntered = Completer<void>();
      fixture.io.identityClosed = Completer<void>();
      final gate = Completer<void>();
      fixture.io.identityRelease = gate;
      final results = <TextResult>[];
      final pending = engine
          .streamText(
            run.id,
            TextRequest(prompt: 'OK'),
            timeout: const Duration(milliseconds: 50),
          )
          .forEach((event) {
            if (event.result != null) results.add(event.result!);
          });
      final failed = expectLater(
        pending,
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.timedOut,
          ),
        ),
      );
      try {
        await fixture.io.identityEntered!.future;
        await failed.timeout(
          const Duration(milliseconds: 150),
          onTimeout: () =>
              throw StateError('identity deadline did not drain SSE'),
        );
        await fixture.io.identityClosed!.future.timeout(
          const Duration(milliseconds: 150),
        );
        expect(engine.runtimeInstances.single.activeRequests, 0);
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
        expect(results, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        fixture.io.identityRelease = null;
        await failed;
      }
    },
  );
  for (final stream in [false, true]) {
    test(
      '${stream ? 'SSE' : 'JSON'} cancellation closes only pending identity and preserves peer Ready',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final engine = fixture.engine();
        addTearDown(() async {
          await engine.shutdown();
          await engine.close();
        });
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        final first = await engine.startRuntime(fixture.asset.id);
        final peer = await engine.startRuntime(fixture.asset.id);
        fixture.io.identityEntered = Completer<void>();
        fixture.io.identityClosed = Completer<void>();
        final gate = Completer<void>();
        fixture.io.identityRelease = gate;
        final cancellation = DecisionCancellation();
        final Future<Object?> pending = stream
            ? engine
                  .streamText(
                    first.id,
                    TextRequest(prompt: 'OK'),
                    cancellation: cancellation,
                  )
                  .toList()
            : engine.generateText(
                first.id,
                TextRequest(prompt: 'OK'),
                cancellation: cancellation,
              );
        final failed = expectLater(
          pending,
          throwsA(
            isA<SplashRequestException>().having(
              (e) => e.kind,
              'kind',
              DecisionFailureKind.cancelled,
            ),
          ),
        );
        try {
          await fixture.io.identityEntered!.future;
          cancellation.cancel();
          await failed.timeout(
            const Duration(milliseconds: 150),
            onTimeout: () =>
                throw StateError('identity cancellation did not drain request'),
          );
          await fixture.io.identityClosed!.future.timeout(
            const Duration(milliseconds: 150),
          );
          expect(
            engine.runtimeInstances.every(
              (run) =>
                  run.status == RuntimeInstanceStatus.ready &&
                  run.activeRequests == 0,
            ),
            isTrue,
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          fixture.io.identityRelease = null;
          await failed;
        }
        expect(
          (await engine.generateText(peer.id, TextRequest(prompt: 'OK'))).text,
          'OK',
        );
        expect(
          (await engine.generateText(first.id, TextRequest(prompt: 'OK'))).text,
          'OK',
        );
        expect(fixture.io.starts, 2);
      },
    );
  }
}

class SplashRuntimeFixture {
  SplashRuntimeFixture(
    this.root,
    this.source,
    this.library,
    this.asset,
    this.assembly,
    this.installation,
    this.io,
  );
  final Directory root;
  final Directory source;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final Directory assembly;
  final SplashInstallation installation;
  final SplashTestProcessIO io;

  static Future<SplashRuntimeFixture> create({
    bool ordinaryChat = true,
    bool supportsSystemone = false,
  }) async {
    final root = await Directory.systemTemp.createTemp('splash-runtime-');
    final source = Directory('${root.path}/source');
    for (final path in [
      '.venv/bin/python',
      'build/splash',
      'server/server.py',
      'install/launcher.py',
      'install/gguf.py',
    ]) {
      final file = File('${source.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString('original $path');
    }
    final io = SplashTestProcessIO(source, mutate: false);
    if (supportsSystemone) {
      await File('${source.path}/server/server.py').writeAsString(
        '"/v1/systemone": PostRoute("_post_systemone", SYSTEMONE_ERRORS)',
      );
    }
    final installation = await SplashEngine.inspectInstallation(
      source,
      io: io,
      readParameters: true,
    );
    final library = ModelLibrary();
    final model = await writeDecisionKev(
      Directory('${root.path}/models'),
      ordinaryChat: ordinaryChat,
    );
    final asset = (await library.scan(model.parent, verifyFiles: true)).single;
    final result = SplashRuntimeFixture(
      root,
      source,
      library,
      asset,
      Directory('${root.path}/assembly'),
      installation,
      io,
    );
    await result.writeAssembly(model);
    return result;
  }

  SplashEngine engine({
    SplashInstallation? installation,
    EngineLaunchConfiguration Function(String)? configurationFor,
    Future<void> Function(SplashModelBinding)? saveBinding,
  }) => SplashEngine(
    installation: installation ?? this.installation,
    library: library,
    useRegistry: ModelUseRegistry(library),
    runtimeDirectory: Directory('${root.path}/runtime'),
    io: io,
    configurationFor:
        configurationFor ??
        (_) => EngineLaunchConfiguration(family: EngineFamily.splash),
    saveBinding: saveBinding ?? (_) async {},
  );

  Future<void> writeAssembly(File target) async {
    if (await assembly.exists()) await assembly.delete(recursive: true);
    await assembly.create(recursive: true);
    final paths = <String, File>{};
    for (final role in [
      'config.json',
      'draft/config.json',
      'draft/model.safetensors',
      'tokenizer/tokenizer.json',
      'tokenizer/tokenizer_config.json',
    ]) {
      final file = File('${assembly.path}/$role');
      await file.parent.create(recursive: true);
      await file.writeAsString('{"fixture":"$role"}');
      paths[role] = file;
    }
    await Directory('${assembly.path}/target').create();
    await Link('${assembly.path}/target/model.gguf').create(target.path);
    paths['target/model.gguf'] = target;
    final records = <String, Object?>{};
    for (final entry in paths.entries) {
      records[entry.key] = {
        'path': await entry.value.resolveSymbolicLinks(),
        'bytes': await entry.value.length(),
        'digest': (await sha256.bind(entry.value.openRead()).first).toString(),
      };
    }
    await File('${assembly.path}/model.json').writeAsString(
      jsonEncode({
        'version': 1,
        'model': 'fixture/target:Q8',
        'family': 'Qwen3.8-27B',
        'target_format': 'gguf',
        'vision_format': 'none',
        'files': records,
      }),
    );
  }

  Future<void> close() async {
    await io.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class SplashTestProcessIO implements SplashProcessIO {
  SplashTestProcessIO(
    this.root, {
    this.mutate = true,
    this.wrongPrefix = false,
  });
  final Directory root;
  final bool mutate;
  final bool wrongPrefix;
  final calls = <List<String>>[];
  final httpPaths = <String>[];
  final chatModels = <String>[];
  final decisionBodies = <Map>[];
  Completer<void>? decisionEntered;
  Completer<void>? decisionRelease;
  int decisionStatus = 200;
  Map<String, Object?> Function(Map body)? decisionResponse;
  Map<String, Object?>? monitorStatus;
  void Function()? afterDecision;
  bool rejectTransferEncoding = false;
  int sizedPosts = 0;
  int starts = 0;
  int? expectedStarts;
  Completer<void>? startsEntered;
  Duration identityDelay = Duration.zero;
  Completer<void>? identityEntered;
  Completer<void>? identityClosed;
  Completer<void>? identityRelease;
  final detachedIdentitySockets = <Socket>{};
  bool modelCheckFailure = false;
  bool helpFailure = false;
  bool omitDone = false;
  bool wrongPid = false;
  bool emptyText = false;
  bool unknownGroup = false;
  final groupSignals = <int>[];
  Completer<void>? modelCheckEntered;
  Completer<void>? releaseCheck;
  final children = <SplashTestChild>[];
  String? nativeResponseModel;
  final startEntered = Completer<void>();
  Completer<void>? releaseStart;
  final holdReached = Completer<void>();
  final releaseHeld = Completer<void>();
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    calls.add(arguments);
    if (arguments.first == 'model-check') {
      if (modelCheckEntered?.isCompleted == false) {
        modelCheckEntered!.complete();
      }
      await releaseCheck?.future;
      return modelCheckFailure
          ? const EngineCommandResult(70, '', 'invalid target/draft pairing')
          : const EngineCommandResult(0, '{"family":"Qwen3.8-27B"}', '');
    }
    if (arguments.any((value) => value.contains('scalar_metadata'))) {
      return const EngineCommandResult(
        0,
        '{"unsigned":{},"float":{},"string":{}}',
        '',
      );
    }
    if (arguments.any((value) => value.contains('sys.prefix'))) {
      return EngineCommandResult(
        0,
        '{"prefix":"${root.path}/${wrongPrefix ? 'system' : '.venv'}"}',
        '',
      );
    }
    if (arguments.contains('--help')) {
      if (mutate) {
        await File('${root.path}/build/splash')
            .writeAsString('concurrent binary replacement');
      }
      return helpFailure
          ? const EngineCommandResult(70, '', 'fixture help failed')
          : const EngineCommandResult(
              0,
              '--max-context TOKENS  Maximum context',
              '',
            );
    }
    return EngineCommandResult(
      0,
      arguments.contains('-c') ? 'Splash (source checkout)' : 'Python 3.14.7',
      '',
    );
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    starts++;
    if (starts == expectedStarts && startsEntered?.isCompleted == false) {
      startsEntered!.complete();
    }
    if (!startEntered.isCompleted) startEntered.complete();
    await releaseStart?.future;
    String value(String option) => arguments[arguments.lastIndexOf(option) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(value('--port')),
    );
    final child = SplashTestChild(server, 30000 + children.length);
    children.add(child);
    final model = value('--model');
    final alias = value('--served-model-name');
    nativeResponseModel = model;
    server.listen((request) async {
      try {
        request.response.headers.contentType = ContentType.json;
        Object response;
        httpPaths.add(request.uri.path);
        switch (request.uri.path) {
          case '/ready':
            if (identityDelay > Duration.zero || identityRelease != null) {
              final delay = identityDelay;
              identityDelay = Duration.zero;
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              detachedIdentitySockets.add(socket);
              void closed() {
                detachedIdentitySockets.remove(socket);
                if (identityClosed?.isCompleted == false) {
                  identityClosed!.complete();
                }
              }

              socket.listen(
                (_) {},
                onDone: closed,
                onError: (Object _) {
                  closed();
                },
              );
              unawaited(socket.done.catchError((Object _) {}));
              final body = utf8.encode('{"status":"ready"}');
              socket.write(
                'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
              );
              socket.write('{"status":');
              await socket.flush();
              if (identityEntered?.isCompleted == false) {
                identityEntered!.complete();
              }
              if (identityRelease != null) {
                await identityRelease!.future;
              } else {
                await Future<void>.delayed(delay);
              }
              try {
                socket.write('"ready"}');
                await socket.flush();
                await socket.close();
              } on IOException {
                socket.destroy();
              }
              return;
            }
            response = {'status': 'ready'};
          case '/status':
            response = {
              ...?monitorStatus,
              'ready': true,
              'instance': {
                'id': 'source-${child.pid}',
                'pid': child.pid + (wrongPid ? 1 : 0),
                'model': model,
                'host': '127.0.0.1',
                'port': server.port,
              },
              'transport': {
                'ready': true,
                'recovering': false,
                'stopped': false,
                'restarts': 0,
              },
            };
          case '/v1/models':
            response = {
              'object': 'list',
              'data': [
                {'id': model},
                {'id': alias},
              ],
            };
          case '/v1/systemone':
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            decisionBodies.add(body);
            if (decisionEntered?.isCompleted == false) {
              decisionEntered!.complete();
            }
            if (decisionRelease != null) await decisionRelease!.future;
            request.response.statusCode = decisionStatus;
            response =
                decisionResponse?.call(body) ??
                {
                  'model': nativeResponseModel ?? model,
                  'answers': {
                    for (final entry in (body['questions'] as Map).entries)
                      '${entry.key}': {
                        'type': 'choice',
                        'choice': ((entry.value as Map)['criteria'] as Map)
                            .keys
                            .first,
                        'probabilities': {
                          for (final key
                              in ((entry.value as Map)['criteria'] as Map).keys)
                            '$key':
                                key ==
                                    ((entry.value as Map)['criteria'] as Map)
                                        .keys
                                        .first
                                ? 1.0
                                : 0.0,
                        },
                        'confidence': 1.0,
                      },
                  },
                  'usage': {'input_tokens': 10, 'output_tokens': 0},
                };
            afterDecision?.call();
          case '/v1/chat/completions':
            if (rejectTransferEncoding &&
                (request.headers.value(HttpHeaders.transferEncodingHeader) !=
                        null ||
                    request.contentLength < 0)) {
              request.response.statusCode = 400;
              request.response.write(
                '{"error":{"message":"transfer encoding is not supported"}}',
              );
              await request.response.close();
              return;
            }
            if (request.contentLength >= 0) sizedPosts++;
            final body = jsonDecode(
              await request.cast<List<int>>().transform(utf8.decoder).join(),
            ) as Map;
            chatModels.add(body['model'] as String);
            if ((body['messages'] as List).last['content'] == 'hold') {
              if (!holdReached.isCompleted) holdReached.complete();
              await releaseHeld.future;
            }
            if (body['stream'] == true) {
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
              );
              request.response.bufferOutput = false;
              for (final frame in [
                {
                  'model': model,
                  'choices': [
                    {
                      'index': 0,
                      'delta': {'role': 'assistant', 'content': 'OK'},
                      'finish_reason': null,
                    },
                  ],
                },
                {
                  'model': model,
                  'choices': [
                    {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
                  ],
                },
                {
                  'model': model,
                  'choices': [],
                  'usage': {
                    'prompt_tokens': 2,
                    'completion_tokens': 1,
                    'total_tokens': 3,
                  },
                },
              ]) {
                request.response.write('data: ${jsonEncode(frame)}\n\n');
              }
              if ((body['messages'] as List).last['content'] == 'streamhold') {
                await request.response.flush();
                await releaseHeld.future;
              }
              if (!omitDone) request.response.write('data: [DONE]\n\n');
              await request.response.close();
              return;
            }
            response = {
              'model': model,
              'choices': [
                {
                  'index': 0,
                  'message': {
                    'role': 'assistant',
                    'content': emptyText ? '' : 'OK',
                    'reasoning_content': emptyText ? 'thought' : null,
                  },
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 2,
                'completion_tokens': 1,
                'total_tokens': 3,
              },
            };
          default:
            response = {'error': 'unknown'};
        }
        request.response.write(jsonEncode(response));
        await request.response.close();
      } on HttpException {
        /* client cancellation */
      } on SocketException {
        /* client cancellation */
      }
    });
    return child;
  }

  @override
  Future<bool> groupAlive(int ownedParentPid) async {
    if (unknownGroup) throw const SplashEngineException('group state unknown');
    return children.any(
      (child) =>
          child.pid == ownedParentPid &&
          (child.orphanLive || !child.done.isCompleted),
    );
  }

  @override
  Future<void> signalOwnedGroup(
    int ownedParentPid,
    ProcessSignal signal,
  ) async {
    groupSignals.add(ownedParentPid);
    children.singleWhere((child) => child.pid == ownedParentPid).kill(signal);
  }

  Future<void> close() async {
    if (!releaseHeld.isCompleted) releaseHeld.complete();
    if (identityRelease?.isCompleted == false) identityRelease!.complete();
    for (final socket in detachedIdentitySockets.toList()) {
      socket.destroy();
    }
    for (final child in children) {
      child.kill(ProcessSignal.sigterm);
      await child.exitCode;
    }
  }
}

class SplashTestChild implements EngineChild {
  SplashTestChild(this.server, this.pid);
  final HttpServer server;
  @override
  final int pid;
  final done = Completer<int>();
  bool orphanLive = false;
  bool closing = false;
  void crash() {
    orphanLive = true;
    done.complete(70);
  }

  @override
  Future<int> get exitCode => done.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    if (!closing) {
      closing = true;
      orphanLive = false;
      server.close(force: true).then((_) {
        if (!done.isCompleted) done.complete(0);
      });
    }
    return true;
  }
}
