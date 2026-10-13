import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'download_panel.dart';
import 'model_downloader.dart';
import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'engine_source_build.dart';
import 'jev_debug.dart';
import 'llama_engine.dart';

class DownloadTasksPage extends StatelessWidget {
  const DownloadTasksPage({super.key, required this.downloads, this.engines});

  final DownloadTaskController downloads;
  final EngineCatalog? engines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const JevPageHeader(title: '下载'),
        Expanded(
          child: StreamBuilder<EngineCatalogState>(
            stream: engines?.changes,
            initialData: engines?.state,
            builder: (context, engineSnapshot) => StreamBuilder<DownloadState>(
              stream: downloads.downloader.changes,
              initialData: downloads.downloader.state,
              builder: (context, snapshot) {
                final state = snapshot.data!;
                final tasks = engines?.installationTasks ?? {};
                if (state.status == DownloadStatus.idle &&
                    tasks.isEmpty &&
                    engines?.sourceBuildProgress == null) {
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
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  );
                }
                final entries = tasks.entries.toList();
                final sourceTask = engines?.sourceBuildProgress != null;
                final modelTask = state.status != DownloadStatus.idle;
                final activeEngines = tasks.values
                    .where((task) => task.active)
                    .length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        '进行中：引擎 $activeEngines · 模型 ${state.isActive ? 1 : 0}'
                        '${engines?.sourceBuildActive == true ? ' · 源码构建 1' : ''}',
                        key: const Key('download-active-count'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount:
                            entries.length +
                            (sourceTask ? 1 : 0) +
                            (modelTask ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (sourceTask && index == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: _sourceTask(context, engines!),
                            );
                          }
                          final engineIndex = index - (sourceTask ? 1 : 0);
                          if (engineIndex == entries.length) {
                            return _task(context, state);
                          }
                          final task = entries[engineIndex];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: _engineTask(
                              context,
                              engineSnapshot.data!.entries.singleWhere(
                                (entry) => entry.id == task.key,
                              ),
                              task.value,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    ),
  );

  Widget _sourceTask(BuildContext context, EngineCatalog catalog) {
    final progress = catalog.sourceBuildProgress!;
    final request = catalog.sourceBuildRequest!;
    final logPath = catalog.sourceBuildLogPath;
    final phase = switch (progress.phase) {
      EngineSourceBuildPhase.validating => '检查工具',
      EngineSourceBuildPhase.cloning => '获取源码',
      EngineSourceBuildPhase.checkout => '选择版本',
      EngineSourceBuildPhase.configuring => '准备编译',
      EngineSourceBuildPhase.building => '编译中',
      EngineSourceBuildPhase.inspecting => '核验并登记',
      EngineSourceBuildPhase.complete => '已完成',
      EngineSourceBuildPhase.failed => '失败',
      EngineSourceBuildPhase.cancelled => '已取消',
    };
    final message =
        sealDebugJson({'message': progress.logText})['message'] as String;
    final summary = message.length > 1024
        ? message.substring(message.length - 1024)
        : message;
    return JevSurface(
      key: const Key('engine-source-task'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.build_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  request.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              JevStatusChip(
                label: phase,
                tone: progress.phase == EngineSourceBuildPhase.failed
                    ? JevStatusTone.error
                    : JevStatusTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(repositoryDisplayLabel(request.source)),
          if (catalog.sourceBuildActive) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            TextButton(
              onPressed: catalog.cancelSourceBuild,
              child: const Text('取消构建'),
            ),
          ],
          if (summary.isNotEmpty)
            Text(summary, maxLines: 4, overflow: TextOverflow.ellipsis),
          if (logPath != null) ...[
            SelectableText(logPath),
            TextButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('在 Finder 中显示'),
              onPressed: () async {
                try {
                  await const MethodChannel(
                    'com.ghost233.ghostmodeldeck/native',
                  ).invokeMethod<void>('revealInFinder', {'path': logPath});
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Finder 定位失败：$error')),
                    );
                  }
                }
              },
            ),
          ],
          if (!catalog.sourceBuildActive &&
              [
                EngineSourceBuildPhase.failed,
                EngineSourceBuildPhase.cancelled,
              ].contains(progress.phase))
            TextButton(
              onPressed: () {
                unawaited(
                  catalog
                      .buildFromSource(request)
                      .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
                );
              },
              child: const Text('重试构建'),
            ),
        ],
      ),
    );
  }

  Widget _engineTask(
    BuildContext context,
    EngineRegistration entry,
    EngineInstallProgress progress,
  ) {
    final label = switch (progress.phase) {
      EngineInstallPhase.downloading => '下载中',
      EngineInstallPhase.verifying => '校验中',
      EngineInstallPhase.unpacking => '安装中',
      EngineInstallPhase.complete => '已完成',
      EngineInstallPhase.cancelled => '已取消',
      EngineInstallPhase.failed => '失败',
    };
    return JevSurface(
      key: ValueKey('engine-download-${entry.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  engineDisplayName(entry),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              JevStatusChip(
                label: label,
                tone: progress.phase == EngineInstallPhase.failed
                    ? JevStatusTone.error
                    : JevStatusTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(engineSourceLabel(entry)),
          const SizedBox(height: 16),
          if (progress.active)
            LinearProgressIndicator(
              value:
                  progress.phase == EngineInstallPhase.downloading &&
                      progress.total > 0
                  ? (progress.received / progress.total).clamp(0, 1)
                  : null,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              Text('${_size(progress.received)} / ${_size(progress.total)}'),
              if (progress.phase == EngineInstallPhase.downloading) ...[
                if (progress.total > 0)
                  Text(
                    '${(100 * progress.received / progress.total).clamp(0, 100).toStringAsFixed(1)}%',
                  ),
                Text('平均速度：${_size(progress.bytesPerSecond.round())}/s'),
              ],
            ],
          ),
          if (progress.error != null)
            Text(
              progress.error!,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: progress.active
                ? OutlinedButton(
                    onPressed: () => engines!.cancelInstallation(entry.id),
                    child: const Text('取消'),
                  )
                : progress.phase == EngineInstallPhase.complete
                ? const SizedBox.shrink()
                : FilledButton(
                    onPressed: () async {
                      try {
                        await engines!.installManaged(entry.id);
                      } catch (_) {
                        /* State retains the original installation failure. */
                      }
                    },
                    child: const Text('重试'),
                  ),
          ),
        ],
      ),
    );
  }

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
