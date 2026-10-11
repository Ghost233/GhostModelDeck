import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/startlux_runtime.dart';

void main() {
  test(
    'pre-cancelled runtime never loads assets or changes foreign files',
    () async {
      final root = await _temp();
      final keep = File('${root.path}/keep');
      await keep.writeAsString('keep');
      final runtime = StartluxRuntime(
        Directory('${root.path}/runtime'),
        assets: (_) => throw StateError('must not load assets'),
      );
      addTearDown(runtime.close);
      await expectLater(
        runtime.prepare(DecisionCancellation()..cancel()),
        throwsA(isA<StartluxRuntimeCancelled>()),
      );
      expect(await keep.readAsString(), 'keep');
      expect(await root.list().length, 1);
    },
  );

  test(
    'unknown cache, external symlink and foreign lock are preserved',
    () async {
      final root = await _temp();
      final foreign = await Directory('${root.path}/foreign').create();
      final keep = File('${foreign.path}/keep');
      await keep.writeAsString('external');
      final targets = [
        Directory('${root.path}/unknown'),
        Directory('${root.path}/linked'),
        Directory('${root.path}/locked'),
      ];
      await targets[0].create();
      await File('${targets[0].path}/keep').writeAsString('unknown');
      await Link(targets[1].path).create(foreign.path);
      final lock = File('${targets[2].path}.prepare-lock');
      await lock.writeAsString('foreign-lock');
      for (final target in targets) {
        final runtime = StartluxRuntime(
          target,
          assets: _asset,
          createHttpClient: () => throw StateError('must not download'),
        );
        addTearDown(runtime.close);
        await expectLater(
          runtime.prepare(DecisionCancellation()),
          throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
        );
      }
      expect(await keep.readAsString(), 'external');
      expect(await File('${targets[0].path}/keep').readAsString(), 'unknown');
      expect(await Link(targets[1].path).target(), foreign.path);
      expect(await lock.readAsString(), 'foreign-lock');
    },
  );

  test(
    'download size and checksum failures clean only owned staging',
    () async {
      final root = await _temp();
      final keep = File('${root.path}/keep');
      await keep.writeAsString('unrelated');
      for (final wrongHash in [false, true]) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final size = wrongHash ? 25030095 : 2;
          request.response.contentLength = size;
          final zeroes = Uint8List(64 * 1024);
          var remaining = size;
          while (remaining > 0) {
            final length = remaining < zeroes.length
                ? remaining
                : zeroes.length;
            request.response.add(Uint8List.sublistView(zeroes, 0, length));
            remaining -= length;
          }
          await request.response.close();
        });
        final runtime = StartluxRuntime(
          Directory('${root.path}/runtime'),
          assets: _asset,
          createHttpClient: () => _LocalClient(server.port),
        );
        addTearDown(runtime.close);
        await expectLater(
          runtime.prepare(DecisionCancellation()),
          throwsA(isA<FormatException>()),
        );
        expect(await Directory('${root.path}/runtime').exists(), isFalse);
        expect(await root.list().map((f) => f.path.split('/').last).toList(), [
          'keep',
        ]);
        expect(runtime.cleanupErrors, isEmpty);
      }
      expect(await keep.readAsString(), 'unrelated');
    },
  );

  test('cancelling a real download releases request and owned staging', () async {
    final root = await _temp();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestDone = Completer<void>();
    server.listen((request) async {
      try {
        request.response.bufferOutput = false;
        request.response.add([1, 2, 3]);
        await request.response.flush();
        // HttpResponse.done waits for response.close(), so an intentionally
        // unfinished producer cannot use it as the peer-release observation.
        // Observe EOF on the real accepted socket without ending our response.
        final socket = await request.response.detachSocket(writeHeaders: false);
        try {
          await socket.drain<void>();
        } finally {
          await socket.close();
        }
      } catch (_) {
        // The request is intentionally aborted by the client's cancellation.
      } finally {
        requestDone.complete();
      }
    });
    final runtime = StartluxRuntime(
      Directory('${root.path}/runtime'),
      assets: _asset,
      createHttpClient: () => _LocalClient(server.port),
    );
    addTearDown(runtime.close);
    final token = DecisionCancellation();
    await expectLater(
      runtime.prepare(
        token,
        onProgress: (progress) {
          if (progress.downloadedBytes > 0) token.cancel();
        },
      ),
      throwsA(isA<StartluxRuntimeCancelled>()),
    );
    await requestDone.future.timeout(const Duration(seconds: 5));
    expect(await root.list().length, 0);
    expect(runtime.cleanupErrors, isEmpty);
  });

  test(
    'completed cache checks files before the runtime process boundary',
    () async {
      final root = await _temp();
      final cache = Directory('${root.path}/runtime');
      final calls = File('${root.path}/calls');
      await _receiptFixture(cache, calls);
      final runtime = StartluxRuntime(
        cache,
        assets: _asset,
        createHttpClient: () =>
            throw StateError('cache reuse must not download'),
      );
      addTearDown(runtime.close);
      final result = await runtime.prepare(DecisionCancellation());
      expect(result.reused, isTrue);
      expect(result.pythonPath, '${cache.path}/venv/bin/python');
      expect(result.fingerprint, hasLength(64));
      expect((result.provenance['identity'] as Map)['machine'], 'arm64');
      expect(await calls.readAsLines(), hasLength(2));
      final binary = File('${cache.path}/venv/bin/python');
      await binary.writeAsString('tampered');
      await expectLater(
        runtime.prepare(DecisionCancellation()),
        throwsA(isA<FormatException>()),
      );
      expect(await calls.readAsLines(), hasLength(2));
      expect(await binary.readAsString(), 'tampered');
    },
  );

  test(
    'successful runtime preparation reports owned lock cleanup failure',
    () async {
      final root = await _temp();
      final cache = Directory('${root.path}/runtime');
      await _receiptFixture(cache, File('${root.path}/calls'));
      final runtime = StartluxRuntime(
        cache,
        assets: _asset,
        createHttpClient: () => throw StateError('reuse must not download'),
      );
      try {
        await expectLater(
          runtime.prepare(
            DecisionCancellation(),
            onProgress: (event) {
              if (event.phase == 'reused') {
                // Real macOS filesystem boundary: preparation already verified the
                // cache, but its parent now denies deletion of the owned lock.
                expect(
                  Process.runSync('/bin/chmod', ['500', root.path]).exitCode,
                  0,
                );
              }
            },
          ),
          throwsA(
            predicate(
              (Object error) => error.toString().contains('prepare-lock'),
            ),
          ),
        );
        expect(runtime.prepared, isNull);
        expect(runtime.cleanupErrors, isNotEmpty);
        expect(await File('${cache.path}.prepare-lock').exists(), isTrue);
        await expectLater(
          runtime.close(),
          throwsA(
            predicate(
              (Object error) => error.toString().contains('prepare-lock'),
            ),
          ),
        );
        expect(await File('${cache.path}/complete.json').exists(), isTrue);
      } finally {
        expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
        try {
          await runtime.close();
        } catch (_) {
          /* The failure is asserted above. */
        }
      }
    },
  );

  test(
    'runtime preserves primary preparation error and owned cleanup error',
    () async {
      final root = await _temp();
      final cache = await Directory('${root.path}/runtime').create();
      final keep = File('${cache.path}/user-file');
      await keep.writeAsString('keep');
      final runtime = StartluxRuntime(
        cache,
        assets: _asset,
        createHttpClient: () =>
            throw StateError('incomplete cache must not download'),
      );
      try {
        await expectLater(
          runtime.prepare(
            DecisionCancellation(),
            onProgress: (event) {
              if (event.phase == 'verify-cache') {
                expect(
                  Process.runSync('/bin/chmod', ['500', root.path]).exitCode,
                  0,
                );
              }
            },
          ),
          throwsA(
            predicate(
              (Object error) =>
                  error.toString().contains('完整验收记录') &&
                  error.toString().contains('prepare-lock'),
            ),
          ),
        );
        expect(runtime.prepared, isNull);
        expect(runtime.cleanupErrors, isNotEmpty);
        expect(await keep.readAsString(), 'keep');
        await expectLater(
          runtime.close(),
          throwsA(
            predicate(
              (Object error) =>
                  error.toString().contains('完整验收记录') &&
                  error.toString().contains('prepare-lock'),
            ),
          ),
        );
      } finally {
        expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
        try {
          await runtime.close();
        } catch (_) {
          /* The failure is asserted above. */
        }
      }
    },
  );

  test(
    'runtime retry keeps unresolved lock cleanup visible after failed retry',
    () async {
      final root = await _temp();
      final cache = Directory('${root.path}/runtime');
      await _receiptFixture(cache, File('${root.path}/calls'));
      final runtime = StartluxRuntime(
        cache,
        assets: _asset,
        createHttpClient: () => throw StateError('reuse must not download'),
      );
      try {
        final first = await _lockCleanupFailure(runtime, root);
        final previousErrors = List<String>.of(first.cleanupErrors);
        await expectLater(
          runtime.prepare(DecisionCancellation()),
          throwsA(isA<StartluxRuntimeCleanupException>()),
        );
        expect(runtime.cleanupErrors, containsAll(previousErrors));
        expect(runtime.prepared, isNull);
        expect(await File('${cache.path}.prepare-lock').exists(), isTrue);
        await expectLater(
          runtime.close(),
          throwsA(
            predicate(
              (Object error) => previousErrors.every(error.toString().contains),
            ),
          ),
        );
      } finally {
        expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
        try {
          await runtime.close();
        } catch (_) {
          /* Asserted in the body. */
        }
      }
    },
  );

  for (final canceled in [false, true]) {
    test(
      'runtime retry preserves original ${canceled ? 'cancellation' : 'preparation error'} and cleanup',
      () async {
        final root = await _temp();
        final cache = Directory('${root.path}/runtime');
        if (canceled) {
          await _receiptFixture(cache, File('${root.path}/calls'));
        } else {
          await cache.create();
        }
        final marker = File('${root.path}/protected');
        await marker.writeAsString('keep');
        final runtime = StartluxRuntime(
          cache,
          assets: _asset,
          createHttpClient: () => throw StateError('must not download'),
        );
        try {
          final first = await _lockCleanupFailure(
            runtime,
            root,
            phase: 'verify-cache',
            canceled: canceled,
          );
          final primary = canceled ? '已取消' : '完整验收记录';
          expect(first.originalError.toString(), contains(primary));
          await expectLater(
            runtime.prepare(DecisionCancellation()),
            throwsA(
              predicate(
                (Object error) =>
                    error is StartluxRuntimeCleanupException &&
                    error.toString().contains(primary) &&
                    first.cleanupErrors.every(error.toString().contains),
              ),
            ),
          );
          expect(runtime.cleanupErrors, containsAll(first.cleanupErrors));
          expect(runtime.prepared, isNull);
          expect(await marker.readAsString(), 'keep');
          await expectLater(
            runtime.close(),
            throwsA(
              predicate(
                (Object error) =>
                    error.toString().contains(primary) &&
                    first.cleanupErrors.every(error.toString().contains),
              ),
            ),
          );
        } finally {
          expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
          try {
            await runtime.close();
          } catch (_) {
            /* Asserted in the body. */
          }
        }
      },
    );
  }

  test('runtime retry clears old cleanup only after restored lock and complete success', () async {
    final root = await _temp();
    final cache = Directory('${root.path}/runtime');
    await _receiptFixture(cache, File('${root.path}/calls'));
    final runtime = StartluxRuntime(
      cache,
      assets: _asset,
      createHttpClient: () => throw StateError('reuse must not download'),
    );
    try {
      await _lockCleanupFailure(runtime, root);
      expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
      // Explicit test-owner recovery, never automatic deletion by the product.
      await File('${cache.path}.prepare-lock').delete();
      final result = await runtime.prepare(DecisionCancellation());
      expect(result.reused, isTrue);
      expect(runtime.prepared, same(result));
      expect(runtime.cleanupErrors, isEmpty);
      expect(await File('${cache.path}.prepare-lock').exists(), isFalse);
      expect(await File('${cache.path}/complete.json').exists(), isTrue);
      await runtime.close();
    } finally {
      expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
      try {
        await runtime.close();
      } catch (_) {
        /* First failure must remain visible. */
      }
    }
  });

  test(
    'runtime retry keeps old cleanup when restored lock precedes invalid cache',
    () async {
      final root = await _temp();
      final cache = Directory('${root.path}/runtime');
      final calls = File('${root.path}/calls');
      await _receiptFixture(cache, calls);
      final runtime = StartluxRuntime(
        cache,
        assets: _asset,
        createHttpClient: () =>
            throw StateError('invalid cache must not download'),
      );
      try {
        final first = await _lockCleanupFailure(runtime, root);
        expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
        await File('${cache.path}.prepare-lock').delete();
        final python = File('${cache.path}/venv/bin/python');
        await python.writeAsString('tampered');
        await expectLater(
          runtime.prepare(DecisionCancellation()),
          throwsA(
            predicate(
              (Object error) =>
                  error is StartluxRuntimeCleanupException &&
                  error.toString().contains('SHA256') &&
                  first.cleanupErrors.every(error.toString().contains),
            ),
          ),
        );
        expect(runtime.prepared, isNull);
        expect(await python.readAsString(), 'tampered');
        expect(await calls.readAsLines(), hasLength(2));
        expect(runtime.cleanupErrors, containsAll(first.cleanupErrors));
        await expectLater(
          runtime.close(),
          throwsA(
            predicate(
              (Object error) =>
                  error.toString().contains('SHA256') &&
                  first.cleanupErrors.every(error.toString().contains),
            ),
          ),
        );
      } finally {
        expect(Process.runSync('/bin/chmod', ['700', root.path]).exitCode, 0);
        try {
          await runtime.close();
        } catch (_) {
          /* Asserted in the body. */
        }
      }
    },
  );

  test(
    'relative tar symlinks and executable files are extracted safely',
    () async {
      final root = await _temp();
      final archive = File('${root.path}/archive.gz');
      await archive.writeAsBytes(
        _tar([
          _Entry(
            'python/bin/python3.12',
            'file',
            utf8.encode('runtime'),
            mode: 0x1ed,
          ),
          const _Entry('python/bin/python3', 'link', [], link: 'python3.12'),
        ]),
      );
      final destination = Directory('${root.path}/unpacked');
      await extractStartluxRuntimeArchive(
        archive,
        destination,
        DecisionCancellation(),
      );
      expect(
        await File('${destination.path}/python/bin/python3').readAsString(),
        'runtime',
      );
      expect(
        await Link('${destination.path}/python/bin/python3').target(),
        'python3.12',
      );
    },
  );

  test(
    'tar traversal, external links and link-parent writes are rejected',
    () async {
      final root = await _temp();
      final entries = <List<_Entry>>[
        [
          const _Entry('../escape', 'file', [1]),
        ],
        [
          const _Entry('/escape', 'file', [1]),
        ],
        [const _Entry('python/a', 'link', [], link: '../../escape')],
        [const _Entry('python/a', 'link', [], link: '/tmp/escape')],
        [
          const _Entry('python/a', 'link', [], link: 'b'),
          const _Entry('python/a/child', 'file', [1]),
        ],
        [const _Entry('python/a', 'hardlink', [], link: 'b')],
      ];
      for (var i = 0; i < entries.length; i++) {
        final archive = File('${root.path}/archive-$i.gz');
        await archive.writeAsBytes(_tar(entries[i]));
        final destination = Directory('${root.path}/output-$i');
        await expectLater(
          extractStartluxRuntimeArchive(
            archive,
            destination,
            DecisionCancellation(),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await destination.exists(), isFalse);
      }
      expect(await File('${root.path}/escape').exists(), isFalse);
    },
  );

  test(
    'PAX long UTF8 paths and linkpath preserve their actual targets',
    () async {
      final root = await _temp();
      final longPath = 'python/lib/${List.filled(120, 'a').join()}/模块.py';
      final archive = File('${root.path}/pax.gz');
      await archive.writeAsBytes(
        _tar([
          _Entry('pax/file', 'pax', _paxRecord('path', longPath)),
          const _Entry('placeholder', 'file', [1, 2, 3]),
          _Entry('pax/link', 'pax', [
            ..._paxRecord('path', 'python/alias'),
            ..._paxRecord('linkpath', longPath.substring('python/'.length)),
          ]),
          const _Entry('placeholder-link', 'link', [], link: 'ignored'),
        ]),
      );
      final destination = Directory('${root.path}/unpacked');
      await extractStartluxRuntimeArchive(
        archive,
        destination,
        DecisionCancellation(),
      );
      expect(await File('${destination.path}/$longPath').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(await File('${destination.path}/python/alias').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'PAX path overrides cannot escape and malformed records are rejected',
    () async {
      final root = await _temp();
      for (final record in [
        _paxRecord('path', '../escape'),
        utf8.encode('999 path=python/a\n'),
      ]) {
        final archive = File('${root.path}/pax.gz');
        await archive.writeAsBytes(
          _tar([
            _Entry('pax/metadata', 'pax', record),
            const _Entry('placeholder', 'file', [1]),
          ]),
        );
        final destination = Directory('${root.path}/output');
        await expectLater(
          extractStartluxRuntimeArchive(
            archive,
            destination,
            DecisionCancellation(),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await destination.exists(), isFalse);
      }
      expect(await File('${root.path}/escape').exists(), isFalse);
    },
  );

  test('tar payload padding and both end records are required', () async {
    final root = await _temp();
    final valid = gzip.decode(
      _tar([
        const _Entry('python/a', 'file', [1, 2, 3]),
      ]),
    );
    final invalid = [
      valid.sublist(0, 515),
      valid.sublist(0, 1024),
      valid.sublist(0, 1536),
      [...valid, 1],
    ];
    for (var i = 0; i < invalid.length; i++) {
      final archive = File('${root.path}/truncated-$i.gz');
      await archive.writeAsBytes(gzip.encode(invalid[i]));
      final destination = Directory('${root.path}/output-$i');
      await expectLater(
        extractStartluxRuntimeArchive(
          archive,
          destination,
          DecisionCancellation(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await destination.exists(), isFalse);
    }
  });

  test(
    'truncated tar and an existing destination never overwrite files',
    () async {
      final root = await _temp();
      final existing = await Directory('${root.path}/existing').create();
      final keep = File('${existing.path}/keep');
      await keep.writeAsString('keep');
      final archive = File('${root.path}/a.gz');
      final valid = gzip.decode(
        _tar([
          const _Entry('python/a', 'file', [1, 2, 3]),
        ]),
      );
      await archive.writeAsBytes(gzip.encode(valid.sublist(0, 513)));
      await expectLater(
        extractStartluxRuntimeArchive(
          archive,
          Directory('${root.path}/output'),
          DecisionCancellation(),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        extractStartluxRuntimeArchive(
          archive,
          existing,
          DecisionCancellation(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await keep.readAsString(), 'keep');
    },
  );
}

Future<Directory> _temp() async {
  final temporary = await Directory.systemTemp.createTemp(
    'gmd-startlux-runtime-',
  );
  final root = Directory(await temporary.resolveSymbolicLinks());
  addTearDown(() => root.delete(recursive: true));
  return root;
}

Future<Uint8List> _asset(String path) => File(path).readAsBytes();

class _LocalClient implements HttpClient {
  _LocalClient(this.port);
  final int port;
  final HttpClient inner = HttpClient();
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      inner.getUrl(Uri.parse('http://127.0.0.1:$port/asset'));
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// This local executable is a process-boundary fixture, not a CPython runtime
// acceptance claim. Real managed CPython and native imports have separate proof.
Future<void> _receiptFixture(Directory cache, File calls) async {
  await Directory('${cache.path}/venv/bin').create(recursive: true);
  final python = File('${cache.path}/venv/bin/python');
  final assetBytes = await _asset(
    '${StartluxRuntime.assetRoot}/python-asset.json',
  );
  final wheelBytes = await _asset('${StartluxRuntime.assetRoot}/wheels.json');
  final requirementBytes = await _asset(
    '${StartluxRuntime.assetRoot}/requirements.lock',
  );
  final asset = (jsonDecode(utf8.decode(assetBytes)) as Map)['asset'];
  final wheels =
      (jsonDecode(utf8.decode(wheelBytes)) as Map)['packages'] as List;
  final packages = [
    for (final entry in wheels)
      {'name': (entry as Map)['name'], 'version': entry['version']},
  ];
  final identity = {
    'version': StartluxRuntime.pythonVersion,
    'system': 'Darwin',
    'machine': 'arm64',
    'executable': python.path,
  };
  await python.writeAsString('''#!/bin/sh
printf 'called\\n' >> '${calls.path}'
case "\$*" in
  *importlib.metadata*) printf '%s\\n' '${jsonEncode(packages)}' ;;
  *) printf '%s\\n' '${jsonEncode(identity)}' ;;
esac
''');
  expect((await Process.run('/bin/chmod', ['755', python.path])).exitCode, 0);
  final files = {
    'venv/bin/python': {
      'size': await python.length(),
      'sha256': sha256.convert(await python.readAsBytes()).toString(),
    },
  };
  await File('${cache.path}/complete.json').writeAsString(
    jsonEncode({
      'owner': StartluxRuntime.owner,
      'fingerprint': sha256.convert([
        ...assetBytes,
        ...wheelBytes,
        ...requirementBytes,
      ]).toString(),
      'asset': asset,
      'wheels': wheels,
      'requirements_sha256': sha256.convert(requirementBytes).toString(),
      'packages': packages,
      'identity': identity,
      'files': files,
    }),
  );
}

class _Entry {
  const _Entry(
    this.name,
    this.kind,
    this.bytes, {
    this.link = '',
    this.mode = 0x1a4,
  });
  final String name;
  final String kind;
  final List<int> bytes;
  final String link;
  final int mode;
}

List<int> _tar(List<_Entry> entries) {
  final result = BytesBuilder();
  for (final entry in entries) {
    final header = Uint8List(512);
    void text(int start, int width, String value) {
      final encoded = utf8.encode(value);
      header.setRange(start, start + encoded.length, encoded);
    }

    text(0, 100, entry.name);
    text(100, 8, '${entry.mode.toRadixString(8).padLeft(7, '0')}\u0000');
    text(
      124,
      12,
      '${entry.bytes.length.toRadixString(8).padLeft(11, '0')}\u0000',
    );
    header.fillRange(148, 156, 32);
    header[156] = switch (entry.kind) {
      'link' => 50,
      'hardlink' => 49,
      'pax' => 120,
      _ => 48,
    };
    text(157, 100, entry.link);
    text(257, 6, 'ustar');
    final checksum = header.fold(0, (int a, int b) => a + b);
    text(148, 8, '${checksum.toRadixString(8).padLeft(6, '0')}\u0000 ');
    result.add(header);
    result.add(entry.bytes);
    result.add(Uint8List((512 - entry.bytes.length % 512) % 512));
  }
  result.add(Uint8List(1024));
  return gzip.encode(result.takeBytes());
}

List<int> _paxRecord(String key, String value) {
  final payload = '$key=$value\n';
  var length = utf8.encode(payload).length + 2;
  while (true) {
    final record = utf8.encode('$length $payload');
    if (record.length == length) return record;
    length = record.length;
  }
}

Future<StartluxRuntimeCleanupException> _lockCleanupFailure(
  StartluxRuntime runtime,
  Directory parent, {
  String phase = 'reused',
  bool canceled = false,
}) async {
  final token = DecisionCancellation();
  StartluxRuntimeCleanupException? failure;
  await expectLater(
    runtime.prepare(
      token,
      onProgress: (event) {
        if (event.phase == phase) {
          expect(
            Process.runSync('/bin/chmod', ['500', parent.path]).exitCode,
            0,
          );
          if (canceled) token.cancel();
        }
      },
    ),
    throwsA(
      predicate((Object error) {
        if (error is! StartluxRuntimeCleanupException) return false;
        failure = error;
        return true;
      }),
    ),
  );
  expect(runtime.prepared, isNull);
  expect(failure!.cleanupErrors, isNotEmpty);
  return failure!;
}
