import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/omlx_engine.dart';

import 'fixtures/engine_archive.dart';

void main() {
  test('engine download reports bytes, allows peer settings, refuses duplicate work and cancels with staging cleaned', () async {
    final root = await Directory.systemTemp.createTemp('gmd-install-task-');
    final library = ModelLibrary();
    final data = engineArchive();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releaseBody = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = data.length;
      request.response.add(data.sublist(0, 32));
      await request.response.flush();
      await releaseBody.future;
      try {
        await request.response.close();
      } catch (_) {
        /* Client cancelled. */
      }
    });
    final downloading = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('http://127.0.0.1:${server.port}/engine.tar.gz'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
    );
    final peer = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      release: standardLlamaRelease,
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: downloading,
      standardEngine: peer,
      useRegistry: ModelUseRegistry(library),
      registryFile: File('${root.path}/engines.json'),
    );
    final received = catalog.changes.firstWhere(
      (_) => (downloading.installationProgress?.received ?? 0) > 0,
    );
    final installation = catalog.installManaged(EngineCatalog.officialId);
    final result = installation.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    try {
      expect(
        identical(
          installation,
          catalog.installManaged(EngineCatalog.officialId),
        ),
        isTrue,
      );
      await received.timeout(const Duration(seconds: 5));
      expect(catalog.state.busy, isFalse);
      expect(catalog.installationTasks[EngineCatalog.officialId]!.received, 32);
      await catalog
          .saveLaunchDefaults(
            EngineCatalog.standardId,
            EngineLaunchConfiguration(argumentText: '--ctx-size 65536'),
          )
          .timeout(const Duration(seconds: 1));
      expect(
        catalog.launchDefaultsFor(EngineCatalog.standardId).argumentText,
        '--ctx-size 65536',
      );
      catalog.cancelInstallation(EngineCatalog.officialId);
      expect(
        await result.timeout(const Duration(seconds: 5)),
        isA<LlamaEngineException>(),
      );
      expect(
        downloading.installationProgress!.phase,
        EngineInstallPhase.cancelled,
      );
      expect(downloading.installationProgress!.received, 32);
      expect(await Directory('${root.path}/owned/b11381').exists(), isFalse);
      expect(await Directory('${root.path}/owned').list().toList(), isEmpty);
    } finally {
      catalog.cancelInstallation(EngineCatalog.officialId);
      releaseBody.complete();
      await result;
      await catalog.shutdown();
      catalog.close();
      downloading.close();
      peer.close();
      library.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });

  test('oMLX native download streams progress and cancellation closes the transfer', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-progress-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.add(List.filled(1024, 7));
      await request.response.flush();
      await release.future;
      try {
        await request.response.close();
      } catch (_) {
        /* Download cancelled. */
      }
    });
    final cancellation = DecisionCancellation();
    final received = Completer<int>();
    final operation = NativeOmlxProcessIO().downloadWithProgress(
      Uri.parse('http://127.0.0.1:${server.port}/dmg'),
      File('${root.path}/dmg'),
      cancellation: cancellation,
      onProgress: (bytes) {
        if (!received.isCompleted) received.complete(bytes);
      },
    );
    final result = operation.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    try {
      expect(await received.future.timeout(const Duration(seconds: 5)), 1024);
      cancellation.cancel();
      expect(
        await result.timeout(const Duration(seconds: 5)),
        isA<Exception>(),
      );
    } finally {
      cancellation.cancel();
      release.complete();
      await result;
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
