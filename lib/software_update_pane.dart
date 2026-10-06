import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'update_checker.dart';
import 'update_download_service.dart';

/// 软件更新面板的外部依赖（E08 构造注入）。
///
/// 纯 Dart 的 [UpdateChecker] / [UpdateDownloadService] 不依赖插件，
/// 生产环境由 main.dart 用 package_info_plus 的版本号接线，
/// 测试注入 fake，不触碰网络与文件系统。
class SoftwareUpdateConfig {
  const SoftwareUpdateConfig({
    required this.currentVersion,
    required this.checkForUpdates,
    required this.downloadUpdate,
  });

  final String currentVersion;
  final Future<UpdateCheckResult> Function() checkForUpdates;
  final Future<UpdateDownloadOutcome> Function(
    UpdateAvailable update, {
    UpdateProgressCallback? onProgress,
    UpdateInstallConfirmer? confirmBeforeInstall,
  })
  downloadUpdate;
}

/// 「软件更新」设置页：进入时自动检查一次，可手动重查，
/// 有更新时下载 → 校验 → 确认 → 保存到 ~/Downloads 并打开。
class SoftwareUpdatePane extends StatefulWidget {
  const SoftwareUpdatePane({super.key, required this.config});

  /// null 表示当前版本不可用（如插件缺失），面板降级为只读。
  final SoftwareUpdateConfig? config;

  @override
  State<SoftwareUpdatePane> createState() => _SoftwareUpdatePaneState();
}

