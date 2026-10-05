import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'download_panel.dart';
import 'model_downloader.dart';

class DownloadTasksPage extends StatelessWidget {
  const DownloadTasksPage({super.key, required this.downloads});

  final DownloadTaskController downloads;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const JevPageHeader(title: '下载任务'),
        Expanded(
          child: StreamBuilder<DownloadState>(
            stream: downloads.downloader.changes,
            initialData: downloads.downloader.state,
            builder: (context, snapshot) {
              final state = snapshot.data!;
              if (state.status == DownloadStatus.idle) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.download_outlined,
                        size: 32,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '暂无下载',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return ListView(children: [_task(context, state)]);
            },
          ),
        ),
      ],
    ),
  );

  Widget _task(BuildContext context, DownloadState state) {
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final failure = const {
      DownloadStatus.failed,
      DownloadStatus.conflict,
      DownloadStatus.restartRequired,
      DownloadStatus.interrupted,
    }.contains(state.status);
    return JevSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.view_in_ar_outlined,
                  size: 21,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.modelLabel ?? state.repositoryId ?? '模型包',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        state.repositoryId,
                        state.variantLabel,
                      ].whereType<String>().join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              JevStatusChip(
                label: _status(state.status),
                tone: failure
                    ? JevStatusTone.error
                    : state.status == DownloadStatus.installed
                    ? JevStatusTone.success
                    : JevStatusTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (state.isActive) ...[
            LinearProgressIndicator(
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
              value: state.totalBytes != null && state.totalBytes! > 0
                  ? (state.downloadedBytes / state.totalBytes!).clamp(0, 1)
                  : null,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Text(
                state.reusedExisting
                    ? '本地文件复用'
                    : state.source == DownloadSource.lmStudio
                    ? 'LM Studio 代理'
                    : 'HF 直连',
                style: secondary,
              ),
              const Spacer(),
              Text(
                '${_size(state.downloadedBytes)}${state.totalBytes == null ? '' : ' / ${_size(state.totalBytes!)}'}',
                style: secondary,
              ),
            ],
          ),
          if (state.currentFile != null && state.isActive) ...[
            const SizedBox(height: 8),
            Text(
              state.currentFile!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: secondary,
            ),
          ],
          if (state.libraryPath != null) ...[
            const SizedBox(height: 12),
            SelectableText(state.libraryPath!, style: secondary),
          ],
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Text(
              state.error!,
              style: secondary?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          if (state.isActive || _retryable(state.status)) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: state.isActive
                  ? OutlinedButton(
                      onPressed: downloads.downloader.cancel,
                      child: const Text('取消'),
                    )
                  : FilledButton(
                      onPressed: downloads.canRetry
                          ? () => downloads.retry(
                              restart:
                                  state.status ==
                                  DownloadStatus.restartRequired,
                            )
                          : null,
                      child: Text(
                        state.status == DownloadStatus.restartRequired
                            ? '重新下载'
                            : '重试',
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

bool _retryable(DownloadStatus status) => const {
  DownloadStatus.cancelled,
  DownloadStatus.interrupted,
  DownloadStatus.failed,
  DownloadStatus.restartRequired,
}.contains(status);

String _status(DownloadStatus status) => switch (status) {
  DownloadStatus.idle => '',
  DownloadStatus.downloading => '下载中',
  DownloadStatus.verifying => '校验中',
  DownloadStatus.installed => '已完成',
  DownloadStatus.cancelled => '已取消',
  DownloadStatus.interrupted => '已中断',
  DownloadStatus.restartRequired => '需要重启下载',
  DownloadStatus.conflict => '文件冲突',
  DownloadStatus.failed => '失败',
};

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
