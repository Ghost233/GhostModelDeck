import 'package:flutter/material.dart';

import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'llama_engine.dart';
import 'local_model_package.dart';
import 'model_library.dart';

Future<LlamaInstance?> showModelRunDialog(
  BuildContext context, {
  required EngineCatalog catalog,
  required ModelLibrary library,
  required LocalModelPackage modelPackage,
  required LocalModelVariant variant,
}) => showDialog<LlamaInstance>(
  context: context,
  barrierDismissible: true,
  builder: (_) => ModelRunDialog(
    catalog: catalog,
    library: library,
    modelPackage: modelPackage,
    variant: variant,
  ),
);

class ModelRunDialog extends StatefulWidget {
  const ModelRunDialog({
    super.key,
    required this.catalog,
    required this.library,
    required this.modelPackage,
    required this.variant,
  });
  final EngineCatalog catalog;
  final ModelLibrary library;
  final LocalModelPackage modelPackage;
  final LocalModelVariant variant;
  @override
  State<ModelRunDialog> createState() => _ModelRunDialogState();
}

class _ModelRunDialogState extends State<ModelRunDialog> {
  String? _engineId;
  String? _error;
  bool _working = false;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await widget.catalog.refresh();
      if (!mounted) return;
      final installed = widget.catalog.state.entries
          .where((value) => value.status == LlamaInstallationStatus.installed)
          .toList();
      setState(() {
        _engineId = installed.firstOrNull?.id;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _run() async {
    if (_engineId == null || _working || _loading) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final assets = (await widget.library.verify(widget.variant.artifactIds))
          .where((value) => value.kind == AssetKind.decision)
          .toList();
      if (assets.length != 1 ||
          assets.single.integrity != AssetIntegrity.complete) {
        throw const LlamaEngineException('此变体缺少完整决策资产');
      }
      final instance = await widget.catalog
          .providerFor(_engineId!)
          .start(assets.single.id);
      if (mounted) Navigator.pop(context, instance);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = widget.catalog.state.entries
        .where((value) => value.status == LlamaInstallationStatus.installed)
        .toList();
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        title: const Text('运行模型'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.modelPackage.name, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(widget.variant.label, style: theme.textTheme.bodySmall),
              const SizedBox(height: 24),
              DropdownButtonFormField<String>(
                key: ValueKey(_loading),
                initialValue: _engineId,
                isExpanded: true,
                itemHeight: 58,
                decoration: const InputDecoration(
                  labelText: '推理引擎',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
                selectedItemBuilder: (context) => [
                  for (final entry in entries)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${engineDisplayName(entry)} · ${engineVersionLabel(entry.version)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                ],
                items: [
                  for (final entry in entries)
                    DropdownMenuItem(
                      value: entry.id,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            engineDisplayName(entry),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${engineVersionLabel(entry.version)} · ${engineSourceLabel(entry)}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: _working || _loading
                    ? null
                    : (value) => setState(() => _engineId = value),
              ),
              if (entries.isEmpty && !_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('请先安装或关联引擎'),
                ),
              if (_working || _loading)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _working || _loading || _engineId == null ? null : _run,
            child: Text(_working ? '启动中' : '运行'),
          ),
        ],
      ),
    );
  }
}
