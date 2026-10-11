import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/download_panel.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_package.dart';

void main() {
  test('a desktop task handles a terminal cleanup failure while preserving failed state and rejecting new attempts', () async {
    const revision = '0123456789012345678901234567890123456789';
    final directory = await Directory.systemTemp.createTemp('task-cleanup-');
    final formal = Directory('${directory.path}/publisher/model');
    await formal.create(recursive: true);
    File? removedTemporary;
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.pathSegments.last == 'Model-00032-of-00032.gguf') {
        removedTemporary =
            (await Directory('${directory.path}/.ghostmodeldeck/downloads')
                        .list(recursive: true)
                        .where(
                          (entry) => entry.path.endsWith(
                            '/Model-00002-of-00032.gguf.part',
                          ),
                        )
                        .toList())
                    .single
                as File;
      }
      request.response.write('abc');
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final downloader = ModelDownloader(hfEndpoint: endpoint);
    final preferences = DownloadPreferences(
      file: File('${directory.path}/preferences.json'),
    );
    final tasks = DownloadTaskController(
      downloader: downloader,
      preferences: preferences,
    );
    addTearDown(() async {
      await downloader.close().then<void>((_) {}, onError: (Object _) {});
      preferences.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: revision,
      requestedRevision: 'main',
      source: endpoint,
      files: [
        for (var i = 1; i <= 32; i++)
          HfModelFile(
            path: 'Model-${i.toString().padLeft(5, '0')}-of-00032.gguf',
            sizeBytes: 3,
            sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          ),
      ],
    );
    final package = ModelPackage.discover(repository).single;
    final selection = package.selectVariant(package.variants.single.id);
    final installationPaused = Completer<void>();
    final resumeInstallation = Completer<void>();
    final blocked = File('${formal.path}/Model-00002-of-00032.gguf');
    final nextTarget =
        '${await formal.resolveSymbolicLinks()}/Model-00003-of-00032.gguf';
    final filesystemZone = Zone.current;
    final task = IOOverrides.runZoned(
      () => tasks.start(
        selection: selection,
        currentRepository: repository,
        libraryPath: directory.path,
      ),
      fseGetType: (path, followLinks) async {
        final type = await filesystemZone.run(
          () => FileSystemEntity.type(path, followLinks: followLinks),
        );
        if (path == nextTarget &&
            removedTemporary != null &&
            !installationPaused.isCompleted &&
            await filesystemZone.run(
                  () => FileSystemEntity.type(blocked.path, followLinks: false),
                ) ==
                FileSystemEntityType.file) {
          installationPaused.complete();
          await resumeInstallation.future;
        }
        return type;
      },
    );
    final handled = expectLater(task, completes);
    try {
      await installationPaused.future.timeout(const Duration(seconds: 5));
      final temporary = removedTemporary!;
      expect(
        await FileSystemEntity.identical(temporary.path, blocked.path),
        isTrue,
      );
      temporary.deleteSync();
      downloader.cancel();
    } finally {
      resumeInstallation.complete();
    }
    await handled;
    expect(downloader.state.status, DownloadStatus.failed);
    expect(downloader.state.error, contains('下载清理未完成'));
    expect(tasks.canRetry, isFalse);
    final requestCount = requests.length;
    await tasks.retry();
    final nextPath = '${directory.path}/another-library';
    await tasks.start(
      selection: selection,
      currentRepository: repository,
      libraryPath: nextPath,
    );
    expect(requests, hasLength(requestCount));
    expect(await Directory(nextPath).exists(), isFalse);
    expect(downloader.state.status, DownloadStatus.failed);
    await expectLater(downloader.close(), throwsA(isA<Exception>()));
  });

  test(
    'changing download settings affects the next task, not cancelled resume',
    () async {
      const revision = '0123456789012345678901234567890123456789';
      final directory = await Directory.systemTemp.createTemp('task-source-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final fragment = Completer<void>();
      final requests = <String>[];
      final ranges = <String?>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.headers.set(HttpHeaders.etagHeader, '"fixed-asset"');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (requests.length == 1) {
          request.response.bufferOutput = false;
          request.response.contentLength = 6;
          request.response.add(utf8.encode('abc'));
          await request.response.flush();
          await release.future;
          try {
            await request.response.close();
          } on IOException {
            /* cancelled */
          }
        } else if (requests.length == 2) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 3-5/6',
          );
          request.response.contentLength = 3;
          request.response.add(utf8.encode('def'));
          await request.response.close();
        } else {
          request.response.contentLength = 6;
          request.response.add(utf8.encode('abcdef'));
          await request.response.close();
        }
      });
      final base = 'http://127.0.0.1:${server.port}';
      final downloader = ModelDownloader(
        hfEndpoint: Uri.parse('$base/hf'),
        lmStudioEndpoint: Uri.parse('$base/proxy'),
      );
      final preferences = DownloadPreferences(
        file: File('${directory.path}/preferences.json'),
      );
      await preferences.saveSource(DownloadSource.lmStudio);
      final tasks = DownloadTaskController(
        downloader: downloader,
        preferences: preferences,
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        downloader.close();
        preferences.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      HfRepositoryFiles repository(String id) => HfRepositoryFiles(
        summary: HfRepositorySummary(id: id),
        revision: revision,
        requestedRevision: 'main',
        source: Uri.parse('$base/hf'),
        files: const [
          HfModelFile(
            path: 'model.gguf',
            sizeBytes: 6,
            sha256: 'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721',
          ),
        ],
      );
      final first = repository('publisher/first');
      final sub = downloader.changes.listen((state) {
        if (state.downloadedBytes == 3 && !fragment.isCompleted) {
          fragment.complete();
        }
      });
      final transfer = tasks.start(
        selection: ModelPackage.discover(first).single.selectVariant(
          ModelPackage.discover(first).single.variants.single.id,
        ),
        currentRepository: first,
        libraryPath: directory.path,
      );
      await fragment.future.timeout(const Duration(seconds: 5));
      await preferences.saveSource(DownloadSource.hf);
      expect(downloader.state.source, DownloadSource.lmStudio);
      downloader.cancel();
      await transfer.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(downloader.state.status, DownloadStatus.cancelled);
      await tasks.retry();
      expect(
        downloader.state.status,
        DownloadStatus.installed,
        reason: downloader.state.error,
      );
      expect(requests, [
        '/proxy/publisher/first/resolve/$revision/model.gguf',
        '/proxy/publisher/first/resolve/$revision/model.gguf',
      ]);
      expect(ranges, [null, 'bytes=3-']);
      expect(downloader.state.libraryPath, directory.path);
      expect(
        await File('${directory.path}/publisher/first/model.gguf')
            .readAsString(),
        'abcdef',
      );
      final second = repository('publisher/second');
      final secondPackage = ModelPackage.discover(second).single;
      final nextDirectory = '${directory.path}/new model directory';
      await tasks.start(
        selection: secondPackage.selectVariant(
          secondPackage.variants.single.id,
        ),
        currentRepository: second,
        libraryPath: nextDirectory,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      expect(downloader.state.source, DownloadSource.hf);
      expect(downloader.state.libraryPath, nextDirectory);
      expect(
        requests.last,
        '/hf/publisher/second/resolve/$revision/model.gguf',
      );
    },
  );
}
