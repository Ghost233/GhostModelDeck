import 'dart:io';

import 'package:flutter/material.dart';

import 'download_preferences.dart';
import 'hf_model_browser.dart';
import 'model_downloader.dart';
import 'model_package.dart';

/// Keeps the task's source, revision and destination across cancel/retry.
class DownloadTaskController {
  DownloadTaskController({required this.downloader, required this.preferences});

  final ModelDownloader downloader;
  final DownloadPreferences preferences;
  ModelPackageSelection? _selection;
  HfRepositoryFiles? _repository;
  String? _libraryPath;
  DownloadSource? _source;

  bool get canRetry =>
      _selection != null &&
      downloader.acceptsDownloads &&
      !downloader.state.isActive;

  Future<void> start({
    required ModelPackageSelection selection,
    required HfRepositoryFiles currentRepository,
    required String libraryPath,
  }) async {
    if (!downloader.acceptsDownloads || downloader.state.isActive) return;
    _selection = selection;
    _repository = currentRepository;
    _libraryPath = libraryPath;
    _source = preferences.source;
    await _run();
  }

  Future<void> retry({bool restart = false}) async {
    if (!canRetry) return;
    await _run(restart: restart);
  }

  Future<void> _run({bool restart = false}) async {
    try {
      await downloader.downloadPackage(
        selection: _selection!,
        currentRepository: _repository!,
        libraryDirectory: Directory(_libraryPath!),
        source: _source!,
        restart: restart,
      );
    } catch (_) {
      // The desktop displays terminal cleanup failure through downloader state.
      // The owning downloader still rejects close/manager shutdown with it.
      if (downloader.acceptsDownloads ||
          downloader.state.status != DownloadStatus.failed) {
        rethrow;
      }
    }
  }
}

/// The selected package has one action; configuration lives in Settings.
class DownloadPanel extends StatelessWidget {
  const DownloadPanel({
    super.key,
    required this.downloads,
    required this.browser,
    required this.modelPackage,
    this.variantId,
    required this.libraryPath,
    this.onDownloadStarted,
  });

  final DownloadTaskController downloads;
  final HfModelBrowser browser;
  final ModelPackage? modelPackage;
  final String? variantId;
  final String libraryPath;
  final VoidCallback? onDownloadStarted;

  ModelVariant? get _variant {
    final variants = modelPackage?.variants;
    if (variants == null || variants.isEmpty) return null;
    if (variantId == null) return variants.length == 1 ? variants.single : null;
    final matches = variants.where((variant) => variant.id == variantId);
    return matches.length == 1 ? matches.single : null;
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<HfBrowserState>(
    stream: browser.changes,
    initialData: browser.state,
    builder: (context, browserSnapshot) => StreamBuilder<DownloadState>(
      stream: downloads.downloader.changes,
      initialData: downloads.downloader.state,
      builder: (context, snapshot) {
        final repository = browserSnapshot.data!.repository;
        final variant = _variant;
        final canDownload =
            downloads.downloader.acceptsDownloads &&
            !snapshot.data!.isActive &&
            libraryPath.isNotEmpty &&
            browserSnapshot.data!.repositoryStatus == RequestStatus.ready &&
            modelPackage != null &&
            variant != null &&
            variant.canDownload &&
            repository?.summary.id == modelPackage!.repository.summary.id &&
            repository?.revision == modelPackage!.repository.revision;
        return Padding(
          padding: const EdgeInsets.only(top: 24),
          child: SizedBox(
            width: double.infinity,
            height: 40,
            child: FilledButton.icon(
              onPressed: canDownload
                  ? () {
                      downloads.start(
                        selection: modelPackage!.selectVariant(variant.id),
                        currentRepository: repository!,
                        libraryPath: libraryPath,
                      );
                      onDownloadStarted?.call();
                    }
                  : null,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('下载'),
            ),
          ),
        );
      },
    ),
  );
}
