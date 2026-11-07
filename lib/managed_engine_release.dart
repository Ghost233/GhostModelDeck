import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'engine_runtime.dart';

class ManagedEngineRelease {
  const ManagedEngineRelease({
    required this.family,
    required this.tag,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    this.artifactTag,
    this.commit,
  });

  final EngineFamily family;
  final String tag;
  final Uri url;
  final String sha256;
  final int sizeBytes;
  final String? artifactTag;
  final String? commit;
  String get version => tag.replaceFirst(RegExp(r'^v'), '');

  Map<String, Object?> toJson() => {
    'family': family.name,
    'tag': tag,
    'url': url.toString(),
    'sha256': sha256,
    'size': sizeBytes,
    'artifactTag': ?artifactTag,
    'commit': ?commit,
  };

  factory ManagedEngineRelease.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('引擎发行记录无效');
    }
    final familyName = value['family'];
    final tag = value['tag'];
    final digest = value['sha256'];
    final size = value['size'];
    final address = value['url'];
    final artifactTag = value['artifactTag'];
    final commit = value['commit'];
    if (familyName is! String ||
        !['llamaCpp', 'omlx'].contains(familyName) ||
        tag is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+_-]*$').hasMatch(tag) ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        size is! int ||
        size <= 0 ||
        address is! String ||
        artifactTag != null && artifactTag is! String ||
        commit != null && commit is! String) {
      throw const FormatException('引擎发行记录无效');
    }
    final family = EngineFamily.values.byName(familyName);
    final url = Uri.tryParse(address);
    final repository = family == EngineFamily.llamaCpp
        ? 'ggml-org/llama.cpp'
        : 'jundot/omlx';
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.userInfo.isNotEmpty ||
        !url.path.startsWith('/$repository/releases/download/')) {
      throw const FormatException('引擎发行地址不属于主线仓库');
    }
    if (family == EngineFamily.llamaCpp &&
        (artifactTag is! String ||
            !RegExp(r'^b\d+$').hasMatch(artifactTag) ||
            commit is! String ||
            !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit))) {
      throw const FormatException('llama.cpp 发行构建身份不完整');
    }
    return ManagedEngineRelease(
      family: family,
      tag: tag,
      url: url,
      sha256: digest,
      sizeBytes: size,
      artifactTag: artifactTag as String?,
      commit: commit as String?,
    );
  }
}

/// Resolves official release metadata. Download and installation remain owned by
/// the existing engines, including their digest checks and cancellation.
class ManagedEngineReleaseClient {
  ManagedEngineReleaseClient({Uri? apiBase, this.macosMajor})
    : apiBase = apiBase ?? Uri.https('api.github.com', '/');
  final Uri apiBase;
  final int? macosMajor;

