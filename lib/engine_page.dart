import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'management_table.dart';
import 'engine_launch_editor.dart';
import 'engine_runtime.dart';
import 'engine_source_dialog.dart';
import 'omlx_engine.dart';
import 'llama_engine.dart';

class EnginePage extends StatefulWidget {
  const EnginePage({
    super.key,
    required this.catalog,
    required this.pickEngineDirectory,
    this.onDownloadStarted,
  });
  final EngineCatalog catalog;
  final Future<String?> Function() pickEngineDirectory;
  final VoidCallback? onDownloadStarted;
  @override
  State<EnginePage> createState() => _EnginePageState();
}

class _EnginePageState extends State<EnginePage> {
  String? _error;
  bool _working = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run(widget.catalog.refresh);
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _link() async {
    final path = await widget.pickEngineDirectory();
    if (path != null) {
      await _run(() async {
        await widget.catalog.link(path);
      });
    }
  }

  Future<void> _buildSource() async {
    final started = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EngineSourceDialog(catalog: widget.catalog),
    );
    if (started == true && mounted) widget.onDownloadStarted?.call();
  }

  void _install(EngineRegistration entry) {
    unawaited(
      widget.catalog.installManaged(entry.id).catchError((Object error) {
        if (mounted) setState(() => _error = error.toString());
      }),
    );
    widget.onDownloadStarted?.call();
  }

  void _redownload(EngineRegistration entry) {
    try {
      widget.catalog.assertRedownloadable(entry.id);
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    unawaited(
      widget.catalog.redownloadManaged(entry.id).catchError((Object error) {
        if (mounted) setState(() => _error = error.toString());
      }),
    );
    widget.onDownloadStarted?.call();
  }

  Future<void> _configure(EngineRegistration entry) async {
    try {
      await widget.catalog.readParameters(entry.id);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => EngineLaunchEditor(
        title: '${engineDisplayName(entry)} · 启动参数',
        initialConfiguration: widget.catalog.launchDefaultsFor(entry.id),
        executable: entry.splashInstallation?.python.path ?? entry.path,
        recognition: widget.catalog.parameterRecognitionFor(entry.id),
        onSave: (configuration) =>
            widget.catalog.saveLaunchDefaults(entry.id, configuration),
      ),
    );
  }

  Future<void> _remove(EngineRegistration entry) async {
    await _run(() async {
      final plan = await widget.catalog.prepareRemoval(entry.id);
      if (!mounted) return;
      final linked = entry.source == EngineSource.linked;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(linked ? '解除引擎关联' : '删除受管引擎'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(engineDisplayName(entry)),
                const SizedBox(height: 12),
                if (linked)
                  Text(entry.path ?? '')
                else ...[
                  Text('${plan.paths.length} 个文件 · ${_size(plan.sizeBytes)}'),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(plan.paths.join('\n')),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(linked ? '解除关联' : '删除'),
            ),
          ],
        ),
      );
      await widget.catalog.remove(plan, confirmed: confirmed == true);
    });
  }

  void _details(EngineRegistration entry) {
    final sourceBuild = entry.sourceBuild;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(engineDisplayName(entry)),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: SelectableText(
              [
                engineSourceLabel(entry),
                if (sourceBuild != null) ...[
                  '来源地址 ${sourceBuild['source']}',
                  '请求版本 ${sourceBuild['requested_ref'] ?? '仓库默认版本'}',
                  '实际提交 ${sourceBuild['commit']}',
                  '构建日志 ${sourceBuild['log_path']}',
                ],
                if (entry.family == EngineFamily.omlx) ...[
                  OmlxEngine.artifactUrl,
                  if (entry.omlxReceipt != null) ...[
                    '发行标签 ${entry.omlxReceipt!.releaseLabel} · app 构建 ${entry.omlxReceipt!.build}',
                    'DMG SHA-256 ${entry.omlxReceipt!.dmgSha256 ?? '本地关联：未验证发行 DMG'}',
                    'Bundle 清单 SHA-256 ${entry.omlxReceipt!.bundleManifestSha256}',
                    'Python ${entry.omlxReceipt!.runtimeIdentity.python} · ${entry.omlxReceipt!.runtimeIdentity.architecture}',
                  ],
                ],
                if (entry.version != null) entry.version!,
                if (entry.path != null) entry.path!,
                if (entry.release != null) ...[
                  '发行标签 ${entry.release!.tag}',
                  '归档 ${entry.release!.archiveRoot} · 构建 ${entry.release!.buildNumber}',
                  '提交 ${entry.release!.commit}',
                  entry.release!.url.toString(),
                ],
                if (entry.archiveSha256 != null)
                  '归档 SHA-256 ${entry.archiveSha256}',
                if (entry.binarySha256 != null)
                  '可执行文件 SHA-256 ${entry.binarySha256}',
                '安装 ID ${entry.installationId}',
              ].join('\n\n'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _tableActions(EngineRegistration entry, bool busy) {
    final linked = entry.source == EngineSource.linked;
    final installed = entry.status == LlamaInstallationStatus.installed;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          key: ValueKey('engine-details:${entry.id}'),
          tooltip: '引擎详情',
          onPressed: () => _details(entry),
          icon: const Icon(Icons.info_outline, size: 18),
        ),
        IconButton(
          key: ValueKey('engine-parameters:${entry.id}'),
          tooltip: '启动参数',
          onPressed: busy ? null : () => _configure(entry),
          icon: const Icon(Icons.tune, size: 18),
        ),
        if (entry.status == LlamaInstallationStatus.installing &&
            widget.onDownloadStarted != null)
          OutlinedButton(
            onPressed: widget.onDownloadStarted,
            child: const Text('查看下载'),
          )
        else if (!linked && !installed)
          FilledButton(
            onPressed:
                busy || entry.status == LlamaInstallationStatus.installing
                ? null
                : () => _install(entry),
            child: Text(
              entry.status == LlamaInstallationStatus.installing ? '安装中' : '安装',
            ),
          ),
        if (!linked &&
            (installed || entry.status == LlamaInstallationStatus.failed))
          TextButton(
            onPressed:
                busy || entry.status == LlamaInstallationStatus.installing
                ? null
                : () => _redownload(entry),
            child: const Text('重新下载'),
          ),
        if (linked || installed)
          PopupMenuButton<String>(
            key: ValueKey('engine-more:${entry.id}'),
            tooltip: '更多',
            enabled: !busy,
            onSelected: (_) => _remove(entry),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'remove',
                child: Text(linked ? '解除关联' : '删除'),
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<EngineCatalogState>(
    stream: widget.catalog.changes,
    initialData: widget.catalog.state,
    builder: (context, snapshot) {
      final state = snapshot.data!;
      final busy = _working || state.busy;
      final entries = state.entries
          .where(
            (entry) =>
                ![EngineCatalog.embeddingId].contains(entry.id) ||
                entry.status != LlamaInstallationStatus.absent,
          )
          .toList();
      final showSplash = !entries.any(
        (entry) => entry.family == EngineFamily.splash,
      );
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JevPageHeader(
            title: '引擎管理',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '刷新引擎',
                  onPressed: busy ? null : () => _run(widget.catalog.refresh),
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: busy ? null : _link,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('关联引擎'),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: widget.catalog.sourceBuilder == null
                      ? '源码构建服务尚未准备'
                      : '从本地仓库或 GitHub 构建新的引擎',
                  child: OutlinedButton.icon(
                    key: const Key('engine-source-open'),
                    onPressed: busy || widget.catalog.sourceBuilder == null
                        ? null
                        : _buildSource,
                    icon: const Icon(Icons.build_outlined, size: 18),
                    label: const Text('从 Git 构建'),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null || state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _error ?? state.error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ManagementTable<EngineRegistration?>(
              id: 'engines',
              items: [...entries, if (showSplash) null],
              rowKey: (entry) => entry?.id ?? 'splash-unlinked',
              searchText: (entry) => entry == null
                  ? 'Splash incoai/splash'
                  : '${engineDisplayName(entry)} ${engineSourceLabel(entry)} ${entry.version ?? entry.release?.tag ?? ''}',
              status: (entry) => entry == null ? '未关联' : _statusLabel(entry),
              columns: [
                ManagementColumn(
                  label: '引擎名',
                  minWidth: 170,
                  flex: 2,
                  compare: (a, b) =>
                      (a == null ? 'Splash' : engineDisplayName(a)).compareTo(
                        b == null ? 'Splash' : engineDisplayName(b),
                      ),
                  cell: (entry) {
                    if (entry == null) return const Text('Splash');
                    final notice =
                        entry.error ??
                        widget.catalog.configurationVersionNoticeFor(entry.id);
                    return Tooltip(
                      message: notice ?? engineDisplayName(entry),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            engineDisplayName(entry),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (notice != null)
                            Text(
                              notice,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: entry.error == null
                                    ? null
                                    : theme.colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                ManagementColumn(
                  label: '仓库或本地路径',
                  minWidth: 220,
                  flex: 3,
                  compare: (a, b) =>
                      (a == null ? 'incoai/splash' : engineSourceLabel(a))
                          .compareTo(
                            b == null ? 'incoai/splash' : engineSourceLabel(b),
                          ),
                  cell: (entry) {
                    final source = entry == null
                        ? 'incoai/splash'
                        : engineSourceLabel(entry);
                    return Tooltip(
                      message: source,
                      child: Text(
                        source,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
                ManagementColumn(
                  label: '版本',
                  minWidth: 160,
                  compare: (a, b) => (a?.version ?? a?.release?.tag ?? '')
                      .compareTo(b?.version ?? b?.release?.tag ?? ''),
                  cell: (entry) => Text(
                    entry == null
                        ? '—'
                        : entry.version == null
                        ? '${entry.release?.tag ?? '未知版本'} · macOS arm64'
                        : engineVersionLabel(entry.version),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ManagementColumn(
                  label: '状态',
                  minWidth: 150,
                  flex: 0,
                  compare: (a, b) => (a == null ? '未关联' : _statusLabel(a))
                      .compareTo(b == null ? '未关联' : _statusLabel(b)),
                  cell: (entry) => entry == null
                      ? const JevStatusChip(
                          label: '未关联',
                          tone: JevStatusTone.neutral,
                        )
                      : _status(context, entry),
                ),
                ManagementColumn(
                  label: '操作',
                  minWidth: 280,
                  flex: 0,
                  cell: (entry) => entry == null
                      ? OutlinedButton(
                          onPressed: busy ? null : _link,
                          child: const Text('关联'),
                        )
                      : _tableActions(entry, busy),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

Widget _status(BuildContext context, EngineRegistration entry) {
  final error = entry.status == LlamaInstallationStatus.failed;
  final text = _statusLabel(entry);
  return JevStatusChip(
    label: text,
    tone: error ? JevStatusTone.error : JevStatusTone.neutral,
  );
}

String _statusLabel(EngineRegistration entry) => switch (entry.status) {
  LlamaInstallationStatus.absent => '未安装',
  LlamaInstallationStatus.installing => '安装中',
  LlamaInstallationStatus.installed =>
    entry.source == EngineSource.linked ? '已关联' : '已安装',
  LlamaInstallationStatus.failed => '需要检查',
};

String _size(int value) => value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)} KiB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
