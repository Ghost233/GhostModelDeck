import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  test('linked standard timestamp changes retain typed identity and saved startup', () async {
    final fixture = await _RecognitionFixture.create(
      linkedVersion:
          '0.00.000.141 I srv llama_server: initializing ...\n$_standardVersion',
    );
    addTearDown(fixture.close);
    const text = '--context-tokens 1024';
    await fixture.catalog.saveLaunchDefaults(
      fixture.id,
      EngineLaunchConfiguration(argumentText: text),
    );
    final fingerprint = fixture.engine.binarySha256;
    fixture.io.versionOutput =
        '0.00.000.090 I srv llama_server: initializing ...\n$_standardVersion';
    await fixture.catalog.refresh();
    expect(
      fixture.engine.state.installation,
      LlamaInstallationStatus.installed,
    );
    expect(fixture.engine.binaryVersion!.build, 11146);
    expect(fixture.engine.binarySha256, fingerprint);
    expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
    final preview = await fixture.engine.previewLaunch(fixture.asset.id);
    expect(preview.overriddenForm, contains('--ctx-size'));
    await HttpOverrides.runWithHttpOverrides(() async {
      final instance = await fixture.engine.start(fixture.asset.id);
      expect(instance.status, LlamaInstanceStatus.ready);
      expect(fixture.io.started.single.skip(8), preview.arguments.skip(8));
      await fixture.engine.stop(instance.id);
    }, _NetworkBoundary());
  });
  for (final change in [
    'semantic',
    'build',
    'commit',
    'platform',
    'fingerprint',
  ]) {
    test(
      'linked timestamp normalization still rejects changed $change identity',
      () async {
        final fixture = await _RecognitionFixture.create(
          linkedVersion: _standardVersion,
        );
        addTearDown(fixture.close);
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: '--context-tokens 1024'),
        );
        if (change == 'fingerprint') {
          await File(fixture.engine.executablePath!)
              .writeAsString('changed content');
        } else {
          fixture.io.versionOutput = switch (change) {
            'semantic' => _standardVersion.replaceFirst('0.5.0-dev', '0.5.0'),
            'build' => _standardVersion.replaceFirst('11146', '11147'),
            'commit' => _standardVersion.replaceFirst('7fe450e19', '000000000'),
            _ => _standardVersion.replaceFirst('Darwin arm64', 'Darwin x86_64'),
          };
        }
        await fixture.catalog.refresh();
        expect(
          fixture.engine.state.installation,
          LlamaInstallationStatus.failed,
        );
        expect(
          fixture.engine.parameterRecognition.recognizes('--context-tokens'),
          isFalse,
        );
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
          '--context-tokens 1024',
        );
        await expectLater(
          fixture.engine.start(fixture.asset.id),
          throwsA(isA<LlamaEngineException>()),
        );
        expect(fixture.io.started, isEmpty);
      },
    );
  }
  test(
    'unparseable linked versions retain strict raw equality fallback',
    () async {
      const opaque = 'version: vendor opaque\nbuilt for Darwin arm64';
      final fixture = await _RecognitionFixture.create(linkedVersion: opaque);
      addTearDown(fixture.close);
      await fixture.catalog.refresh();
      expect(
        fixture.engine.state.installation,
        LlamaInstallationStatus.installed,
      );
      fixture.io.versionOutput = 'diagnostic changed\n$opaque';
      await fixture.catalog.refresh();
      expect(fixture.engine.state.installation, LlamaInstallationStatus.failed);
      expect(fixture.io.started, isEmpty);
    },
  );
  testWidgets(
    'unverified executable keeps help limits visible and permits configuration save',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _RecognitionFixture.create(managed: true),
      ))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        await File(fixture.engine.executablePath!)
            .writeAsString('unverified content');
        await fixture.catalog.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EnginePage(
                catalog: fixture.catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await fixture.catalog.refresh();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('启动参数').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前帮助规则不可用'), findsOneWidget);
      expect(find.byTooltip('复制命令'), findsNothing);
      final input = find.widgetWithText(TextField, '启动参数文本');
      await tester.ensureVisible(input);
      await tester.enterText(input, '--future new');
      await tester.pump();
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
        '--future new',
      );
      expect(fixture.io.started, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'shutdown drains accepted help IO without accepting its late rules',
    () async {
      final fixture = await _RecognitionFixture.create(managed: true);
      addTearDown(fixture.close);
      const text = '--context-tokens 2048';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      final fingerprint =
          fixture.engine.parameterRecognition.contentFingerprint;
      fixture.io.help = _currentHelp.replaceAll(
        '--context-tokens',
        '--late-context',
      );
      fixture.io.helpRequested = Completer<void>();
      fixture.io.helpRelease = Completer<void>();
      addTearDown(() {
        final release = fixture.io.helpRelease!;
        if (!release.isCompleted) release.complete();
      });
      final refresh = fixture.catalog.refresh();
      await fixture.io.helpRequested!.future.timeout(
        const Duration(seconds: 5),
      );
      var drained = false;
      final shutdown = fixture.engine.shutdown().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      fixture.io.helpRelease!.complete();
      await refresh;
      await shutdown;
      expect(
        fixture.engine.parameterRecognition.recognizes('--late-context'),
        isFalse,
      );
      expect(
        fixture.engine.parameterRecognition.canonicalName('--context-tokens'),
        '--ctx-size',
      );
      expect(
        fixture.engine.parameterRecognition.contentFingerprint,
        fingerprint,
      );
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
      expect(fixture.io.started, isEmpty);
      await expectLater(
        fixture.engine.start(fixture.asset.id),
        throwsA(isA<StateError>()),
      );
    },
  );
  for (final managed in [false, true]) {
    test(
      '${managed ? 'managed' : 'linked'} partial help preserves same-content usable rules through refresh and startup',
      () async {
        final fixture = await _RecognitionFixture.create(managed: managed);
        addTearDown(fixture.close);
        const text = '--extra-path "--model" --context-tokens 1024';
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: text),
        );
        final before = await fixture.engine.previewLaunch(fixture.asset.id);
        final originalForm = fixture.catalog
            .launchDefaultsFor(fixture.id)
            .formValues;
        for (final help in [
          '$_requiredFlatHelp\n-c, --ctx-size N      current context description\n',
          _requiredFlatHelp,
        ]) {
          fixture.io.help = help;
          await fixture.catalog.refresh();
          expect(
            fixture.engine.state.installation,
            LlamaInstallationStatus.installed,
          );
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          expect(preview.arguments, before.arguments);
          expect(
            preview.notices.any(
              (notice) =>
                  notice.contains('帮助') &&
                  (notice.contains('部分') || notice.contains('无法解析')),
            ),
            isTrue,
          );
          expect(
            fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
            text,
          );
          expect(
            fixture.catalog.launchDefaultsFor(fixture.id).formValues,
            originalForm,
          );
          await HttpOverrides.runWithHttpOverrides(() async {
            final instance = await fixture.engine.start(fixture.asset.id);
            expect(instance.status, LlamaInstanceStatus.ready);
            expect(fixture.io.started.last.skip(8), before.arguments.skip(8));
            await fixture.engine.stop(instance.id);
          }, _NetworkBoundary());
        }
      },
    );
  }
  for (final managed in [false, true]) {
    test(
      '${managed ? 'managed content' : 'required linked help'} failure discards old rules without discarding configuration',
      () async {
        final fixture = await _RecognitionFixture.create(managed: managed);
        addTearDown(fixture.close);
        const text = '--context-tokens 2048';
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: text),
        );
        expect(
          fixture.engine.parameterRecognition.recognizes('--context-tokens'),
          isTrue,
        );
        if (managed) {
          await File(fixture.engine.executablePath!)
              .writeAsString('different actual content');
        } else {
          fixture.io.helpExit = 1;
        }
        await fixture.catalog.refresh();
        expect(
          fixture.engine.state.installation,
          LlamaInstallationStatus.failed,
        );
        expect(
          fixture.engine.parameterRecognition.recognizes('--context-tokens'),
          isFalse,
        );
        expect(fixture.engine.parameterRecognition.contentFingerprint, isNull);
        expect(fixture.engine.parameterRecognition.version, isNull);
        expect(fixture.engine.parameterRecognition.notices, isNotEmpty);
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
          text,
        );
        await expectLater(
          fixture.engine.start(fixture.asset.id),
          throwsA(isA<LlamaEngineException>()),
        );
        expect(fixture.io.started, isEmpty);
      },
    );
  }
  test(
    'managed optional help failure preserves current rules and saved startup',
    () async {
      final fixture = await _RecognitionFixture.create(managed: true);
      addTearDown(fixture.close);
      const text = '--context-tokens 1536 --brand-new "value space"';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      final before = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(before.overriddenForm, contains('--ctx-size'));
      fixture.io.helpFailure = TimeoutException('controlled help deadline');
      fixture.io.versionDiagnostic = 'same content, changed diagnostic text\n';
      await fixture.catalog.refresh();
      expect(
        fixture.engine.state.installation,
        LlamaInstallationStatus.installed,
      );
      expect(
        fixture.engine.parameterRecognition.status,
        EngineHelpStatus.unavailable,
      );
      expect(
        fixture.engine.parameterRecognition.version,
        fixture.engine.observedVersion,
      );
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
      final after = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(after.arguments, before.arguments);
      expect(
        after.notices.any(
          (notice) => notice.contains('帮助') && notice.contains('失败'),
        ),
        isTrue,
      );
      expect(
        after.notices.any((notice) => notice.contains('未知参数 --brand-new')),
        isTrue,
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        final instance = await fixture.engine.start(fixture.asset.id);
        expect(instance.status, LlamaInstanceStatus.ready);
        expect(fixture.io.started.single.skip(8), after.arguments.skip(8));
        await fixture.engine.stop(instance.id);
      }, _NetworkBoundary());
      expect(fixture.io.helpBudgets, isNotEmpty);
      expect(
        fixture.io.helpBudgets.every(
          (budget) =>
              budget > Duration.zero && budget <= const Duration(seconds: 10),
        ),
        isTrue,
      );
    },
  );
  test(
    'help-known option values retain quoted option names at startup',
    () async {
      final fixture = await _RecognitionFixture.create();
      addTearDown(fixture.close);
      await fixture.catalog.refresh();
      const text =
          '--extra-path "--model" --extra-path "--ctx-size" '
          '--control-vector-layer-range "--alias" "--port"';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      final preview = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(
        fixture.engine.parameterRecognition.canonicalName('--no-perf'),
        '--no-perf',
      );
      expect(preview.overriddenForm, isEmpty);
      expect(preview.arguments.skip(8), [
        '--ctx-size',
        '4096',
        '--batch-size',
        '4096',
        '--ubatch-size',
        '4096',
        '--parallel',
        '1',
        '--n-gpu-layers',
        '99',
        '--device',
        'MTL0',
        '--extra-path',
        '--model',
        '--extra-path',
        '--ctx-size',
        '--control-vector-layer-range',
        '--alias',
        '--port',
      ]);
      await HttpOverrides.runWithHttpOverrides(() async {
        final instance = await fixture.engine.start(fixture.asset.id);
        expect(fixture.io.started.single.skip(8), preview.arguments.skip(8));
        expect(instance.launchCommand!.arguments, fixture.io.started.single);
        await fixture.engine.stop(instance.id);
      }, _NetworkBoundary());
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
    },
  );
  testWidgets(
    'current linked help aliases reach editor save, preview and actual startup',
    (tester) async {
      final fixture = (await tester.runAsync(_RecognitionFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EnginePage(
                catalog: fixture.catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await fixture.catalog.refresh();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('启动参数').last);
      await tester.pumpAndSettle();
      final input = find.widgetWithText(TextField, '启动参数文本');
      await tester.ensureVisible(input);
      const source =
          '--context-tokens 2048 --extra-path "two words" --extra-path=again --no-perf';
      await tester.enterText(input, source);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '上下文大小'))
            .decoration!
            .errorText,
        '已被文本覆盖',
      );
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
        source,
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          expect(preview.arguments, isNot(contains('--ctx-size')));
          expect(preview.overriddenForm, contains('--ctx-size'));
          expect(
            preview.notices.where((notice) => notice.contains('未知参数')),
            isEmpty,
          );
          final instance = await fixture.engine.start(fixture.asset.id);
          expect(instance.status, LlamaInstanceStatus.ready);
          expect(fixture.io.started.single.skip(8), [
            '--batch-size',
            '4096',
            '--ubatch-size',
            '4096',
            '--parallel',
            '1',
            '--n-gpu-layers',
            '99',
            '--device',
            'MTL0',
            '--context-tokens',
            '2048',
            '--extra-path',
            'two words',
            '--extra-path=again',
            '--no-perf',
          ]);
          expect(instance.launchCommand!.arguments, fixture.io.started.single);
          expect(preview.arguments.skip(8), fixture.io.started.single.skip(8));
          await fixture.engine.stop(instance.id);
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

const _currentHelp = '''----- common params -----
-m, --model FNAME                      model path to load
-a, --alias STRING                     API model alias
--host HOST                            listen address
--port PORT                            listen port
-c, --ctx-size, --context-tokens N      number of context tokens
                                       current engine context description
-b, --batch-size N                     logical batch size
-ub, --ubatch-size N                    physical batch size
-np, --parallel N                      parallel slots
-ngl, --gpu-layers, --n-gpu-layers N    GPU layer count
-dev, --device DEVICE                  selected device
--extra-path PATH                      additional path for this version
--control-vector-layer-range START END
                                       selected layer range
--perf, --no-perf                      whether to enable performance timings
''';

const _requiredFlatHelp =
    '--model --alias --host --port --ctx-size --batch-size --ubatch-size '
    '--parallel --n-gpu-layers --device';

const _standardVersion =
    'version: 0.5.0-dev (build 11146, commit 7fe450e19)\nbuilt for Darwin arm64';

class _RecognitionFixture {
  _RecognitionFixture(
    this.root,
    this.library,
    this.official,
    this.catalog,
    this.io,
  );
  final Directory root;
  final ModelLibrary library;
  final LlamaEngine official;
  final EngineCatalog catalog;
  final _RecognitionIO io;
  late String id;
  late LibraryArtifact asset;
  LlamaEngine get engine => catalog.providerFor(id);

  static Future<_RecognitionFixture> create({
    bool managed = false,
    String? linkedVersion,
  }) async {
    final root = await Directory.systemTemp.createTemp('gmd-recognition-');
    final library = ModelLibrary();
    final use = ModelUseRegistry(library);
    final io = _RecognitionIO();
    if (linkedVersion != null) io.versionOutput = linkedVersion;
    final data = engineArchive();
    final official = LlamaEngine(
      library: library,
      useRegistry: use,
      io: io,
      installationDirectory: Directory('${root.path}/owned'),
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://fixture.example/engine'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      io: io,
      registryFile: File('${root.path}/engines.json'),
    );
    final fixture = _RecognitionFixture(root, library, official, catalog, io);
    if (managed) {
      final archive = await File('${root.path}/engine.tar.gz')
          .writeAsBytes(data);
      await catalog.installOfficial(verifiedArchive: archive);
      fixture.id = EngineCatalog.officialId;
    } else {
      final binary = await File('${root.path}/external/llama-server')
          .create(recursive: true);
      await binary.writeAsString(
        'external executable at the process I/O boundary',
      );
      expect(
        (await Process.run('/bin/chmod', ['+x', binary.path])).exitCode,
        0,
      );
      fixture.id = (await catalog.link(binary.path)).id;
    }
    await writeDecisionKev(
      Directory('${root.path}/models'),
      ordinaryChat: true,
    );
    fixture.asset = (await library.scan(
      Directory('${root.path}/models'),
      verifyFiles: true,
    )).single;
    return fixture;
  }

  Future<void> close() async {
    await catalog.stopManaged();
    catalog.close();
    official.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class _RecognitionIO implements EngineProcessIO {
  String help = _currentHelp;
  Object? helpFailure;
  String versionDiagnostic = '';
  String versionOutput =
      'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64';
  Completer<void>? helpRequested;
  Completer<void>? helpRelease;
  int helpExit = 0;
  final helpBudgets = <Duration>[];
  final started = <List<String>>[];
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
      return EngineCommandResult(0, '$versionDiagnostic$versionOutput', '');
    }
    if (arguments.singleOrNull == '--help') {
      helpBudgets.add(timeout);
      if (helpRequested != null && !helpRequested!.isCompleted) {
        helpRequested!.complete();
        await helpRelease!.future;
      }
      if (helpFailure != null) throw helpFailure!;
      return EngineCommandResult(helpExit, help, '');
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
    started.add(List.of(arguments));
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
      } else {
        await request.drain<void>();
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
      }
      await request.response.close();
    });
    return _RecognitionChild(server);
  }
}

class _RecognitionChild implements EngineChild {
  _RecognitionChild(this.server);
  final HttpServer server;
  final stopped = Completer<int>();
  @override
  int get pid => 42429;
  @override
  Future<int> get exitCode => stopped.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    server.close(force: true).then((_) {
      if (!stopped.isCompleted) stopped.complete(0);
    });
    return true;
  }
}

class _NetworkBoundary extends HttpOverrides {}