  Future<ManagedEngineRelease> latest(EngineFamily family) async {
    if (family == EngineFamily.splash) {
      throw const FormatException('Splash 继续使用已关联的本地引擎');
    }
    final client = HttpClient();
    try {
      final repository = family == EngineFamily.llamaCpp
          ? 'ggml-org/llama.cpp'
          : 'jundot/omlx';
      final release = await _json(client, '/repos/$repository/releases/latest');
      _checkRelease(release);
      final tag = release['tag_name'] as String;
      if (family == EngineFamily.omlx) {
        final major =
            macosMajor ??
            int.tryParse(
              RegExp(r'Version (\d+)')
                      .firstMatch(Platform.operatingSystemVersion)?[1] ??
                  '',
            );
        if (major == null || major < 15) {
          throw const FormatException('当前 oMLX 主线发行需要 macOS 15 或更新系统');
        }
        final version = tag.replaceFirst(RegExp(r'^v'), '');
        final platform = major >= 26 ? 'macos26-27' : 'macos15-sequoia';
        final asset = _asset(release, 'oMLX-$version-$platform.dmg');
        return _candidate(family, tag, asset);
      }
      var artifactRelease = release;
      var artifactTag = tag;
      if (!RegExp(r'^b\d+$').hasMatch(tag)) {
        final pointer = _asset(release, 'nightly-tag.txt');
        final pointerSize = pointer['size'];
        if (pointer['id'] is! int || pointerSize is! int || pointerSize > 64) {
          throw const FormatException('llama.cpp 构建标签记录无效');
        }
        final bytes = await _get(
          client,
          '/repos/$repository/releases/assets/${pointer['id']}',
          binary: true,
        );
        if (bytes.length != pointer['size'] ||
            sha256.convert(bytes).toString() != _digest(pointer)) {
          throw const FormatException('llama.cpp 构建标签摘要不符');
        }
        artifactTag = utf8.decode(bytes).trim();
        if (!RegExp(r'^b\d+$').hasMatch(artifactTag)) {
          throw const FormatException('llama.cpp 构建标签无效');
        }
        artifactRelease = await _json(
          client,
          '/repos/$repository/releases/tags/$artifactTag',
        );
        // A stable semver release pins an upstream nightly build; the build's
        // prerelease flag does not change the stable channel we selected.
        _checkRelease(artifactRelease, pinnedBuild: true);
        if (artifactRelease['tag_name'] != artifactTag) {
          throw const FormatException('llama.cpp 构建发行标签不符');
        }
      }
      var commit = artifactRelease['target_commitish'];
      if (commit is! String || !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
        final resolved = await _json(
          client,
          '/repos/$repository/commits/$artifactTag',
        );
        commit = resolved['sha'];
      }
      final asset = _asset(
        artifactRelease,
        'llama-$artifactTag-bin-macos-arm64.tar.gz',
      );
      return _candidate(
        family,
        tag,
        asset,
        artifactTag: artifactTag,
        commit: commit,
      );
    } finally {
      client.close(force: true);
    }
  }

  ManagedEngineRelease _candidate(
    EngineFamily family,
    String tag,
    Map<String, Object?> asset, {
    String? artifactTag,
    Object? commit,
  }) => ManagedEngineRelease.fromJson({
    'family': family.name,
    'tag': tag,
    'url': asset['browser_download_url'],
    'sha256': _digest(asset),
    'size': asset['size'],
    'artifactTag': ?artifactTag,
    'commit': ?commit,
  });

  void _checkRelease(Map<String, Object?> release, {bool pinnedBuild = false}) {
    if (release['draft'] != false ||
        (pinnedBuild
            ? release['prerelease'] is! bool
            : release['prerelease'] != false) ||
        release['tag_name'] is! String ||
        release['assets'] is! List) {
      throw const FormatException('上游未提供有效的正式引擎发行');
    }
  }

  Map<String, Object?> _asset(Map<String, Object?> release, String name) {
    final matches = (release['assets'] as List<Object?>)
        .whereType<Map<String, Object?>>()
        .where(
          (asset) => asset['name'] == name && asset['state'] == 'uploaded',
        );
    if (matches.length != 1) throw FormatException('上游发行缺少 $name');
    return matches.single;
  }

  String _digest(Map<String, Object?> asset) {
    final digest = asset['digest'];
    if (digest is! String ||
        !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('上游未提供可信的引擎 SHA-256 摘要');
    }
    return digest.substring(7);
  }

  Future<Map<String, Object?>> _json(HttpClient client, String path) async {
    final value = jsonDecode(utf8.decode(await _get(client, path)));
    if (value is! Map<String, Object?>) throw const FormatException('上游发行响应无效');
    return value;
  }

  Future<List<int>> _get(
    HttpClient client,
    String path, {
    bool binary = false,
  }) async {
    final request = await client
        .getUrl(apiBase.resolve(path))
        .timeout(const Duration(seconds: 15));
    request.headers.set('User-Agent', 'GhostModelDeck');
    request.headers.set(
      'Accept',
      binary ? 'application/octet-stream' : 'application/vnd.github+json',
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('上游发行读取失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const FormatException('上游发行响应过大');
      }
    }
    return bytes;
  }
}
