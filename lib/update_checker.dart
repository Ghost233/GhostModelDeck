import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

/// 更新检查结果（Q8A 三态 + 失败）。
///
/// 所有错误都映射为 [UpdateCheckFailure]，本模块不向外抛异常。
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// 仓库尚未发布任何正式版（GitHub 返回 404）。
final class UpdateNoReleaseYet extends UpdateCheckResult {
  const UpdateNoReleaseYet();
}

/// 最新发布版本不高于当前版本。
final class UpdateUpToDate extends UpdateCheckResult {
  const UpdateUpToDate({
    required this.currentVersion,
    required this.latestVersion,
  });

  final String currentVersion;
  final String latestVersion;
}

/// 存在更高版本的正式发布。
final class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable({
    required this.version,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sha256,
  });

  /// 规范化后的 semver 文本（不含 v 前缀）。
  final String version;
  final Uri downloadUrl;

  /// DMG 字节数；优先取 manifest，其次 GitHub asset 元数据，可能为空。
  final int? sizeBytes;

  /// 64 位小写十六进制 sha256；manifest 与 sidecar 都缺失时为 null，
  /// 此时 UI 必须禁止下载（无法校验完整性）。
  final String? sha256;
}

/// 检查失败（网络、HTTP 错误、数据格式错误等）。
final class UpdateCheckFailure extends UpdateCheckResult {
  const UpdateCheckFailure(this.reason, [this.cause]);

  final String reason;
  final Object? cause;
}

/// GhostModelDeck 软件更新查询服务（匿名 GitHub REST，无令牌）。
///
/// 纯 Dart、无 UI 依赖，供设置页与 #28 的 SDK 桥复用。
/// 流程：`releases/latest` → 比较 tag 与当前版本 → 取 DMG 的
/// sha256/size（优先 manifest.json，缺失时回退 `<dmg>.sha256` 或
/// SHA256SUMS sidecar）。
class UpdateChecker {
  UpdateChecker({
    required this.currentVersion,
    this.owner = 'Ghost233',
    this.repo = 'GhostModelDeck',
    Uri? baseUri,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : baseUri = baseUri ?? Uri.https('api.github.com', ''),
       _clientFactory = clientFactory ?? HttpClient.new;

  /// 当前版本（来自 package_info_plus 的 Info.plist，非硬编码）。
  final String currentVersion;
  final String owner;
  final String repo;
  final Uri baseUri;
  final Duration timeout;
  final HttpClient Function() _clientFactory;

  static const String manifestAssetName = 'manifest.json';
  static const String checksumSumsAssetName = 'SHA256SUMS';

  Future<UpdateCheckResult> check() async {
    HttpClient? client;
    try {
      client = _clientFactory();
      final release = await _get(
        client,
        _endpoint('/repos/$owner/$repo/releases/latest'),
      );
      if (release.statusCode == HttpStatus.notFound) {
        return const UpdateNoReleaseYet();
      }
      if (release.statusCode != HttpStatus.ok) {
        return UpdateCheckFailure('GitHub 请求失败（HTTP ${release.statusCode}）');
      }
      final releaseJson = jsonDecode(release.body);
      if (releaseJson is! Map<String, Object?>) {
        return const UpdateCheckFailure('发布信息格式无效');
      }
      final tag = releaseJson['tag_name'];
      if (tag is! String) {
        return const UpdateCheckFailure('发布信息缺少 tag_name');
      }
      final latest = _parseVersion(tag);
      if (latest == null) {
        return UpdateCheckFailure('无法解析最新版本号：$tag');
      }
      final current = _parseVersion(currentVersion);
      if (current == null) {
        return UpdateCheckFailure('无法解析当前版本号：$currentVersion');
      }
      // SemVer §10：比较时忽略构建元数据，否则 0.1.0+2 会被误判为更新。
      if (_withoutBuild(latest) <= _withoutBuild(current)) {
        return UpdateUpToDate(
          currentVersion: currentVersion,
          latestVersion: latest.toString(),
        );
      }
      final assets = _parseAssets(releaseJson['assets']);
      final dmg = _findDmgAsset(assets);
      if (dmg == null) {
        return const UpdateCheckFailure('最新发布中找不到 DMG 安装包');
      }
      final integrity = await _resolveIntegrity(client, assets, dmg);
      return UpdateAvailable(
        version: latest.toString(),
        downloadUrl: dmg.downloadUrl,
        sizeBytes: integrity.size ?? dmg.size,
        sha256: integrity.sha256,
      );
    } on _InvalidManifestException {
      return const UpdateCheckFailure('manifest.json 格式无效');
    } on TimeoutException catch (e) {
      return UpdateCheckFailure('请求超时', e);
    } on SocketException catch (e) {
      return UpdateCheckFailure('网络连接失败', e);
    } on HttpException catch (e) {
      return UpdateCheckFailure('网络请求失败', e);
    } on FormatException catch (e) {
      return UpdateCheckFailure('返回内容不是有效 JSON', e);
    } catch (e) {
      return UpdateCheckFailure('检查更新失败', e);
    } finally {
      client?.close(force: true);
    }
  }

  Uri _endpoint(String path) {
    final base = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$base$path');
  }

  Future<_HttpTextResponse> _get(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'GhostModelDeck/$currentVersion',
    );
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join();
    return _HttpTextResponse(response.statusCode, body);
  }

  /// DMG 的 sha256/size：优先 manifest.json；manifest 缺失或取不到时
  /// 回退 `<dmg>.sha256` / SHA256SUMS sidecar（MacLauncher 先例）。
  /// sidecar 也拿不到时不视为检查失败，仅 sha256 留空交由 UI 禁止下载。
  Future<({String? sha256, int? size})> _resolveIntegrity(
    HttpClient client,
    List<_ReleaseAsset> assets,
    _ReleaseAsset dmg,
  ) async {
    final manifest = _findAsset(assets, manifestAssetName);
    if (manifest != null) {
      final response = await _get(client, manifest.downloadUrl);
      if (response.statusCode == HttpStatus.ok) {
        final parsed = _parseManifest(response.body, dmg.name);
        if (parsed != null) return parsed;
      }
    }
    final sidecar =
        _findAsset(assets, '${dmg.name}.sha256') ??
        _findAsset(assets, checksumSumsAssetName);
    if (sidecar != null) {
      final response = await _get(client, sidecar.downloadUrl);
      if (response.statusCode == HttpStatus.ok) {
        final sha256 = _extractSha256(response.body, dmg.name);
        if (sha256 != null) return (sha256: sha256, size: null);
      }
    }
    return (sha256: null, size: null);
  }

  /// 解析 manifest.json 并返回 DMG 条目；manifest 不含该 DMG 时返回
  /// null（走 sidecar），格式错误抛 [_InvalidManifestException]。
  static ({String? sha256, int? size})? _parseManifest(
    String body,
    String dmgName,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const _InvalidManifestException();
    }
    if (decoded is! Map<String, Object?>) {
      throw const _InvalidManifestException();
    }
    final rawAssets = decoded['assets'];
    if (rawAssets is! List) throw const _InvalidManifestException();
    for (final raw in rawAssets) {
      if (raw is! Map<String, Object?>) {
        throw const _InvalidManifestException();
      }
      if (raw['name'] != dmgName) continue;
      final sha256 = raw['sha256'];
      final size = raw['size'];
      return (
        sha256: sha256 is String && _isHexDigest(sha256)
            ? sha256.toLowerCase()
            : null,
        size: size is int ? size : null,
      );
    }
    return null;
  }