class _SoftwareUpdatePaneState extends State<SoftwareUpdatePane> {
  bool _checking = false;
  bool _downloading = false;
  bool _autoChecked = false;
  UpdateCheckResult? _result;
  UpdateDownloadProgress? _progress;
  UpdateDownloadOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _autoCheckOnce();
  }

  @override
  void didUpdateWidget(SoftwareUpdatePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 版本号异步到达（package_info_plus）：面板首次拿到配置时自动检查一次。
    _autoCheckOnce();
  }

  void _autoCheckOnce() {
    if (_autoChecked || widget.config == null) return;
    _autoChecked = true;
    unawaited(_check());
  }

  Future<void> _check() async {
    final config = widget.config;
    if (config == null || _checking) return;
    setState(() {
      _checking = true;
      _outcome = null;
    });
    final result = await config.checkForUpdates();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  Future<void> _startDownload(UpdateAvailable update) async {
    final config = widget.config;
    if (config == null || _downloading) return;
    final sha256 = update.sha256;
    if (sha256 == null) return; // 无摘要禁止下载，UI 已禁用按钮。
    setState(() {
      _downloading = true;
      _progress = null;
      _outcome = null;
    });
    final outcome = await config.downloadUpdate(
      update,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
      confirmBeforeInstall: _confirmInstall,
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _outcome = outcome;
    });
  }

  /// 校验通过后的确认：保存到 ~/Downloads 并打开，或取消（临时文件删除）。
  Future<bool> _confirmInstall(UpdateDownloadReady ready) async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载完成'),
        content: Text(
          '更新包已下载并通过 sha256 校验（${ready.sha256Hex.substring(0, 12)}…）。\n'
          '保存到 ~/Downloads 并打开 DMG 安装包？',
        ),
        actions: [
          TextButton(
            key: const ValueKey('update-confirm-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('update-confirm-open'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存并打开'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final theme = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          children: [
            const JevPageHeader(title: '软件更新'),
            JevSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('当前版本', style: theme.titleSmall),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          config?.currentVersion ?? '未知',
                          key: const ValueKey('update-current-version'),
                          style: theme.bodyMedium,
                        ),
                      ),
                      FilledButton.tonal(
                        key: const ValueKey('update-check-now'),
                        onPressed: config == null || _checking
                            ? null
                            : () => unawaited(_check()),
                        child: Text(_checking ? '正在检查…' : '立即检查'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildState(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildState(BuildContext context) {
    if (widget.config == null) {
      return Text(
        '无法读取当前版本，更新检查不可用。',
        key: const ValueKey('update-state-unavailable'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    if (_downloading) return _buildDownloading(context);
    final outcome = _outcome;
    if (outcome != null) return _buildOutcome(context, outcome);
    if (_checking && _result == null) {
      return const Row(
        key: ValueKey('update-state-checking'),
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('正在检查更新…'),
        ],
      );
    }
    final result = _result;
    if (result == null) {
      return Text('尚未检查更新。', style: Theme.of(context).textTheme.bodySmall);
    }
    return switch (result) {
      UpdateNoReleaseYet() => const JevStatusChip(
        key: ValueKey('update-state-no-release'),
        label: '尚未发布正式版',
      ),
      UpdateUpToDate() => const JevStatusChip(
        key: ValueKey('update-state-up-to-date'),
        label: '已是最新',
        tone: JevStatusTone.success,
      ),
      UpdateAvailable() => _buildAvailable(context, result),
      UpdateCheckFailure() => Text(
        '检查失败：${result.reason}',
        key: const ValueKey('update-state-failed'),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    };
  }

  Widget _buildAvailable(BuildContext context, UpdateAvailable update) {
    final theme = Theme.of(context).textTheme;
    final sha256 = update.sha256;
    return Column(
      key: const ValueKey('update-state-available'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const JevStatusChip(label: '有更新', tone: JevStatusTone.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '新版本 v${update.version}（${update.sizeBytes == null ? '大小未知' : _formatBytes(update.sizeBytes!)}）',
                style: theme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (sha256 == null)
          Text(
            '该发布缺少校验摘要，无法安全下载。',
            style: theme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          )
        else
          FilledButton(
            key: const ValueKey('update-download-button'),
            onPressed: () => unawaited(_startDownload(update)),
            child: const Text('下载'),
          ),
      ],
    );
  }

  Widget _buildDownloading(BuildContext context) {
    final progress = _progress;
    final fraction = progress?.fraction;
    final percent = fraction == null
        ? null
        : '${(fraction * 100).toStringAsFixed(0)}%';
    final detail = progress == null
        ? '正在下载…'
        : [
            ?percent,
            if (progress.totalBytes != null)
              '${_formatBytes(progress.receivedBytes)} / ${_formatBytes(progress.totalBytes!)}'
            else
              _formatBytes(progress.receivedBytes),
            '${_formatBytes(progress.bytesPerSecond.round())}/s',
          ].join(' · ');
    return Column(
      key: const ValueKey('update-state-downloading'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          key: const ValueKey('update-download-progress'),
          value: fraction,
        ),
        const SizedBox(height: 8),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildOutcome(BuildContext context, UpdateDownloadOutcome outcome) {
    final theme = Theme.of(context).textTheme;
    final errorColor = Theme.of(context).colorScheme.error;
    return switch (outcome) {
      UpdateDownloadCompleted() =>
        outcome.opened
            ? Text(
                '已保存到 ${outcome.path} 并已打开。',
                key: const ValueKey('update-state-completed'),
                style: theme.bodyMedium,
              )
            : Text(
                '已保存到 ${outcome.path}，但打开失败：${outcome.openError}',
                key: const ValueKey('update-state-open-failed'),
                style: theme.bodySmall?.copyWith(color: errorColor),
              ),
      UpdateDownloadIntegrityFailure() => Text(
        '更新包校验失败：sha256 不匹配，已阻止打开。',
        key: const ValueKey('update-state-integrity-failed'),
        style: theme.bodySmall?.copyWith(color: errorColor),
      ),
      UpdateDownloadDeclined() => Text(
        '已取消，安装包未保存。',
        key: const ValueKey('update-state-declined'),
        style: theme.bodySmall,
      ),
      UpdateDownloadFailed() => Text(
        '下载失败：${outcome.reason}',
        key: const ValueKey('update-state-download-failed'),
        style: theme.bodySmall?.copyWith(color: errorColor),
      ),
    };
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
