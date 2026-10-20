import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'engine_catalog.dart';
import 'engine_labels.dart';
import 'splash_engine.dart';
import 'omlx_engine.dart';
import 'engine_launch_configuration.dart';
import 'engine_launch_editor.dart';
import 'parameter_editor.dart';
import 'generation_configuration.dart';
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
    this.initialSplashAssembly,
    this.initialInstanceId,
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
  final String? initialInstanceId;
  final Directory? initialSplashAssembly;
  final List<({String label, int? before, int? after})> Function(
    EngineLaunchConfiguration, {
    int? Function()? resolvedContext,
  })?
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
  bool _testing = false;
  bool _loading = true;
  EngineLaunchCommand? _preview;
  bool _previewBlocked = false;
  final _formValues = <String, String>{};
  Map<String, Object?> _generationValues = {};
  String? _generationError;
  EngineLaunchConfiguration? _baseline;
  final _argumentText = TextEditingController();
  DrafterConfiguration? _drafter;
  bool _legacyDrafter = false;
  EngineLaunchConfiguration? _defaults;
  DecisionCancellation? _testCancellation;
  String? _result;
  EngineLaunchConfiguration? get _draft {
    if (_defaults == null) return null;
    GenerationConfiguration generation;
    try {
      generation = GenerationConfiguration.fromJson(_generationValues);
      generation.nativeValues(splash: _defaults!.family == EngineFamily.splash);
      _generationError = null;
    } on FormatException catch (error) {
      _generationError = error.message;
      generation =
          _baseline?.generation ?? const GenerationConfiguration.empty();
    }
    return EngineLaunchConfiguration(
      family: _defaults!.family,
      formValues: _formValues,
      argumentText: _argumentText.text,
      drafter: _drafter,
      generation: generation,
    );
  }

  void _loadDraft(String? engineId) {
    _formValues.clear();
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
    _formValues.addAll(config.formValues);
    _generationValues = Map<String, Object?>.from(config.generation.values);
    _baseline = config;
    _argumentText.text = config.argumentText;
    _drafter = config.drafter ?? config.legacyLlamaDrafter;
    _legacyDrafter =
        config.drafter == null && config.legacyLlamaDrafter != null;
    _result = null;
  }

  @override
  void dispose() {
    unawaited(_catalogChanges?.cancel());
    _testCancellation?.cancel();
    _instanceName.dispose();
    _argumentText.dispose();
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
      if (engineId != null) await widget.catalog.readParameters(engineId);
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
      final runtime = widget.catalog.runtimeFor(engineId) as SplashEngine;
      if (_drafter == null) {
        final migrated = await runtime.drafterConfigurationFor(
          assets.single.id,
          previous:
              widget.initialEngineId == engineId &&
                  widget.variant.id == _variant.id
              ? widget.initialSplashAssembly
              : null,
        );
        if (!mounted ||
            _engineId != engineId ||
            _configurationAsset?.id != assets.single.id) {
          return null;
        }
        _drafter = migrated;
        _legacyDrafter = migrated.enabled;
      }
      return runtime.previewLaunch(assets.single.id, configuration: _draft);
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

  Future<void> _selectEngine(
    String? engineId, {
    bool rememberCurrent = true,
  }) async {
    if (_generationError != null) {
      setState(() => _error = _generationError);
      return;
    }
    if (rememberCurrent &&
        _engineId != null &&
        _configurationAsset != null &&
        _draft != null) {
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
      if (engineId != null) await widget.catalog.readParameters(engineId);
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
    if (_working ||
        _loading ||
        id == null ||
        asset == null ||
        draft == null ||
        _generationError != null) {
      return;
    }
    setState(() {
      _working = true;
      _testing = test;
      _error = null;
      _result = null;
    });
    try {
      if (_legacyDrafter) {
        throw StateError('旧草稿绑定待修复：请重新选择本地来源，或关闭草稿模型');
      }
      if (draft.drafter != null) {
        DrafterConfiguration.fromJson(draft.drafter!.toJson());
      }
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
        if (draft.drafter == null &&
            draft.generation.values.isEmpty &&
            draft.loadingIdentity == _defaults!.loadingIdentity) {
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
      if (mounted) {
        setState(() {
          _working = false;
          _testing = false;
        });
      }
    }
  }

  int _previewGeneration = 0;
  Future<void> _selectModel(String id) async {
    if (_generationError != null) {
      setState(() => _error = _generationError);
      return;
    }
    final current = _configurationAsset;
    if (_engineId != null && current != null && _draft != null) {
      _drafts['$_engineId/${current.id}'] = _draft!;
    }
    final asset = widget.modelChoices!.singleWhere((a) => a.id == id);
    setState(() {
      _variant = LocalModelVariant(
        id: asset.id,
        label: '${asset.format} · ${asset.quantization ?? ''}',
        artifacts: [asset],
      );
      _package = LocalModelPackage(
        directoryPath: File(asset.files.first.path).parent.path,
        name: asset.name,
        variants: [_variant],
        details: [],
      );
    });
    await _selectEngine(_engineId, rememberCurrent: false);
  }

  Future<void> _checkDrafter() async {
    final engineId = _engineId;
    final asset = _configurationAsset;
    final configuration = _draft;
    if (_working ||
        engineId == null ||
        asset == null ||
        configuration == null) {
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (_legacyDrafter) {
        throw StateError('旧草稿绑定待修复：请重新选择本地来源，或关闭草稿模型');
      }
      _testCancellation = DecisionCancellation();
      final runtime = widget.catalog.runtimeFor(engineId);
      if (runtime is SplashEngine) {
        await runtime.prepareModelBinding(
          asset.id,
          configuration: configuration,
          cancellation: _testCancellation,
        );
      } else if (runtime is LlamaEngine) {
        await runtime.checkDrafterFiles(asset.id, configuration);
        if (_testCancellation!.isCancelled) throw StateError('草稿文件检查已取消');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _testCancellation = null;
      if (mounted) setState(() => _working = false);
    }
  }

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
        .where((e) => e.status == LlamaInstallationStatus.installed)
        .toList();
    final asset = _configurationAsset;
    final draft = _draft;
    final entry = entries.where((e) => e.id == _engineId).firstOrNull;
    final runtime = entry == null ? null : widget.catalog.runtimeFor(entry.id);
    final activeRuntime = widget.initialInstanceId == null
        ? null
        : widget.catalog.runningOwnerFor(widget.initialInstanceId!);
    final check = asset == null || draft == null
        ? null
        : runtime is SplashEngine
        ? runtime.drafterCheckFor(asset.id, draft)
        : runtime is LlamaEngine
        ? runtime.drafterCheckFor(asset.id, draft)
        : null;
    final impact = draft == null || _previewBlocked
        ? const <({String label, int? before, int? after})>[]
        : widget.contextPreview?.call(
                draft,
                resolvedContext: () => entry == null
                    ? null
                    : widget.catalog.contextLengthForConfiguration(
                        entry.id,
                        draft,
                      ),
              ) ??
              const <({String label, int? before, int? after})>[];
    final busy = _working || _loading;
    final decisionModel = [
      'kev',
      'vllm-d3',
      'laya',
    ].contains(asset?.decisionType);
    final choices = widget.modelChoices;
    return PopScope(
      canPop: !_working,
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1160,
          height: (MediaQuery.sizeOf(context).height - 72)
              .clamp(400, 850)
              .toDouble(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.onSaveInstance == null ? '运行模型' : '实例配置',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (_loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 15),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.onSaveInstance != null) ...[
                      Expanded(
                        child: TextField(
                          key: const Key('launch-instance-name'),
                          controller: _instanceName,
                          enabled: !busy,
                          decoration: const InputDecoration(labelText: '实例名称'),
                        ),
                      ),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('instance-engine:$_engineId'),
                        initialValue: _engineId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '推理引擎'),
                        itemHeight: 58,
                        selectedItemBuilder: (context) => [
                          for (final e in entries)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${engineDisplayName(e)} · ${engineVersionLabel(e.version)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                        ],
                        items: [
                          for (final e in entries)
                            DropdownMenuItem(
                              value: e.id,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    engineDisplayName(e),
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${engineVersionLabel(e.version)} · ${engineSourceLabel(e)}',
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (id) => unawaited(_selectEngine(id)),
                      ),
                    ),
                    if (choices != null && choices.isNotEmpty) ...[
                      const SizedBox(width: 14),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('instance-model:${asset?.id}'),
                          initialValue: choices.any((a) => a.id == asset?.id)
                              ? asset?.id
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '目标模型'),
                          items: [
                            for (final a in choices)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  a.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (id) {
                                  if (id != null) unawaited(_selectModel(id));
                                },
                        ),
                      ),
                    ],
                  ],
                ),
                if (choices == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: Text(
                      '${_package.name} · ${_variant.label}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 15),
                Expanded(
                  child: draft == null || asset == null
                      ? Center(child: Text(_loading ? '正在读取配置…' : '请先安装或关联引擎'))
                      : ParameterEditor(
                          key: ValueKey(
                            'parameter-editor:$_engineId/${asset.id}',
                          ),
                          family: draft.family,
                          formValues: _formValues,
                          initialFormValues: _baseline?.formValues ?? const {},
                          generationValues: _generationValues,
                          initialGenerationValues:
                              _baseline?.generation.values ?? const {},
                          drafter: _drafter,
                          initialDrafter: _baseline?.drafter,
                          check: check,
                          actualDrafter: widget.initialInstanceId == null
                              ? null
                              : activeRuntime is SplashEngine
                              ? activeRuntime.actualDrafterFor(
                                  widget.initialInstanceId!,
                                )
                              : activeRuntime is LlamaEngine
                              ? activeRuntime.actualDrafterFor(
                                  widget.initialInstanceId!,
                                )
                              : null,
                          actualCompact:
                              widget.initialInstanceId == null ||
                                  activeRuntime is! SplashEngine
                              ? null
                              : activeRuntime.actualCompactFor(
                                  widget.initialInstanceId!,
                                ),
                          legacyDrafter: _legacyDrafter,
                          recognition: entry == null
                              ? null
                              : widget.catalog.parameterRecognitionFor(
                                  entry.id,
                                ),
                          command: _preview,
                          enabled: !busy,
                          showGeneration:
                              asset.kind != AssetKind.embedding &&
                              !decisionModel,
                          showDrafter:
                              draft.family != EngineFamily.omlx &&
                              asset.kind != AssetKind.embedding,
                          decisionModel: decisionModel,
                          capacityChanges: impact,
                          onFormChanged: (values) {
                            _formValues
                              ..clear()
                              ..addAll(values);
                            unawaited(_updatePreview());
                          },
                          onGenerationChanged: (values) {
                            _generationValues = values;
                            unawaited(_updatePreview());
                          },
                          onDrafterChanged: (value) {
                            _drafter = value;
                            _legacyDrafter = false;
                            unawaited(_updatePreview());
                          },
                          onCheckDrafter: _checkDrafter,
                          argumentEditor: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                key: const Key('engine-argument-text'),
                                controller: _argumentText,
                                enabled: !busy,
                                minLines: 3,
                                maxLines: 7,
                                onChanged: (_) => unawaited(_updatePreview()),
                                decoration: InputDecoration(
                                  labelText: '可选启动参数文本',
                                  helperText: '已知参数可直接在各分组设置；同名调优项仍为文本优先。',
                                  errorText: _previewBlocked ? _error : null,
                                  errorMaxLines: 3,
                                ),
                              ),
                              const SizedBox(height: 15),
                              if (_preview != null)
                                EngineLaunchCommandView(command: _preview!),
                            ],
                          ),
                        ),
                ),
                if (_working) const LinearProgressIndicator(minHeight: 2),
                if (_generationError != null ||
                    _error != null ||
                    _result != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      _generationError ?? _error ?? _result!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _generationError != null || _error != null
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                const Divider(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '保存配置不启动模型；生成默认值用于下一次请求。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _working
                          ? (_testCancellation == null
                                ? null
                                : () => _testCancellation!.cancel())
                          : () => Navigator.pop(context),
                      child: Text(
                        _working ? (_testing ? '取消测试' : '取消检查') : '取消',
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed:
                          busy ||
                              _engineId == null ||
                              _previewBlocked ||
                              _generationError != null ||
                              !widget.catalog.runtimeEnabled
                          ? null
                          : () => _submit(test: true),
                      child: const Text('测试运行'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed:
                          busy ||
                              draft == null ||
                              asset == null ||
                              _generationError != null
                          ? null
                          : () => _submit(test: false),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
