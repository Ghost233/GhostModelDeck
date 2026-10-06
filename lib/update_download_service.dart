import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 下载进度快照（百分比由 [fraction] 派生，速度为全程平均）。
class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });

  final int receivedBytes;

  /// 服务端 content-length，未知时为 null。
  final int? totalBytes;
  final double bytesPerSecond;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// 校验通过、等待用户确认的安装包信息。
class UpdateDownloadReady {
  const UpdateDownloadReady({
    required this.stagedPath,
    required this.totalBytes,
    required this.sha256Hex,
  });

  final String stagedPath;
  final int totalBytes;
  final String sha256Hex;
}

typedef UpdateProgressCallback = void Function(UpdateDownloadProgress progress);

/// 版本号 → 目标保存路径（默认 `~/Downloads/GhostModelDeck-<x.y.z>.dmg`）。
typedef UpdateTargetPathResolver = FutureOr<String> Function(String version);

/// 校验通过后的确认回调；返回 false 表示用户取消（临时文件将被删除）。
typedef UpdateInstallConfirmer = Future<bool> Function(
  UpdateDownloadReady ready,
);

/// 打开安装包；返回 null 表示成功，否则为错误描述。
typedef UpdateOpenLauncher = Future<String?> Function(String path);

/// 下载结果。本模块不向外抛异常。
sealed class UpdateDownloadOutcome {
  const UpdateDownloadOutcome();
}

/// 已保存到目标路径并尝试打开。
final class UpdateDownloadCompleted extends UpdateDownloadOutcome {
  const UpdateDownloadCompleted({
    required this.path,
    required this.totalBytes,
    required this.sha256Hex,
    this.openError,
  });

  final String path;
  final int totalBytes;
  final String sha256Hex;

  /// null 表示 `open` 成功。
  final String? openError;

  bool get opened => openError == null;
}

/// 用户在确认步骤取消；安装包未保存、未打开。
final class UpdateDownloadDeclined extends UpdateDownloadOutcome {
  const UpdateDownloadDeclined();
}

/// sha256 校验失败：绝不打开，临时文件已删除。
final class UpdateDownloadIntegrityFailure extends UpdateDownloadOutcome {
  const UpdateDownloadIntegrityFailure({
    required this.expectedSha256,
    required this.actualSha256,
  });

  final String expectedSha256;
  final String actualSha256;
}

final class UpdateDownloadFailed extends UpdateDownloadOutcome {
  const UpdateDownloadFailed(this.reason, [this.cause]);

  final String reason;
  final Object? cause;
}

/// 更新包下载服务（Q5B）：单流下载 → 流式 sha256 校验 → （可选确认）→
/// 保存到 ~/Downloads → `open` 打开。未签名应用绝不做自动安装/替换。
class UpdateDownloadService {
  UpdateDownloadService({
    HttpClient Function()? clientFactory,
    UpdateTargetPathResolver? targetPathResolver,
    UpdateOpenLauncher? openLauncher,
    this.timeout = const Duration(minutes: 30),
    this.progressInterval = const Duration(milliseconds: 200),
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _targetPathResolver = targetPathResolver ?? defaultTargetPath,
       _openLauncher = openLauncher ?? defaultOpen;

  /// 请求建立阶段的超时（响应体流不计时，大文件下载不受限）。
  final Duration timeout;

  /// 进度回调的最小间隔（完成时总会再发一次）。
  final Duration progressInterval;

  final HttpClient Function() _clientFactory;
  final UpdateTargetPathResolver _targetPathResolver;
  final UpdateOpenLauncher _openLauncher;

  static String defaultTargetPath(String version) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('无法确定用户主目录（HOME 未设置）');
    }
    return '$home/Downloads/GhostModelDeck-$version.dmg';
  }

  static Future<String?> defaultOpen(String path) async {
    final result = await Process.run('open', [path]);
    if (result.exitCode == 0) return null;
    return 'open 退出码 ${result.exitCode}：${result.stderr}';
  }

  Future<UpdateDownloadOutcome> downloadUpdate({
    required Uri source,
    required String version,
    required String expectedSha256,
    int? expectedSizeBytes,
    UpdateProgressCallback? onProgress,
    UpdateInstallConfirmer? confirmBeforeInstall,
  }) async {
    HttpClient? client;
    IOSink? sink;
    String? stagingPath;
    try {
      final targetPath = await _targetPathResolver(version);
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      final staging = File('${target.path}.part');
      stagingPath = staging.path;
      await _deleteQuietly(staging);

      client = _clientFactory();
      final request = await client.getUrl(source).timeout(timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'GhostModelDeck/$version',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        return UpdateDownloadFailed('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength >= 0
          ? response.contentLength
          : expectedSizeBytes;

      sink = staging.openWrite();
      final collector = _DigestCollector();
      final digestSink = sha256.startChunkedConversion(collector);
      var received = 0;
      final stopwatch = Stopwatch()..start();
      var lastEmitMs = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        digestSink.add(chunk);
        received += chunk.length;
        final elapsedMs = stopwatch.elapsedMilliseconds;
        final done = total != null && received >= total;
        if (onProgress != null &&
            (done ||
                elapsedMs - lastEmitMs >= progressInterval.inMilliseconds)) {
          lastEmitMs = elapsedMs;
          // 进度回调属于观察者，其异常不应中断下载。
          try {
            onProgress(
              UpdateDownloadProgress(
                receivedBytes: received,
                totalBytes: total,
                bytesPerSecond: elapsedMs > 0 ? received * 1000 / elapsedMs : 0,
              ),
            );
          } catch (_) {}
        }
      }
      digestSink.close();
      await sink.flush();
      await sink.close();
      sink = null;

      final digest = collector.digest;
      if (digest == null) {
        await _deleteQuietly(staging);
        return const UpdateDownloadFailed('完整性校验计算失败');
      }
      final actualSha256 = digest.toString().toLowerCase();
      final expected = expectedSha256.toLowerCase();
      if (actualSha256 != expected) {
        await _deleteQuietly(staging);
        return UpdateDownloadIntegrityFailure(
          expectedSha256: expected,
          actualSha256: actualSha256,
        );
      }

      final ready = UpdateDownloadReady(
        stagedPath: staging.path,
        totalBytes: received,
        sha256Hex: actualSha256,
      );
      final confirmed = confirmBeforeInstall == null
          ? true
          : await confirmBeforeInstall(ready);
      if (!confirmed) {
        await _deleteQuietly(staging);
        return const UpdateDownloadDeclined();
      }

      if (await target.exists()) await target.delete();
      await staging.rename(target.path);
      stagingPath = null;

      final openError = await _openLauncher(target.path);
      return UpdateDownloadCompleted(
        path: target.path,
        totalBytes: received,
        sha256Hex: actualSha256,
        openError: openError,
      );
    } on TimeoutException catch (e) {
      return UpdateDownloadFailed('下载超时', e);
    } on SocketException catch (e) {
      return UpdateDownloadFailed('网络连接失败', e);
    } on HttpException catch (e) {
      return UpdateDownloadFailed('网络请求失败', e);
    } on FileSystemException catch (e) {
      return UpdateDownloadFailed('写入安装包失败', e);
    } catch (e) {
      return UpdateDownloadFailed('下载失败', e);
    } finally {
      client?.close(force: true);
      try {
        await sink?.close();
      } catch (_) {
        // 关闭错误不掩盖原始结果。
      }
      final leftover = stagingPath;
      if (leftover != null) await _deleteQuietly(File(leftover));
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不掩盖原始结果。
    }
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
