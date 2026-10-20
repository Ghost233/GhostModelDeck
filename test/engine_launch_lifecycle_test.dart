import 'fixtures/parameter_editor_navigation.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/jev_debug.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  test(
    'llama spawn failures hide CLI keys before process ownership starts',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.close);
      fixture.io.failStart = true;
      final engine = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/auth-managed'),
        io: fixture.io,
        linkedInstallation: await inspectLinkedLlama(
          fixture.binary,
          fixture.io,
        ),
      );
      addTearDown(() async {
        await engine.shutdown();
        engine.close();
      });
      await engine.refreshInstallation();
      Object? failure;
      try {
        await engine.start(
          fixture.asset.id,
          configuration: EngineLaunchConfiguration(
            formValues: {'--api-key': 'spawn-private-key'},
          ),
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<LlamaEngineException>());
      expect(failure.toString(), isNot(contains('spawn-private-key')));
      expect(
        engine.runtimeInstances.single.error,
        isNot(contains('spawn-private-key')),
      );
      expect(engine.runtimeInstances.single.hasLiveProcess, isFalse);
    }, _LifecycleNetwork()),
  );
  test(
    'llama API key permits owned startup and keeps protected discovery closed',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.close);
      final engine = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/auth-managed'),
        io: fixture.io,
        linkedInstallation: await inspectLinkedLlama(
          fixture.binary,
          fixture.io,
        ),
        loadTimeout: const Duration(milliseconds: 300),
        sourceBuild: {'supports_systemone': true},
      );
      addTearDown(() async {
        await engine.shutdown();
        engine.close();
      });
      await engine.refreshInstallation();
      final run = await engine.start(
        fixture.asset.id,
        configuration: EngineLaunchConfiguration(
          formValues: {'--api-key': 'form-key'},
          argumentText: '--api-key text-key,second-key',
        ),
      );
      expect(run.status, LlamaInstanceStatus.ready);
      final client = HttpClient();
      try {
        for (final key in [null, 'wrong-key', 'text-key']) {
          final request = await client.getUrl(run.endpoint.resolve('/props'));
          if (key != null) request.headers.set('Authorization', 'Bearer $key');
          final response = await request.close();
          expect(response.statusCode, key == 'text-key' ? 200 : 401);
          await response.drain<void>();
        }
      } finally {
        client.close(force: true);
      }
      expect(
        (await engine.generateText(run.id, TextRequest(prompt: 'hello'))).text,
        'hello',
      );
      final events = await engine
          .streamText(run.id, TextRequest(prompt: 'hello'))
          .toList();
      expect(
        events.where((event) => event.result != null).single.result!.text,
        'hello',
      );
      final telemetry = await engine.readTelemetry(
        run.id,
        cancellation: DecisionCancellation(),
      );
      expect(telemetry.running, 0);
      expect(
        (await engine.decide(
          run.id,
          DecisionRequest(
            state: 'test',
            instructions: 'choose',
            options: {'yes': 'Yes', 'no': 'No'},
          ),
        )).choice,
        'yes',
      );
      fixture.io.inferenceError = 'native rejected text-key and second-key';
      final trace = DecisionIOTrace();
      Object? failure;
      try {
        await engine.decideBatch(
          run.id,
          DecisionBatchRequest(
            state: 'text-key',
            questions: {
              'pick': ChoiceQuestion(
                instructions: 'choose',
                options: {'yes': 'Yes', 'no': 'No'},
              ),
            },
          ),
          ioTrace: trace,
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<LlamaRequestException>());
      for (final key in ['text-key', 'second-key']) {
        expect(failure.toString(), isNot(contains(key)));
        expect(
          (failure as LlamaRequestException).rawResponse,
          isNot(contains(key)),
        );
        expect(jsonEncode(trace.toJson()), isNot(contains(key)));
      }
    }, _LifecycleNetwork()),
  );
  test(
    'llama key files and saved keys stay isolated between running owners',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.close);
      final keys = File('${fixture.root.path}/keys.txt');
      await keys.writeAsString('# comment\n\nfile-key\nspare-key\n');
      var configuration = EngineLaunchConfiguration(
        formValues: {'--api-key-file': keys.path},
      );
      final engine = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/auth-managed'),
        io: fixture.io,
        linkedInstallation: await inspectLinkedLlama(
          fixture.binary,
          fixture.io,
        ),
        loadTimeout: const Duration(milliseconds: 300),
        sourceBuild: {'supports_systemone': false},
      )..readLaunchConfigurationFrom((_) => configuration);
      addTearDown(() async {
        await engine.shutdown();
        engine.close();
      });
      await engine.refreshInstallation();
      final first = await engine.start(fixture.asset.id);
      await keys.writeAsString('changed-file-key\n');
      configuration = EngineLaunchConfiguration(
        formValues: {},
        argumentText: '--api_key second-owner-key',
      );
      expect(
        (await engine.generateText(
          first.id,
          TextRequest(prompt: 'hello'),
        )).text,
        'hello',
      );
      final second = await engine.start(fixture.asset.id);
      expect(
        (await engine.generateText(
          second.id,
          TextRequest(prompt: 'hello'),
        )).text,
        'hello',
      );
      final firstEvents = await engine
          .streamText(first.id, TextRequest(prompt: 'hello'))
          .toList();
      expect(
        firstEvents.where((event) => event.result != null).single.result!.text,
        'hello',
      );
      await engine.stop(first.id);
      expect(
        (await engine.generateText(
          second.id,
          TextRequest(prompt: 'hello'),
        )).text,
        'hello',
      );
    }, _LifecycleNetwork()),
  );
  test('unlink keeps saved instances and their parameters without retaining engine history', () async {
    final fixture = await _LifecycleFixture.create();
    addTearDown(fixture.close);
    final entry = await fixture.catalog.link(fixture.binary.path);
    final file = File('${fixture.root.path}/instances.json');
    final instances = LaunchInstances(catalog: fixture.catalog, file: file);
    addTearDown(instances.close);
    final saved = await instances.save(
      name: 'My model',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '2048'},
        argumentText: '--threads 3',
      ),
    );
    final original = await file.readAsString();
    await fixture.catalog.remove(
      await fixture.catalog.prepareRemoval(entry.id),
      confirmed: true,
    );
    expect(await file.readAsString(), original);
    expect(instances.find(saved.id)!.publicName, saved.publicName);
    expect(instances.missingReason(saved), '引擎缺失或未安装');
    await fixture.reopen();
    final reopened = LaunchInstances(catalog: fixture.catalog, file: file);
    addTearDown(reopened.close);
    await reopened.load();
    final retained = reopened.find(saved.id)!;
    expect(retained.toJson(), saved.toJson());
    expect(reopened.missingReason(retained), '引擎缺失或未安装');
    expect(await fixture.binary.readAsString(), 'original linked engine');
    expect(fixture.io.startedArguments, isEmpty);
  });

  test(
    'obsolete history fields are ignored on load and omitted on the next save',
    () async {
      for (final obsolete in <Object?>[
        null,
        17,
        {
          'old-engine': {'defaults': 'invalid old configuration'},
        },
      ]) {
        final fixture = await _LifecycleFixture.create();
        addTearDown(fixture.close);
        final entry = await fixture.catalog.link(fixture.binary.path);
        final file = fixture.catalog.registryFile;
        final value = jsonDecode(await file.readAsString()) as Map;
        value['schema'] = 5;
        value['launchDefaults'] = {};
        value['modelLaunchOverrides'] = {};
        value['unlinkedConfigurations'] = obsolete;
        await file.writeAsString(jsonEncode(value));
        await fixture.reopen();
        expect(
          fixture.catalog.state.entries.any((e) => e.id == entry.id),
          isTrue,
        );
        await fixture.catalog.saveLaunchDefaults(
          entry.id,
          EngineLaunchConfiguration(formValues: {'--ctx-size': '8192'}),
        );
        final saved = jsonDecode(await file.readAsString()) as Map;
        expect(saved.containsKey('unlinkedConfigurations'), isFalse);
        expect(
          fixture.catalog.launchDefaultsFor(entry.id).formValues['--ctx-size'],
          '8192',
        );
        expect(fixture.io.startedArguments, isEmpty);
      }
    },
  );

  testWidgets(
    'unlink leaves no configuration history or recovery entry after reopen',
    (tester) async {
      final fixture = (await tester.runAsync(_LifecycleFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      late String artifactId;
      await tester.runAsync(() async {
        final entry = await fixture.catalog.link(fixture.binary.path);
        artifactId = fixture.asset.id;
        await fixture.catalog.saveModelLaunchOverrides(
          entry.id,
          artifactId,
          EngineLaunchConfiguration(
            formValues: {'--ctx-size': '1024'},
            argumentText: ' --threads 5\n',
          ),
        );
        await fixture.catalog.setModelLaunchMode(
          entry.id,
          artifactId,
          independent: false,
        );
        await fixture.catalog.remove(
          await fixture.catalog.prepareRemoval(entry.id),
          confirmed: true,
        );
        await fixture.reopen();
      });
      await _showPage(tester, fixture);
      expect(find.text('未关联启动配置'), findsNothing);
      expect(find.text('选择目标恢复'), findsNothing);
      final saved = await tester.runAsync(
        () => fixture.catalog.registryFile.readAsString(),
      );
      expect(
        (jsonDecode(saved!) as Map).containsKey('unlinkedConfigurations'),
        isFalse,
      );
      expect(fixture.io.startedArguments, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test('unlink preserves its registration on write failure and refuses an accepted startup', () async {
    final fixture = await _LifecycleFixture.create();
    addTearDown(fixture.close);
    final entry = await fixture.catalog.link(fixture.binary.path);
    await fixture.catalog.saveLaunchDefaults(
      entry.id,
      EngineLaunchConfiguration(formValues: {'--ctx-size': '2048'}),
    );
    final plan = await fixture.catalog.prepareRemoval(entry.id);
    final original = await fixture.catalog.registryFile.readAsString();
    final obstruction = await Directory(
      '${fixture.catalog.registryFile.path}.tmp',
    ).create();
    await expectLater(
      fixture.catalog.remove(plan, confirmed: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      fixture.catalog.providerFor(entry.id).state.installation,
      LlamaInstallationStatus.installed,
    );
    expect(
      (jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map)
          .containsKey('unlinkedConfigurations'),
      isFalse,
    );
    expect(await fixture.catalog.registryFile.readAsString(), original);
    await obstruction.delete();
    await HttpOverrides.runWithHttpOverrides(() async {
      final provider = fixture.catalog.providerFor(entry.id);
      fixture.io.startEntered = Completer<void>();
      fixture.io.releaseStart = Completer<void>();
      final startup = provider.start(fixture.asset.id);
      await fixture.io.startEntered!.future.timeout(const Duration(seconds: 5));
      expect(
        provider.hasLiveInstances,
        isTrue,
        reason:
            'accepted startup owns a pending process before it becomes ready',
      );
      final removalAdmitted = fixture.catalog.changes.firstWhere(
        (state) => state.busy,
      );
      final rejectedRemoval = expectLater(
        fixture.catalog.remove(plan, confirmed: true),
        throwsA(isA<LlamaEngineException>()),
      );
      await removalAdmitted.timeout(const Duration(seconds: 5));
      fixture.io.releaseStart!.complete();
      final running = await startup;
      await rejectedRemoval;
      expect(
        running.status,
        LlamaInstanceStatus.ready,
        reason: 'already accepted startup keeps ownership',
      );
      expect(
        fixture.catalog.state.entries.any((value) => value.id == entry.id),
        isTrue,
      );
      expect(
        (jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map)
            .containsKey('unlinkedConfigurations'),
        isFalse,
      );
      expect(await fixture.catalog.registryFile.readAsString(), original);
      expect(
        running.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '2048']),
      );
      await provider.stop(running.id);
      fixture.io.startEntered = null;
      fixture.io.releaseStart = null;
      await fixture.catalog.remove(
        await fixture.catalog.prepareRemoval(entry.id),
        confirmed: true,
      );
    }, _LifecycleNetwork());
    expect(
      fixture.catalog.state.entries.any((value) => value.id == entry.id),
      isFalse,
    );
    final saved =
        jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map;
    expect(saved.containsKey('unlinkedConfigurations'), isFalse);
    expect(
      (saved['launchDefaults'] as Map?)?.containsKey(entry.id) ?? false,
      isFalse,
    );
    expect(
      (saved['configurationVersions'] as Map?)?.containsKey(entry.id) ?? false,
      isFalse,
    );
    expect(await fixture.binary.readAsString(), 'original linked engine');
  });
  test('mixed-family persisted configurations are rejected before applying any registration', () async {
    for (final location in [
      'active-default',
      'active-model',
      'managed-default',
    ]) {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.close);
      final registration = await fixture.catalog.link(fixture.binary.path);
      await fixture.catalog.saveLaunchDefaults(
        registration.id,
        EngineLaunchConfiguration(formValues: {'--ctx-size': '2048'}),
      );
      await fixture.catalog.saveModelLaunchOverrides(
        registration.id,
        fixture.asset.id,
        EngineLaunchConfiguration(formValues: const {}),
      );
      await fixture.catalog.setModelLaunchMode(
        registration.id,
        fixture.asset.id,
        independent: false,
      );
      final file = fixture.catalog.registryFile;
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final incompatible = EngineLaunchConfiguration(family: EngineFamily.omlx)
          .toJson();
      switch (location) {
        case 'active-default':
          (value['launchDefaults'] as Map)[registration.id] = incompatible;
        case 'active-model':
          (((value['modelLaunchOverrides'] as Map)[registration.id]
                      as Map)[fixture.asset.id]
                  as Map)['configuration'] =
              incompatible;
        case 'managed-default':
          (value['launchDefaults'] as Map)[EngineCatalog.officialId] =
              incompatible;
      }
      final corrupted = jsonEncode(value);
      await file.writeAsString(corrupted);
      await expectLater(
        fixture.reopen(),
        throwsA(isA<LlamaEngineException>()),
        reason: location,
      );
      expect(
        fixture.catalog.state.entries.where(
          (entry) => entry.source == EngineSource.linked,
        ),
        isEmpty,
        reason: location,
      );
      expect(
        fixture.catalog
            .launchDefaultsFor(EngineCatalog.officialId)
            .formValues['--ctx-size'],
        '4096',
        reason: location,
      );
      expect(
        await file.readAsString(),
        corrupted,
        reason: 'invalid JSON is not rewritten',
      );
      expect(fixture.io.startedArguments, isEmpty);
    }
  });
  test(
    'verified managed releases preserve tuning across reconstruction',
    () async {
      for (final standard in [false, true]) {
        final root = await Directory.systemTemp.createTemp(
          'gmd-release-tuning-',
        );
        final library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final io = _LifecycleIO();
        final engines = <LlamaEngine>[];
        final catalogs = <EngineCatalog>[];
        addTearDown(() async {
          for (final catalog in catalogs) {
            await catalog.stopManaged();
            catalog.close();
          }
          for (final engine in engines) {
            engine.close();
          }
          library.close();
          await root.delete(recursive: true);
        });
        await writeDecisionKev(
          Directory('${root.path}/models'),
          ordinaryChat: true,
        );
        final asset = (await library.scan(
          Directory('${root.path}/models'),
          verifyFiles: true,
        )).single;
        final id = standard
            ? EngineCatalog.standardId
            : EngineCatalog.officialId;
        Future<EngineCatalog> install(int build) async {
          final bytes = engineArchive(artifactTag: 'b$build');
          final archive = await File('${root.path}/$build.tar.gz')
              .writeAsBytes(bytes);
          final engine = LlamaEngine(
            library: library,
            installationDirectory: Directory('${root.path}/owned'),
            io: io,
            useRegistry: use,
            installationId: id,
            release: LlamaRelease(
              tag: standard ? 'v0.5.$build' : 'b$build',
              artifactTag: 'b$build',
              expectedBuild: build,
              supportsSystemone: !standard,
              commit: build == 12000 ? 'abcdef123' : 'abcdef124',
              url: Uri.parse('https://github.com/fixture'),
              sha256: sha256.convert(bytes).toString(),
              sizeBytes: bytes.length,
            ),
          );
          engines.add(engine);
          final fallback = standard
              ? LlamaEngine(
                  library: library,
                  installationDirectory: Directory('${root.path}/absent'),
                  io: io,
                  useRegistry: use,
                )
              : engine;
          if (standard) engines.add(fallback);
          final catalog = EngineCatalog(
            library: library,
            officialEngine: fallback,
            standardEngine: standard ? engine : null,
            registryFile: File('${root.path}/engines.json'),
            io: io,
            useRegistry: use,
          );
          catalogs.add(catalog);
          await catalog.installManaged(id, verifiedArchive: archive);
          await catalog.refresh();
          expect(
            catalog.providerFor(id).state.installation,
            LlamaInstallationStatus.installed,
          );
          return catalog;
        }

        var catalog = await install(12000);
        final original = EngineLaunchConfiguration(
          formValues: {'--ctx-size': '2048'},
          argumentText: ' --old-option keep\n',
        );
        await catalog.saveLaunchDefaults(id, original);
        await catalog.saveModelLaunchOverrides(
          id,
          asset.id,
          EngineLaunchConfiguration(formValues: const {}),
        );
        await catalog.setModelLaunchMode(id, asset.id, independent: false);
        expect(catalog.configurationVersionNoticeFor(id), isNull);
        io.version = '0.00.001 I init\n${io.version}';
        await catalog.refresh();
        expect(catalog.configurationVersionNoticeFor(id), isNull);
        await catalog.stopManaged();
        catalog.close();
        for (final engine in engines) {
          engine.close();
        }
        catalogs.clear();
        engines.clear();
        io.version = 'version: 0.5.0-dev (build 12001, commit abcdef124)\nbuilt for Darwin arm64';
        io.help += '\n--new-option VALUE  current option';
        catalog = await install(12001);
        expect(catalog.launchDefaultsFor(id).toJson(), original.toJson());
        final selection = catalog.modelLaunchOverridesFor(id, asset.id);
        expect(selection.enabled, isFalse);
        expect(selection.configuration!.formValues, isEmpty);
        expect(
          catalog.parameterRecognitionFor(id).recognizes('--new-option'),
          isTrue,
        );
        expect(
          catalog.configurationVersionNoticeFor(id),
          contains('参数来源版本已变化'),
        );
        final preview = await catalog.providerFor(id).previewLaunch(asset.id);
        expect(
          preview.arguments,
          containsAllInOrder(['--ctx-size', '2048', '--old-option', 'keep']),
        );
        expect(io.startedArguments, isEmpty);
        await catalog.setModelLaunchMode(id, asset.id, independent: true);
        final emptyPreview = await catalog
            .providerFor(id)
            .previewLaunch(asset.id);
        expect(emptyPreview.arguments, hasLength(8));
        await HttpOverrides.runWithHttpOverrides(() async {
          final instance = await catalog.providerFor(id).start(asset.id);
          expect(instance.launchCommand!.arguments, io.startedArguments.single);
          expect(io.startedArguments.single, hasLength(8));
          await catalog.providerFor(id).stop(instance.id);
        }, _LifecycleNetwork());
      }
    },
  );
  testWidgets(
    'a verified original path update keeps tuning while a later relink starts with defaults',
    (tester) async {
      final fixture = (await tester.runAsync(_LifecycleFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      late EngineRegistration source, target;
      await tester.runAsync(() async {
        source = await fixture.catalog.link(fixture.binary.path);
        await fixture.catalog.saveLaunchDefaults(
          source.id,
          EngineLaunchConfiguration(
            formValues: {
              ...EngineLaunchConfiguration.initialValues,
              '--ctx-size': '2048',
            },
            argumentText: ' --old-option keep\n',
          ),
        );
        await fixture.catalog.saveModelLaunchOverrides(
          source.id,
          fixture.asset.id,
          EngineLaunchConfiguration(
            formValues: {'--ctx-size': '1024'},
            argumentText: '--threads 4',
          ),
        );
        await fixture.catalog.setModelLaunchMode(
          source.id,
          fixture.asset.id,
          independent: false,
        );
        await fixture.binary.writeAsString('upgraded linked engine');
        fixture.io.version = 'version: 0.5.0-dev (build 12001, commit abcdef124)\nbuilt for Darwin arm64';
        fixture.io.help += '\n--new-option VALUE current option';
        await fixture.catalog.readParameters(
          fixture.catalog.state.entries.last.id,
        );
        expect(
          fixture.catalog.state.entries
              .singleWhere((entry) => entry.id == source.id)
              .status,
          LlamaInstallationStatus.installed,
        );
        expect(
          fixture.catalog.launchDefaultsFor(source.id).argumentText,
          ' --old-option keep\n',
        );
        expect(
          fixture.catalog.providerFor(source.id).linkedInstallation!.version,
          fixture.io.version,
        );
        expect(
          fixture.catalog
              .parameterRecognitionFor(source.id)
              .recognizes('--new-option'),
          isTrue,
        );
        expect(fixture.io.startedArguments, isEmpty);
        await fixture.catalog.remove(
          await fixture.catalog.prepareRemoval(source.id),
          confirmed: true,
        );
        await fixture.reopen();
        target = await fixture.catalog.link(fixture.binary.path);
        expect(target.id, isNot(source.id));
        expect(fixture.catalog.launchDefaultsFor(target.id).argumentText, '');
        final modes = fixture.catalog.modelLaunchOverridesFor(
          target.id,
          fixture.asset.id,
        );
        expect(modes.enabled, isFalse);
        expect(modes.configuration, isNull);
        expect(
          fixture.catalog.launchDefaultsFor(target.id).formValues['--ctx-size'],
          '4096',
        );
        expect(fixture.catalog.launchDefaultsFor(target.id).argumentText, '');
        expect(
          fixture.catalog.parameterRecognitionFor(target.id).version,
          fixture.io.version,
        );
        expect(fixture.io.startedArguments, isEmpty);
      });
      await _showPage(tester, fixture);
      expect(find.textContaining('参数来源版本已变化'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'relinking exposes fresh defaults without a history recovery action',
    (tester) async {
      final fixture = (await tester.runAsync(_LifecycleFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      late EngineRegistration previous;
      await tester.runAsync(() async {
        previous = await fixture.catalog.link(fixture.binary.path);
        await fixture.catalog.saveLaunchDefaults(
          previous.id,
          EngineLaunchConfiguration(
            formValues: {
              ...EngineLaunchConfiguration.initialValues,
              '--ctx-size': '2048',
            },
            argumentText: ' --threads 3\n',
          ),
        );
        await fixture.catalog.saveModelLaunchOverrides(
          previous.id,
          fixture.asset.id,
          EngineLaunchConfiguration(formValues: const {}),
        );
        await fixture.catalog.remove(
          await fixture.catalog.prepareRemoval(previous.id),
          confirmed: true,
        );
        await fixture.reopen();
      });
      await _showPage(tester, fixture);
      await tester.runAsync(() async {
        final linked = fixture.catalog.changes.firstWhere(
          (state) =>
              state.entries.any((entry) => entry.source == EngineSource.linked),
        );
        await tester.tap(find.widgetWithText(OutlinedButton, '关联引擎'));
        await linked.timeout(const Duration(seconds: 5));
        await fixture.catalog.readParameters(
          fixture.catalog.state.entries.last.id,
        );
        await tester.pump();
      });
      await tester.pumpAndSettle();
      final target = fixture.catalog.state.entries.singleWhere(
        (entry) => entry.source == EngineSource.linked,
      );
      expect(target.id, isNot(previous.id));
      expect(
        fixture.catalog.launchDefaultsFor(target.id).formValues['--ctx-size'],
        '4096',
      );
      expect(fixture.catalog.launchDefaultsFor(target.id).argumentText, '');
      expect(
        fixture.catalog
            .modelLaunchOverridesFor(target.id, fixture.asset.id)
            .configuration,
        isNull,
      );
      expect(find.text('未关联启动配置'), findsNothing);
      expect(find.text('选择目标恢复'), findsNothing);
      expect(fixture.io.startedArguments, isEmpty);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final provider = fixture.catalog.providerFor(target.id);
          final preview = await provider.previewLaunch(fixture.asset.id);
          final running = await provider.start(fixture.asset.id);
          expect(preview.arguments, containsAllInOrder(['--ctx-size', '4096']));
          expect(preview.provisional, isTrue);
          final boundPreview = [
            for (final value in preview.arguments)
              switch (value) {
                '<启动时分配的模型标识>' => running.id,
                '<启动时分配的端口>' => '${running.endpoint.port}',
                _ => value,
              },
          ];
          expect(boundPreview, fixture.io.startedArguments.single);
          expect(
            running.launchCommand!.arguments,
            fixture.io.startedArguments.single,
          );
          await provider.stop(running.id);
        }, _LifecycleNetwork()),
      );
      expect(
        await tester.runAsync(() => fixture.binary.readAsString()),
        'original linked engine',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unlink removes its settings without a configuration history across reopen',
    (tester) async {
      final fixture = (await tester.runAsync(_LifecycleFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      final entry = (await tester.runAsync(
        () => fixture.catalog.link(fixture.binary.path),
      ))!;
      await _showPage(tester, fixture);
      await tester.runAsync(() async {
        final action = find.byKey(ValueKey('engine-parameters:${entry.id}'));
        await tester.ensureVisible(action);
        await tester.tap(action);
        await fixture.catalog.readParameters(entry.id);
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '上下文与内存');
      await tester.enterText(
        find.byKey(const Key('parameter-number:--ctx-size')),
        '2048',
      );
      await selectParameterGroup(tester, '参数文本与命令');
      final text = find.byKey(const Key('engine-argument-text'));
      await tester.ensureVisible(text);
      await tester.enterText(text, ' --threads 3\n');
      await tester.pump();
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
        await fixture.catalog.saveModelLaunchOverrides(
          entry.id,
          fixture.asset.id,
          EngineLaunchConfiguration(formValues: const {}),
        );
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final prepared = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        final more = find.byKey(ValueKey('engine-more:${entry.id}'));
        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.text('解除关联').last);
        await prepared.timeout(const Duration(seconds: 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final removed = fixture.catalog.changes.firstWhere(
          (state) => state.entries.every((value) => value.id != entry.id),
        );
        await tester.tap(find.widgetWithText(FilledButton, '解除关联'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await removed.timeout(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.reopen();
      });
      await _showPage(tester, fixture);
      expect(find.text('未关联启动配置'), findsNothing);
      expect(find.text('选择目标恢复'), findsNothing);
      final saved = await tester.runAsync(
        () => fixture.catalog.registryFile.readAsString(),
      );
      final registry = jsonDecode(saved!) as Map;
      expect(registry.containsKey('unlinkedConfigurations'), isFalse);
      expect(
        (registry['modelLaunchOverrides'] as Map?)?.containsKey(entry.id) ??
            false,
        isFalse,
      );
      expect(
        await tester.runAsync(() => fixture.binary.readAsString()),
        'original linked engine',
      );
      expect(fixture.io.startedArguments, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

class _LifecycleNetwork extends HttpOverrides {}

Future<void> _showPage(WidgetTester tester, _LifecycleFixture fixture) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildJevTheme(Brightness.light),
        home: Scaffold(
          body: EnginePage(
            catalog: fixture.catalog,
            pickEngineDirectory: () async => fixture.binary.path,
          ),
        ),
      ),
    );
    await fixture.catalog.readParameters(fixture.catalog.state.entries.last.id);
  });
  await tester.pumpAndSettle();
}

class _LifecycleFixture {
  _LifecycleFixture(this.root, this.binary);
  final Directory root;
  final File binary;
  final io = _LifecycleIO();
  late ModelLibrary library;
  late LlamaEngine official;
  late EngineCatalog catalog;
  late LibraryArtifact asset;
  static Future<_LifecycleFixture> create() async {
    final root = await Directory.systemTemp.createTemp('gmd-launch-lifecycle-');
    final binary = await File('${root.path}/external/llama-server')
        .create(recursive: true);
    await binary.writeAsString('original linked engine');
    await Process.run('/bin/chmod', ['+x', binary.path]);
    await Directory('${root.path}/managed').create();
    await writeDecisionKev(
      Directory('${root.path}/models'),
      ordinaryChat: true,
    );
    final fixture = _LifecycleFixture(root, binary).._open();
    fixture.asset = (await fixture.library.scan(
      Directory('${root.path}/models'),
      verifyFiles: true,
    )).single;
    return fixture;
  }

  void _open() {
    library = ModelLibrary();
    final use = ModelUseRegistry(library);
    official = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/managed'),
      io: io,
      useRegistry: use,
    );
    catalog = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: File('${root.path}/engines.json'),
      io: io,
    );
  }

  Future<void> reopen() async {
    await catalog.stopManaged();
    catalog.close();
    official.close();
    library.close();
    _open();
    await catalog.refresh();
    asset = (await library.scan(
      Directory('${root.path}/models'),
      verifyFiles: true,
    )).single;
  }

  Future<void> close() async {
    await catalog.stopManaged();
    catalog.close();
    official.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class _LifecycleIO implements EngineProcessIO {
  String? inferenceError;
  bool failStart = false;
  Completer<void>? startEntered;
  Completer<void>? releaseStart;
  Completer<void>? versionStarted;
  Completer<void>? releaseVersion;
  String version =
      'version: 0.5.0-dev (build 12000, commit abcdef123)\nbuilt for Darwin arm64';
  String help =
      '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device --api-key --api-key-file';
  final startedArguments = <List<String>>[];
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.singleOrNull == '--version') {
      if (releaseVersion != null) {
        if (!versionStarted!.isCompleted) versionStarted!.complete();
        await releaseVersion!.future;
      }
      return EngineCommandResult(0, version, '');
    }
    if (arguments.singleOrNull == '--help') {
      return EngineCommandResult(0, help, '');
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
    startedArguments.add(List.of(arguments));
    if (failStart) {
      throw ProcessException(
        executable,
        arguments,
        'native process unavailable',
        2,
      );
    }
    if (startEntered != null && !startEntered!.isCompleted) {
      startEntered!.complete();
    }
    await releaseStart?.future;
    String value(String flag) => arguments[arguments.indexOf(flag) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(value('--port')),
    );
    final keys = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      if (arguments[index].replaceAll('_', '-') == '--api-key') {
        keys.addAll(arguments[++index].split(','));
      }
      if (arguments[index].replaceAll('_', '-') == '--api-key-file') {
        keys.addAll(
          (await File(arguments[++index]).readAsLines()).where(
            (line) => line.isNotEmpty && !line.startsWith('#'),
          ),
        );
      }
    }
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (keys.isNotEmpty &&
          request.uri.path != '/health' &&
          !keys.any(
            (key) => request.headers.value('Authorization') == 'Bearer $key',
          )) {
        request.response.statusCode = 401;
        request.response.write('{"error":"invalid or missing API key"}');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/v1/systemone' && inferenceError != null) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error': inferenceError}));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': value('--alias'),
            'model_path': value('--model'),
          }),
        );
      } else if (request.uri.path == '/slots') {
        request.response.write('[]');
      } else if (request.uri.path == '/metrics') {
        request.response.headers.contentType = ContentType.text;
        request.response.write('llamacpp:requests_processing 0\n');
      } else if (request.uri.path == '/v1/systemone') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        request.response.write(
          jsonEncode({
            'model': value('--alias'),
            'answers': {
              for (final entry in (body['questions'] as Map).entries)
                '${entry.key}': {
                  'type': 'choice',
                  'choice': 'yes',
                  'probabilities': {'yes': 1.0, 'no': 0.0},
                  'confidence': 1.0,
                },
            },
            'usage': {'input_tokens': 10, 'output_tokens': 0},
          }),
        );
      } else {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (body['stream'] == true) {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          for (final choice in [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'hello'},
              'finish_reason': null,
            },
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ]) {
            request.response.write(
              'data: ${jsonEncode({
                'model': value('--alias'),
                'choices': [choice],
              })}\n\n',
            );
          }
          request.response.write(
            'data: ${jsonEncode({
              'model': value('--alias'),
              'choices': [],
              'usage': {'completion_tokens': 1},
            })}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
          return;
        }
        request.response.write(
          jsonEncode({
            'model': value('--alias'),
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'hello'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'completion_tokens': 1},
          }),
        );
      }
      await request.response.close();
    });
    return _LifecycleChild(server);
  }
}

class _LifecycleChild implements EngineChild {
  _LifecycleChild(this.server);
  final HttpServer server;
  final exited = Completer<int>();
  @override
  int get pid => 43431;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    server.close(force: true).then((_) {
      if (!exited.isCompleted) exited.complete(0);
    });
    return true;
  }
}
