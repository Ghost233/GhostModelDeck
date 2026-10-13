import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/download_panel.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/download_tasks_page.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

void main() {
  testWidgets(
    'an active engine task keeps peer actions enabled and exposes progress plus cancel in Downloads',
    (tester) async {
      final library = ModelLibrary();
      final cpp = LlamaEngine(
        library: library,
        installationDirectory: Directory('/unused'),
      );
      final catalog = _DownloadViewCatalog(
        library: library,
        officialEngine: cpp,
        useRegistry: ModelUseRegistry(library),
        registryFile: File('/unused/engines.json'),
      );
      final downloader = ModelDownloader();
      final preferences = DownloadPreferences(
        file: File('/unused/preferences.json'),
      );
      addTearDown(() async {
        await downloader.close();
        preferences.dispose();
        catalog.close();
        cpp.close();
        library.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EnginePage(
              catalog: catalog,
              pickEngineDirectory: () async => null,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '安装'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '安装中'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadTasksPage(
              engines: catalog,
              downloads: DownloadTaskController(
                downloader: downloader,
                preferences: preferences,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('进行中：引擎 1 · 模型 0'), findsOneWidget);
      expect(find.text('平均速度：0 B/s'), findsOneWidget);
      expect(find.text('ggml-org/llama.cpp'), findsOneWidget);
      expect(find.text('1.0 KiB / 2.0 KiB'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      expect(catalog.cancelledId, EngineCatalog.officialId);
      await tester.pump();
      expect(find.text('进行中：引擎 0 · 模型 0'), findsOneWidget);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.textContaining('平均速度'), findsNothing);

      catalog.setTasks({
        EngineCatalog.officialId: const EngineInstallProgress(
          EngineInstallPhase.downloading,
          received: 1024,
          total: 2048,
          bytesPerSecond: 4096,
        ),
        EngineCatalog.standardId: const EngineInstallProgress(
          EngineInstallPhase.downloading,
          received: 2048,
          total: 8192,
          bytesPerSecond: 2048,
        ),
      });
      await tester.pump();
      expect(find.text('进行中：引擎 2 · 模型 0'), findsOneWidget);
      expect(find.text('平均速度：4.0 KiB/s'), findsOneWidget);
      expect(find.text('平均速度：2.0 KiB/s'), findsOneWidget);
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.text('25.0%'), findsOneWidget);
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .map((widget) => widget.value),
        [0.5, 0.25],
      );

      var openedDownloads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EnginePage(
              catalog: catalog,
              pickEngineDirectory: () async => null,
              onDownloadStarted: () => openedDownloads++,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, '查看下载'));
      expect(openedDownloads, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

/// A UI state fixture; real transfer, queue and cancellation behavior are checked
/// separately against loopback HTTP in engine_install_task_test.dart.
class _DownloadViewCatalog extends EngineCatalog {
  _DownloadViewCatalog({
    required super.library,
    required super.officialEngine,
    required super.useRegistry,
    required super.registryFile,
  });
  String? cancelledId;
  final _updates = StreamController<EngineCatalogState>.broadcast();
  @override
  Stream<EngineCatalogState> get changes => _updates.stream;
  @override
  void close() {
    unawaited(_updates.close());
    super.close();
  }

  void setTasks(Map<String, EngineInstallProgress> tasks) {
    _tasks = tasks;
    _updates.add(state);
  }

  @override
  Future<void> refresh() async {}
  @override
  void cancelInstallation(String id) {
    cancelledId = id;
    setTasks({
      ..._tasks,
      id: EngineInstallProgress(
        EngineInstallPhase.cancelled,
        received: _tasks[id]!.received,
        total: _tasks[id]!.total,
      ),
    });
  }

  @override
  Map<String, EngineInstallProgress> get installationTasks => _tasks;
  Map<String, EngineInstallProgress> _tasks = {
    EngineCatalog.officialId: const EngineInstallProgress(
      EngineInstallPhase.downloading,
      received: 1024,
      total: 2048,
    ),
  };
  @override
  EngineCatalogState get state => EngineCatalogState(
    entries: [
      EngineRegistration(
        id: EngineCatalog.officialId,
        name: 'JEV',
        source: EngineSource.managed,
        status: LlamaInstallationStatus.installing,
        release: officialLlamaRelease,
      ),
      EngineRegistration(
        id: EngineCatalog.standardId,
        name: 'llama.cpp',
        source: EngineSource.managed,
        status: LlamaInstallationStatus.absent,
        release: standardLlamaRelease,
      ),
    ],
  );
}
