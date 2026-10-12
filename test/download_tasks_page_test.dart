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
  @override
  Future<void> refresh() async {}
  @override
  void cancelInstallation(String id) {
    cancelledId = id;
  }

  @override
  Map<String, EngineInstallProgress> get installationTasks => {
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
