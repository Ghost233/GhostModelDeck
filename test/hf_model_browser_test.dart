import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/model_package.dart';

import 'fixtures/mlx_package.dart';

void main() {
  test('native quantization comes from fixed config bytes not the repository name', () async {
    const revision = 'a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3';
    final bodies = mlxPackageBytes();
    final requests = <String>[];
    var config = await File('test/fixtures/hf_mlx_qwen2_config_a5339a4.json')
        .readAsString();
    expect(utf8.encode(config), hasLength(783));
    expect(
      sha256.convert(utf8.encode(config)).toString(),
      'b045e57ea90b8f1b35f89f954b176a5c1faa02bd0af2c89bcec191239d66cef4',
    );
    var wrongBlob = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.startsWith('/api/')) {
        request.response.write(
          jsonEncode({
            'id': 'publisher/4bit-mlx-name-is-not-evidence',
            'sha': revision,
            'siblings': [
              for (final entry in bodies.entries)
                {
                  'rfilename': entry.key,
                  if (entry.key == 'config.json')
                    'blobId': wrongBlob
                        ? '0000000000000000000000000000000000000000'
                        : sha1.convert([
                            ...utf8.encode(
                              'blob ${utf8.encode(config).length}\u0000',
                            ),
                            ...utf8.encode(config),
                          ]).toString(),
                  'size': entry.key == 'config.json'
                      ? utf8.encode(config).length
                      : entry.value.length,
                },
            ],
          }),
        );
      } else {
        request.response.write(config);
      }
      await request.response.close();
    });
    final browser = HfModelBrowser(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(() async {
      browser.close();
      await server.close(force: true);
    });
    await browser.selectRepository('publisher/4bit-mlx-name-is-not-evidence');
    final variant = ModelPackage.discover(browser.state.repository!)
        .single
        .variants
        .single;
    expect(variant.format, 'Safetensors');
    expect(variant.quantization, '4bit · group 64');
    expect(
      requests.last,
      '/publisher/4bit-mlx-name-is-not-evidence/resolve/$revision/config.json',
    );
    wrongBlob = true;
    await browser.selectRepository('publisher/4bit-mlx-name-is-not-evidence');
    expect(
      ModelPackage.discover(browser.state.repository!)
          .single
          .variants
          .single
          .quantization,
      isNull,
    );
    wrongBlob = false;
    config =
        '{"model_type":"qwen2","quantization":{"bits":"4","group_size":64}}';
    await browser.selectRepository('publisher/4bit-mlx-name-is-not-evidence');
    expect(
      ModelPackage.discover(browser.state.repository!)
          .single
          .variants
          .single
          .quantization,
      isNull,
    );
    config = '{"model_type":"qwen2"}';
    await browser.selectRepository('publisher/4bit-mlx-name-is-not-evidence');
    expect(
      ModelPackage.discover(browser.state.repository!)
          .single
          .variants
          .single
          .quantization,
      isNull,
    );
  });
  test('keyword search exposes repositories returned by HF', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Uri>[];
    server.listen((request) async {
      requests.add(request.uri);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode([
          {
            'id': 'independent-author/unlisted-model',
            'pipeline_tag': 'text-classification',
            'downloads': 37,
            'tags': ['license:apache-2.0'],
          },
        ]),
      );
      await request.response.close();
    });
    final browser = HfModelBrowser(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(() async {
      browser.close();
      await server.close(force: true);
    });

    await browser.search('unlisted model');

    expect(browser.state.searchStatus, RequestStatus.ready);
    expect(
      browser.state.repositories.single.id,
      'independent-author/unlisted-model',
    );
    expect(browser.state.repositories.single.task, 'text-classification');
    expect(browser.state.repositories.single.downloads, 37);
    expect(browser.state.repositories.single.license, 'apache-2.0');
    expect(requests.single.path, '/api/models');
    expect(requests.single.queryParameters['search'], 'unlisted model');
  });

  test(
    'repository selection keeps fixed revision and selected asset files',
    () async {
      final fixture = await _browserFor({
        'id': 'research/choice-assets',
        'sha': '1234567890abcdef1234567890abcdef12345678',
        'cardData': {'license': 'mit'},
        'siblings': [
          {
            'rfilename': 'weights/model-Q4_K_M.gguf',
            'size': 1048576,
            'blobId': 'git-blob-id',
            'lfs': {
              'sha256': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
              'size': 1048576,
            },
          },
          {'rfilename': 'tokenizer.json', 'size': 512},
          {'rfilename': 'head.customweight'},
        ],
      });
      final browser = fixture.browser;

      await browser.selectRepository(
        'research/choice-assets',
        revision: 'release/v1',
      );
      browser.setFileSelected('weights/model-Q4_K_M.gguf', true);
      browser.setFileSelected('tokenizer.json', true);

      expect(browser.state.repositoryStatus, RequestStatus.ready);
      expect(
        browser.state.repository!.revision,
        '1234567890abcdef1234567890abcdef12345678',
      );
      expect(browser.state.repository!.requestedRevision, 'release/v1');
      expect(browser.state.repository!.source.host, '127.0.0.1');
      expect(browser.state.repository!.summary.license, 'mit');
      final weight = browser.state.repository!.files.first;
      expect(weight.path, 'weights/model-Q4_K_M.gguf');
      expect(weight.format, 'GGUF');
      expect(weight.sizeBytes, 1048576);
      expect(weight.blobId, 'git-blob-id');
      expect(
        weight.sha256,
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
      );
      expect(browser.state.repository!.files.last.sizeBytes, isNull);
      expect(browser.state.selectedFiles.map((file) => file.path), [
        'weights/model-Q4_K_M.gguf',
        'tokenizer.json',
      ]);
      expect(browser.state.selectedBytes, 1049088);
      expect(fixture.requests.single.pathSegments.last, 'release/v1');
      expect(fixture.requests.single.queryParameters['blobs'], 'true');
      browser.setFileSelected('head.customweight', true);
      expect(browser.state.selectedBytes, isNull);
    },
  );

  test(
    'repository input opens its actual files without a keyword candidate list',
    () async {
      final fixture = await _browserFor({
        'id': 'independent-author/new-model',
        'sha': 'abcdef1234567890abcdef1234567890abcdef12',
        'siblings': [
          {'rfilename': 'model.safetensors', 'size': 2048},
        ],
      });

      await fixture.browser.search('independent-author/new-model');
      expect(
        fixture.browser.state.repository!.summary.id,
        'independent-author/new-model',
      );
      await fixture.browser.search(
        'https://huggingface.co/independent-author/new-model',
      );

      expect(fixture.browser.state.searchStatus, RequestStatus.ready);
      expect(
        fixture.browser.state.repositories.single.id,
        'independent-author/new-model',
      );
      expect(
        fixture.browser.state.repository!.files.single.format,
        'Safetensors',
      );
      expect(fixture.browser.state.repository!.summary.license, isNull);
      expect(fixture.requests.last.pathSegments, [
        'api',
        'models',
        'independent-author',
        'new-model',
        'revision',
        'main',
      ]);
      expect(
        fixture.requests.every(
          (uri) => !uri.queryParameters.containsKey('search'),
        ),
        isTrue,
      );
    },
  );

  test('an empty HF search reports no results', () async {
    final fixture = await _browserFor([]);

    await fixture.browser.search('no matching decision model');

    expect(fixture.browser.state.searchStatus, RequestStatus.empty);
    expect(fixture.browser.state.repositories, isEmpty);
    expect(fixture.browser.state.repository, isNull);
  });

  test(
    'failed HF requests do not invent repositories or selected files',
    () async {
      final fixture = await _browserFor({
        'error': 'Unavailable',
      }, statusCode: 503);

      await fixture.browser.search('arbitrary model');

      expect(fixture.browser.state.searchStatus, RequestStatus.failed);
      expect(fixture.browser.state.searchError, 'HF 请求失败 (503)');
      expect(fixture.browser.state.repositories, isEmpty);
      expect(fixture.browser.state.selectedFiles, isEmpty);
    },
  );

  test('a real repository with no files has an empty file status', () async {
    final fixture = await _browserFor({
      'id': 'research/empty-assets',
      'sha': '1234567890abcdef1234567890abcdef12345678',
      'siblings': [],
    });

    await fixture.browser.search('research/empty-assets');

    expect(fixture.browser.state.searchStatus, RequestStatus.ready);
    expect(fixture.browser.state.repositoryStatus, RequestStatus.empty);
    expect(fixture.browser.state.repository!.files, isEmpty);
    expect(fixture.browser.state.selectedFiles, isEmpty);
  });

  test(
    'metadata without a fixed commit cannot become an asset selection',
    () async {
      final fixture = await _browserFor({
        'id': 'research/unpinned-assets',
        'sha': 'main',
        'siblings': [
          {'rfilename': 'model.gguf', 'size': 256},
        ],
      });

      await fixture.browser.search('research/unpinned-assets');

      expect(fixture.browser.state.searchStatus, RequestStatus.failed);
      expect(fixture.browser.state.repositoryStatus, RequestStatus.failed);
      expect(fixture.browser.state.repositoryError, 'HF 数据格式异常');
      expect(fixture.browser.state.repository, isNull);
      expect(fixture.browser.state.selectedFiles, isEmpty);
    },
  );

  test(
    'changing revision clears file choices from the previous asset',
    () async {
      final fixture = await _browserFor(
        (Uri uri) => {
          'id': 'research/versioned-assets',
          'sha': uri.pathSegments.last == 'v1'
              ? '1234567890abcdef1234567890abcdef12345678'
              : 'abcdef1234567890abcdef1234567890abcdef12',
          'siblings': [
            {
              'rfilename': uri.pathSegments.last == 'v1'
                  ? 'old-Q4.gguf'
                  : 'new-Q8.gguf',
              'size': 512,
            },
          ],
        },
      );
      final browser = fixture.browser;
      await browser.selectRepository(
        'research/versioned-assets',
        revision: 'v1',
      );
      browser.setFileSelected('old-Q4.gguf', true);
      final previous = browser.state;

      await browser.selectRepository(
        'research/versioned-assets',
        revision: 'v2',
      );

      expect(
        browser.state.repository!.revision,
        'abcdef1234567890abcdef1234567890abcdef12',
      );
      expect(browser.state.repository!.files.single.path, 'new-Q8.gguf');
      expect(browser.state.selectedFiles, isEmpty);
      expect(previous.selectedFiles.single.path, 'old-Q4.gguf');
      expect(
        () => browser.setFileSelected('old-Q4.gguf', true),
        throwsArgumentError,
      );
      expect(browser.state.selectedFiles, isEmpty);
    },
  );

  test(
    'a failed search can be retried through the same application entry',
    () async {
      var attempts = 0;
      final fixture = await _browserWithHandler((request) async {
        if (attempts++ == 0) {
          await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
        } else {
          await _reply(request, [
            {'id': 'another-author/recovered-model'},
          ]);
        }
      });
      await fixture.browser.search('recoverable query');
      expect(fixture.browser.state.searchStatus, RequestStatus.failed);

      await fixture.browser.search('recoverable query');

      expect(fixture.browser.state.searchStatus, RequestStatus.ready);
      expect(fixture.browser.state.searchError, isNull);
      expect(
        fixture.browser.state.repositories.single.id,
        'another-author/recovered-model',
      );
    },
  );

  test('an older search response cannot replace the current query', () async {
    final firstArrived = Completer<void>();
    final releaseFirst = Completer<void>();
    addTearDown(() {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
    });
    final fixture = await _browserWithHandler((request) async {
      final older = request.uri.queryParameters['search'] == 'older query';
      if (older) {
        firstArrived.complete();
        await releaseFirst.future;
      }
      await _reply(request, [
        {'id': older ? 'author/older-result' : 'author/current-result'},
      ]);
    });
    final olderRequest = fixture.browser.search('older query');
    await firstArrived.future;

    await fixture.browser.search('current query');
    releaseFirst.complete();
    await olderRequest;

    expect(fixture.browser.state.query, 'current query');
    expect(
      fixture.browser.state.repositories.single.id,
      'author/current-result',
    );
    expect(fixture.browser.state.searchStatus, RequestStatus.ready);
  });

  test(
    'an older revision response cannot replace current files or choices',
    () async {
      final firstArrived = Completer<void>();
      final releaseFirst = Completer<void>();
      addTearDown(() {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
      });
      final fixture = await _browserWithHandler((request) async {
        final older = request.uri.pathSegments.last == 'older';
        if (older) {
          firstArrived.complete();
          await releaseFirst.future;
        }
        await _reply(request, {
          'id': 'author/changing-revisions',
          'sha': older
              ? '1234567890abcdef1234567890abcdef12345678'
              : 'abcdef1234567890abcdef1234567890abcdef12',
          'siblings': [
            {'rfilename': older ? 'old.gguf' : 'current.gguf', 'size': 1024},
          ],
        });
      });
      final browser = fixture.browser;
      final olderRequest = browser.selectRepository(
        'author/changing-revisions',
        revision: 'older',
      );
      await firstArrived.future;

      await browser.selectRepository(
        'author/changing-revisions',
        revision: 'current',
      );
      browser.setFileSelected('current.gguf', true);
      releaseFirst.complete();
      await olderRequest;

      expect(
        browser.state.repository!.revision,
        'abcdef1234567890abcdef1234567890abcdef12',
      );
      expect(browser.state.repository!.requestedRevision, 'current');
      expect(browser.state.repository!.files.single.path, 'current.gguf');
      expect(browser.state.selectedFiles.single.path, 'current.gguf');
    },
  );

  test(
    'reopening offline reads fixed cached metadata with an explicit origin',
    () async {
      final cache = await Directory.systemTemp.createTemp('jev-hf-metadata-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      var offline = false;
      server.listen((request) async {
        if (offline) {
          await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
        } else {
          await _reply(request, {
            'id': 'author/cached-assets',
            'sha': '1234567890abcdef1234567890abcdef12345678',
            'pipeline_tag': 'text-classification',
            'cardData': {'license': 'apache-2.0'},
            'siblings': [
              {
                'rfilename': 'model.gguf',
                'size': 4096,
                'blobId': 'cache-git-blob',
                'lfs': {
                  'sha256': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
                },
              },
            ],
          });
        }
      });
      final online = HfModelBrowser(endpoint: endpoint, cacheDirectory: cache);
      addTearDown(() async {
        online.close();
        await server.close(force: true);
        await cache.delete(recursive: true);
      });
      await online.search('author/cached-assets');
      expect(online.state.repositoryOrigin, MetadataOrigin.online);
      online.close();
      offline = true;
      final reopened = HfModelBrowser(
        endpoint: endpoint,
        cacheDirectory: cache,
      );
      addTearDown(reopened.close);

      await reopened.selectRepository('author/cached-assets');

      expect(reopened.state.repositoryStatus, RequestStatus.ready);
      expect(reopened.state.repositoryOrigin, MetadataOrigin.cache);
      expect(reopened.state.repositoryError, 'HF 请求失败 (503)');
      final cached = reopened.state.repository!;
      expect(cached.revision, '1234567890abcdef1234567890abcdef12345678');
      expect(cached.source, endpoint);
      expect(cached.summary.license, 'apache-2.0');
      expect(cached.summary.task, 'text-classification');
      expect(cached.files.single.path, 'model.gguf');
      expect(cached.files.single.format, 'GGUF');
      expect(cached.files.single.sizeBytes, 4096);
      expect(cached.files.single.blobId, 'cache-git-blob');
      expect(
        cached.files.single.sha256,
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
      );
      reopened.setFileSelected('model.gguf', true);
      expect(reopened.state.repositoryOrigin, MetadataOrigin.cache);
      expect(reopened.state.repositoryError, 'HF 请求失败 (503)');

      await reopened.search('author/cached-assets');
      expect(reopened.state.searchOrigin, MetadataOrigin.cache);
      expect(reopened.state.repositoryOrigin, MetadataOrigin.cache);
      expect(reopened.state.repositories.single.id, 'author/cached-assets');
    },
  );

  test(
    'cached keyword results remain distinguishable from an online search',
    () async {
      final cache = await Directory.systemTemp.createTemp('jev-hf-keywords-');
      addTearDown(() => cache.delete(recursive: true));
      var offline = false;
      final fixture = await _browserWithHandler((request) async {
        if (offline) {
          await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
        } else {
          await _reply(request, [
            {
              'id': 'author/keyword-result',
              'downloads': 21,
              'pipeline_tag': 'text-classification',
              'tags': ['license:mit'],
            },
          ]);
        }
      }, cacheDirectory: cache);
      await fixture.browser.search('offline keyword');
      expect(fixture.browser.state.searchOrigin, MetadataOrigin.online);
      fixture.browser.close();
      offline = true;
      final reopened = HfModelBrowser(
        endpoint: fixture.endpoint,
        cacheDirectory: cache,
      );
      addTearDown(reopened.close);

      await reopened.search('offline keyword');

      expect(reopened.state.searchStatus, RequestStatus.ready);
      expect(reopened.state.searchOrigin, MetadataOrigin.cache);
      expect(reopened.state.searchError, 'HF 请求失败 (503)');
      expect(reopened.state.repositories.single.id, 'author/keyword-result');
      expect(reopened.state.repositories.single.downloads, 21);
      expect(reopened.state.repositories.single.task, 'text-classification');
      expect(reopened.state.repositories.single.license, 'mit');
    },
  );

  test('offline selection can read the cached fixed commit directly', () async {
    final cache = await Directory.systemTemp.createTemp('jev-hf-fixed-');
    addTearDown(() => cache.delete(recursive: true));
    var offline = false;
    final fixture = await _browserWithHandler((request) async {
      if (offline) {
        await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
      } else {
        await _reply(request, {
          'id': 'author/pinned-assets',
          'sha': '1234567890abcdef1234567890abcdef12345678',
          'siblings': [
            {'rfilename': 'model.gguf', 'size': 256},
          ],
        });
      }
    }, cacheDirectory: cache);
    await fixture.browser.selectRepository('author/pinned-assets');
    fixture.browser.close();
    offline = true;
    final reopened = HfModelBrowser(
      endpoint: fixture.endpoint,
      cacheDirectory: cache,
    );
    addTearDown(reopened.close);

    await reopened.selectRepository(
      'author/pinned-assets',
      revision: '1234567890abcdef1234567890abcdef12345678',
    );

    expect(reopened.state.repositoryOrigin, MetadataOrigin.cache);
    expect(
      reopened.state.repository!.requestedRevision,
      '1234567890abcdef1234567890abcdef12345678',
    );
    expect(
      reopened.state.repository!.revision,
      '1234567890abcdef1234567890abcdef12345678',
    );
    expect(reopened.state.repository!.files.single.path, 'model.gguf');
    expect(reopened.state.repository!.source, fixture.endpoint);
  });

  test('corrupt cached files cannot become offline metadata', () async {
    final cache = await Directory.systemTemp.createTemp('jev-hf-corrupt-');
    addTearDown(() => cache.delete(recursive: true));
    var offline = false;
    final fixture = await _browserWithHandler((request) async {
      if (offline) {
        await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
      } else {
        await _reply(request, {
          'id': 'author/corrupted-assets',
          'sha': '1234567890abcdef1234567890abcdef12345678',
          'siblings': [
            {'rfilename': 'model.gguf', 'size': 256},
          ],
        });
      }
    }, cacheDirectory: cache);
    await fixture.browser.selectRepository('author/corrupted-assets');
    fixture.browser.close();
    final files = await cache
        .list(recursive: true)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      await file.writeAsString('not valid metadata');
    }
    offline = true;
    final reopened = HfModelBrowser(
      endpoint: fixture.endpoint,
      cacheDirectory: cache,
    );
    addTearDown(reopened.close);

    await reopened.selectRepository('author/corrupted-assets');

    expect(reopened.state.repositoryStatus, RequestStatus.failed);
    expect(reopened.state.repositoryOrigin, isNull);
    expect(reopened.state.repositoryError, 'HF 请求失败 (503)');
    expect(reopened.state.repository, isNull);
  });

  test(
    'private repository metadata is not retained for offline reads',
    () async {
      final cache = await Directory.systemTemp.createTemp('jev-hf-private-');
      addTearDown(() => cache.delete(recursive: true));
      var offline = false;
      final fixture = await _browserWithHandler((request) async {
        if (offline) {
          await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
        } else {
          await _reply(request, {
            'id': 'author/private-assets',
            'private': true,
            'sha': '1234567890abcdef1234567890abcdef12345678',
            'siblings': [
              {'rfilename': 'model.gguf', 'size': 256},
            ],
          });
        }
      }, cacheDirectory: cache);
      await fixture.browser.selectRepository('author/private-assets');
      expect(fixture.browser.state.repositoryOrigin, MetadataOrigin.online);
      expect(await cache.list().toList(), isEmpty);
      fixture.browser.close();
      offline = true;
      final reopened = HfModelBrowser(
        endpoint: fixture.endpoint,
        cacheDirectory: cache,
      );
      addTearDown(reopened.close);

      await reopened.selectRepository('author/private-assets');

      expect(reopened.state.repositoryStatus, RequestStatus.failed);
      expect(reopened.state.repositoryOrigin, isNull);
      expect(reopened.state.repository, isNull);
    },
  );

  test('cached metadata is scoped to its actual HF endpoint', () async {
    final cache = await Directory.systemTemp.createTemp('jev-hf-source-');
    addTearDown(() => cache.delete(recursive: true));
    final source = await _browserFor({
      'id': 'author/source-assets',
      'sha': '1234567890abcdef1234567890abcdef12345678',
      'siblings': [
        {'rfilename': 'model.gguf', 'size': 256},
      ],
    }, cacheDirectory: cache);
    await source.browser.selectRepository('author/source-assets');
    source.browser.close();
    final differentSource = await _browserFor(
      {'error': 'Unavailable'},
      statusCode: 503,
      cacheDirectory: cache,
    );

    await differentSource.browser.selectRepository('author/source-assets');

    expect(
      differentSource.browser.state.repositoryStatus,
      RequestStatus.failed,
    );
    expect(differentSource.browser.state.repositoryOrigin, isNull);
    expect(differentSource.browser.state.repository, isNull);
  });

  test(
    'an LFS pointer without SHA256 stays distinct from a direct Git blob',
    () async {
      final cache = await Directory.systemTemp.createTemp('jev-hf-lfs-');
      addTearDown(() => cache.delete(recursive: true));
      var offline = false;
      final fixture = await _browserWithHandler((request) async {
        if (offline) {
          await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
        } else {
          await _reply(request, {
            'id': 'author/lfs-flags',
            'sha': '1234567890abcdef1234567890abcdef12345678',
            'siblings': [
              {
                'rfilename': 'large.gguf',
                'blobId': 'pointer-only-id',
                'lfs': {},
              },
              {
                'rfilename': 'config.json',
                'blobId': 'direct-payload-id',
                'size': 17,
              },
            ],
          });
        }
      }, cacheDirectory: cache);
      await fixture.browser.selectRepository('author/lfs-flags');
      expect(fixture.browser.state.repository!.files.first.isLfs, isTrue);
      expect(fixture.browser.state.repository!.files.first.sha256, isNull);
      expect(fixture.browser.state.repository!.files.last.isLfs, isFalse);
      fixture.browser.close();
      offline = true;
      final reopened = HfModelBrowser(
        endpoint: fixture.endpoint,
        cacheDirectory: cache,
      );
      addTearDown(reopened.close);

      await reopened.selectRepository('author/lfs-flags');

      expect(reopened.state.repositoryOrigin, MetadataOrigin.cache);
      expect(reopened.state.repository!.files.first.isLfs, isTrue);
      expect(reopened.state.repository!.files.first.sha256, isNull);
      expect(reopened.state.repository!.files.first.blobId, 'pointer-only-id');
      expect(reopened.state.repository!.files.last.isLfs, isFalse);
      expect(reopened.state.repository!.files.last.blobId, 'direct-payload-id');
    },
  );

  test('legacy cached absence of LFS evidence remains unknown', () async {
    final cache = await Directory.systemTemp.createTemp('jev-hf-legacy-lfs-');
    addTearDown(() => cache.delete(recursive: true));
    var offline = false;
    final fixture = await _browserWithHandler((request) async {
      if (offline) {
        await _reply(request, {'error': 'Unavailable'}, statusCode: 503);
      } else {
        await _reply(request, {
          'id': 'author/legacy-lfs',
          'sha': '1234567890abcdef1234567890abcdef12345678',
          'siblings': [
            {'rfilename': 'unknown.gguf', 'blobId': 'pointer-id', 'lfs': {}},
            {
              'rfilename': 'known.gguf',
              'lfs': {
                'sha256': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
              },
            },
          ],
        });
      }
    }, cacheDirectory: cache);
    await fixture.browser.selectRepository('author/legacy-lfs');
    fixture.browser.close();
    final files = await cache
        .list()
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final metadata = jsonDecode(await file.readAsString()) as Map;
      final siblings = metadata['payload']['siblings'] as List;
      for (final sibling in siblings.cast<Map>()) {
        sibling.remove('isLfs');
        if (sibling['lfs'] is Map && (sibling['lfs'] as Map).isEmpty) {
          sibling.remove('lfs');
        }
      }
      await file.writeAsString(jsonEncode(metadata));
    }
    offline = true;
    final reopened = HfModelBrowser(
      endpoint: fixture.endpoint,
      cacheDirectory: cache,
    );
    addTearDown(reopened.close);

    await reopened.selectRepository('author/legacy-lfs');

    expect(reopened.state.repositoryOrigin, MetadataOrigin.cache);
    expect(reopened.state.repository!.files.first.isLfs, isNull);
    expect(reopened.state.repository!.files.first.blobId, 'pointer-id');
    expect(reopened.state.repository!.files.last.isLfs, isTrue);
  });
}

Future<({HfModelBrowser browser, List<Uri> requests, Uri endpoint})>
_browserFor(
  Object response, {
  int statusCode = 200,
  Directory? cacheDirectory,
}) async {
  return _browserWithHandler((request) {
    final body = response is Object Function(Uri)
        ? response(request.uri)
        : response;
    return _reply(request, body, statusCode: statusCode);
  }, cacheDirectory: cacheDirectory);
}

Future<({HfModelBrowser browser, List<Uri> requests, Uri endpoint})>
_browserWithHandler(
  Future<void> Function(HttpRequest) handler, {
  Directory? cacheDirectory,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <Uri>[];
  server.listen((request) async {
    requests.add(request.uri);
    await handler(request);
  });
  final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
  final browser = HfModelBrowser(
    endpoint: endpoint,
    cacheDirectory: cacheDirectory,
  );
  addTearDown(() async {
    browser.close();
    await server.close(force: true);
  });
  return (browser: browser, requests: requests, endpoint: endpoint);
}

Future<void> _reply(
  HttpRequest request,
  Object response, {
  int statusCode = 200,
}) async {
  request.response.statusCode = statusCode;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(response));
  await request.response.close();
}
