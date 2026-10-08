import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/omlx_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/engine_archive.dart';

void main() {
  testWidgets(
    'engine defaults editor previews and copies the edited complete command',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine engine;
      late EngineCatalog catalog;
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd engine preview ');
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final data = engineArchive();
        final archive = await File('${root.path}/engine.tar.gz')
            .writeAsBytes(data);
        engine = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/engines'),
          io: _InstallIO(),
          useRegistry: use,
          release: LlamaRelease(
            tag: 'b11381',
            commit: '836d57176',
            url: Uri.parse('https://github.com/fixture'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: engine,
          useRegistry: use,
          registryFile: File('${root.path}/engines.json'),
        );
        await catalog.installOfficial(verifiedArchive: archive);
      });
      addTearDown(() async {
        catalog.close();
        engine.close();
        library.close();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: EnginePage(
                catalog: catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('启动参数'));
      await tester.pumpAndSettle();
      expect(find.text('完整启动命令'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '上下文大小'), '2048');
      // Present the frame scheduled by onChanged before interacting with its
      // command view, and verify the displayed preview changed before copying.
      await tester.pump();
      expect(find.textContaining('--ctx-size 2048'), findsOneWidget);
      final copy = find.byTooltip('复制命令');
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(clipboard, startsWith("'${engine.executablePath}' --model "));
      expect(clipboard, contains('运行时选择的模型路径'));
      expect(clipboard, contains('--host 127.0.0.1'));
      expect(clipboard, contains("--port '<启动时分配的端口>'"));
      expect(clipboard, contains('--ctx-size 2048'));
      expect(clipboard, contains('--device MTL0'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'engine launch defaults edited on the engine page survive reopen',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine engine;
      late EngineCatalog catalog;
      void createCatalog() {
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        engine = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/engines'),
          useRegistry: use,
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: engine,
          useRegistry: use,
          registryFile: File('${root.path}/registry.json'),
        );
      }

      Future<void> showEnginePage() async {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildJevTheme(Brightness.light),
              home: Scaffold(
                body: EnginePage(
                  catalog: catalog,
                  pickEngineDirectory: () async => null,
                ),
              ),
            ),
          );
          await catalog.refresh();
        });
        await tester.pumpAndSettle();
      }

      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd-launch-defaults-');
        createCatalog();
      });
      addTearDown(() async {
        catalog.close();
        engine.close();
        library.close();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await showEnginePage();
      expect(find.byTooltip('启动参数'), findsOneWidget);
      await tester.tap(find.byTooltip('启动参数'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '上下文大小'), '2048');
      await tester.runAsync(() async {
        final saved = catalog.changes.firstWhere((state) => !state.busy);
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        catalog.close();
        engine.close();
        library.close();
        createCatalog();
      });
      await showEnginePage();
      await tester.tap(find.byTooltip('启动参数'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, '上下文大小'),
      );
      expect(field.controller!.text, '2048');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same engine page exposes official full-app install without implying a callable oMLX pool',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine cpp;
      late EngineCatalog catalog;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd-omlx-page-');
        library = ModelLibrary();
        cpp = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/cpp'),
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: cpp,
          omlxEngine: OmlxEngine(
            installationDirectory: Directory('${root.path}/omlx'),
          ),
          useRegistry: ModelUseRegistry(library),
          registryFile: File('${root.path}/engines.json'),
        );
      });
      addTearDown(() async {
        catalog.close();
        cpp.close();
        library.close();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: EnginePage(
                catalog: catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      expect(find.text('oMLX · 官方 0.7.0'), findsOneWidget);
      expect(find.text('完整官方 app · 生产模型运行尚未接通'), findsOneWidget);
      expect(find.text('安装'), findsNWidgets(2));
      expect(find.text('Ready'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'engine management contains install and association but no model execution or LM Studio connection form',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine official;
      late EngineCatalog catalog;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jev-engine-page-');
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        official = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/engines'),
          useRegistry: use,
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: official,
          useRegistry: use,
          registryFile: File('${root.path}/registry.json'),
        );
      });
      addTearDown(() async {
        catalog.close();
        official.close();
        library.close();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(28),
                child: EnginePage(
                  catalog: catalog,
                  pickEngineDirectory: () async => null,
                ),
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      expect(find.text('关联引擎'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget);
      expect(find.text('运行'), findsNothing);
      expect(find.text('启动模型'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'engine page installs and removes selected standard release without changing JEV peer',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine jev, standard;
      late EngineCatalog catalog;
      late HttpServer download;
      var requests = 0;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd-dual-engine-page-');
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final data = engineArchive(artifactTag: 'b11146');
        download = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        download.listen((request) async {
          requests++;
          expect(request.uri.path, '/llama-b11146.tar.gz');
          request.response.add(data);
          await request.response.close();
        });
        final owned = Directory('${root.path}/engines');
        final peerData = engineArchive();
        jev = LlamaEngine(
          library: library,
          installationDirectory: owned,
          useRegistry: use,
          io: _InstallIO(),
          release: LlamaRelease(
            tag: 'b11381',
            commit: '836d57176',
            url: Uri.parse('https://github.com/fixture'),
            sha256: sha256.convert(peerData).toString(),
            sizeBytes: peerData.length,
          ),
        );
        standard = LlamaEngine(
          library: library,
          installationDirectory: owned,
          useRegistry: use,
          io: _InstallIO(),
          release: LlamaRelease(
            tag: 'v0.5.0',
            artifactTag: 'b11146',
            expectedBuild: 11146,
            supportsSystemone: false,
            commit: '7fe450e19305b828c199d602c23a8337aaa1f03b',
            url: Uri.parse(
              'http://127.0.0.1:${download.port}/llama-b11146.tar.gz',
            ),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: jev,
          standardEngine: standard,
          useRegistry: use,
          registryFile: File('${root.path}/registry.json'),
        );
        final archive = await File('${root.path}/peer.tar.gz')
            .writeAsBytes(peerData);
        await catalog.installOfficial(verifiedArchive: archive);
      });
      addTearDown(() async {
        catalog.close();
        jev.close();
        standard.close();
        library.close();
        await tester.runAsync(() async {
          await download.close(force: true);
          await root.delete(recursive: true);
        });
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(28),
                child: EnginePage(
                  catalog: catalog,
                  pickEngineDirectory: () async => null,
                ),
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      expect(find.text('llama.cpp · 标准 v0.5.0'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final installed = catalog.changes.firstWhere(
            (_) =>
                standard.state.installation ==
                LlamaInstallationStatus.installed,
          );
          await tester.tap(find.widgetWithText(FilledButton, '安装'));
          await installed.timeout(const Duration(seconds: 5));
          await catalog.refresh();
          await tester.pump();
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(standard.executablePath, endsWith('/v0.5.0/llama-server'));
      expect(jev.state.installation, LlamaInstallationStatus.installed);
      expect(find.text('安装'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, '删除').last);
        for (
          var n = 0;
          n < 100 && find.text('删除受管引擎').evaluate().isEmpty;
          n++
        ) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('删除受管引擎'), findsOneWidget);
      await tester.runAsync(() async {
        // Keep the stream subscription and confirmation in the real I/O zone.
        final removed = catalog.changes.firstWhere(
          (_) => standard.state.installation == LlamaInstallationStatus.absent,
        );
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
        // Navigator completes confirmation after its reverse animation. The first
        // frame starts the ticker; the next advances it before waiting for I/O.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await removed.timeout(const Duration(seconds: 5));
        await catalog.refresh();
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(standard.executablePath, isNull);
      expect(jev.state.installation, LlamaInstallationStatus.installed);
      expect(
        await tester.runAsync(() => File(jev.executablePath!).exists()),
        isTrue,
      );
      expect(find.text('安装'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}

class _InstallIO implements EngineProcessIO {
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      expect(timeout, const Duration(seconds: 10));
      return EngineCommandResult(
        0,
        executable.contains('b11146') || executable.contains('v0.5.0')
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
  Future<EngineChild> start(String executable, List<String> arguments) =>
      throw UnimplementedError();
}
