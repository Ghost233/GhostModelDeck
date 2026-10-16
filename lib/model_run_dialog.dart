import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'splash_engine.dart';
import 'omlx_engine.dart';
import 'engine_launch_configuration.dart';
import 'engine_launch_editor.dart';
import 'model_launch_test.dart';
import 'engine_runtime.dart';
import 'llama_engine.dart';
import 'local_model_package.dart';
import 'model_library.dart';

Future<void> showModelRunDialog(
  BuildContext context, {
  required EngineCatalog catalog,
  required ModelLibrary library,
  required LocalModelPackage modelPackage,
  required LocalModelVariant variant,
}) => showDialog<void>(
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
    this.modelChoices,
    this.initialEngineId,
    this.initialConfiguration,
    this.initialName,
    this.onSaveInstance,
    this.contextPreview,
  });
  final EngineCatalog catalog;
  final ModelLibrary library;
  final LocalModelPackage modelPackage;
  final LocalModelVariant variant;
  final List<LibraryArtifact>? modelChoices;
  final String? initialEngineId;
  final EngineLaunchConfiguration? initialConfiguration;
  final String? initialName;
  final List<({String label, int? before, int? after})> Function(
    EngineLaunchConfiguration,
  )?
  contextPreview;
  final Future<void> Function(
    String name,
    String engineId,
    LibraryArtifact artifact,
    EngineLaunchConfiguration configuration,
  )?
  onSaveInstance;
  @override
  State<ModelRunDialog> createState() => _ModelRunDialogState();
}

class _ModelRunDialogState extends State<ModelRunDialog> {
  late LocalModelVariant _variant = widget.variant;
  late LocalModelPackage _package = widget.modelPackage;
  late final _instanceName = TextEditingController(
    text: widget.initialName ?? _package.name,
  );
  final _drafts = <String, EngineLaunchConfiguration>{};
  String? _engineId;
  String? _error;
  bool _working = false;
  bool _loading = true;
  int _impactPage = 0;
  EngineLaunchCommand? _preview;
  bool _previewBlocked = false;
  final _fields = <String, TextEditingController>{};
  final _argumentText = TextEditingController();
  EngineLaunchConfiguration? _defaults;
  DecisionCancellation? _testCancellation;
  String? _result;
  EngineLaunchConfiguration? get _draft => _defaults == null
      ? null
      : EngineLaunchConfiguration(
          family: _defaults!.family,
          formValues: {
            for (final entry in _fields.entries)
              if (entry.value.text.isNotEmpty) entry.key: entry.value.text,
          },
          argumentText: _argumentText.text,
        );

  void _loadDraft(String? engineId) {
    for (final field in _fields.values) {
      field.dispose();
    }
    _fields.clear();
    final asset = _configurationAsset;
    _defaults = engineId == null
        ? null
        : widget.catalog.launchDefaultsFor(engineId);
    if (_defaults == null || asset == null) return;
    final config =
        _drafts['$engineId/${asset.id}'] ??
        (widget.initialEngineId == engineId && widget.variant.id == _variant.id
            ? widget.initialConfiguration
            : null) ??
        (widget.onSaveInstance == null
            ? widget.catalog.launchConfigurationFor(engineId!, asset.id)
            : _defaults!);
    for (final name in EngineLaunchConfiguration.labelsFor(
      config.family,
    ).keys) {
      _fields[name] = TextEditingController(
        text: config.formValues[name] ?? '',
      );
    }
    _argumentText.text = config.argumentText;
    _result = null;
  }

