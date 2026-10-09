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
  test(
    'linked Splash refuses content changed during actual help observation',
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
      await expectLater(
        SplashEngine.inspectInstallation(root, io: io),
        throwsA(isA<SplashEngineException>()),
      );
      expect(io.starts, 0);
      expect(io.calls.any((args) => args.contains('make')), isFalse);
    },
  );
  test(
    'source registration rejects Python outside its declared venv prefix',
    () async {
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
      await expectLater(
        SplashEngine.inspectInstallation(root, io: io),
        throwsA(isA<SplashEngineException>()),
      );
      expect(io.starts, 0);
    },
  );
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
  test('binding does not save a locally complete model rejected by native model-check', () async {
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
    await expectLater(
      engine.bindModel(fixture.asset.id, fixture.assembly),
      throwsA(isA<SplashEngineException>()),
    );
    expect(saved, 0);
    expect(engine.bindingFor(fixture.asset.id), isNull);
    expect(fixture.io.starts, 0);
  });
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
  test('restored installation is an unverified receipt until current identity is checked', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final recorded = SplashInstallation.fromJson(fixture.installation.toJson());
    final engine = fixture.engine(installation: recorded);
    expect(engine.state.installation, isNot(LlamaInstallationStatus.installed));
    await engine.refreshInstallation();
    expect(engine.state.installation, LlamaInstallationStatus.installed);
    await File('${fixture.source.path}/build/splash')
        .writeAsString('updated binary');
    await engine.refreshInstallation();
    expect(engine.state.installation, LlamaInstallationStatus.failed);
    await expectLater(
      engine.previewLaunch(fixture.asset.id),
      throwsA(isA<SplashEngineException>()),
    );
    expect(fixture.io.starts, 0);
    await engine.close();
  });
  test('actual help failure retains linked identity and built-in raw launch support', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.helpFailure = true;
    final installation = await SplashEngine.inspectInstallation(
      fixture.source,
      io: fixture.io,
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
  test('accepted start fixes all model use during precheck and shutdown prevents late spawn', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final deletion = await fixture.library.prepareDeletion([fixture.asset.id]);
    fixture.io.modelCheckEntered = Completer<void>();
    fixture.io.releaseCheck = Completer<void>();
    final pending = engine.startRuntime(fixture.asset.id);
    final rejected = expectLater(
      pending,
      throwsA(isA<SplashEngineException>()),
    );
    await fixture.io.modelCheckEntered!.future;
    try {
      await expectLater(
        fixture.library.delete(deletion, confirmed: true),
        throwsA(isA<LibraryException>()),
      );
    } finally {
      engine.beginShutdown();
      fixture.io.releaseCheck!.complete();
      await rejected;
      await engine.shutdown();
      await engine.close();
    }
    expect(fixture.io.starts, 0);
    expect(await File(fixture.asset.files.single.path).exists(), isTrue);
    expect(
      await fixture.library.prepareDeletion([fixture.asset.id]),
      isA<DeletionPlan>(),
    );
  });
  test(
    'source replacement withdraws every old Ready receipt without a reload',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final first = await engine.startRuntime(fixture.asset.id);
      await engine.startRuntime(fixture.asset.id);
      await File('${fixture.source.path}/build/splash')
          .writeAsString('replacement');
      await expectLater(
        engine.generateText(first.id, TextRequest(prompt: 'OK')),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.notReady,
          ),
        ),
      );
      expect(
        engine.runtimeInstances.every(
          (run) =>
              run.capabilities.isEmpty &&
              run.status == RuntimeInstanceStatus.failed,
        ),
        isTrue,
      );
      expect(fixture.io.starts, 2);
      await engine.shutdown();
      await engine.close();
    },
  );
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
      'startup refuses ${wrongPid ? 'unowned PID' : 'reasoning-only empty content'} as Ready',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        fixture.io.wrongPid = wrongPid;
        fixture.io.emptyText = !wrongPid;
        final engine = fixture.engine();
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        await expectLater(
          engine.startRuntime(fixture.asset.id),
          throwsA(isA<SplashEngineException>()),
        );
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
    final hashes = Map<String, Object?>.from(row['fingerprints'] as Map)
      ..remove(fixture.installation.python.path);
    expect(
      () => SplashInstallation.fromJson({...row, 'fingerprints': hashes}),
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
  test('binding verifies Git blob OIDs and SHA256 while persisting full SHA256 only', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final role = File('${fixture.assembly.path}/draft/config.json');
    await role.writeAsString('{"name":"草稿配置"}');
    final bytes = await role.readAsBytes();
    final fullHash = sha256.convert(bytes).toString();
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
    expect(binding.sourceHashes[await role.resolveSymbolicLinks()], fullHash);
    expect(
      binding.sourceHashes.values.every(
        (value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value),
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
      await expectLater(
        engine.bindModel(fixture.asset.id, fixture.assembly),
        throwsA(isA<SplashEngineException>()),
      );
      expect(saved, 1);
      expect(engine.bindingFor(fixture.asset.id), same(binding));
    }
    expect(fixture.io.starts, 0);
  });
  for (final failNative in [false, true]) {
    test(
      'bind precheck keeps fixed use and releases after ${failNative ? 'failure' : 'success'}',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
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
        final plan = await fixture.library.prepareDeletion([fixture.asset.id]);
        fixture.io.modelCheckFailure = failNative;
        fixture.io.modelCheckEntered = Completer<void>();
        fixture.io.releaseCheck = Completer<void>();
        final pending = engine.bindModel(fixture.asset.id, fixture.assembly);
        final completed = failNative
            ? expectLater(pending, throwsA(isA<SplashEngineException>()))
            : pending.then<void>((_) {});
        await fixture.io.modelCheckEntered!.future;
        try {
          await expectLater(
            fixture.library.delete(plan, confirmed: true),
            throwsA(isA<LibraryException>()),
          );
        } finally {
          fixture.io.releaseCheck!.complete();
          await completed;
        }
        expect(await File(fixture.asset.files.single.path).exists(), isTrue);
        expect(saved, failNative ? 0 : 1);
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
      'bind rechecks ${mutateManifest ? 'manifest' : 'source content'} after native check before replacing saved binding',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
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
        final old = await engine.bindModel(fixture.asset.id, fixture.assembly);
        fixture.io.modelCheckEntered = Completer<void>();
        fixture.io.releaseCheck = Completer<void>();
        final pending = engine.bindModel(fixture.asset.id, fixture.assembly);
        final rejected = expectLater(
          pending,
          throwsA(isA<SplashEngineException>()),
        );
        await fixture.io.modelCheckEntered!.future;
        if (mutateManifest) {
          final file = File('${fixture.assembly.path}/model.json');
          final row = jsonDecode(await file.readAsString()) as Map;
          row['model'] = 'changed/model';
          await file.writeAsString(jsonEncode(row));
        } else {
          await File('${fixture.assembly.path}/draft/config.json')
              .writeAsString('{"fixture":"changed after check began"}');
        }
        fixture.io.releaseCheck!.complete();
        await rejected;
        expect(saved, 1);
        expect(engine.bindingFor(fixture.asset.id), same(old));
        expect(
          await fixture.library.prepareDeletion([fixture.asset.id]),
          isA<DeletionPlan>(),
        );
        expect(fixture.io.starts, 0);
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

  static Future<SplashRuntimeFixture> create() async {
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
    final installation = await SplashEngine.inspectInstallation(source, io: io);
    final library = ModelLibrary();
    final model = await writeDecisionKev(
      Directory('${root.path}/models'),
      ordinaryChat: true,
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
  int starts = 0;
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
          case '/v1/chat/completions':
            final body = jsonDecode(
              await request.cast<List<int>>().transform(utf8.decoder).join(),
            ) as Map;
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
