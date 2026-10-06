import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/update_download_service.dart';

/// 本地回环下载源：以固定字节内容响应 GET。
class _ByteServer {
  HttpServer? _server;
  List<int> body = const [];
  int status = HttpStatus.ok;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final uri = Uri.parse('http://127.0.0.1:${server.port}/pkg.dmg');
    server.listen((request) async {
      request.response.statusCode = status;
      if (status == HttpStatus.ok) {
        request.response.contentLength = body.length;
        request.response.add(body);
      }
      await request.response.close();
    });
    return uri;
  }

  Future<void> close() async => _server?.close(force: true);
}

void main() {
  late _ByteServer server;
  late Uri source;
  late Directory tempDir;
  late List<String> openedPaths;

  setUp(() async {
    server = _ByteServer();
    source = await server.start();
    tempDir = await Directory.systemTemp.createTemp('update-download-test');
    openedPaths = [];
  });

  tearDown(() async {
    await server.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String targetFor(String version) =>
      '${tempDir.path}/Downloads/GhostModelDeck-$version.dmg';

  UpdateDownloadService service({Duration progressInterval = Duration.zero}) =>
      UpdateDownloadService(
        targetPathResolver: targetFor,
        openLauncher: (path) async {
          openedPaths.add(path);
          return null;
        },
        progressInterval: progressInterval,
      );

  final payload = utf8.encode('ghost-model-deck dmg payload' * 100);
  String payloadSha() => sha256.convert(payload).toString();

  test(
    'downloads, verifies sha256, saves to resolved path and opens',
    () async {
      server.body = payload;
      final progress = <UpdateDownloadProgress>[];
      final outcome = await service().downloadUpdate(
        source: source,
        version: '0.2.0',
        expectedSha256: payloadSha(),
        onProgress: progress.add,
      );
      expect(outcome, isA<UpdateDownloadCompleted>());
      final completed = outcome as UpdateDownloadCompleted;
      expect(completed.path, targetFor('0.2.0'));
      expect(completed.opened, isTrue);
      expect(completed.totalBytes, payload.length);
      expect(completed.sha256Hex, payloadSha());
      expect(openedPaths, [targetFor('0.2.0')]);
      expect(await File(targetFor('0.2.0')).readAsBytes(), payload);
      // 进度单调递增且收尾于完整长度。
      expect(progress, isNotEmpty);
      expect(progress.last.receivedBytes, payload.length);
      expect(progress.last.totalBytes, payload.length);
      expect(progress.last.fraction, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(
          progress[i].receivedBytes,
          greaterThanOrEqualTo(progress[i - 1].receivedBytes),
        );
      }
    },
  );

  test('sha256 mismatch never opens and removes all files', () async {
    server.body = payload;
    final outcome = await service().downloadUpdate(
      source: source,
      version: '0.2.0',
      expectedSha256: '0' * 64,
    );
    expect(outcome, isA<UpdateDownloadIntegrityFailure>());
    final failure = outcome as UpdateDownloadIntegrityFailure;
    expect(failure.expectedSha256, '0' * 64);
    expect(failure.actualSha256, payloadSha());
    expect(openedPaths, isEmpty);
    expect(await File(targetFor('0.2.0')).exists(), isFalse);
    expect(await File('${targetFor('0.2.0')}.part').exists(), isFalse);
  });

  test(
    'user declining the confirmation keeps nothing and opens nothing',
    () async {
      server.body = payload;
      UpdateDownloadReady? ready;
      final outcome = await service().downloadUpdate(
        source: source,
        version: '0.2.0',
        expectedSha256: payloadSha(),
        confirmBeforeInstall: (r) async {
          ready = r;
          return false;
        },
      );
      expect(outcome, isA<UpdateDownloadDeclined>());
      expect(ready?.sha256Hex, payloadSha()); // 确认发生在校验通过之后
      expect(openedPaths, isEmpty);
      expect(await File(targetFor('0.2.0')).exists(), isFalse);
    },
  );

  test('confirmed download moves verified bytes to target and opens', () async {
    server.body = payload;
    final outcome = await service().downloadUpdate(
      source: source,
      version: '0.2.0',
      expectedSha256: payloadSha().toUpperCase(), // 大小写不敏感
      confirmBeforeInstall: (r) async => true,
    );
    expect(outcome, isA<UpdateDownloadCompleted>());
    expect(openedPaths, [targetFor('0.2.0')]);
    expect(await File(targetFor('0.2.0')).readAsBytes(), payload);
  });

  test('open failure is reported while the file stays saved', () async {
    server.body = payload;
    final outcome =
        await UpdateDownloadService(
          targetPathResolver: targetFor,
          openLauncher: (path) async => 'open 退出码 1：boom',
        ).downloadUpdate(
          source: source,
          version: '0.2.0',
          expectedSha256: payloadSha(),
        );
    final completed = outcome as UpdateDownloadCompleted;
    expect(completed.opened, isFalse);
    expect(completed.openError, contains('boom'));
    expect(await File(targetFor('0.2.0')).exists(), isTrue);
  });

  test(
    'HTTP error maps to UpdateDownloadFailed without side effects',
    () async {
      server.status = HttpStatus.notFound;
      final outcome = await service().downloadUpdate(
        source: source,
        version: '0.2.0',
        expectedSha256: payloadSha(),
      );
      expect(outcome, isA<UpdateDownloadFailed>());
      expect((outcome as UpdateDownloadFailed).reason, contains('404'));
      expect(openedPaths, isEmpty);
      expect(await File(targetFor('0.2.0')).exists(), isFalse);
    },
  );

  test('network error maps to UpdateDownloadFailed and never throws', () async {
    final outcome = await service().downloadUpdate(
      source: Uri.parse('http://127.0.0.1:1/pkg.dmg'),
      version: '0.2.0',
      expectedSha256: payloadSha(),
      expectedSizeBytes: payload.length,
    );
    expect(outcome, isA<UpdateDownloadFailed>());
  });

  test('default target path resolves under ~/Downloads', () {
    final path = UpdateDownloadService.defaultTargetPath('0.2.0');
    expect(path, endsWith('/Downloads/GhostModelDeck-0.2.0.dmg'));
  });
}
