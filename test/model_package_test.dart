import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_package.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/mlx_package.dart';

import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

const _revision = '0123456789012345678901234567890123456789';

HfRepositoryFiles _fixtureRepository(
  Map<String, List<int>> bodies,
  Uri endpoint,
) => HfRepositoryFiles(
  summary: const HfRepositorySummary(id: 'publisher/model'),
  revision: 'a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3',
  requestedRevision: 'main',
  source: endpoint,
  files: [
    for (final entry in bodies.entries)
      HfModelFile(
        path: entry.key,
        sizeBytes: entry.value.length,
        sha256: sha256.convert(entry.value).toString(),
        isLfs: true,
      ),
  ],
);

void main() {
  test('indexed MLX public package cancellation reopens Range ETag resume with proxy lineage', () async {
    final root = await Directory.systemTemp.createTemp('gmd-mlx-resume-');
    final bodies = mlxPackageBytes();
    final payload = bodies['model.safetensors']!;
    final half = payload.length ~/ 2;
    final release = Completer<void>();
    final fragment = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var firstWeight = true;
    String? range;
    String? validator;
    server.listen((request) async {
      final path = request.uri.pathSegments.skip(4).join('/');
      final bytes = bodies[path]!;
      request.response.headers.set(HttpHeaders.etagHeader, '"mlx-fixed-v1"');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (path == 'model.safetensors' && firstWeight) {
        firstWeight = false;
        request.response.bufferOutput = false;
        request.response.contentLength = bytes.length;
        request.response.add(bytes.take(half).toList());
        await request.response.flush();
        await release.future;
      } else if (path == 'model.safetensors') {
        range = request.headers.value(HttpHeaders.rangeHeader);
        validator = request.headers.value(HttpHeaders.ifRangeHeader);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $half-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length - half;
        request.response.add(bytes.sublist(half));
      } else {
        request.response.add(bytes);
      }
      try {
        await request.response.close();
      } on IOException {
        // First response intentionally stops while the downloader is cancelled.
      }
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    var downloader = ModelDownloader(lmStudioEndpoint: endpoint);
    final library = ModelLibrary();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await downloader.close();
      library.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final repository = _fixtureRepository(bodies, endpoint);
    final package = ModelPackage.discover(repository).single;
    final selection = package.selectVariant(package.variants.single.id);
    int? weightStartedAt;
    final subscription = downloader.changes.listen((state) {
      if (state.currentFile == 'model.safetensors') {
        weightStartedAt ??= state.downloadedBytes;
        if (state.status == DownloadStatus.downloading &&
            state.downloadedBytes > weightStartedAt! &&
            !fragment.isCompleted) {
          fragment.complete();
        }
      }
    });
    final transfer = downloader.downloadPackage(
      selection: selection,
      currentRepository: repository,
      libraryDirectory: root,
      source: DownloadSource.lmStudio,
    );
    await fragment.future.timeout(const Duration(seconds: 5));
    expect(downloader.state.downloadedBytes - weightStartedAt!, half);
    downloader.cancel();
    await transfer.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    expect(downloader.state.status, DownloadStatus.cancelled);
    expect(
      await File('${root.path}/publisher/model/model.safetensors').exists(),
      isFalse,
    );
    final fragments = await Directory('${root.path}/.ghostmodeldeck/downloads')
        .list(recursive: true)
        .where((entry) => entry.path.endsWith('/model.safetensors.part'))
        .cast<File>()
        .toList();
    expect(await fragments.single.readAsBytes(), payload.take(half).toList());
    await downloader.close();
    release.complete();
    downloader = ModelDownloader(lmStudioEndpoint: endpoint);
    await downloader.downloadPackage(
      selection: selection,
      currentRepository: repository,
      libraryDirectory: root,
      source: DownloadSource.lmStudio,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    expect(range, 'bytes=$half-');
    expect(validator, '"mlx-fixed-v1"');
    expect(
      downloader.state.downloadedBytes,
      bodies.values.fold<int>(0, (sum, bytes) => sum + bytes.length),
    );
    final receipt = jsonDecode(
      await File(
        '${root.path}/.ghostmodeldeck/installations/${downloader.state.installationId}.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    expect(receipt['source'], 'lmStudio');
    expect(receipt['revision'], repository.revision);
    expect(receipt['files'], hasLength(9));
    final asset = (await library.scan(root, verifyFiles: true)).single;
    expect(asset.sourceVerified, isTrue);
    expect(asset.files, hasLength(9));
  });
  for (final failure in [
    'missing',
    'checksum',
    'offline',
    'conflict',
    'index-missing',
    'mixed-unindexed',
  ]) {
    test(
      'indexed MLX public downloadPackage preserves assets on $failure',
      () async {
        final root = await Directory.systemTemp.createTemp('gmd-mlx-failure-');
        final bodies = mlxPackageBytes();
        if (failure == 'index-missing') {
          bodies['model.safetensors.index.json'] = utf8.encode(
            '{"weight_map":{"layer.weight":"absent.safetensors"}}',
          );
        }
        if (failure == 'mixed-unindexed') {
          bodies.remove('model.safetensors.index.json');
          bodies['model-F16.safetensors'] = bodies['model.safetensors']!;
        }
        final sentinel = await File('${root.path}/existing/user.asset')
            .create(recursive: true);
        await sentinel.writeAsString('untouched user asset');
        File? collision;
        if (failure == 'conflict') {
          collision = await File('${root.path}/publisher/model/vocab.json')
              .create(recursive: true);
          await collision.writeAsString('existing formal content');
        }
        final before = await sentinel.stat();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((request) async {
          requests++;
          final path = request.uri.pathSegments.skip(4).join('/');
          final bytes = bodies[path]!;
          if (path == 'model.safetensors' && failure == 'missing') {
            request.response.statusCode = HttpStatus.notFound;
          } else if (path == 'model.safetensors' && failure == 'checksum') {
            request.response.add([...bytes.take(bytes.length - 1), 255]);
          } else if (path == 'model.safetensors' && failure == 'offline') {
            request.response.contentLength = bytes.length;
            request.response.add(bytes.take(bytes.length ~/ 2).toList());
          } else {
            request.response.add(bytes);
          }
          try {
            await request.response.close();
          } on IOException {
            // Deliberately truncated HTTP body simulates a broken connection.
          }
        });
        final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
        final downloader = ModelDownloader(hfEndpoint: endpoint);
        addTearDown(() async {
          await downloader.close();
          await server.close(force: true);
          await root.delete(recursive: true);
        });
        final repository = _fixtureRepository(bodies, endpoint);
        final package = ModelPackage.discover(repository).single;
        await downloader.downloadPackage(
          selection: package.selectVariant(package.variants.first.id),
          currentRepository: repository,
          libraryDirectory: root,
        );
        expect(
          downloader.state.status,
          failure == 'conflict'
              ? DownloadStatus.conflict
              : failure == 'offline'
              ? DownloadStatus.interrupted
              : DownloadStatus.failed,
        );
        expect(
          await File('${root.path}/publisher/model/model.safetensors').exists(),
          isFalse,
        );
        expect(await sentinel.readAsString(), 'untouched user asset');
        expect((await sentinel.stat()).modified, before.modified);
        if (collision != null) {
          expect(await collision.readAsString(), 'existing formal content');
        }
        if (failure == 'mixed-unindexed') {
          expect(
            package.variants.every((variant) => !variant.canDownload),
            isTrue,
          );
          expect(requests, 0);
        }
        final receipts = Directory(
          '${root.path}/.ghostmodeldeck/installations',
        );
        expect(
          await receipts.exists() ? await receipts.list().toList() : [],
          isEmpty,
        );
      },
    );
  }
  test(
    'GGUF receipt companions remain in scan verification and deletion',
    () async {
      final temp = await Directory.systemTemp.createTemp('gmd-gguf-closure-');
      final source = await Directory('${temp.path}/source').create();
      final root = await Directory('${temp.path}/library').create();
      final gguf = await writeDecisionKev(source);
      final bodies = <String, List<int>>{
        'Kev-Q8_0.gguf': await gguf.readAsBytes(),
        'chat_template.jinja': utf8.encode('{{ messages }}'),
      };
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add(
          bodies[request.uri.pathSegments.skip(4).join('/')]!,
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      final library = ModelLibrary();
      addTearDown(() async {
        await downloader.close();
        library.close();
        await server.close(force: true);
        await temp.delete(recursive: true);
      });
      final repository = _fixtureRepository(bodies, endpoint);
      final package = ModelPackage.discover(repository).single;
      await downloader.downloadPackage(
        selection: package.selectVariant(package.variants.single.id),
        currentRepository: repository,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      final asset = (await library.scan(root)).single;
      expect(asset.files, hasLength(2));
      final checked = (await library.verify([asset.id])).single;
      expect(checked.sourceVerified, isTrue);
      final plan = await library.prepareDeletion([checked.id]);
      expect(plan.files, hasLength(2));
      final registry = ModelUseRegistry(library);
      final template = '${root.path}/publisher/model/chat_template.jinja';
      await registry.update('engine-a', [template]);
      await registry.update('engine-b', [template]);
      await registry.update('engine-a', []);
      await expectLater(
        library.delete(plan, confirmed: true),
        throwsA(isA<LibraryException>()),
      );
      await registry.update('engine-b', []);
      expect(
        await library.delete(plan, confirmed: true),
        DeletionResult.deleted,
      );
      expect(await File(template).exists(), isFalse);
      expect(await gguf.exists(), isTrue);
    },
  );
  test('indexed MLX download scan and verify retain all nine assets', () async {
    final root = await Directory.systemTemp.createTemp('gmd-mlx-');
    final bodies = mlxPackageBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = <String>[];
    server.listen((request) async {
      final path = request.uri.pathSegments.skip(4).join('/');
      requested.add(path);
      request.response.add(bodies[path]!);
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final downloader = ModelDownloader(hfEndpoint: endpoint);
    final library = ModelLibrary();
    addTearDown(() async {
      await downloader.close();
      library.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: 'a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3',
      requestedRevision: 'main',
      source: endpoint,
      files: [
        for (final entry in bodies.entries)
          HfModelFile(
            path: entry.key,
            sizeBytes: entry.value.length,
            sha256: sha256.convert(entry.value).toString(),
            isLfs: true,
          ),
        const HfModelFile(path: 'unused-Q8.safetensors', sizeBytes: 99),
      ],
    );
    final package = ModelPackage.discover(repository).single;
    await downloader.downloadPackage(
      selection: package.selectVariant(package.variants.single.id),
      currentRepository: repository,
      libraryDirectory: root,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    expect(requested.toSet(), bodies.keys.toSet());
    final asset = (await library.scan(root)).single;
    expect(
      asset.files.map((file) => file.path.split('/').last).toSet(),
      bodies.keys.toSet(),
    );
    final local = await LocalModelPackages.discover(root, [asset]);
    expect(local.packages.single.variants.single.files, hasLength(9));
    expect(
      local.packages.single.variants.single.label,
      'Safetensors · 4bit · group 64',
    );
    expect(asset.integrity, AssetIntegrity.unknown);
    expect(asset.engineCapability, EngineCapability.awaitingVerification);
    final checked = (await library.verify([asset.id])).single;
    expect(checked.fingerprintsVerified, isTrue);
    expect(checked.sourceVerified, isTrue);
    expect(
      local.packages.single.variants.single.sizeBytes,
      bodies.values.fold<int>(0, (sum, bytes) => sum + bytes.length),
    );
    final plan = await library.prepareDeletion([checked.id]);
    expect(plan.files, hasLength(9));
    expect(
      await library.delete(plan, confirmed: false),
      DeletionResult.cancelled,
    );
    final registry = ModelUseRegistry(library);
    final companion = '${root.path}/publisher/model/vocab.json';
    await registry.update('engine-a', [companion]);
    await registry.update('engine-b', [companion]);
    await registry.update('engine-a', []);
    await expectLater(
      library.delete(plan, confirmed: true),
      throwsA(isA<LibraryException>()),
    );
    await registry.update('engine-b', []);
    // Same length text changes must be caught by selected full verification.
    await File(companion).writeAsString('{"jello":0}');
    final changed = (await library.verify([checked.id])).single;
    expect(changed.integrity, AssetIntegrity.corrupt);
    expect(changed.sourceVerified, isFalse);
    await File(companion).writeAsBytes(bodies['vocab.json']!);
    await File('${root.path}/publisher/model/merges.txt').delete();
    final missing = (await library.scan(root, verifyFiles: true)).single;
    expect(missing.integrity, AssetIntegrity.incomplete);
    await File('${root.path}/publisher/model/merges.txt')
        .writeAsBytes(bodies['merges.txt']!);
    final restored = (await library.scan(root, verifyFiles: true)).single;
    final fresh = await library.prepareDeletion([restored.id]);
    expect(
      await library.delete(fresh, confirmed: true),
      DeletionResult.deleted,
    );
    for (final path in bodies.keys) {
      expect(
        await File('${root.path}/publisher/model/$path').exists(),
        isFalse,
      );
    }
    expect(await root.exists(), isTrue);
  });
  test('the fixed native Laya package includes its complete tokenizer and encoder configuration only', () async {
    // Primary HF metadata snapshot, retrieved at this immutable revision.
    const revision = '1720e3e3357cfe1e281542e223f8273b0890ca34';
    final metadata = await File(
      'test/fixtures/hf_laya_multilingual_1720e3e.json',
    ).readAsString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      request.response.write(metadata);
      await request.response.close();
    });
    final browser = HfModelBrowser(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(() async {
      browser.close();
      await server.close(force: true);
    });
    await browser.selectRepository(
      'convaiinnovations/laya-multilingual',
      revision: revision,
    );
    final original = browser.state.repository!;
    expect(original.revision, revision);
    expect(requests, [
      '/api/models/convaiinnovations/laya-multilingual/revision/$revision',
    ]);
    final repository = HfRepositoryFiles(
      summary: original.summary,
      revision: original.revision,
      requestedRevision: original.requestedRevision,
      source: original.source,
      files: [
        ...original.files,
        const HfModelFile(path: 'other-model/model.safetensors', sizeBytes: 99),
        const HfModelFile(path: 'other-model/config.json', sizeBytes: 2),
        const HfModelFile(path: 'other-model/tokenizer.json', sizeBytes: 2),
        const HfModelFile(path: 'quantized/model-Q8_0.gguf', sizeBytes: 99),
      ],
    );
    final variant = ModelPackage.discover(repository)
        .singleWhere((package) => package.directory.isEmpty)
        .variants
        .single;
    expect(variant.resolution, PackageResolution.resolved);
    expect(variant.canDownload, isTrue);
    expect(variant.sizeBytes, 678201774);
    expect(variant.files.map((file) => file.path).toSet(), {
      'config.json',
      'model.safetensors',
      'rl_agent_config.json',
      'encoder/config.json',
      'tokenizer/tokenizer.json',
      'tokenizer/tokenizer_config.json',
    });
    expect(
      variant.files
          .singleWhere((file) => file.path == 'tokenizer/tokenizer.json')
          .sizeBytes,
      34363188,
    );
    final missingVocabulary = HfRepositoryFiles(
      summary: repository.summary,
      revision: repository.revision,
      requestedRevision: repository.requestedRevision,
      source: repository.source,
      files: repository.files
          .where((file) => file.path != 'tokenizer/tokenizer.json')
          .toList(),
    );
    final incomplete = ModelPackage.discover(missingVocabulary)
        .singleWhere((package) => package.directory.isEmpty)
        .variants
        .single;
    expect(incomplete.resolution, PackageResolution.incomplete);
    expect(incomplete.canDownload, isFalse);
  });

  test('locally reused files retain their fixed lineage and upstream verification after a library scan', () async {
    final root = await Directory.systemTemp.createTemp('jev-local-receipt-');
    final existing = await writeDecisionKev(root);
    final before = await existing.stat();
    final digest = sha256.convert(await existing.readAsBytes()).toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final downloader = ModelDownloader(
      hfEndpoint: endpoint,
      lmStudioEndpoint: endpoint,
    );
    final library = ModelLibrary();
    addTearDown(() async {
      await downloader.close();
      library.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(
        id: 'author/Kev',
        license: 'apache-2.0',
      ),
      revision: _revision,
      requestedRevision: 'main',
      source: endpoint,
      files: [
        HfModelFile(
          path: 'Kev-Q8_0.gguf',
          sizeBytes: before.size,
          sha256: digest,
          isLfs: true,
        ),
      ],
    );
    final package = ModelPackage.discover(repository).single;
    await downloader.downloadPackage(
      selection: package.selectVariant(package.variants.single.id),
      currentRepository: repository,
      libraryDirectory: root,
      source: DownloadSource.lmStudio,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    expect(downloader.state.reusedExisting, isTrue);
    expect(requests, 0);
    expect((await existing.stat()).modified, before.modified);
    final receiptFile = File(
      '${root.path}/.ghostmodeldeck/installations/${downloader.state.installationId}.json',
    );
    final receipt =
        jsonDecode(await receiptFile.readAsString()) as Map<String, dynamic>;
    expect(receipt['source'], 'local');
    expect(receipt['sourceTransferPerformed'], isFalse);
    final asset = (await library.scan(root, verifyFiles: true)).single;
    expect(asset.repoId, 'author/Kev');
    expect(asset.revision, _revision);
    expect(asset.license, 'apache-2.0');
    expect(asset.integrity, AssetIntegrity.complete);
    expect(asset.sourceVerified, isTrue);
    final changedBytes = await existing.readAsBytes();
    changedBytes[changedBytes.length - 1] = 1;
    await existing.writeAsBytes(changedBytes);
    final changed = (await library.scan(root, verifyFiles: true)).single;
    expect(changed.integrity, AssetIntegrity.corrupt);
    expect(changed.sourceVerified, isFalse);
    expect(
      jsonDecode(await receiptFile.readAsString())['sourceTransferPerformed'],
      isFalse,
    );
  });

  test('a GGUF quantization resolves its complete shards and companions', () {
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: Uri.parse('https://huggingface.co'),
      files: const [
        HfModelFile(path: 'Model-Q4_K_M-00001-of-00002.gguf', sizeBytes: 3),
        HfModelFile(path: 'Model-Q4_K_M-00002-of-00002.gguf', sizeBytes: 3),
        HfModelFile(path: 'Model-Q8_0.gguf', sizeBytes: 99),
        HfModelFile(path: 'config.json', sizeBytes: 2),
        HfModelFile(path: 'tokenizer.json', sizeBytes: 2),
        HfModelFile(path: 'decision_head.safetensors', sizeBytes: 4),
        HfModelFile(path: 'README.md', sizeBytes: 8),
      ],
    );
    final packages = ModelPackage.discover(repository);
    expect(packages, hasLength(1));
    final model = packages.single;
    expect(model.label, 'Model');
    expect(model.repository.revision, _revision);
    expect(model.variants.map((variant) => variant.quantization).toSet(), {
      'Q4_K_M',
      'Q8_0',
    });
    final q4 = model.variants.singleWhere(
      (variant) => variant.quantization == 'Q4_K_M',
    );
    final selection = model.selectVariant(q4.id);
    expect(selection.variant.canDownload, isTrue);
    expect(selection.variant.format, 'GGUF');
    expect(selection.variant.sizeBytes, 14);
    expect(selection.variant.files.map((file) => file.path).toSet(), {
      'Model-Q4_K_M-00001-of-00002.gguf',
      'Model-Q4_K_M-00002-of-00002.gguf',
      'config.json',
      'tokenizer.json',
      'decision_head.safetensors',
    });
    expect(() => selection.variant.files.clear(), throwsUnsupportedError);
  });

  test(
    'package action reuses only complete full-hash verified installations',
    () async {
      final root = await Directory.systemTemp.createTemp('jev-package-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.add(utf8.encode('abc'));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final repository = HfRepositoryFiles(
        summary: const HfRepositorySummary(id: 'publisher/model'),
        revision: _revision,
        requestedRevision: 'main',
        source: endpoint,
        files: const [
          HfModelFile(
            path: 'Model-Q8_0.gguf',
            sizeBytes: 3,
            isLfs: true,
            sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
          ),
          HfModelFile(path: 'Model-Q4_K_M.gguf', sizeBytes: 99),
        ],
      );
      await downloader.download(
        repository: repository,
        selectedFilePaths: {'Model-Q8_0.gguf'},
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      final file = File('${root.path}/publisher/model/Model-Q8_0.gguf');
      final modified = (await file.stat()).modified;
      final records = await Directory(
        '${root.path}/.ghostmodeldeck/installations',
      ).list().where((entry) => entry is File).cast<File>().toList();
      final originalRecord = await records.single.readAsString();
      final package = ModelPackage.discover(repository).single;
      final selection = package.selectVariant(
        package.variants
            .singleWhere((variant) => variant.quantization == 'Q8_0')
            .id,
      );
      await downloader.downloadPackage(
        selection: selection,
        currentRepository: repository,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      expect(requests, 1);
      expect((await file.stat()).modified, modified);
      expect(await records.single.readAsString(), originalRecord);
      await file.writeAsString('xyz');
      await downloader.downloadPackage(
        selection: selection,
        currentRepository: repository,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.conflict);
      expect(await file.readAsString(), 'xyz');
      expect(requests, 1);
      final newer = HfRepositoryFiles(
        summary: repository.summary,
        revision: '1111111111111111111111111111111111111111',
        requestedRevision: 'main',
        source: endpoint,
        files: repository.files,
      );
      await downloader.downloadPackage(
        selection: selection,
        currentRepository: newer,
        libraryDirectory: root,
      );
      expect(downloader.state.status, DownloadStatus.failed);
      expect(requests, 1);
    },
  );

  test('a Safetensors folder package resolves its index tokenizer and head', () async {
    final root = await Directory.systemTemp.createTemp('jev-package-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = {
      'encoder/model.safetensors.index.json': '{"weight_map":{"layer.a":"alpha.safetensors","layer.b":"beta.safetensors"}}',
      'encoder/alpha.safetensors': 'abc',
      'encoder/beta.safetensors': 'def',
      'encoder/unused-quant.safetensors': 'unselected',
      'encoder/config.json': '{}',
      'encoder/tokenizer.json': '{}',
      'encoder/decision_head.npz': 'head',
      'other-model/model.safetensors': 'other',
      'other-model/config.json': '{}',
      'other-model/tokenizer.json': '{}',
    };
    final requested = <String>[];
    server.listen((request) async {
      final path = request.uri.pathSegments.skip(4).join('/');
      requested.add(path);
      request.response.add(utf8.encode(bodies[path]!));
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final downloader = ModelDownloader(hfEndpoint: endpoint);
    addTearDown(() async {
      downloader.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: endpoint,
      files: bodies.entries
          .map(
            (entry) => HfModelFile(
              path: entry.key,
              sizeBytes: utf8.encode(entry.value).length,
            ),
          )
          .toList(),
    );
    final packages = ModelPackage.discover(repository);
    expect(packages.map((package) => package.directory).toSet(), {
      'encoder',
      'other-model',
    });
    final package = packages.singleWhere(
      (package) => package.directory == 'encoder',
    );
    final variant = package.variants.single;
    expect(variant.format, 'Safetensors');
    expect(variant.canDownload, isTrue);
    expect(variant.resolution, PackageResolution.indexed);
    expect(variant.sizeBytes, isNull);
    await downloader.downloadPackage(
      selection: package.selectVariant(variant.id),
      currentRepository: repository,
      libraryDirectory: root,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    final expected = bodies.keys
        .where(
          (path) => path.startsWith('encoder/') && !path.contains('unused-'),
        )
        .toSet();
    expect(requested.toSet(), expected);
    final receipt = File(
      '${root.path}/.ghostmodeldeck/installations/${downloader.state.installationId}.json',
    );
    final savedReceipt = await receipt.readAsString();
    requested.clear();
    await downloader.downloadPackage(
      selection: package.selectVariant(variant.id),
      currentRepository: repository,
      libraryDirectory: root,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    expect(downloader.state.reusedExisting, isTrue);
    expect(requested, isEmpty);
    expect(await receipt.readAsString(), savedReceipt);
    final forged = jsonDecode(savedReceipt) as Map<String, dynamic>;
    (forged['files'] as List).removeLast();
    await receipt.writeAsString(jsonEncode(forged));
    await downloader.downloadPackage(
      selection: package.selectVariant(variant.id),
      currentRepository: repository,
      libraryDirectory: root,
    );
    expect(downloader.state.status, DownloadStatus.conflict);
    expect(requested, isEmpty);
    expect(
      jsonDecode(await receipt.readAsString())['files'],
      hasLength(expected.length - 1),
    );
    await receipt.writeAsString(savedReceipt);
    final existingShard = File(
      '${root.path}/publisher/model/encoder/alpha.safetensors',
    );
    await existingShard.writeAsString('xyz');
    await downloader.downloadPackage(
      selection: package.selectVariant(variant.id),
      currentRepository: repository,
      libraryDirectory: root,
    );
    expect(downloader.state.status, DownloadStatus.conflict);
    expect(requested, isEmpty);
    expect(await existingShard.readAsString(), 'xyz');
    await existingShard.writeAsString('abc');
    final changedRevision = HfRepositoryFiles(
      summary: repository.summary,
      revision: '1111111111111111111111111111111111111111',
      requestedRevision: 'main',
      source: endpoint,
      files: repository.files
          .map(
            (file) => file.path == 'encoder/alpha.safetensors'
                ? const HfModelFile(
                    path: 'encoder/alpha.safetensors',
                    sizeBytes: 3,
                    sha256: '3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282',
                  )
                : file,
          )
          .toList(),
    );
    final newerPackage = ModelPackage.discover(changedRevision)
        .singleWhere((model) => model.directory == 'encoder');
    await downloader.downloadPackage(
      selection: newerPackage.selectVariant(newerPackage.variants.single.id),
      currentRepository: changedRevision,
      libraryDirectory: root,
    );
    expect(downloader.state.status, DownloadStatus.conflict);
    expect(requested, isEmpty);
    expect(await existingShard.readAsString(), 'abc');
    expect(await receipt.readAsString(), savedReceipt);
    for (final path in expected) {
      expect(
        await File('${root.path}/publisher/model/$path').readAsString(),
        bodies[path],
      );
    }
    expect(
      await File(
        '${root.path}/publisher/model/encoder/unused-quant.safetensors',
      ).exists(),
      isFalse,
    );
    expect(
      await Directory('${root.path}/publisher/model/other-model').exists(),
      isFalse,
    );
  });

  test(
    'a model includes its sole projector and rejects ambiguous projectors',
    () {
      final repository = HfRepositoryFiles(
        summary: const HfRepositorySummary(
          id: 'lmstudio-community/Qwen3.5-0.8B-GGUF',
        ),
        revision: '26bab2c9369648924251c0ebb3dae012f5147707',
        requestedRevision: 'main',
        source: Uri.parse('https://huggingface.co'),
        files: const [
          HfModelFile(path: 'Qwen3.5-0.8B-Q4_K_M.gguf', sizeBytes: 527502816),
          HfModelFile(path: 'Qwen3.5-0.8B-Q6_K.gguf', sizeBytes: 629743584),
          HfModelFile(path: 'Qwen3.5-0.8B-Q8_0.gguf', sizeBytes: 811843040),
          HfModelFile(
            path: 'mmproj-Qwen3.5-0.8B-BF16.gguf',
            sizeBytes: 207345952,
          ),
          HfModelFile(path: 'README.md', sizeBytes: 2108),
        ],
      );
      final model = ModelPackage.discover(repository).single;
      expect(model.variants, hasLength(3));
      final q8 = model.variants.singleWhere(
        (variant) => variant.quantization == 'Q8_0',
      );
      expect(q8.canDownload, isTrue);
      expect(q8.sizeBytes, 1019188992);
      expect(q8.files.map((file) => file.path).toSet(), {
        'Qwen3.5-0.8B-Q8_0.gguf',
        'mmproj-Qwen3.5-0.8B-BF16.gguf',
      });
      final ambiguous = HfRepositoryFiles(
        summary: repository.summary,
        revision: repository.revision,
        requestedRevision: 'main',
        source: repository.source,
        files: [
          ...repository.files,
          const HfModelFile(path: 'mmproj-other-F16.gguf', sizeBytes: 100),
        ],
      );
      final unresolved = ModelPackage.discover(ambiguous).single;
      expect(unresolved.variants, hasLength(3));
      expect(
        unresolved.variants.every(
          (variant) =>
              variant.resolution == PackageResolution.ambiguous &&
              !variant.canDownload &&
              variant.sizeBytes == null,
        ),
        isTrue,
      );
      expect(
        unresolved.variants.first.unavailableReason,
        contains('projector'),
      );
      final projectorOnly = HfRepositoryFiles(
        summary: repository.summary,
        revision: repository.revision,
        requestedRevision: 'main',
        source: repository.source,
        files: [repository.files[3]],
      );
      expect(ModelPackage.discover(projectorOnly), isEmpty);
    },
  );
}
