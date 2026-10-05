import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_package.dart';

const _revision = '0123456789012345678901234567890123456789';
const _abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  test('closing an active package drains cancellation before returning and seals new downloads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'jev-download-close-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(utf8.encode('abc'));
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: endpoint,
      files: const [
        HfModelFile(path: 'model.gguf', sizeBytes: 3, sha256: _abcSha256),
      ],
    );
    final downloader = ModelDownloader(hfEndpoint: endpoint);
    final closingRequested = Completer<void>();
    Future<void>? closing;
    var transferFinished = false;
    final subscription = downloader.changes.listen((state) {
      if (state.status == DownloadStatus.downloading &&
          state.downloadedBytes == 3 &&
          !closingRequested.isCompleted) {
        scheduleMicrotask(() {
          closing = Future<void>.sync(downloader.close);
          closingRequested.complete();
        });
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await Future<void>.sync(downloader.close);
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final selection = ModelPackage.discover(repository).single
        .selectVariant('GGUF:model');
    final transfer = downloader
        .downloadPackage(
          selection: selection,
          currentRepository: repository,
          libraryDirectory: directory,
        )
        .whenComplete(() => transferFinished = true);
    await closingRequested.future.timeout(const Duration(seconds: 3));
    await closing!;
    expect(
      transferFinished,
      isTrue,
      reason: 'The shell can exit only after cancellation and file cleanup have settled',
    );
    await transfer;
    expect(
      await File('${directory.path}/publisher/model/model.gguf').exists(),
      isFalse,
    );
    await downloader.downloadPackage(
      selection: selection,
      currentRepository: repository,
      libraryDirectory: directory,
    );
    expect(
      await File('${directory.path}/publisher/model/model.gguf').exists(),
      isFalse,
    );
  });

  test(
    'installs only selected fixed-revision assets with exact lineage',
    () async {
      final directory = await Directory.systemTemp.createTemp('jev-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.set(HttpHeaders.etagHeader, '"chosen-abc"');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.add(utf8.encode('abc'));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });

      await downloader.download(
        repository: HfRepositoryFiles(
          summary: const HfRepositorySummary(id: 'publisher/model'),
          revision: _revision,
          requestedRevision: 'main',
          source: endpoint,
          files: const [
            HfModelFile(path: 'chosen.gguf', sizeBytes: 3, sha256: _abcSha256),
            HfModelFile(path: 'other-quantization.gguf', sizeBytes: 99),
          ],
        ),
        selectedFilePaths: {'chosen.gguf'},
        libraryDirectory: directory,
      );

      expect(downloader.state.status, DownloadStatus.installed);
      expect(
        await File('${directory.path}/publisher/model/chosen.gguf')
            .readAsString(),
        'abc',
      );
      expect(
        await File('${directory.path}/publisher/model/other-quantization.gguf')
            .exists(),
        isFalse,
      );
      expect(requests, ['/publisher/model/resolve/$_revision/chosen.gguf']);
      final records = await Directory(
        '${directory.path}/.ghostmodeldeck/installations',
      ).list().where((entry) => entry is File).toList();
      expect(records, hasLength(1));
      final record = jsonDecode(
        await (records.single as File).readAsString(),
      ) as Map<String, dynamic>;
      expect(record['repoId'], 'publisher/model');
      expect(record['revision'], _revision);
      expect(record['source'], 'hf');
      expect(record['files'], [
        {
          'path': 'publisher/model/chosen.gguf',
          'sizeBytes': 3,
          'sha256': _abcSha256,
          'upstreamSha256': _abcSha256,
          'gitBlobId': null,
          'isLfs': null,
          'upstreamVerified': true,
        },
      ]);
    },
  );

  test(
    'installs index-referenced weights and required sidecars only',
    () async {
      final directory = await Directory.systemTemp.createTemp('jev-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const index =
          '{"weight_map":{"a":"chunk-a.safetensors",'
          '"b":"chunk-b.safetensors"}}';
      final bodies = <String, String>{
        'model.safetensors.index.json': index,
        'chunk-a.safetensors': 'abc',
        'chunk-b.safetensors': 'def',
        'config.json': '{}',
        'tokenizer.json': '{}',
        'decision_head.safetensors': 'head',
        'other-quantization.gguf': 'unselected',
      };
      server.listen((request) async {
        final body = bodies[request.uri.pathSegments.last];
        request.response.add(utf8.encode(body!));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      await downloader.download(
        repository: HfRepositoryFiles(
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
        ),
        selectedFilePaths: {'model.safetensors.index.json'},
        libraryDirectory: directory,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      for (final path in bodies.keys.where(
        (path) => !path.startsWith('other-'),
      )) {
        expect(
          await File('${directory.path}/publisher/model/$path').readAsString(),
          bodies[path],
        );
      }
      expect(
        await File('${directory.path}/publisher/model/other-quantization.gguf')
            .exists(),
        isFalse,
      );
      final records = await Directory(
        '${directory.path}/.ghostmodeldeck/installations',
      ).list().where((entry) => entry is File).toList();
      final record = jsonDecode(
        await (records.single as File).readAsString(),
      ) as Map<String, dynamic>;
      expect(record['files'], hasLength(6));
      expect(
        (record['files'] as List).every(
          (file) => file['upstreamVerified'] == false,
        ),
        isTrue,
      );
    },
  );

  test('cancelled fragments resume after reopening only with matching Range', () async {
    final directory = await Directory.systemTemp.createTemp('jev-download-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releaseFirstResponse = Completer<void>();
    final firstResponseFlushed = Completer<void>();
    final fragmentReceived = Completer<void>();
    var requestNumber = 0;
    String? requestedRange;
    String? requestedValidator;
    server.listen((request) async {
      requestNumber++;
      request.response.headers.set(HttpHeaders.etagHeader, '"asset-v1"');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set('x-repo-commit', _revision);
      if (requestNumber == 1) {
        request.response.bufferOutput = false;
        request.response.contentLength = 6;
        request.response.add(utf8.encode('abc'));
        await request.response.flush();
        firstResponseFlushed.complete();
        await releaseFirstResponse.future;
        try {
          await request.response.close();
        } on IOException {
          // The client deliberately cancels before the remaining bytes arrive.
        }
      } else {
        requestedRange = request.headers.value(HttpHeaders.rangeHeader);
        requestedValidator = request.headers.value(HttpHeaders.ifRangeHeader);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 3-5/6',
        );
        request.response.contentLength = 3;
        request.response.add(utf8.encode('def'));
        await request.response.close();
      }
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    var downloader = ModelDownloader(hfEndpoint: endpoint);
    addTearDown(() async {
      if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
      downloader.close();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: endpoint,
      files: const [
        HfModelFile(
          path: 'model.gguf',
          sizeBytes: 6,
          sha256: 'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721',
        ),
      ],
    );
    final subscription = downloader.changes.listen((state) {
      if (state.status == DownloadStatus.downloading &&
          state.downloadedBytes == 3 &&
          !fragmentReceived.isCompleted) {
        fragmentReceived.complete();
      }
    });
    final transfer = downloader.download(
      repository: repository,
      selectedFilePaths: {'model.gguf'},
      libraryDirectory: directory,
    );
    await firstResponseFlushed.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('HTTP fixture did not flush'),
    );
    await fragmentReceived.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError(
        'No fragment progress: '
        '${downloader.state.status}/${downloader.state.downloadedBytes}',
      ),
    );
    downloader.cancel();
    await transfer.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('Cancellation did not complete'),
    );
    await subscription.cancel();
    expect(downloader.state.status, DownloadStatus.cancelled);
    expect(
      await File('${directory.path}/publisher/model/model.gguf').exists(),
      isFalse,
    );
    final fragments =
        await Directory('${directory.path}/.ghostmodeldeck/downloads')
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.part'))
            .toList();
    expect(await (fragments.single as File).readAsString(), 'abc');
    downloader.close();
    downloader = ModelDownloader(hfEndpoint: endpoint);
    await downloader.download(
      repository: repository,
      selectedFilePaths: {'model.gguf'},
      libraryDirectory: directory,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    expect(requestedRange, 'bytes=3-');
    expect(requestedValidator, '"asset-v1"');
    expect(
      await File('${directory.path}/publisher/model/model.gguf').readAsString(),
      'abcdef',
    );
  });

  test('checks Git blob identity before publishing an installation', () async {
    final directory = await Directory.systemTemp.createTemp('jev-download-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var body = 'xyz';
    server.listen((request) async {
      request.response.add(utf8.encode(body));
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final downloader = ModelDownloader(hfEndpoint: endpoint);
    addTearDown(() async {
      downloader.close();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    await Directory('${directory.path}/publisher/model')
        .create(recursive: true);
    final existing = File('${directory.path}/publisher/model/keep.gguf');
    await existing.writeAsString('foreign');
    final repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: endpoint,
      files: const [
        HfModelFile(
          path: 'model.gguf',
          sizeBytes: 3,
          blobId: 'f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f',
          isLfs: false,
        ),
      ],
    );
    await downloader.download(
      repository: repository,
      selectedFilePaths: {'model.gguf'},
      libraryDirectory: directory,
    );
    expect(downloader.state.status, DownloadStatus.failed);
    expect(
      await File('${directory.path}/publisher/model/model.gguf').exists(),
      isFalse,
    );
    expect(await existing.readAsString(), 'foreign');
    body = 'abc';
    await downloader.download(
      repository: repository,
      selectedFilePaths: {'model.gguf'},
      libraryDirectory: directory,
      restart: true,
    );
    expect(downloader.state.status, DownloadStatus.installed);
    final records = await Directory(
      '${directory.path}/.ghostmodeldeck/installations',
    ).list().where((entry) => entry is File).toList();
    final record = jsonDecode(
      await (records.single as File).readAsString(),
    ) as Map<String, dynamic>;
    expect(record['files'][0]['upstreamVerified'], isTrue);
    expect(
      record['files'][0]['gitBlobId'],
      'f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f',
    );
    expect(record['files'][0]['sha256'], _abcSha256);
  });

  test('colliding files directories and symlinks never get replaced', () async {
    final directory = await Directory.systemTemp.createTemp('jev-download-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(utf8.encode('abc'));
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    for (final kind in ['file', 'directory', 'symlink']) {
      final library = Directory('${directory.path}/$kind');
      final parent = Directory('${library.path}/publisher/model');
      await parent.create(recursive: true);
      final collision = '${parent.path}/z.gguf';
      final preserved = kind == 'directory'
          ? File('$collision/keep')
          : kind == 'symlink'
          ? File('${library.path}/symlink-target')
          : File(collision);
      if (kind == 'directory') await Directory(collision).create();
      await preserved.writeAsString('foreign');
      if (kind == 'symlink') await Link(collision).create(preserved.path);
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      await downloader.download(
        repository: HfRepositoryFiles(
          summary: const HfRepositorySummary(id: 'publisher/model'),
          revision: _revision,
          requestedRevision: 'main',
          source: endpoint,
          files: const [
            HfModelFile(path: 'a.gguf', sizeBytes: 3, sha256: _abcSha256),
            HfModelFile(path: 'z.gguf', sizeBytes: 3, sha256: _abcSha256),
          ],
        ),
        selectedFilePaths: {'a.gguf', 'z.gguf'},
        libraryDirectory: library,
      );
      expect(downloader.state.status, DownloadStatus.conflict, reason: kind);
      expect(await preserved.readAsString(), 'foreign', reason: kind);
      expect(
        await File('${parent.path}/a.gguf').exists(),
        isFalse,
        reason: kind,
      );
      if (kind == 'directory') {
        expect(await Directory(collision).list().length, 1);
      }
      if (kind == 'symlink') {
        expect(await Link(collision).target(), preserved.path);
      }
      expect(
        await Directory('${library.path}/.ghostmodeldeck/installations')
            .exists(),
        isFalse,
        reason: kind,
      );
      downloader.close();
    }
  });

  test(
    'adds a quantization by reusing an identical shared companion',
    () async {
      final directory = await Directory.systemTemp.createTemp('jev-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add(
          utf8.encode(
            request.uri.pathSegments.last == 'config.json' ? '{}' : 'abc',
          ),
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      final parent = Directory('${directory.path}/publisher/model');
      await parent.create(recursive: true);
      final config = File('${parent.path}/config.json');
      await config.writeAsString('{}');
      final originalModified = (await config.stat()).modified;
      final previousWeight = File('${parent.path}/old-Q8.gguf');
      await previousWeight.writeAsString('foreign');
      await downloader.download(
        repository: HfRepositoryFiles(
          summary: const HfRepositorySummary(id: 'publisher/model'),
          revision: _revision,
          requestedRevision: 'main',
          source: endpoint,
          files: const [
            HfModelFile(path: 'new-Q4.gguf', sizeBytes: 3, sha256: _abcSha256),
            HfModelFile(path: 'config.json', sizeBytes: 2),
            HfModelFile(path: 'old-Q8.gguf', sizeBytes: 99),
          ],
        ),
        selectedFilePaths: {'new-Q4.gguf'},
        libraryDirectory: directory,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      expect(await File('${parent.path}/new-Q4.gguf').readAsString(), 'abc');
      expect(await config.readAsString(), '{}');
      expect((await config.stat()).modified, originalModified);
      expect(await previousWeight.readAsString(), 'foreign');
    },
  );

  test(
    'LFS pointer or unknown blob IDs do not verify payload provenance',
    () async {
      final directory = await Directory.systemTemp.createTemp('jev-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add(utf8.encode('xyz'));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      addTearDown(() async {
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      for (final isLfs in <bool?>[true, null]) {
        final library = Directory('${directory.path}/$isLfs');
        final downloader = ModelDownloader(hfEndpoint: endpoint);
        await downloader.download(
          repository: HfRepositoryFiles(
            summary: const HfRepositorySummary(id: 'publisher/model'),
            revision: _revision,
            requestedRevision: 'main',
            source: endpoint,
            files: [
              HfModelFile(
                path: 'model.gguf',
                sizeBytes: 3,
                blobId: 'f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f',
                isLfs: isLfs,
              ),
            ],
          ),
          selectedFilePaths: {'model.gguf'},
          libraryDirectory: library,
        );
        expect(downloader.state.status, DownloadStatus.installed);
        final records = await Directory(
          '${library.path}/.ghostmodeldeck/installations',
        ).list().where((entry) => entry is File).toList();
        final record = jsonDecode(
          await (records.single as File).readAsString(),
        ) as Map<String, dynamic>;
        expect(record['files'][0]['upstreamVerified'], isFalse);
        expect(record['files'][0]['isLfs'], isLfs);
        expect(
          await File('${library.path}/publisher/model/model.gguf')
              .readAsString(),
          'xyz',
        );
        downloader.close();
      }
    },
  );

  test(
    'resume rejection preserves fragments and existing shared assets',
    () async {
      for (final mode in [
        'etag',
        'range',
        'offset',
        'commit',
        'validator',
        'source',
        'hash',
      ]) {
        final fixture = await _PartialFixture.create(
          initialEtag: mode == 'validator' ? null : '"asset-v1"',
          onRetry: (request) {
            switch (mode) {
              case 'etag':
                request.response.headers.set(
                  HttpHeaders.etagHeader,
                  '"asset-v2"',
                );
                break;
              case 'range':
                request.response.statusCode = HttpStatus.ok;
                request.response.headers.removeAll(
                  HttpHeaders.contentRangeHeader,
                );
                break;
              case 'offset':
                request.response.headers.set(
                  HttpHeaders.contentRangeHeader,
                  'bytes 2-4/6',
                );
                break;
              case 'commit':
                request.response.headers.set(
                  'x-repo-commit',
                  '1111111111111111111111111111111111111111',
                );
                break;
            }
          },
        );
        addTearDown(fixture.dispose);
        await fixture.cancelFirstTransfer();
        final fragment = (await fixture.fragments()).single;
        expect(await fragment.readAsString(), 'abc', reason: mode);
        final repository = mode == 'hash'
            ? HfRepositoryFiles(
                summary: fixture.repository.summary,
                revision: _revision,
                requestedRevision: 'main',
                source: fixture.endpoint,
                files: [
                  HfModelFile(
                    path: 'model.gguf',
                    sizeBytes: 6,
                    sha256: '0000000000000000000000000000000000000000000000000000000000000000',
                    isLfs: true,
                  ),
                ],
              )
            : fixture.repository;
        await fixture.downloader.download(
          repository: repository,
          selectedFilePaths: {'model.gguf'},
          libraryDirectory: fixture.directory,
          source: mode == 'source'
              ? DownloadSource.lmStudio
              : DownloadSource.hf,
        );
        expect(
          fixture.downloader.state.status,
          DownloadStatus.restartRequired,
          reason: mode,
        );
        expect(await fragment.readAsString(), 'abc', reason: mode);
        expect(await fixture.existing.readAsString(), 'foreign', reason: mode);
        expect(
          await File('${fixture.directory.path}/publisher/model/model.gguf')
              .exists(),
          isFalse,
          reason: mode,
        );
        expect(
          fixture.requests,
          ['validator', 'source', 'hash'].contains(mode) ? 1 : 2,
          reason: mode,
        );
      }
    },
  );

  test(
    'a fully received cancelled payload is verified from cache at EOF',
    () async {
      final fixture = await _PartialFixture.create(initialBytes: 'abcdef');
      addTearDown(fixture.dispose);
      await fixture.cancelFirstTransfer();
      expect(await (await fixture.fragments()).single.readAsString(), 'abcdef');
      await fixture.downloader.download(
        repository: fixture.repository,
        selectedFilePaths: {'model.gguf'},
        libraryDirectory: fixture.directory,
      );
      expect(fixture.downloader.state.status, DownloadStatus.installed);
      expect(fixture.requests, 1);
      expect(
        await File('${fixture.directory.path}/publisher/model/model.gguf')
            .readAsString(),
        'abcdef',
      );
      expect(await fixture.existing.readAsString(), 'foreign');
    },
  );

  test(
    'arbitrary non-weight selections do not pull unrelated model sidecars',
    () async {
      final directory = await Directory.systemTemp.createTemp('jev-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = {
        'README.md': 'docs',
        'notes.index.json': '{"sections":[]}',
        'config.json': '{}',
        'tokenizer.json': 'unselected tokenizer',
        'other.gguf': 'unselected quantization',
      };
      final requested = <String>[];
      server.listen((request) async {
        final name = request.uri.pathSegments.last;
        requested.add(name);
        request.response.add(utf8.encode(bodies[name]!));
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final downloader = ModelDownloader(hfEndpoint: endpoint);
      addTearDown(() async {
        downloader.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      await downloader.download(
        repository: HfRepositoryFiles(
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
        ),
        selectedFilePaths: {'README.md', 'notes.index.json'},
        libraryDirectory: directory,
      );
      expect(downloader.state.status, DownloadStatus.installed);
      expect(requested.toSet(), {'README.md', 'notes.index.json'});
      for (final path in ['README.md', 'notes.index.json']) {
        expect(
          await File('${directory.path}/publisher/model/$path').readAsString(),
          bodies[path],
        );
      }
      for (final path in ['config.json', 'tokenizer.json', 'other.gguf']) {
        expect(
          await File('${directory.path}/publisher/model/$path').exists(),
          isFalse,
        );
      }
    },
  );

  test(
    'a transient resume HTTP failure retains progress and can retry',
    () async {
      late _PartialFixture fixture;
      fixture = await _PartialFixture.create(
        onRetry: (request) {
          if (fixture.requests == 2) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            request.response.headers.removeAll(HttpHeaders.etagHeader);
            request.response.headers.removeAll(HttpHeaders.contentRangeHeader);
          }
        },
      );
      addTearDown(fixture.dispose);
      await fixture.cancelFirstTransfer();
      final fragment = (await fixture.fragments()).single;
      await fixture.downloader.download(
        repository: fixture.repository,
        selectedFilePaths: {'model.gguf'},
        libraryDirectory: fixture.directory,
      );
      expect(fixture.downloader.state.status, DownloadStatus.failed);
      expect(fixture.downloader.state.error, contains('503'));
      expect(fixture.downloader.state.downloadedBytes, 3);
      expect(await fragment.readAsString(), 'abc');
      expect(await fixture.existing.readAsString(), 'foreign');
      await fixture.downloader.download(
        repository: fixture.repository,
        selectedFilePaths: {'model.gguf'},
        libraryDirectory: fixture.directory,
      );
      expect(fixture.downloader.state.status, DownloadStatus.installed);
      expect(fixture.requests, 3);
      expect(
        await File('${fixture.directory.path}/publisher/model/model.gguf')
            .readAsString(),
        'abcdef',
      );
      expect(await fixture.existing.readAsString(), 'foreign');
    },
  );
}

class _PartialFixture {
  _PartialFixture._(this.directory, this.server, this.endpoint);

  final Directory directory;
  final HttpServer server;
  final Uri endpoint;
  final _release = Completer<void>();
  late final ModelDownloader downloader;
  late final HfRepositoryFiles repository;
  late final String initialBytes;
  int requests = 0;

  File get existing => File('${directory.path}/publisher/model/keep.gguf');

  static Future<_PartialFixture> create({
    String initialBytes = 'abc',
    String? initialEtag = '"asset-v1"',
    void Function(HttpRequest)? onRetry,
  }) async {
    final directory = await Directory.systemTemp.createTemp('jev-download-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final fixture = _PartialFixture._(directory, server, endpoint);
    fixture.initialBytes = initialBytes;
    fixture.downloader = ModelDownloader(
      hfEndpoint: endpoint,
      lmStudioEndpoint: endpoint.replace(path: '/v1/hf-proxy/'),
    );
    fixture.repository = HfRepositoryFiles(
      summary: const HfRepositorySummary(id: 'publisher/model'),
      revision: _revision,
      requestedRevision: 'main',
      source: endpoint,
      files: const [
        HfModelFile(
          path: 'model.gguf',
          sizeBytes: 6,
          isLfs: true,
          sha256: 'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721',
        ),
      ],
    );
    await fixture.existing.parent.create(recursive: true);
    await fixture.existing.writeAsString('foreign');
    server.listen((request) async {
      fixture.requests++;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set('x-repo-commit', _revision);
      if (fixture.requests == 1) {
        if (initialEtag != null) {
          request.response.headers.set(HttpHeaders.etagHeader, initialEtag);
        }
        request.response.bufferOutput = false;
        request.response.contentLength = 6;
        request.response.add(utf8.encode(initialBytes));
        await request.response.flush();
        await fixture._release.future;
      } else {
        request.response.headers.set(HttpHeaders.etagHeader, '"asset-v1"');
        if (initialBytes.length == 6) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */6',
          );
          request.response.contentLength = 0;
        } else {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 3-5/6',
          );
          onRetry?.call(request);
          final body = request.response.statusCode == HttpStatus.ok
              ? 'abcdef'
              : 'def';
          request.response.contentLength = body.length;
          request.response.add(utf8.encode(body));
        }
      }
      try {
        await request.response.close();
      } on IOException {
        // The downloader can reject a response before its body is consumed.
      }
    });
    return fixture;
  }

  Future<void> cancelFirstTransfer() async {
    final received = Completer<void>();
    final subscription = downloader.changes.listen((state) {
      if (state.status == DownloadStatus.downloading &&
          state.downloadedBytes == initialBytes.length &&
          !received.isCompleted) {
        downloader.cancel();
        received.complete();
      }
    });
    final transfer = downloader.download(
      repository: repository,
      selectedFilePaths: {'model.gguf'},
      libraryDirectory: directory,
    );
    await received.future.timeout(const Duration(seconds: 5));
    await transfer.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    expect(downloader.state.status, DownloadStatus.cancelled);
  }

  Future<List<File>> fragments() async =>
      (await Directory('${directory.path}/.ghostmodeldeck/downloads')
              .list(recursive: true)
              .where((entry) => entry.path.endsWith('.part'))
              .toList())
          .cast<File>();

  Future<void> dispose() async {
    if (!_release.isCompleted) _release.complete();
    downloader.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}
