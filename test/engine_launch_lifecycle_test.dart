import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  testWidgets(
    'unlinked history shows retained model tuning and artifact identity after reopen',
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
      await tester.tap(find.widgetWithText(OutlinedButton, '未关联启动配置'));
      await tester.pumpAndSettle();
      expect(find.text('继承引擎默认 · 独立内容已保留'), findsOneWidget);
      expect(find.text('--ctx-size: 1024'), findsOneWidget);
      expect(find.text(' --threads 5\n'), findsOneWidget);
      expect(find.text(artifactId), findsOneWidget);
      expect(fixture.io.startedArguments, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test('unlink preserves its registration on write failure and waits for accepted startup', () async {
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
    expect(fixture.catalog.unlinkedConfigurations, isEmpty);
    expect(await fixture.catalog.registryFile.readAsString(), original);
    await obstruction.delete();
    await HttpOverrides.runWithHttpOverrides(() async {
      final provider = fixture.catalog.providerFor(entry.id);
      fixture.io.versionStarted = Completer<void>();
      fixture.io.releaseVersion = Completer<void>();
      final startup = provider.start(fixture.asset.id);
      await fixture.io.versionStarted!.future.timeout(
        const Duration(seconds: 5),
      );
      expect(
        provider.hasLiveInstances,
        isFalse,
        reason: 'accepted startup is still checking identity before reserving its model',
      );
      final removalAdmitted = fixture.catalog.changes.firstWhere(
        (state) => state.busy,
      );
      final rejectedRemoval = expectLater(
        fixture.catalog.remove(plan, confirmed: true),
        throwsA(isA<LlamaEngineException>()),
      );
      await removalAdmitted.timeout(const Duration(seconds: 5));
      fixture.io.releaseVersion!.complete();
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
      expect(fixture.catalog.unlinkedConfigurations, isEmpty);
      expect(await fixture.catalog.registryFile.readAsString(), original);
      expect(
        running.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '2048']),
      );
      await provider.stop(running.id);
      fixture.io.versionStarted = null;
      fixture.io.releaseVersion = null;
      await fixture.catalog.remove(
        await fixture.catalog.prepareRemoval(entry.id),
        confirmed: true,
      );
    }, _LifecycleNetwork());
    expect(
      fixture.catalog.unlinkedConfigurations.single.registrationId,
      entry.id,
    );
    expect(await fixture.binary.readAsString(), 'original linked engine');
  });
  test('mixed-family persisted configurations are rejected before applying any registration', () async {
    for (final location in [
      'active-default',
      'active-model',
      'managed-default',
      'history-default',
      'history-model',
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
      if (location.startsWith('history')) {
        await fixture.catalog.remove(
          await fixture.catalog.prepareRemoval(registration.id),
          confirmed: true,
        );
      }
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
        case 'history-default':
          ((value['unlinkedConfigurations'] as Map)[registration.id]
                  as Map)['defaults'] =
              incompatible;
        case 'history-model':
          ((((value['unlinkedConfigurations'] as Map)[registration.id]
                          as Map)['models']
                      as Map)[fixture.asset.id]
                  as Map)['configuration'] =
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
      expect(fixture.catalog.unlinkedConfigurations, isEmpty, reason: location);
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
    'a changed external version retains tuning but requires verified relink and shows its source version',
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
        await fixture.catalog.refresh();
        expect(
          fixture.catalog.state.entries
              .singleWhere((entry) => entry.id == source.id)
              .status,
          LlamaInstallationStatus.failed,
        );
        expect(
          fixture.catalog.launchDefaultsFor(source.id).argumentText,
          ' --old-option keep\n',
        );
        await expectLater(
          fixture.catalog.providerFor(source.id).start(fixture.asset.id),
          throwsA(isA<LlamaEngineException>()),
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
        await fixture.catalog.restoreUnlinkedConfiguration(
          source.id,
          target.id,
        );
        final modes = fixture.catalog.modelLaunchOverridesFor(
          target.id,
          fixture.asset.id,
        );
        expect(modes.enabled, isFalse);
        expect(modes.configuration!.formValues['--ctx-size'], '1024');
        expect(modes.configuration!.argumentText, '--threads 4');
        expect(
          fixture.catalog.launchDefaultsFor(target.id).formValues['--ctx-size'],
          '2048',
        );
        expect(
          fixture.catalog.launchDefaultsFor(target.id).argumentText,
          ' --old-option keep\n',
        );
        expect(
          fixture.catalog.parameterRecognitionFor(target.id).version,
          fixture.io.version,
        );
        expect(fixture.io.startedArguments, isEmpty);
      });
      await _showPage(tester, fixture);
      expect(find.textContaining('参数来源版本已变化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'relinking requires an explicit history source and target before restoring parameters',
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
        await fixture.catalog.refresh();
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
      await tester.tap(find.text('未关联启动配置'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '选择目标恢复'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '选择目标恢复'));
      await tester.pumpAndSettle();
      final restore = find.widgetWithText(FilledButton, '恢复到所选引擎');
      expect(tester.widget<FilledButton>(restore).onPressed, isNull);
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, '恢复到引擎'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is DropdownMenuItem<String> &&
                  widget.value == target.id,
            )
            .last,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final restored = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(restore);
        await restored.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.launchDefaultsFor(target.id).formValues['--ctx-size'],
        '2048',
      );
      expect(
        fixture.catalog.launchDefaultsFor(target.id).argumentText,
        ' --threads 3\n',
      );
      final independent = fixture.catalog.modelLaunchOverridesFor(
        target.id,
        fixture.asset.id,
      );
      expect(independent.enabled, isTrue);
      expect(independent.configuration!.formValues, isEmpty);
      expect(independent.configuration!.argumentText, '');
      expect(
        fixture.io.startedArguments,
        isEmpty,
        reason: 'restoring preferences does not start a model',
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final provider = fixture.catalog.providerFor(target.id);
          final preview = await provider.previewLaunch(fixture.asset.id);
          final running = await provider.start(fixture.asset.id);
          expect(preview.arguments, hasLength(8));
          expect(fixture.io.startedArguments.single, hasLength(8));
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
    'unlink preserves a visible configuration history across reopen',
    (tester) async {
      final fixture = (await tester.runAsync(_LifecycleFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      final entry = (await tester.runAsync(
        () => fixture.catalog.link(fixture.binary.path),
      ))!;
      await _showPage(tester, fixture);
      await tester.tap(find.byTooltip('启动参数').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '上下文大小'), '2048');
      final text = find.widgetWithText(TextField, '启动参数文本');
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
        await tester.tap(find.widgetWithText(TextButton, '解除关联'));
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
      expect(find.text('未关联启动配置'), findsOneWidget);
      await tester.tap(find.text('未关联启动配置'));
      await tester.pumpAndSettle();
      expect(find.textContaining(fixture.binary.path), findsWidgets);
      expect(find.textContaining(' --threads 3\n'), findsOneWidget);
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
    await fixture.catalog.refresh();
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
  Completer<void>? versionStarted;
  Completer<void>? releaseVersion;
  String version =
      'version: 0.5.0-dev (build 12000, commit abcdef123)\nbuilt for Darwin arm64';
  String help =
      '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device';
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
    String value(String flag) => arguments[arguments.indexOf(flag) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(value('--port')),
    );
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': value('--alias'),
            'model_path': value('--model'),
          }),
        );
      } else {
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
