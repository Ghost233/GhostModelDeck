import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/update_checker.dart';

/// 本地回环 GitHub API stub：可配置 releases/latest 响应与各 asset 内容，
/// 并记录请求路径与头部。测试不做真实网络访问。
class _GitHubStub {
  HttpServer? _server;
  int releaseStatus = HttpStatus.ok;

  /// 以 stub 地址为参数延迟构造 release body（asset URL 需要端口号）。
  String Function(Uri baseUri) releaseBody = _defaultReleaseBody;
  final Map<String, (int, String)> routes = {};
  final List<String> requestedPaths = [];
  String? lastAccept;
  String? lastUserAgent;

  static const releasePath = '/repos/Ghost233/GhostModelDeck/releases/latest';

  static String _defaultReleaseBody(Uri baseUri) => releaseJson(
    tag: 'v0.2.0',
    assets: [
      assetJson(
        'GhostModelDeck-0.2.0.dmg',
        '$baseUri/downloads/GhostModelDeck-0.2.0.dmg',
        size: 41943040,
      ),
      assetJson('manifest.json', '$baseUri/downloads/manifest.json'),
    ],
  );

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final baseUri = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      final response = request.response;
      if (request.uri.path == releasePath) {
        lastAccept = request.headers.value(HttpHeaders.acceptHeader);
        lastUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
        response.statusCode = releaseStatus;
        if (releaseStatus == HttpStatus.ok) {
          response.write(releaseBody(baseUri));
        }
      } else {
        final route = routes[request.uri.path];
        if (route == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.statusCode = route.$1;
          response.write(route.$2);
        }
      }
      await response.close();
    });
    return baseUri;
  }

  Future<void> close() async => _server?.close(force: true);
}

String releaseJson({
  required String tag,
  List<Map<String, Object?>> assets = const [],
}) {
  final buffer = StringBuffer()
    ..write('{"tag_name":"$tag","draft":false,"prerelease":false,"assets":[')
    ..write(assets.map(jsonEncodeAsset).join(','))
    ..write(']}');
  return buffer.toString();
}

String jsonEncodeAsset(Map<String, Object?> asset) {
  final entries = asset.entries
      .map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}')
      .join(',');
  return '{$entries}';
}

Map<String, Object?> assetJson(String name, String url, {int? size}) => {
  'name': name,
  'browser_download_url': url,
  'size': ?size,
};

String manifestJson({
  required String version,
  required String dmgName,
  required String sha256,
  required int size,
}) =>
    '{"version":"$version","tag":"v$version","assets":['
    '{"name":"$dmgName","sha256":"$sha256","size":$size}'
    ']}';

