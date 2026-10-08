import 'package:flutter/material.dart';

import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'engine_launch_configuration.dart';
import 'engine_launch_editor.dart';
import 'engine_runtime.dart';
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
  EngineLaunchCommand? _preview;
  bool _previewBlocked = false;
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
      final engineId = installed.firstOrNull?.id;
      _engineId = engineId;
      final preview = await _previewFor(engineId);
      if (!mounted) return;
      setState(() {
        _engineId = engineId;
        _preview = preview;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _previewBlocked = error is LaunchArgumentTextException;
          _loading = false;
        });
      }
    }
  }

  Future<EngineLaunchCommand?> _previewFor(String? engineId) async {
    if (engineId == null) return null;
    final entry = widget.catalog.state.entries.singleWhere(
      (entry) => entry.id == engineId,
    );
    if (entry.family != EngineFamily.llamaCpp) return null;
    final assets = widget.variant.artifacts
        .where(
          (asset) => [AssetKind.decision, AssetKind.chat].contains(asset.kind),
        )
        .toList();
    if (assets.length != 1) return null;
    return widget.catalog.providerFor(engineId).previewLaunch(assets.single.id);
  }

  Future<void> _selectEngine(String? engineId) async {
    setState(() {
      _engineId = engineId;
      _preview = null;
      _loading = true;
      _error = null;
      _previewBlocked = false;
    });
    try {
      final preview = await _previewFor(engineId);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _previewBlocked = error is LaunchArgumentTextException;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
          .where(
            (value) =>
                [AssetKind.decision, AssetKind.chat].contains(value.kind),
          )
          .toList();
      if (assets.length != 1 ||
          assets.single.integrity != AssetIntegrity.complete) {
        throw const LlamaEngineException('此变体缺少完整文本或决策 GGUF 资产');
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
          width: 580,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.modelPackage.name,
                  style: theme.textTheme.titleSmall,
                ),
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
                  onChanged: _working || _loading ? null : _selectEngine,
                ),
                if (_preview != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: EngineLaunchCommandView(command: _preview!),
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
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed:
                _working || _loading || _engineId == null || _previewBlocked
                ? null
                : _run,
            child: Text(_working ? '启动中' : '运行'),
          ),
        ],
      ),
    );
  }
}
