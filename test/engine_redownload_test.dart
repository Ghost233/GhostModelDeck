import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_redownload.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/engine_archive.dart';

void main() {
  test('redownload failure restores the exact old installation and preserves an external linked file', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-redownload-restore-',
    );
    addTearDown(() => root.delete(recursive: true));
    final target = await Directory('${root.path}/engine').create();
    final external = await File('${root.path}/external')
        .writeAsString('user bytes');
    await File('${target.path}/server').writeAsString('old bytes');
    await Link('${target.path}/external').create(external.path);
    await expectLater(
      redownloadEngine(target, () async {
        await target.create();
        await File('${target.path}/server').writeAsString('partial new bytes');
        throw StateError('download failed');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await File('${target.path}/server').readAsString(), 'old bytes');
    expect(await Link('${target.path}/external').target(), external.path);
    expect(await external.readAsString(), 'user bytes');
    expect(
      (await root.list().toList()).where(
        (e) => e.path.contains('.gmd-redownload-'),
      ),
      isEmpty,
    );
  });

  test(
    'redownload publishes a fresh installation while preserving sibling assets',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-redownload-success-',
      );
      addTearDown(() => root.delete(recursive: true));
      final target = await Directory('${root.path}/engine').create();
      await File('${target.path}/server').writeAsString('old bytes');
      final model = await File('${root.path}/model.gguf')
          .writeAsString('model');
      await redownloadEngine(target, () async {
        await target.create();
        await File('${target.path}/server').writeAsString('new bytes');
      });
      expect(await File('${target.path}/server').readAsString(), 'new bytes');
      expect(await model.readAsString(), 'model');
      expect(
        (await root.list().toList()).where(
          (e) => e.path.contains('.gmd-redownload-'),
        ),
        isEmpty,
      );
    },
  );

  test('managed redownload streams one task, allows peer settings and restores the old installation on cancellation', () async {
    final root = await Directory.systemTemp.createTemp('gmd-redownload-http-');
    final library = ModelLibrary();
    final data = engineArchive();
    final archive = await File('${root.path}/archive.tar.gz')
        .writeAsBytes(data);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = data.length;
      request.response.add(data.sublist(0, 32));
      await request.response.flush();
      await release.future;
      try {
        await request.response.close();
      } catch (_) {
        /* Cancelled transfer. */
      }
    });
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      io: CouncilRuntimeIO(),
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('http://127.0.0.1:${server.port}/engine.tar.gz'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      useRegistry: ModelUseRegistry(library),
      registryFile: File('${root.path}/engines.json'),
    );
    Future<Object?>? result;
    try {
      await catalog.installOfficial(verifiedArchive: archive);
      await catalog.saveLaunchDefaults(
        EngineCatalog.officialId,
        EngineLaunchConfiguration(argumentText: '--ctx-size 65536'),
      );
      final binary = File(engine.executablePath!);
      final oldBytes = await binary.readAsBytes();
      final received = catalog.changes.firstWhere(
        (_) =>
            (engine.installationProgress?.received ?? 0) == 32 &&
            engine.installationProgress!.active,
      );
      final operation = catalog.redownloadManaged(EngineCatalog.officialId);
      expect(
        identical(
          operation,
          catalog.redownloadManaged(EngineCatalog.officialId),
        ),
        isTrue,
      );
      result = operation.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await received.timeout(const Duration(seconds: 5));
      expect(catalog.state.busy, isFalse);
      expect(
        catalog.installationTasks.values.where((t) => t.active),
        hasLength(1),
      );
      expect(engine.installationProgress!.bytesPerSecond, greaterThan(0));
      await catalog.saveLaunchDefaults(
        EngineCatalog.officialId,
        EngineLaunchConfiguration(argumentText: '--ctx-size 32768'),
      );
      catalog.cancelInstallation(EngineCatalog.officialId);
      expect(
        await result.timeout(const Duration(seconds: 5)),
        isA<LlamaEngineException>(),
      );
      expect(engine.installationProgress!.phase, EngineInstallPhase.cancelled);
      expect(await binary.readAsBytes(), oldBytes);
      expect(engine.state.installation, LlamaInstallationStatus.installed);
      expect(
        catalog.launchDefaultsFor(EngineCatalog.officialId).argumentText,
        '--ctx-size 32768',
      );
    } finally {
      catalog.cancelInstallation(EngineCatalog.officialId);
      release.complete();
      if (result != null) await result;
      await catalog.shutdown();
      catalog.close();
      engine.close();
      library.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