  /// 从 sidecar 文本提取摘要：优先匹配包含 DMG 文件名的行
  /// （SHA256SUMS 格式），其次取全文第一个 64 位十六进制串
  /// （单列 `<dmg>.sha256` 可能没有文件名）。
  static String? _extractSha256(String text, String dmgName) {
    final pattern = RegExp(r'\b[0-9a-fA-F]{64}\b');
    for (final line in const LineSplitter().convert(text)) {
      if (!line.contains(dmgName)) continue;
      final match = pattern.firstMatch(line);
      if (match != null) return match.group(0)!.toLowerCase();
    }
    return pattern.firstMatch(text)?.group(0)!.toLowerCase();
  }

  static bool _isHexDigest(String text) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text);

  static Version? _parseVersion(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    try {
      return Version.parse(text);
    } on FormatException {
      return null;
    }
  }

  static Version _withoutBuild(Version version) {
    final pre = version.preRelease;
    return Version(
      version.major,
      version.minor,
      version.patch,
      pre: pre.isEmpty ? null : pre.join('.'),
    );
  }

  static List<_ReleaseAsset> _parseAssets(Object? raw) {
    if (raw is! List) return const [];
    final assets = <_ReleaseAsset>[];
    for (final item in raw) {
      if (item is! Map<String, Object?>) continue;
      final name = item['name'];
      final url = item['browser_download_url'];
      if (name is! String || url is! String) continue;
      final uri = Uri.tryParse(url);
      if (uri == null) continue;
      final size = item['size'];
      assets.add(
        _ReleaseAsset(
          name: name,
          downloadUrl: uri,
          size: size is int ? size : null,
        ),
      );
    }
    return assets;
  }

  static _ReleaseAsset? _findAsset(List<_ReleaseAsset> assets, String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  static _ReleaseAsset? _findDmgAsset(List<_ReleaseAsset> assets) {
    for (final asset in assets) {
      if (asset.name.endsWith('.dmg')) return asset;
    }
    return null;
  }
}

class _HttpTextResponse {
  const _HttpTextResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final Uri downloadUrl;
  final int? size;
}

class _InvalidManifestException implements Exception {
  const _InvalidManifestException();
}
