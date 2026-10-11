import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_game_work.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'game work exposes only its existing managed source cache location',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-game-source-paths-',
      );
      addTearDown(() => root.delete(recursive: true));
      final cache = Directory('${root.path}/cache');
      final work = BenchmarkGameWork(cache);
      addTearDown(work.close);
      expect(await work.sourceFilePaths(), isEmpty);
      await cache.create();
      expect(await work.sourceFilePaths(), [cache.absolute.path]);
    },
  );
  test('bundled game work prepares fixed arm64 assets and reuses verified app cache', () async {
    final root = await Directory.systemTemp.createTemp('gmd-game-work-');
    addTearDown(() => root.delete(recursive: true));
    final original = Directory(
      '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
    );
    final installation = Directory(
      '${root.path}/node/${JevmanRuntime.archiveRoot}',
    );
    await Directory('${installation.path}/bin').create(recursive: true);
    await File('${original.path}/bin/node')
        .copy('${installation.path}/bin/node');
    await File('${original.path}/LICENSE').copy('${installation.path}/LICENSE');
    expect(
      (await Process.run('/bin/chmod', [
        '700',
        '${installation.path}/bin/node',
      ])).exitCode,
      0,
    );
    final work = BenchmarkGameWork(root, loadAsset: _asset);
    addTearDown(work.close);
    await work.prepare(DecisionCancellation());
    expect(work.status.name, 'ready');
    expect(work.identity['id'], 'jevman');
    expect(work.identity['pin'], '1c8b77ac61bafa10956c601b1c9b339dcd277836');
    expect(work.identity['games'], 100);
    expect((work.identity['node'] as Map)['platform'], 'darwin-arm64');
    final manifest = jsonDecode(
      await File('benchmarks/manifests/jevman.json').readAsString(),
    ) as Map;
    final files = await root.list(recursive: true, followLinks: false).toList();
    final bundles = files
        .whereType<File>()
        .where((file) => file.path.endsWith('/bridge.mjs'))
        .toList();
    expect(bundles, hasLength(1));
    final before = await bundles.single.readAsBytes();
    expect(before, hasLength(manifest['bundleBytes'] as int));
    expect(sha256.convert(before).toString(), manifest['bundleSha256']);
    expect(await File('${installation.path}/bin/node').exists(), isTrue);
    await work.prepare(DecisionCancellation());
    expect(await bundles.single.readAsBytes(), before);
    expect(work.status.name, 'ready');
    await work.close();
    await expectLater(work.prepare(DecisionCancellation()), throwsStateError);
    expect(await bundles.single.readAsBytes(), before);
  });

  test('corrupt bundled game adapter fails before Node preparation', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-game-work-corrupt-',
    );
    addTearDown(() => root.delete(recursive: true));
    final protected = File('${root.path}/unrelated.txt');
    await protected.writeAsString('preserve');
    final work = BenchmarkGameWork(
      root,
      loadAsset: (path) async {
        if (path.endsWith('bridge.mjs')) {
          return ByteData.sublistView(Uint8List.fromList([0]));
        }
        return _asset(path);
      },
    );
    addTearDown(work.close);
    await expectLater(
      work.prepare(DecisionCancellation()),
      throwsFormatException,
    );
    expect(work.status.name, 'failed');
    expect(await Directory('${root.path}/node').exists(), isFalse);
    expect(await protected.readAsString(), 'preserve');
  });

  test('linked game cache is rejected while its external contents remain unchanged', () async {
    final root = await Directory.systemTemp.createTemp('gmd-game-work-link-');
    addTearDown(() => root.delete(recursive: true));
    final external = await Directory('${root.path}/external').create();
    final marker = File('${external.path}/protected.txt');
    await marker.writeAsString('external');
    final link = Link('${root.path}/cache');
    await link.create(external.path);
    final work = BenchmarkGameWork(Directory(link.path), loadAsset: _asset);
    addTearDown(work.close);
    await expectLater(
      work.prepare(DecisionCancellation()),
      throwsFormatException,
    );
    expect(await marker.readAsString(), 'external');
    expect(await external.list(followLinks: false).length, 1);
    expect(await link.exists(), isTrue);
  });
}

Future<ByteData> _asset(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());
