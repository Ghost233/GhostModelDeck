import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'llama_engine.dart';

class EnginePage extends StatefulWidget {
  const EnginePage({
    super.key,
    required this.catalog,
    required this.pickEngineDirectory,
  });
  final EngineCatalog catalog;
  final Future<String?> Function() pickEngineDirectory;
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
                Text(entry.name),
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
                if (entry.version != null) entry.version!,
                if (entry.path != null) entry.path!,
                if (entry.source == EngineSource.managed)
                  widget.catalog.officialEngine.release.url.toString(),
                if (entry.sha256 != null) 'SHA-256 ${entry.sha256}',
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

  @override
  Widget build(BuildContext context) => StreamBuilder<EngineCatalogState>(
    stream: widget.catalog.changes,
    initialData: widget.catalog.state,
    builder: (context, snapshot) {
      final state = snapshot.data!;
      final busy = _working || state.busy;
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
            child: Align(
              alignment: Alignment.topCenter,
              child: JevSurface(
                padding: EdgeInsets.zero,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: state.entries.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final entry = state.entries[index];
                    final linked = entry.source == EngineSource.linked;
                    final installed =
                        entry.status == LlamaInstallationStatus.installed;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.memory_outlined,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      engineDisplayName(entry),
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      entry.version == null
                                          ? 'b11381 · macOS arm64'
                                          : engineVersionLabel(entry.version),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              _status(context, entry),
                              const SizedBox(width: 12),
                              IconButton(
                                tooltip: '引擎详情',
                                onPressed: () => _details(entry),
                                icon: const Icon(Icons.info_outline, size: 18),
                              ),
                              const SizedBox(width: 8),
                              if (!linked && !installed)
                                FilledButton(
                                  onPressed: busy
                                      ? null
                                      : () => _run(
                                          () =>
                                              widget.catalog.installOfficial(),
                                        ),
                                  child: const Text('安装'),
                                ),
                              if (linked || installed)
                                TextButton(
                                  style: TextButton.styleFrom(
                                    foregroundColor: linked
                                        ? theme.colorScheme.onSurfaceVariant
                                        : theme.colorScheme.error,
                                  ),
                                  onPressed: busy ? null : () => _remove(entry),
                                  child: Text(linked ? '解除关联' : '删除'),
                                ),
                            ],
                          ),
                          if (entry.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                entry.error!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

Widget _status(BuildContext context, EngineRegistration entry) {
  final error = entry.status == LlamaInstallationStatus.failed;
  final text = switch (entry.status) {
    LlamaInstallationStatus.absent => '未安装',
    LlamaInstallationStatus.installing => '安装中',
    LlamaInstallationStatus.installed =>
      entry.source == EngineSource.linked ? '已关联' : '已安装',
    LlamaInstallationStatus.failed => '需要检查',
  };
  return JevStatusChip(
    label: text,
    tone: error ? JevStatusTone.error : JevStatusTone.neutral,
  );
}

String _size(int value) => value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)} KiB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
