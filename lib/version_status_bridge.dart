import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'update_checker.dart';

/// #28 版本状况桥：把 #27 更新检查的三态结果如实映射为 MacLauncher SDK 的
/// [VersionStatus]，供 `AppCallbacks.onVersionStatus` 注册。
///
/// 本桥绝不抛异常：检查器（[UpdateChecker.check]）已保证不抛，这里仍兜底
/// 一切意外；SDK 侧对抛异常的回调另有 failure 兜底，双层防御。
class VersionStatusBridge {
  VersionStatusBridge({
    required this.currentVersion,
    required this.checkForUpdates,
  });

  /// 当前版本（包信息的缓存值，来自 Info.plist，不硬编码）；
  /// null 或空表示版本信息尚不可用，如实按查询失败回报。
  final String? Function() currentVersion;

  /// 更新检查 seam：组装处以 `(v) => UpdateChecker(currentVersion: v).check()`
  /// 注入，与设置页共用同一查询实现，不复制查询逻辑；测试注入固定结果。
  final Future<UpdateCheckResult> Function(String currentVersion)
  checkForUpdates;

  /// 执行一次更新检查并映射为 [VersionStatus]。映射规则（#28）：
  /// - [UpdateAvailable] → success，hasUpdate: true，带最新版本号、下载地址，
  ///   sha256 非空时原样透传；
  /// - [UpdateUpToDate] → success，hasUpdate: false，latestVersion 取当前版本；
  /// - [UpdateNoReleaseYet] → unsupported（如实：当前无更新渠道——仓库尚未
  ///   发布任何正式版本），原因写入 failureReason 供启动器原样展示；
  /// - [UpdateCheckFailure] → failure，如实携带失败原因。
  Future<VersionStatus> query() async {
    try {
      final current = currentVersion();
      if (current == null || current.isEmpty) {
        return VersionStatus(
          state: VersionQueryState.failure,
          failureReason: '当前版本不可用（包信息未就绪）',
        );
      }
      final result = await checkForUpdates(current);
      return switch (result) {
        UpdateAvailable(:final version, :final downloadUrl, :final sha256) =>
          VersionStatus(
            state: VersionQueryState.success,
            currentVersion: current,
            hasUpdate: true,
            latestVersion: version,
            downloadUrl: downloadUrl.toString(),
            sha256: sha256,
          ),
        UpdateUpToDate() => VersionStatus(
          state: VersionQueryState.success,
          currentVersion: current,
          hasUpdate: false,
          latestVersion: current,
        ),
        UpdateNoReleaseYet() => VersionStatus(
          state: VersionQueryState.unsupported,
          currentVersion: current,
          failureReason: '当前无更新渠道：仓库尚未发布任何正式版本',
        ),
        UpdateCheckFailure(:final reason) => VersionStatus(
          state: VersionQueryState.failure,
          currentVersion: current,
          failureReason: reason,
        ),
      };
    } catch (error) {
      return VersionStatus(
        state: VersionQueryState.failure,
        failureReason: '版本状况查询异常：$error',
      );
    }
  }
}
