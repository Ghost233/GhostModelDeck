import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  testWidgets(
    'running from the library discovers an existing installation without visiting engine management',
    (tester) async {
      late Directory root, models;
      late ModelLibrary library;
      late LlamaEngine original, fresh;
      late EngineCatalog catalog;
      final io = _RuntimeIO();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jev-library-run-');
        models = Directory('${root.path}/models');
        await writeDecisionKev(models);
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final data = engineArchive();
        final archive = await File('${root.path}/release.tar.gz')
            .writeAsBytes(data);
        final release = LlamaRelease(
          tag: 'b11381',
          commit: '836d57176',
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
        catalog = EngineCatalog(
          library: library,
          officialEngine: fresh,
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
              tester
                  .widget<DropdownButton<String>>(dropdown)
                  .items!
                  .isNotEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(dropdown.items, hasLength(1));
      expect(find.text('请先安装或关联引擎'), findsNothing);
      final engineField = find.byType(DropdownButtonFormField<String>);
      final version = find.textContaining('836d57176');
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
      expect(fresh.state.instances.single.lastResult!.probabilities, {
        'keep': 0.25,
        'change': 0.75,
      });
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
      expect(find.text('运行中'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
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
  bool stopFailure = false;
  int stopAttempts = 0;
  Completer<void>? stopRelease;
  Completer<void>? stopRequested;
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
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
