import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'engine_labels.dart';
import 'launch_instances.dart';
import 'local_model_package.dart';
import 'model_run_dialog.dart';
import 'sdk_service.dart';

class InstancesPage extends StatefulWidget {
  const InstancesPage({
    super.key,
    required this.instances,
    this.initialArtifactId,
    this.onInitialArtifactHandled,
    this.prepare,
    this.startupSet,
  });
  final LaunchInstances instances;
  final String? initialArtifactId;
  final VoidCallback? onInitialArtifactHandled;
  final Future<void> Function()? prepare;
  final StartupModelSet? startupSet;
  @override
  State<InstancesPage> createState() => _InstancesPageState();
}

class _InstancesPageState extends State<InstancesPage> {
  final _working = <String>{};
  String? _error;
  bool _preparing = true;
  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      await widget.prepare?.call();
      if (!mounted) return;
      setState(() => _preparing = false);
      if (widget.initialArtifactId != null) {
        final artifact = widget.initialArtifactId;
        widget.onInitialArtifactHandled?.call();
        await _edit(artifactId: artifact);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  void didUpdateWidget(InstancesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialArtifactId != null &&
        oldWidget.initialArtifactId != widget.initialArtifactId) {
      final artifact = widget.initialArtifactId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onInitialArtifactHandled?.call();
        unawaited(
          _edit(artifactId: artifact).catchError((Object error) {
            if (mounted) setState(() => _error = '$error');
          }),
        );
      });
    }
  }

  Future<void> _edit({LaunchInstance? existing, String? artifactId}) async {
    final store = widget.instances;
    final models = store.catalog.library.state.artifacts
        .where((a) => ['GGUF', 'Safetensors'].contains(a.format))
        .toList();
    final asset = existing == null
        ? models.where((a) => a.id == artifactId).firstOrNull ??
              models.firstOrNull
        : models.where((a) => a.id == existing.artifactId).firstOrNull;
    if (asset == null) {
      setState(() => _error = '请先关联模型；缺失实例的配置继续保留');
      return;
    }
    if (existing != null && store.missingReason(existing) != null) {
      setState(() => _error = '${store.missingReason(existing)}，恢复资源后可编辑原配置');
      return;
    }
    final variant = LocalModelVariant(
      id: asset.id,
      label: '${asset.format} · ${asset.quantization ?? ''}',
      artifacts: [asset],
    );
    await showDialog<void>(
      context: context,
      builder: (_) => ModelRunDialog(
        catalog: store.catalog,
        library: store.catalog.library,
        modelPackage: LocalModelPackage(
          directoryPath: File(asset.files.first.path).parent.path,
          name: asset.name,
          variants: [variant],
          details: [],
        ),
        variant: variant,
        modelChoices: models,
        initialEngineId: existing?.engineId,
        initialConfiguration: existing?.configuration,
        initialName: existing?.name,
        initialAssembly: existing?.splashAssembly,
        onSaveInstance: (name, engine, model, configuration, assembly) async {
          await store.save(
            id: existing?.id,
            name: name,
            artifactId: model.id,
            engineId: engine,
            configuration: configuration,
            splashAssembly: assembly,
          );
        },
      ),
    );
  }

  Future<void> _operate(String id, Future<void> Function() action) async {
    if (!_working.add(id)) return;
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _working.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(LaunchInstance definition) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除实例配置'),
        content: Text('删除“${definition.name}”的启动配置，保留模型和引擎文件。引用它的委员会将标红。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _operate(
        definition.id,
        () => widget.instances.delete(definition.id),
      );
    }
  }

  Future<void> _renamePublic(LaunchInstance definition) async {
    final input = TextEditingController(text: definition.publicName);
    String? error;
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('修改调用名'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('保存后旧调用名立即失效，请同步更新客户端配置。实例显示名和运行参数保持。'),
                TextField(
                  controller: input,
                  enabled: !saving,
                  decoration: const InputDecoration(labelText: '公开调用名'),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        update(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          await widget.instances.renamePublicName(
                            definition.id,
                            input.text,
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (failure) {
                          if (dialogContext.mounted) {
                            update(() {
                              saving = false;
                              error = failure is StateError
                                  ? failure.message
                                  : '$failure';
                            });
                          }
                        }
                      },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      input.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.instances.changes,
    builder: (context, _) {
      final definitions = widget.instances.definitions;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JevPageHeader(
            title: '实例',
            action: TextButton.icon(
              onPressed: _preparing ? null : () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('创建实例'),
            ),
          ),
          const Text('保存模型、引擎与参数的组合；同一组合可保存多份配置。保存不启动模型。'),
          if (_preparing) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: definitions.isEmpty
                ? const Center(child: Text('关联模型和引擎后创建实例'))
                : ListView.builder(
                    itemCount: definitions.length,
                    itemBuilder: (context, index) {
                      final definition = definitions[index];
                      final missing = widget.instances.missingReason(
                        definition,
                      );
                      final runs = widget.instances.runsFor(definition.id);
                      final live = runs.any((r) => r.hasLiveProcess);
                      final engine = widget.instances.catalog.state.entries
                          .where((e) => e.id == definition.engineId)
                          .firstOrNull;
                      final asset = widget
                          .instances
                          .catalog
                          .library
                          .state
                          .artifacts
                          .where((a) => a.id == definition.artifactId)
                          .firstOrNull;
                      final busy = _working.contains(definition.id);
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                definition.name,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: missing == null
                                          ? null
                                          : Theme.of(context).colorScheme.error,
                                    ),
                              ),
                              Text(
                                '${asset?.name ?? '模型缺失'} · ${engine == null ? '引擎缺失' : engineDisplayName(engine)}',
                              ),
                              if (engine != null)
                                SelectableText(
                                  engineSourceLabel(engine),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              Text(
                                missing ??
                                    (widget.instances.isStarting(definition.id)
                                        ? '启动中'
                                        : live
                                        ? '运行中'
                                        : '已保存'),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: missing == null
                                          ? null
                                          : Theme.of(context).colorScheme.error,
                                    ),
                              ),
                              SelectableText(
                                '公开模型 ID  ${definition.publicName}',
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  if (widget.instances.isStarting(
                                    definition.id,
                                  ))
                                    TextButton(
                                      onPressed: () async {
                                        try {
                                          await widget.instances.stop(
                                            definition.id,
                                          );
                                        } catch (error) {
                                          if (mounted) {
                                            setState(() => _error = '$error');
                                          }
                                        }
                                      },
                                      child: const Text('取消启动'),
                                    ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => _renamePublic(definition),
                                    child: const Text('修改调用名'),
                                  ),
                                  if (widget.startupSet != null)
                                    IconButton(
                                      tooltip:
                                          widget.startupSet!.contains(
                                            definition.id,
                                          )
                                          ? '从启动模型集合移除'
                                          : '加入启动模型集合（推理服务启动时加载）',
                                      icon: Icon(
                                        widget.startupSet!.contains(
                                              definition.id,
                                            )
                                            ? Icons.rocket_launch
                                            : Icons.rocket_launch_outlined,
                                      ),
                                      onPressed: busy
                                          ? null
                                          : () => _operate(
                                              definition.id,
                                              () async {
                                                final selection =
                                                    widget.startupSet!;
                                                if (selection.contains(
                                                  definition.id,
                                                )) {
                                                  await selection.remove(
                                                    definition.id,
                                                  );
                                                } else {
                                                  await selection.add(
                                                    definition.id,
                                                  );
                                                }
                                              },
                                            ),
                                    ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () =>
                                              _operate(definition.id, () async {
                                                await widget.instances.copy(
                                                  definition.id,
                                                );
                                              }),
                                    child: const Text('复制'),
                                  ),
                                  TextButton(
                                    onPressed: busy || missing != null
                                        ? null
                                        : () => _edit(existing: definition),
                                    child: const Text('编辑参数'),
                                  ),
                                  TextButton(
                                    onPressed: busy || live || missing != null
                                        ? null
                                        : () =>
                                              _operate(definition.id, () async {
                                                await widget.instances.start(
                                                  definition.id,
                                                );
                                              }),
                                    child: const Text('运行'),
                                  ),
                                  TextButton(
                                    onPressed: busy || !live
                                        ? null
                                        : () => _operate(
                                            definition.id,
                                            () => widget.instances.stop(
                                              definition.id,
                                            ),
                                          ),
                                    child: const Text('停止'),
                                  ),
                                  TextButton(
                                    onPressed: busy || live
                                        ? null
                                        : () => _delete(definition),
                                    child: const Text('删除配置'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}
