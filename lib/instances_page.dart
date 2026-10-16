import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'engine_labels.dart';
import 'launch_instances.dart';
import 'jev_models.dart';
import 'local_model_package.dart';
import 'model_run_dialog.dart';
import 'sdk_service.dart';
import 'management_table.dart';
import 'engine_runtime.dart';

class InstancesPage extends StatefulWidget {
  const InstancesPage({
    super.key,
    required this.instances,
    this.initialArtifactId,
    this.onInitialArtifactHandled,
    this.prepare,
    this.startupSet,
    this.models,
  });
  final LaunchInstances instances;
  final String? initialArtifactId;
  final VoidCallback? onInitialArtifactHandled;
  final Future<void> Function()? prepare;
  final StartupModelSet? startupSet;
  final JevModels? models;
  @override
  State<InstancesPage> createState() => _InstancesPageState();
}

class _InstancesPageState extends State<InstancesPage> {
  final _working = <String>{};
  String? _error;
  String? _errorFile;
  bool _preparing = true;
  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      await widget.prepare?.call();
      await widget.startupSet?.load();
      if (!mounted) return;
      setState(() => _preparing = false);
      if (widget.initialArtifactId != null) {
        final artifact = widget.initialArtifactId;
        widget.onInitialArtifactHandled?.call();
        await _edit(artifactId: artifact);
      }
    } catch (error, stack) {
      await _showFailure(error, stack);
      if (mounted) {
        setState(() {
          _preparing = false;
        });
      }
    }
  }

  Future<void> _showFailure(Object error, StackTrace stack) async {
    try {
      final failure = await widget.instances.recordFailure(error, stack);
      if (mounted) {
        setState(() {
          _error = failure.summary;
          _errorFile = failure.path;
        });
      }
    } catch (loggingError) {
      if (mounted) {
        setState(() {
          _error =
              '${error.toString().split('\n').first}；完整错误保存失败：$loggingError';
          _errorFile = null;
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
        : models.where((a) => a.id == existing.artifactId).firstOrNull ??
              models.firstOrNull;
    if (asset == null) {
      setState(() => _error = '请先关联模型；缺失实例的配置继续保留');
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
        contextPreview: existing == null || widget.models == null
            ? null
            : (configuration) => widget.models!.previewContextChange(
                existing.id,
                configuration,
              ),
        onSaveInstance: (name, engine, model, configuration) async {
          await store.save(
            id: existing?.id,
            name: name,
            artifactId: model.id,
            engineId: engine,
            configuration: configuration,
          );
        },
      ),
    );
  }

  Future<void> _operate(String id, Future<void> Function() action) async {
    if (!_working.add(id)) return;
    setState(() {
      _error = null;
      _errorFile = null;
    });
    try {
      await action();
    } catch (error, stack) {
      await _showFailure(error, stack);
    } finally {
      _working.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _editJevBudget(LaunchInstance definition) async {
    final input = TextEditingController(
      text: '${definition.jevRequestTimeoutSeconds}',
    );
    String? error;
    try {
      final seconds = await showDialog<int>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('JEV 请求预算'),
            content: TextField(
              key: const Key('instance-jev-budget'),
              controller: input,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '整轮请求预算（秒）',
                helperText: '默认 60 秒；保存后用于新的 HTTP/MCP 请求。',
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final seconds = int.tryParse(input.text);
                  if (seconds == null || seconds < 1) {
                    update(() => error = '请输入正整数秒');
                  } else {
                    Navigator.pop(context, seconds);
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (seconds == null) return;
      await _operate(definition.id, () async {
        final current = widget.instances.find(definition.id);
        if (current == null) throw StateError('实例已删除');
        await widget.instances.save(
          id: current.id,
          name: current.name,
          artifactId: current.artifactId,
          engineId: current.engineId,
          configuration: current.configuration,
          splashAssembly: current.splashAssembly,
          jevRequestTimeoutSeconds: seconds,
        );
      });
    } finally {
      input.dispose();
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

  String _stateLabel(LaunchInstance definition) {
    if (_preparing) return '准备中';
    final missing = widget.instances.missingReason(definition);
    if (missing != null) return missing;
    if (widget.instances.isStarting(definition.id)) return '启动中';
    final runs = widget.instances.runsFor(definition.id);
    if (runs.any((run) => run.status == RuntimeInstanceStatus.stopping)) {
      return '停止中';
    }
    if (runs.any(
      (run) =>
          run.status == RuntimeInstanceStatus.ready &&
          run.acceptingRequests &&
          run.hasLiveProcess,
    )) {
      return '运行中';
    }
    if (runs.any((run) => run.status == RuntimeInstanceStatus.failed)) {
      return '失败';
    }
    return runs.isEmpty ? '已保存' : '已停止';
  }

  Future<void> _showActualCommand(LaunchInstance definition) async {
    final command = widget.instances.actualCommand(definition.id);
    if (command == null) return;
    final origin = widget.instances.runningOrigin(definition.id);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('实际启动命令'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (origin != null)
                Text(
                  '实际运行 · ${engineDisplayName(origin)} · ${widget.instances.runningVersion(definition.id) ?? '版本未提供'}',
                ),
              SelectableText(command.displayText),
            ],
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

  Widget _tableActions(LaunchInstance definition) {
    final busy = _preparing || _working.contains(definition.id);
    final starting = widget.instances.isStarting(definition.id);
    final live = widget.instances
        .runsFor(definition.id)
        .any((run) => run.hasLiveProcess);
    final missing = _preparing
        ? null
        : widget.instances.missingReason(definition);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          key: ValueKey('instance-parameters:${definition.id}'),
          onPressed: busy ? null : () => _edit(existing: definition),
          child: const Text('编辑参数'),
        ),
        if (starting)
          TextButton(
            onPressed: () async {
              try {
                await widget.instances.stop(definition.id);
              } catch (error, stack) {
                await _showFailure(error, stack);
              }
            },
            child: const Text('取消启动'),
          )
        else if (live)
          TextButton(
            onPressed: busy
                ? null
                : () => _operate(
                    definition.id,
                    () => widget.instances.stop(definition.id),
                  ),
            child: const Text('停止'),
          )
        else
          TextButton(
            onPressed: busy || missing != null
                ? null
                : () => _operate(definition.id, () async {
                    await widget.instances.start(definition.id);
                  }),
            child: const Text('运行'),
          ),
        PopupMenuButton<String>(
          key: ValueKey('instance-more:${definition.id}'),
          tooltip: '更多',
          enabled: !busy,
          onSelected: (action) async {
            if (action == 'rename') {
              await _renamePublic(definition);
            } else if (action == 'copy') {
              await _operate(definition.id, () async {
                await widget.instances.copy(definition.id);
              });
            } else if (action == 'budget') {
              await _editJevBudget(definition);
            } else if (action == 'command') {
              await _showActualCommand(definition);
            } else {
              await _delete(definition);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('修改调用名')),
            const PopupMenuItem(value: 'copy', child: Text('复制')),
            PopupMenuItem(
              value: 'budget',
              child: Text('JEV 预算 ${definition.jevRequestTimeoutSeconds} 秒'),
            ),
            if (widget.instances.actualCommand(definition.id) != null)
              const PopupMenuItem(value: 'command', child: Text('实际启动命令')),
            PopupMenuItem(
              value: 'delete',
              enabled: !live && !starting,
              child: const Text('删除配置'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.instances.changes,
    builder: (context, _) {
      final store = widget.instances;
      final definitions = store.definitions;
      final assets = {
        for (final asset in store.catalog.library.state.artifacts)
          asset.id: asset,
      };
      final engines = {
        for (final entry in store.catalog.state.entries) entry.id: entry,
      };
      String model(LaunchInstance value) =>
          _preparing ? '读取模型与引擎资源…' : assets[value.artifactId]?.name ?? '—';
      String engine(LaunchInstance value) => engines[value.engineId] == null
          ? '—'
          : engineDisplayName(engines[value.engineId]!);
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
          if (store.persistenceError case final error?)
            Text(
              error,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          if (_error != null)
            Text(
              _error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          if (_errorFile != null) ...[
            const Text('完整错误文件'),
            SelectableText(
              _errorFile!,
              key: const Key('instance-error-file'),
              maxLines: 1,
            ),
            TextButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('在 Finder 中显示'),
              onPressed: () async {
                try {
                  await const MethodChannel(
                    'com.ghost233.ghostmodeldeck/native',
                  ).invokeMethod<void>('revealInFinder', {'path': _errorFile});
                } catch (error) {
                  if (mounted) setState(() => _error = 'Finder 打开失败：$error');
                }
              },
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: ManagementTable<LaunchInstance>(
              id: 'instances',
              items: definitions,
              rowKey: (value) => value.id,
              searchText: (value) =>
                  '${value.name} ${value.publicName} ${model(value)} ${engine(value)}',
              status: _stateLabel,
              emptyLabel: '关联模型和引擎后创建实例',
              columns: [
                ManagementColumn(
                  label: '实例名称',
                  minWidth: 180,
                  flex: 2,
                  compare: (a, b) => a.name.compareTo(b.name),
                  cell: (value) => Text(
                    value.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _preparing || store.missingReason(value) == null
                          ? null
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                ManagementColumn(
                  label: '模型名字',
                  minWidth: 180,
                  flex: 2,
                  compare: (a, b) => a.publicName.compareTo(b.publicName),
                  cell: (value) =>
                      SelectableText(value.publicName, maxLines: 2),
                ),
                ManagementColumn(
                  label: '对应模型',
                  minWidth: 200,
                  flex: 2,
                  compare: (a, b) => model(a).compareTo(model(b)),
                  cell: (value) => Tooltip(
                    message: model(value),
                    child: Text(
                      model(value),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                ManagementColumn(
                  label: '引擎',
                  minWidth: 180,
                  flex: 2,
                  compare: (a, b) => engine(a).compareTo(engine(b)),
                  cell: (value) => Tooltip(
                    message: engines[value.engineId] == null
                        ? '引擎缺失'
                        : engineSourceLabel(engines[value.engineId]!),
                    child: Text(
                      engine(value),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                ManagementColumn(
                  label: '上下文',
                  minWidth: 140,
                  flex: 0,
                  compare: (a, b) => (store.contextLengthFor(a.id) ?? -1)
                      .compareTo(store.contextLengthFor(b.id) ?? -1),
                  cell: (value) {
                    final applied = store.contextLengthFor(value.id);
                    final pending = value.configuration.contextLength;
                    final label = '${applied ?? '—'}';
                    return Tooltip(
                      message: pending == null
                          ? '已生效上下文 $label；启动配置未指定固定值。'
                          : '已生效上下文 $label；保存配置 $pending，修改后重启生效。',
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
                ManagementColumn(
                  label: '并发',
                  minWidth: 90,
                  flex: 0,
                  compare: (a, b) =>
                      (a.configuration.inferenceConcurrency ?? -1).compareTo(
                        b.configuration.inferenceConcurrency ?? -1,
                      ),
                  cell: (value) => Tooltip(
                    message: '保存的推理并发配置；修改后重启生效。',
                    child: Text(
                      '${value.configuration.inferenceConcurrency ?? '—'}',
                    ),
                  ),
                ),
                ManagementColumn(
                  label: '自启动',
                  minWidth: 100,
                  flex: 0,
                  compare: (a, b) =>
                      (widget.startupSet?.contains(a.id) == true ? 1 : 0)
                          .compareTo(
                            widget.startupSet?.contains(b.id) == true ? 1 : 0,
                          ),
                  cell: (value) => widget.startupSet == null
                      ? const Text('—')
                      : Checkbox(
                          key: ValueKey('instance-autostart:${value.id}'),
                          value: widget.startupSet!.contains(value.id),
                          onChanged: _preparing || _working.contains(value.id)
                              ? null
                              : (selected) => _operate(value.id, () async {
                                  if (selected == true) {
                                    await widget.startupSet!.add(value.id);
                                  } else {
                                    await widget.startupSet!.remove(value.id);
                                  }
                                }),
                        ),
                ),
                ManagementColumn(
                  label: '状态',
                  minWidth: 140,
                  flex: 0,
                  compare: (a, b) => _stateLabel(a).compareTo(_stateLabel(b)),
                  cell: (value) => Text(
                    _stateLabel(value),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ManagementColumn(
                  label: '操作',
                  minWidth: 250,
                  flex: 0,
                  cell: _tableActions,
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
