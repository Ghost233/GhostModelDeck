import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  for (final lateLink in [false, true]) {
    test(
      'catalog recycle holds ${lateLink ? 'late linked' : 'captured'} provider admission until every child exits',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-aggregate-recycle-',
        );
        final library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final ios = [_RuntimeIO(), _RuntimeIO(standard: true), _RuntimeIO()];
        final providers = <LlamaEngine>[];
        late EngineCatalog catalog;
        addTearDown(() async {
          if (ios[1].stopRelease != null && !ios[1].stopRelease!.isCompleted) {
            ios[1].stopRelease!.complete();
          }
          await catalog.stopManaged();
          catalog.close();
          for (final provider in providers) {
            provider.close();
          }
          library.close();
          await root.delete(recursive: true);
        });
        final models = Directory('${root.path}/models');
        await writeDecisionKev(models, ordinaryChat: true);
        final asset = (await library.scan(models, verifyFiles: true)).single;
        final archives = <File>[];
        for (var index = 0; index < 2; index++) {
          final standard = index == 1;
          final data = engineArchive(
            artifactTag: standard ? 'b11146' : 'b11381',
          );
          archives.add(
            await File('${root.path}/$index.tar.gz').writeAsBytes(data),
          );
          providers.add(
            LlamaEngine(
              library: library,
              useRegistry: use,
              installationDirectory: Directory('${root.path}/engines'),
              io: ios[index],
              release: LlamaRelease(
                tag: standard ? 'v0.5.0' : 'b11381',
                artifactTag: standard ? 'b11146' : 'b11381',
                expectedBuild: standard ? 11146 : 11381,
                supportsSystemone: !standard,
                expectedBinaryVersion: '0.5.0-dev',
                commit: standard
                    ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                    : '836d57176',
                url: Uri.parse('https://github.com/fixture/$index'),
                sha256: sha256.convert(data).toString(),
                sizeBytes: data.length,
              ),
            ),
          );
        }
        catalog = EngineCatalog(
          library: library,
          officialEngine: providers[0],
          standardEngine: providers[1],
          useRegistry: use,
          registryFile: File('${root.path}/registry.json'),
          io: ios[2],
        );
        await catalog.installOfficial(verifiedArchive: archives[0]);
        await catalog.installManaged(
          EngineCatalog.standardId,
          verifiedArchive: archives[1],
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          final capturedA = catalog.providerFor(EngineCatalog.officialId);
          final runtimeA = catalog.runtimeFor(EngineCatalog.officialId);
          expect(runtimeA, same(capturedA));
          expect(catalog.state.entries.first.family, EngineFamily.llamaCpp);
          final a = await runtimeA.startRuntime(asset.id);
          expect(a.status, RuntimeInstanceStatus.ready);
          expect(a.capabilities, contains(RuntimeCapability.textGeneration));
          expect(
            a.capabilities,
            isNot(contains(RuntimeCapability.choiceProbability)),
          );
          expect(catalog.runsFor([asset.id]).single.instance.id, a.id);
          await providers[1].start(asset.id);
          Future<EngineRegistration>? linking;
          if (lateLink) {
            final external = await File('${root.path}/external/llama-server')
                .create(recursive: true);
            await external.writeAsString('external native fixture');
            expect(
              (await Process.run('/bin/chmod', ['+x', external.path])).exitCode,
              0,
            );
            ios[2].inspectionRequested = Completer<void>();
            ios[2].inspectionRelease = Completer<void>();
            linking = catalog.link(external.path);
            await ios[2].inspectionRequested!.future.timeout(
              const Duration(seconds: 3),
            );
          }
          ios[1].stopRelease = Completer<void>();
          ios[1].stopRequested = Completer<void>();
          final aStopped = capturedA.changes.firstWhere(
            (s) => s.instances.single.status == LlamaInstanceStatus.stopped,
          );
          var recycled = false;
          final recycle = catalog.stopManaged().then((_) => recycled = true);
          try {
            await ios[1].stopRequested!.future.timeout(
              const Duration(seconds: 3),
            );
            await aStopped.timeout(const Duration(seconds: 3));
            await expectLater(
              capturedA.start(asset.id),
              throwsA(isA<LlamaEngineException>()),
            );
            await expectLater(
              providers[1].start(asset.id),
              throwsA(isA<LlamaEngineException>()),
            );
            if (linking != null) {
              final bStopped = providers[1].changes.firstWhere(
                (s) => s.instances.single.status == LlamaInstanceStatus.stopped,
              );
              ios[1].stopRelease!.complete();
              await bStopped.timeout(const Duration(seconds: 3));
              // One event-loop turn settles the completed child futures, while the
              // preaccepted link remains held at its real command I/O seam.
              await Future<void>.delayed(Duration.zero);
              expect(
                recycled,
                isFalse,
                reason: 'catalog must drain preaccepted enrollment',
              );
              ios[2].inspectionRelease!.complete();
              final linked = await linking.timeout(const Duration(seconds: 3));
              final lateProvider = catalog.providerFor(linked.id);
              await expectLater(
                lateProvider.start(asset.id),
                throwsA(isA<LlamaEngineException>()),
              );
              expect(lateProvider.state.instances, isEmpty);
            }
            expect(ios.map((io) => io.startedExecutables.length), [1, 1, 0]);
          } finally {
            if (ios[2].inspectionRelease != null &&
                !ios[2].inspectionRelease!.isCompleted) {
              ios[2].inspectionRelease!.complete();
            }
            if (!ios[1].stopRelease!.isCompleted) {
              ios[1].stopRelease!.complete();
            }
            await recycle;
          }
          expect(
            providers.every(
              (p) => p.state.instances.every((i) => !i.hasLiveProcess),
            ),
            isTrue,
          );
          final next = await capturedA.start(asset.id);
          expect(next.generation, greaterThan(a.generation));
          await capturedA.stopManaged();
          final standalone = await capturedA.start(asset.id);
          expect(standalone.generation, greaterThan(next.generation));
        }, _NetworkBoundary());
      },
    );
  }
  test('dual managed and linked process identities recycle and seal together while removal owns only selected scope', () async {
    final root = await Directory.systemTemp.createTemp('gmd-three-providers-');
    final library = ModelLibrary();
    final use = ModelUseRegistry(library);
    final ios = [_RuntimeIO(), _RuntimeIO(standard: true), _RuntimeIO()];
    final providers = <LlamaEngine>[];
    late EngineCatalog catalog;
    addTearDown(() async {
      await catalog.stopManaged();
      catalog.close();
      for (final provider in providers) {
        provider.close();
      }
      library.close();
      await root.delete(recursive: true);
    });
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: true);
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final archives = <File>[];
    for (var index = 0; index < 2; index++) {
      final standard = index == 1;
      final data = engineArchive(artifactTag: standard ? 'b11146' : 'b11381');
      archives.add(await File('${root.path}/$index.tar.gz').writeAsBytes(data));
      providers.add(
        LlamaEngine(
          library: library,
          useRegistry: use,
          installationDirectory: Directory('${root.path}/engines'),
          io: ios[index],
          release: LlamaRelease(
            tag: standard ? 'v0.5.0' : 'b11381',
            artifactTag: standard ? 'b11146' : 'b11381',
            expectedBuild: standard ? 11146 : 11381,
            supportsSystemone: !standard,
            expectedBinaryVersion: '0.5.0-dev',
            commit: standard
                ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                : '836d57176',
            url: Uri.parse('https://github.com/fixture/$index'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        ),
      );
    }
    catalog = EngineCatalog(
      library: library,
      officialEngine: providers[0],
      standardEngine: providers[1],
      useRegistry: use,
      registryFile: File('${root.path}/registry.json'),
      io: ios[2],
    );
    await catalog.installOfficial(verifiedArchive: archives[0]);
    await catalog.installManaged(
      EngineCatalog.standardId,
      verifiedArchive: archives[1],
    );
    final external = await File('${root.path}/external/llama-server')
        .create(recursive: true);
    await external.writeAsString('external native fixture');
    final chmod = await Process.run('/bin/chmod', ['+x', external.path]);
    expect(chmod.exitCode, 0);
    final linked = await catalog.link(external.parent.path);
    expect(linked.archiveSha256, isNull);
    expect(linked.release, isNull);
    expect(linked.binarySha256, isNotNull);
    final all = [...providers, catalog.providerFor(linked.id)];
    await HttpOverrides.runWithHttpOverrides(() async {
      final first = <LlamaInstance>[];
      for (final provider in all) {
        first.add(await provider.start(asset.id));
      }
      expect(first.map((i) => i.installationId).toSet(), {
        EngineCatalog.officialId,
        EngineCatalog.standardId,
        linked.id,
      });
      expect(first.map((i) => i.engineServiceId).toSet(), hasLength(3));
      expect(
        first.map((i) => i.modelInferenceInstanceId).toSet(),
        hasLength(3),
      );
      expect(
        first.every(
          (i) =>
              i.nativeAlias == i.id &&
              i.capabilities.contains(LlamaCapability.textGeneration),
        ),
        isTrue,
      );
      await expectLater(
        catalog.prepareRemoval(EngineCatalog.standardId),
        throwsA(isA<LlamaEngineException>()),
      );
      ios.first.stopFailure = true;
      await expectLater(
        catalog.stopManaged(),
        throwsA(isA<LlamaEngineException>()),
      );
      expect(ios.map((i) => i.stopAttempts), [1, 1, 1]);
      expect(all.first.state.instances.single.hasLiveProcess, isTrue);
      expect(all.first.state.instances.single.capabilities, isEmpty);
      expect(all[1].state.instances.single.status, LlamaInstanceStatus.stopped);
      expect(all[2].state.instances.single.status, LlamaInstanceStatus.stopped);
      await catalog.stopManaged();
      expect(ios.map((i) => i.stopAttempts), [2, 1, 1]);
      for (final provider in all) {
        expect(
          provider.state.instances.single.status,
          LlamaInstanceStatus.stopped,
        );
        expect(provider.state.instances.single.nativeAlias, isNull);
        expect(provider.state.instances.single.capabilities, isEmpty);
      }
      final restarted = <LlamaInstance>[];
      for (final provider in all) {
        restarted.add(await provider.start(asset.id));
      }
      for (var index = 0; index < 3; index++) {
        expect(restarted[index].installationId, first[index].installationId);
        expect(
          restarted[index].engineServiceId,
          isNot(first[index].engineServiceId),
        );
        expect(restarted[index].id, isNot(first[index].id));
        expect(
          restarted[index].generation,
          greaterThan(first[index].generation),
        );
      }
      final standardBinary = File(all[1].executablePath!);
      await standardBinary.writeAsString('foreign replacement');
      await catalog.refresh();
      expect(all[1].state.installation, LlamaInstallationStatus.failed);
      expect(all[1].state.instances.last.capabilities, isEmpty);
      expect(all[1].state.instances.last.acceptingRequests, isFalse);
      expect(all[1].state.instances.last.nativeAlias, isNull);
      expect(all[1].state.instances.last.hasLiveProcess, isTrue);
      expect(all[0].state.instances.last.status, LlamaInstanceStatus.ready);
      expect(all[2].state.instances.last.status, LlamaInstanceStatus.ready);
      await standardBinary.writeAsString('server fixture');
      await catalog.refresh();
      expect(
        all[1].state.instances.last.capabilities,
        isEmpty,
        reason: 'repair must not resurrect old generation evidence',
      );
      await all[1].stop(restarted[1].id);
      final removal = await catalog.prepareRemoval(EngineCatalog.standardId);
      await catalog.remove(removal, confirmed: true);
      expect(all[0].state.instances.last.status, LlamaInstanceStatus.ready);
      expect(all[2].state.instances.last.status, LlamaInstanceStatus.ready);
      expect(await external.readAsString(), 'external native fixture');
      await catalog.shutdown();
      expect(ios.map((i) => i.stopAttempts), [3, 2, 2]);
      for (final provider in all) {
        expect(provider.state.instances.last.capabilities, isEmpty);
        await expectLater(provider.start(asset.id), throwsA(isA<StateError>()));
      }
    }, _NetworkBoundary());
  });
  for (final selection in [(false, false), (true, false), (true, true)]) {
    final (ordinaryChat, standard) = selection;
    testWidgets(
      'running ${standard
          ? 'selected standard ordinary text'
          : ordinaryChat
          ? 'ordinary text'
          : 'decision'} from the library discovers an existing installation without visiting engine management',
      (tester) async {
        late Directory root, models;
        late ModelLibrary library;
        late LlamaEngine original, fresh;
        LlamaEngine? peer;
        late EngineCatalog catalog;
        final io = _RuntimeIO(standard: standard);
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('jev-library-run-');
          models = Directory('${root.path}/models');
          await writeDecisionKev(models, ordinaryChat: ordinaryChat);
          library = ModelLibrary();
          final use = ModelUseRegistry(library);
          final data = engineArchive(
            artifactTag: standard ? 'b11146' : 'b11381',
          );
          final archive = await File('${root.path}/release.tar.gz')
              .writeAsBytes(data);
          final release = LlamaRelease(
            tag: standard ? 'v0.5.0' : 'b11381',
            artifactTag: standard ? 'b11146' : 'b11381',
            expectedBuild: standard ? 11146 : 11381,
            supportsSystemone: !standard,
            commit: standard
                ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                : '836d57176',
            url: Uri.parse('https://github.com/fixture'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          );
          final owned = Directory('${root.path}/engines');
          original = LlamaEngine(
            library: library,
            installationDirectory: owned,
            io: io,
            release: release,
            useRegistry: use,
          );
          await original.install(verifiedArchive: archive);
          fresh = LlamaEngine(
            library: library,
            installationDirectory: owned,
            io: io,
            release: release,
            useRegistry: use,
            loadTimeout: const Duration(seconds: 2),
          );
          if (standard) {
            final peerData = engineArchive();
            final peerArchive = await File('${root.path}/peer.tar.gz')
                .writeAsBytes(peerData);
            peer = LlamaEngine(
              library: library,
              installationDirectory: owned,
              useRegistry: use,
              io: _RuntimeIO(),
              release: LlamaRelease(
                tag: 'b11381',
                commit: '836d57176',
                url: Uri.parse('https://github.com/fixture'),
                sha256: sha256.convert(peerData).toString(),
                sizeBytes: peerData.length,
              ),
            );
            await peer!.install(verifiedArchive: peerArchive);
          }
          catalog = EngineCatalog(
            library: library,
            officialEngine: peer ?? fresh,
            standardEngine: standard ? fresh : null,
            useRegistry: use,
            registryFile: File('${root.path}/private/engines.json'),
            io: io,
          );
        });
        addTearDown(() async {
          await tester.runAsync(() async {
            if (io.stopRelease != null && !io.stopRelease!.isCompleted) {
              io.stopRelease!.complete();
            }
            await catalog.stopManaged();
            catalog.close();
            original.close();
            fresh.close();
            peer?.close();
            library.close();
            await root.delete(recursive: true);
          });
        });
        expect(fresh.state.installation, LlamaInstallationStatus.absent);
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildJevTheme(Brightness.light),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(28),
                  child: LibraryPage(
                    library: library,
                    libraryPath: models.path,
                    engines: catalog,
                  ),
                ),
              ),
            ),
          );
          for (var n = 0; n < 100; n++) {
            await tester.pump();
            final run = find.widgetWithText(TextButton, '运行');
            if (run.evaluate().isNotEmpty &&
                tester.widget<TextButton>(run).onPressed != null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await tester.tap(find.widgetWithText(TextButton, '运行'));
          for (var n = 0; n < 100; n++) {
            await tester.pump();
            final dropdown = find.byType(DropdownButton<String>);
            if (dropdown.evaluate().isNotEmpty &&
                tester.widget<DropdownButton<String>>(dropdown).items!.length ==
                    (standard ? 2 : 1) &&
                tester.widget<DropdownButton<String>>(dropdown).onChanged !=
                    null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        final dropdown = tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>),
        );
        expect(dropdown.items, hasLength(standard ? 2 : 1));
        if (standard) {
          await tester.tap(find.byType(DropdownButton<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('llama.cpp · 标准 v0.5.0').last);
          await tester.pumpAndSettle();
        }
        expect(find.text('请先安装或关联引擎'), findsNothing);
        final engineField = find.byType(DropdownButtonFormField<String>);
        final version = find.textContaining(
          standard ? '7fe450e19' : '836d57176',
        );
        final fieldBounds = tester.getRect(engineField);
        final versionBounds = tester.getRect(version);
        expect(versionBounds.top, greaterThanOrEqualTo(fieldBounds.top));
        expect(
          versionBounds.bottom,
          lessThanOrEqualTo(fieldBounds.bottom),
          reason: 'The selected engine version must stay inside its input',
        );
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final completed = catalog.changes.firstWhere(
              (_) => fresh.state.instances.any(
                (instance) => instance.status == LlamaInstanceStatus.ready,
              ),
            );
            await tester.tap(find.widgetWithText(FilledButton, '运行'));
            await completed.timeout(const Duration(seconds: 5));
          }, _NetworkBoundary()),
        );
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        expect(find.text('运行中'), findsOneWidget);
        expect(find.text('运行模型'), findsNothing);
        expect(find.widgetWithText(TextButton, '停止'), findsOneWidget);
        if (ordinaryChat) {
          expect(fresh.state.instances.single.lastTextResult!.text, 'Hello.');
          expect(fresh.state.instances.single.capabilities, {
            LlamaCapability.textGeneration,
          });
          expect(fresh.state.instances.single.lastResult, isNull);
        } else {
          expect(fresh.state.instances.single.lastResult!.probabilities, {
            'keep': 0.25,
            'change': 0.75,
          });
        }
        final instance = fresh.state.instances.single;
        expect(
          instance.installationId,
          standard ? EngineCatalog.standardId : EngineCatalog.officialId,
        );
        expect(instance.engineServiceId, isNotNull);
        expect(
          instance.engineServiceId,
          isNot(instance.modelInferenceInstanceId),
        );
        expect(instance.nativeAlias, instance.id);
        expect(instance.pid, 42421);
        expect(instance.generation, greaterThan(0));
        expect(instance.binaryVersion!.build, standard ? 11146 : 11381);
        expect(instance.binaryVersion!.semanticVersion, '0.5.0-dev');
        expect(
          instance.processEnvironment,
          isNull,
          reason: 'I/O fixture does not observe a native environment',
        );
        expect(
          io.startedExecutables.single,
          endsWith('/${standard ? 'v0.5.0' : 'b11381'}/llama-server'),
        );
        if (standard) expect(peer!.state.instances, isEmpty);
        expect(library.state.artifacts.single.fingerprintsVerified, isTrue);
        await expectLater(
          library.prepareDeletion([library.state.artifacts.single.id]),
          throwsA(isA<LibraryException>()),
        );
        io.stopFailure = true;
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(TextButton, '停止'));
          await _settleFilesystemFrames(tester);
        });
        expect(find.text('Bad state: provider refused stop'), findsOneWidget);
        expect(fresh.state.instances.single.status, LlamaInstanceStatus.failed);
        expect(fresh.state.instances.single.hasLiveProcess, isTrue);
        expect(fresh.state.instances.single.acceptingRequests, isFalse);
        expect(fresh.state.instances.single.capabilities, isEmpty);
        await expectLater(
          library.prepareDeletion([library.state.artifacts.single.id]),
          throwsA(isA<LibraryException>()),
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '停止'))
              .onPressed,
          isNotNull,
        );
        io.stopRelease = Completer<void>();
        io.stopRequested = Completer<void>();
        await tester.runAsync(() async {
          final stopped = catalog.changes.firstWhere(
            (_) =>
                fresh.state.instances.single.status ==
                LlamaInstanceStatus.stopped,
          );
          await tester.ensureVisible(find.widgetWithText(TextButton, '停止'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(TextButton, '停止'));
          await tester.pump();
          await io.stopRequested!.future.timeout(const Duration(seconds: 3));
          await tester.pump();
          expect(find.text('运行中'), findsNothing);
          final pendingStop = find.widgetWithText(TextButton, '停止中');
          expect(pendingStop, findsOneWidget);
          expect(tester.widget<TextButton>(pendingStop).onPressed, isNull);
          await tester.tap(pendingStop);
          expect(io.stopAttempts, 2);
          io.stopRelease!.complete();
          for (var n = 0; n < 200; n++) {
            await tester.pump();
            if (fresh.state.instances.single.status ==
                LlamaInstanceStatus.stopped) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          await stopped.timeout(const Duration(seconds: 5));
          expect(
            (await library.prepareDeletion([library.state.artifacts.single.id]))
                .files,
            hasLength(1),
          );
        });
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        expect(find.text('已停止'), findsOneWidget);
        expect(fresh.state.instances.single.hasLiveProcess, isFalse);
        expect(find.text('运行中'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _NetworkBoundary extends HttpOverrides {}

Future<void> _settleFilesystemFrames(WidgetTester tester) async {
  for (var n = 0; n < 100; n++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.text('运行模型').evaluate().isEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Runtime page did not settle');
}

class _RuntimeIO implements EngineProcessIO {
  _RuntimeIO({this.standard = false});
  final bool standard;
  final startedExecutables = <String>[];
  bool stopFailure = false;
  int stopAttempts = 0;
  Completer<void>? stopRelease;
  Completer<void>? stopRequested;
  Completer<void>? inspectionRequested;
  Completer<void>? inspectionRelease;
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.singleOrNull == '--help') {
      return const EngineCommandResult(
        0,
        '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device',
        '',
      );
    }
    if (arguments.singleOrNull == '--version') {
      if (inspectionRequested != null && !inspectionRequested!.isCompleted) {
        inspectionRequested!.complete();
        await inspectionRelease!.future;
      }
      return EngineCommandResult(
        0,
        standard
            ? 'version: 0.5.0-dev (build 11146, commit 7fe450e19)\nbuilt for Darwin arm64'
            : 'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
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

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    startedExecutables.add(executable);
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': arg('--alias'),
            'model_path': arg('--model'),
          }),
        );
      } else if (request.uri.path == '/v1/chat/completions') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], arg('--alias'));
        expect(body['stream'], false);
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'Hello.'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'completion_tokens': 2},
          }),
        );
      } else {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (!(body['questions'] as Map).containsKey('council_choice')) {
          request.response.statusCode = HttpStatus.notImplemented;
          request.response.write('{"error":"fixture has no typed head"}');
          await request.response.close();
          return;
        }
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
                  options.keys.last: 0.75,
                },
              },
            },
            'usage': {'output_tokens': 0},
          }),
        );
      }
      await request.response.close();
    });
    return _RuntimeChild(server, this);
  }
}

class _RuntimeChild implements EngineChild {
  _RuntimeChild(this.server, this.io);
  final HttpServer server;
  final _RuntimeIO io;
  final stopped = Completer<int>();
  @override
  int get pid => 42421;
  @override
  Future<int> get exitCode => stopped.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    io.stopAttempts++;
    if (io.stopFailure) {
      io.stopFailure = false;
      throw StateError('provider refused stop');
    }
    if (io.stopRequested != null && !io.stopRequested!.isCompleted) {
      io.stopRequested!.complete();
    }
    server.close(force: true).then((_) async {
      await io.stopRelease?.future;
      if (!stopped.isCompleted) stopped.complete(0);
    });
    return true;
  }
}