void main() {
  late _GitHubStub stub;
  late Uri baseUri;

  setUp(() async {
    stub = _GitHubStub();
    baseUri = await stub.start();
  });

  tearDown(() => stub.close());

  UpdateChecker checker({String currentVersion = '0.1.0'}) =>
      UpdateChecker(currentVersion: currentVersion, baseUri: baseUri);

  const sha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test('404 release response maps to NoReleaseYet', () async {
    stub.releaseStatus = HttpStatus.notFound;
    final result = await checker().check();
    expect(result, isA<UpdateNoReleaseYet>());
    expect(stub.requestedPaths, [_GitHubStub.releasePath]);
  });

  test('requests carry anonymous GitHub headers', () async {
    await checker(currentVersion: '0.1.0').check();
    expect(stub.lastAccept, 'application/vnd.github+json');
    expect(stub.lastUserAgent, 'GhostModelDeck/0.1.0');
  });

  test('latest equal to current maps to UpToDate', () async {
    stub.releaseBody = (base) => releaseJson(tag: 'v0.1.0');
    final result = await checker(currentVersion: '0.1.0').check();
    expect(result, isA<UpdateUpToDate>());
    expect((result as UpdateUpToDate).latestVersion, '0.1.0');
  });

  test('rollover boundary 0.1.9 vs 0.2.0 compares by semver, not lexicographically', () async {
    // 字典序下 "0.1.9" > "0.2.0"；rollover 规则下 0.2.0 才是更高版本。
    final upgrade = await checker(currentVersion: '0.1.9').check();
    expect(upgrade, isA<UpdateAvailable>());
    expect((upgrade as UpdateAvailable).version, '0.2.0');

    stub.releaseBody = (base) => releaseJson(tag: 'v0.1.9');
    final current = await checker(currentVersion: '0.2.0').check();
    expect(current, isA<UpdateUpToDate>());
  });

  test('build metadata is ignored when comparing versions', () async {
    stub.releaseBody = (base) => releaseJson(tag: 'v0.1.0+9');
    final result = await checker(currentVersion: '0.1.0').check();
    expect(result, isA<UpdateUpToDate>());
  });

  test('UpdateAvailable reads sha256 and size from manifest.json', () async {
    stub.routes['/downloads/manifest.json'] = (
      HttpStatus.ok,
      manifestJson(
        version: '0.2.0',
        dmgName: 'GhostModelDeck-0.2.0.dmg',
        sha256: sha.toUpperCase(),
        size: 41943040,
      ),
    );
    final result = await checker().check();
    expect(result, isA<UpdateAvailable>());
    final update = result as UpdateAvailable;
    expect(update.version, '0.2.0');
    expect(update.sha256, sha); // 统一归一化为小写
    expect(update.sizeBytes, 41943040);
    expect(update.downloadUrl.path, '/downloads/GhostModelDeck-0.2.0.dmg');
  });

  test(
    'falls back to <dmg>.sha256 sidecar when manifest asset is missing',
    () async {
      stub.releaseBody = (base) => releaseJson(
        tag: 'v0.2.0',
        assets: [
          assetJson(
            'GhostModelDeck-0.2.0.dmg',
            '$base/downloads/GhostModelDeck-0.2.0.dmg',
            size: 1234,
          ),
          assetJson(
            'GhostModelDeck-0.2.0.dmg.sha256',
            '$base/downloads/GhostModelDeck-0.2.0.dmg.sha256',
          ),
        ],
      );
      stub.routes['/downloads/GhostModelDeck-0.2.0.dmg.sha256'] = (
        HttpStatus.ok,
        '$sha  GhostModelDeck-0.2.0.dmg\n',
      );
      final result = await checker().check();
      final update = result as UpdateAvailable;
      expect(update.sha256, sha);
      expect(update.sizeBytes, 1234); // manifest 缺失时回退 GitHub asset 元数据
    },
  );

  test('falls back to SHA256SUMS sidecar and matches the DMG line', () async {
    stub.releaseBody = (base) => releaseJson(
      tag: 'v0.2.0',
      assets: [
        assetJson(
          'GhostModelDeck-0.2.0.dmg',
          '$base/downloads/GhostModelDeck-0.2.0.dmg',
        ),
        assetJson('SHA256SUMS', '$base/downloads/SHA256SUMS'),
      ],
    );
    stub.routes['/downloads/SHA256SUMS'] = (
      HttpStatus.ok,
      '${'b' * 64}  GhostModelDeck-0.2.0.zip\n'
          '$sha  GhostModelDeck-0.2.0.dmg\n',
    );
    final result = await checker().check();
    expect((result as UpdateAvailable).sha256, sha);
  });

  test('manifest fetch 404 degrades to sidecar instead of failing', () async {
    stub.releaseBody = (base) => releaseJson(
      tag: 'v0.2.0',
      assets: [
        assetJson(
          'GhostModelDeck-0.2.0.dmg',
          '$base/downloads/GhostModelDeck-0.2.0.dmg',
        ),
        assetJson('manifest.json', '$base/downloads/manifest.json'),
        assetJson('SHA256SUMS', '$base/downloads/SHA256SUMS'),
      ],
    );
    stub.routes['/downloads/manifest.json'] = (HttpStatus.notFound, '');
    stub.routes['/downloads/SHA256SUMS'] = (
      HttpStatus.ok,
      '$sha  GhostModelDeck-0.2.0.dmg\n',
    );
    final result = await checker().check();
    expect((result as UpdateAvailable).sha256, sha);
  });

  test('malformed manifest maps to UpdateCheckFailure', () async {
    stub.routes['/downloads/manifest.json'] = (HttpStatus.ok, 'not-json');
    final result = await checker().check();
    expect(result, isA<UpdateCheckFailure>());
    expect((result as UpdateCheckFailure).reason, contains('manifest.json'));
  });

  test(
    'missing manifest and sidecar yields UpdateAvailable with null sha256',
    () async {
      stub.releaseBody = (base) => releaseJson(
        tag: 'v0.2.0',
        assets: [
          assetJson(
            'GhostModelDeck-0.2.0.dmg',
            '$base/downloads/GhostModelDeck-0.2.0.dmg',
            size: 77,
          ),
        ],
      );
      final result = await checker().check();
      final update = result as UpdateAvailable;
      expect(update.sha256, isNull);
      expect(update.sizeBytes, 77);
    },
  );

  test('non-200 release response maps to UpdateCheckFailure', () async {
    stub.releaseStatus = HttpStatus.internalServerError;
    final result = await checker().check();
    expect(result, isA<UpdateCheckFailure>());
    expect((result as UpdateCheckFailure).reason, contains('500'));
  });

  test('invalid release JSON maps to UpdateCheckFailure', () async {
    stub.releaseBody = (base) => '<html>oops</html>';
    final result = await checker().check();
    expect(result, isA<UpdateCheckFailure>());
  });

  test('release without DMG asset maps to UpdateCheckFailure', () async {
    stub.releaseBody = (base) => releaseJson(tag: 'v0.2.0');
    final result = await checker().check();
    expect(result, isA<UpdateCheckFailure>());
    expect((result as UpdateCheckFailure).reason, contains('DMG'));
  });

  test('network error maps to UpdateCheckFailure and never throws', () async {
    final offline = UpdateChecker(
      currentVersion: '0.1.0',
      baseUri: Uri.parse('http://127.0.0.1:1'),
      timeout: const Duration(seconds: 2),
    );
    final result = await offline.check();
    expect(result, isA<UpdateCheckFailure>());
  });
}