  @override
  void dispose() {
    unawaited(_catalogChanges?.cancel());
    _testCancellation?.cancel();
    _instanceName.dispose();
    _argumentText.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  LibraryArtifact? get _configurationAsset => _variant.artifacts
      .where((asset) => ['GGUF', 'Safetensors'].contains(asset.format))
      .singleOrNull;
  StreamSubscription<EngineCatalogState>? _catalogChanges;

  @override
  void initState() {
    super.initState();
    _catalogChanges = widget.catalog.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      if (widget.onSaveInstance == null) await widget.catalog.refresh();
      if (!mounted) return;
      final installed = widget.catalog.state.entries
          .where((value) => value.status == LlamaInstallationStatus.installed)
          .toList();
      final preferred =
          widget.initialEngineId ??
          (_configurationAsset == null
              ? null
              : widget.catalog.preferredEngineFor(_configurationAsset!.id));
      final engineId =
          installed.where((e) => e.id == preferred).firstOrNull?.id ??
          installed.firstOrNull?.id;
      _engineId = engineId;
      _loadDraft(engineId);
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
    final assets = _variant.artifacts
        .where((asset) => ['GGUF', 'Safetensors'].contains(asset.format))
        .toList();
    if (assets.length != 1) return null;
    if (entry.family == EngineFamily.splash) {
      return (widget.catalog.runtimeFor(engineId) as SplashEngine)
          .previewLaunch(assets.single.id, configuration: _draft);
    }
    if (entry.family == EngineFamily.omlx) {
      return (widget.catalog.runtimeFor(engineId) as OmlxEngine).previewLaunch(
        _draft!,
        sourceBundle: Directory(entry.path!),
        recognition: widget.catalog.parameterRecognitionFor(engineId),
      );
    }
    return widget.catalog
        .providerFor(engineId)
        .previewLaunch(assets.single.id, configuration: _draft);
  }

  Future<void> _selectEngine(String? engineId) async {
    if (_engineId != null && _configurationAsset != null && _draft != null) {
      _drafts['$_engineId/${_configurationAsset!.id}'] = _draft!;
    }
    setState(() {
      _engineId = engineId;
      _preview = null;
      _loading = true;
      _error = null;
      _previewBlocked = false;
    });
    _previewGeneration++;
    _loadDraft(engineId);
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

  Future<void> _submit({required bool test}) async {
    final id = _engineId;
    final asset = _configurationAsset;
    final draft = _draft;
    if (_working || _loading || id == null || asset == null || draft == null) {
      return;
    }
    setState(() {
      _working = true;
      _error = null;
      _result = null;
    });
    try {
      if (test) draft.validateArgumentText();
      if (test) {
        _testCancellation = DecisionCancellation();
        final result = await testModelLaunch(
          catalog: widget.catalog,
          engineId: id,
          artifact: asset,
          configuration: draft,
          cancellation: _testCancellation!,
        );
        if (mounted) setState(() => _result = result);
      } else if (widget.onSaveInstance != null) {
        await widget.onSaveInstance!(_instanceName.text, id, asset, draft);
        if (mounted) Navigator.pop(context);
      } else {
        if (_defaults!.argumentText == draft.argumentText &&
            EngineLaunchConfiguration.labelsFor(draft.family).keys.every(
              (key) =>
                  (_defaults!.formValues[key] ?? '') ==
                  (_fields[key]?.text ?? ''),
            )) {
          await widget.catalog.setModelLaunchMode(
            id,
            asset.id,
            independent: false,
            preferEngine: true,
          );
        } else {
          await widget.catalog.saveModelLaunchOverrides(
            id,
            asset.id,
            draft,
            preferEngine: true,
          );
        }
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _testCancellation = null;
      if (mounted) setState(() => _working = false);
    }
  }

  int _previewGeneration = 0;
  Future<void> _updatePreview() async {
    final generation = ++_previewGeneration;
    setState(() {});
    try {
      final preview = await _previewFor(_engineId);
      if (mounted && generation == _previewGeneration) {
        setState(() {
          _preview = preview;
          _previewBlocked = false;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _previewGeneration) {
        setState(() {
          _preview = null;
          _error = error.toString();
          _previewBlocked = error is LaunchArgumentTextException;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = widget.catalog.state.entries
        .where((value) => value.status == LlamaInstallationStatus.installed)
        .toList();
    final asset = _configurationAsset;
    final impact = _draft == null || _previewBlocked
        ? const <({String label, int? before, int? after})>[]
        : widget.contextPreview?.call(_draft!) ??
              const <({String label, int? before, int? after})>[];
    final impactPages = (impact.length / 5).ceil();
    final impactPage = _impactPage.clamp(
      0,
      impactPages == 0 ? 0 : impactPages - 1,
    );
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        title: Text(widget.onSaveInstance == null ? '运行模型' : '实例配置'),
        insetPadding: const EdgeInsets.all(24),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          height: (MediaQuery.sizeOf(context).height - 220)
              .clamp(260, 720)
              .toDouble(),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.onSaveInstance != null) ...[
                          TextField(
                            key: const Key('launch-instance-name'),
                            controller: _instanceName,
                            enabled: !_working,
                            decoration: const InputDecoration(
                              labelText: '实例名称',
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: _configurationAsset?.id,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: '模型'),
                            items: [
                              for (final model
                                  in widget.modelChoices ?? <LibraryArtifact>[])
                                DropdownMenuItem(
                                  value: model.id,
                                  child: Text(
                                    model.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _working
                                ? null
                                : (id) async {
                                    if (id == null) return;
                                    final asset = widget.modelChoices!
                                        .singleWhere((a) => a.id == id);
                                    setState(() {
                                      _variant = LocalModelVariant(
                                        id: asset.id,
                                        label:
                                            '${asset.format} · ${asset.quantization ?? ''}',
                                        artifacts: [asset],
                                      );
                                      _package = LocalModelPackage(
                                        directoryPath: File(
                                          asset.files.first.path,
                                        ).parent.path,
                                        name: asset.name,
                                        variants: [_variant],
                                        details: [],
                                      );
                                    });
                                    await _selectEngine(_engineId);
                                  },
                          ),
                          const SizedBox(height: 12),
                        ],
                        Text(_package.name, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(_variant.label, style: theme.textTheme.bodySmall),
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
                              : _selectEngine,
                        ),
                        if (_defaults != null) ...[
                          const SizedBox(height: 20),
                          if (impact.isNotEmpty) ...[
                            const Text('容量预览（重启生效）'),
                            for (final change
                                in impact.skip(impactPage * 5).take(5))
                              Text(
                                '${change.label}：${change.before ?? '未指定'} → ${change.after ?? '未指定'}',
                                key: ValueKey(
                                  'context-preview:${change.label}',
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (impactPages > 1)
                              Row(
                                children: [
                                  TextButton(
                                    onPressed: impactPage == 0
                                        ? null
                                        : () => setState(
                                            () => _impactPage = impactPage - 1,
                                          ),
                                    child: const Text('上一页'),
                                  ),
                                  Text('${impactPage + 1} / $impactPages'),
                                  TextButton(
                                    onPressed: impactPage + 1 == impactPages
                                        ? null
                                        : () => setState(
                                            () => _impactPage = impactPage + 1,
                                          ),
                                    child: const Text('下一页'),
                                  ),
                                ],
                              ),
                            const Text('保存只更新待应用参数；成功重启后更新关联容量。'),
                            const SizedBox(height: 12),
                          ],
                          for (final field
                              in EngineLaunchConfiguration.labelsFor(
                                _defaults!.family,
                              ).entries)
                            Padding(
                              key: ValueKey(
                                'engine-parameter-form:${field.key}',
                              ),
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      key: ValueKey(
                                        'model-parameter:${field.key}',
                                      ),
                                      controller: _fields[field.key],
                                      enabled: !_working,
                                      onChanged: (_) => _updatePreview(),
                                      decoration: InputDecoration(
                                        labelText: field.value,
                                        helperText: field.key,
                                        errorText:
                                            _preview?.overriddenForm.contains(
                                                  field.key,
                                                ) ==
                                                true
                                            ? '已被文本覆盖'
                                            : null,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 110,
                                    child:
                                        _fields[field.key]!.text !=
                                            (_defaults!.formValues[field.key] ??
                                                '')
                                        ? TextButton(
                                            onPressed: _working
                                                ? null
                                                : () {
                                                    _fields[field.key]!.text =
                                                        _defaults!
                                                            .formValues[field
                                                            .key] ??
                                                        '';
                                                    _updatePreview();
                                                  },
                                            child: const Text('override ↶'),
                                          )
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('engine-argument-text'),
                                  controller: _argumentText,
                                  enabled: !_working,
                                  minLines: 2,
                                  maxLines: 6,
                                  onChanged: (_) => _updatePreview(),
                                  decoration: InputDecoration(
                                    labelText: '启动参数文本',
                                    helperText: '文本优先；保留未知参数、引号与重复参数。',
                                    errorText: _previewBlocked ? _error : null,
                                    errorMaxLines: 3,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child:
                                    _argumentText.text !=
                                        _defaults!.argumentText
                                    ? TextButton(
                                        onPressed: _working
                                            ? null
                                            : () {
                                                _argumentText.text =
                                                    _defaults!.argumentText;
                                                _updatePreview();
                                              },
                                        child: const Text('override ↶'),
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ],
                        if (entries.isEmpty && !_loading)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text('请先安装或关联引擎'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 20),
              if (_preview != null)
                SizedBox(
                  height: 130,
                  child: SingleChildScrollView(
                    child: EngineLaunchCommandView(command: _preview!),
                  ),
                ),
              if (_working || _loading)
                const LinearProgressIndicator(minHeight: 2),
              if ((_error != null && !_previewBlocked) || _result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error ?? _result!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _error == null ? null : theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _working
                ? (_testCancellation == null
                      ? null
                      : () => _testCancellation!.cancel())
                : () => Navigator.pop(context),
            child: Text(_working ? '取消测试' : '取消'),
          ),
          OutlinedButton(
            onPressed:
                _working ||
                    _loading ||
                    _engineId == null ||
                    _previewBlocked ||
                    !widget.catalog.runtimeEnabled
                ? null
                : () => _submit(test: true),
            child: const Text('测试运行'),
          ),
          FilledButton(
            onPressed: _working || _loading || _draft == null || asset == null
                ? null
                : () => _submit(test: false),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
