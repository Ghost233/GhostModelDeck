import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/managed_engine_release.dart';

void main() {
  late HttpServer server;
  late ManagedEngineReleaseClient client;
  late Map<String, Object> responses;
  late List<String> requests;
  final pointer = utf8.encode('b12110\n');
  Map<String, Object?> asset(
    String repository,
    String tag,
    String name, {
    String? digest,
    int size = 128,
  }) => {
    'id': 1,
    'name': name,
    'state': 'uploaded',
    'size': size,
    'digest': digest ?? 'sha256:${'a' * 64}',
    'browser_download_url':
        'https://github.com/$repository/releases/download/$tag/$name',
  };
  Map<String, Object?> release(String tag, List<Map<String, Object?>> assets) =>
      {
        'tag_name': tag,
        'draft': false,
        'prerelease': false,
        'target_commitish': 'c' * 40,
        'assets': assets,
      };
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = ManagedEngineReleaseClient(
      apiBase: Uri.parse('http://127.0.0.1:${server.port}/'),
      macosMajor: 27,
    );
    requests = [];
    responses = {
      '/repos/ggml-org/llama.cpp/releases/latest': release('v0.9.0', [
        asset(
          'ggml-org/llama.cpp',
          'v0.9.0',
          'nightly-tag.txt',
          digest: 'sha256:${sha256.convert(pointer)}',
          size: pointer.length,
        ),
      ]),
      '/repos/ggml-org/llama.cpp/releases/assets/1': pointer,
      '/repos/ggml-org/llama.cpp/releases/tags/b12110': {
        ...release('b12110', [
          asset(
            'ggml-org/llama.cpp',
            'b12110',
            'llama-b12110-bin-macos-arm64.tar.gz',
          ),
          asset(
            'ggml-org/llama.cpp',
            'b12110',
            'llama-b12110-bin-macos-x64.tar.gz',
          ),
        ]),
        'prerelease': true,
      },
      '/repos/jundot/omlx/releases/latest': release('v0.7.4.dev1', [
        asset('jundot/omlx', 'v0.7.4.dev1', 'oMLX-0.7.4.dev1-macos26-27.dmg'),
        asset(
          'jundot/omlx',
          'v0.7.4.dev1',
          'oMLX-0.7.4.dev1-macos15-sequoia.dmg',
        ),
      ]),
    };
    server.listen((request) async {
      requests.add(request.uri.path);
      final value = responses[request.uri.path];
      if (value == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (value is List<int>) {
        request.response.add(value);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(value));
      }
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test(
    'mainline llama resolves the stable release pointer and arm64 archive',
    () async {
      final result = await client.latest(EngineFamily.llamaCpp);
      expect(result.tag, 'v0.9.0');
      expect(result.artifactTag, 'b12110');
      expect(result.commit, 'c' * 40);
      expect(result.url.path, endsWith('/llama-b12110-bin-macos-arm64.tar.gz'));
      expect(result.sha256, 'a' * 64);
      expect(
        ManagedEngineRelease.fromJson(result.toJson()).toJson(),
        result.toJson(),
      );
      expect(requests, hasLength(3));
    },
  );

  test(
    'pointer digest mismatch stops before resolving or downloading an engine',
    () async {
      responses['/repos/ggml-org/llama.cpp/releases/assets/1'] = utf8.encode(
        'b99999\n',
      );
      await expectLater(
        client.latest(EngineFamily.llamaCpp),
        throwsFormatException,
      );
      expect(requests, hasLength(2));
    },
  );

  test(
    'oMLX resolves the release asset for the actual macOS generation',
    () async {
      final current = await client.latest(EngineFamily.omlx);
      expect(current.version, '0.7.4.dev1');
      expect(current.url.path, endsWith('-macos26-27.dmg'));
      final sequoia = await ManagedEngineReleaseClient(
        apiBase: client.apiBase,
        macosMajor: 15,
      ).latest(EngineFamily.omlx);
      expect(sequoia.url.path, endsWith('-macos15-sequoia.dmg'));
    },
  );

  test('missing release digest is rejected instead of weakening archive validation', () async {
    responses['/repos/jundot/omlx/releases/latest'] = release('v0.7.4.dev1', [
      {
        ...asset(
          'jundot/omlx',
          'v0.7.4.dev1',
          'oMLX-0.7.4.dev1-macos26-27.dmg',
        ),
        'digest': null,
      },
    ]);
    await expectLater(client.latest(EngineFamily.omlx), throwsFormatException);
  });
}
