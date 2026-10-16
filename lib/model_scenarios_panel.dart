import 'dart:async';

import 'package:flutter/material.dart';

import 'council.dart';
import 'model_scenarios.dart';
import 'public_model_names.dart';
import 'jev_models.dart';

class ModelScenariosPanel extends StatefulWidget {
  const ModelScenariosPanel({super.key, required this.controller});
  final CouncilController controller;

  @override
  State<ModelScenariosPanel> createState() => _ModelScenariosPanelState();
}

class _ModelScenariosPanelState extends State<ModelScenariosPanel> {
  late final StreamSubscription<void> _subscription;
  final _saving = <int>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.models.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await widget.controller.models.load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  Future<void> _toggle(int slot, ModelScenario entry, bool enabled) async {
    setState(() => _saving.add(slot));
    try {
      await widget.controller.scenarios.save(
        slot,
        ModelScenario(
          displayName: entry.displayName,
          modelName: entry.modelName,
          instanceId: entry.instanceId,
          councilId: entry.councilId,
          enabled: enabled,
        ),
      );
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving.remove(slot));
    }
  }

  Future<void> _edit(int slot) async {
    final entry = widget.controller.scenarios.entries[slot];
    final displayName = TextEditingController(text: entry.displayName);
    final modelName = TextEditingController(text: entry.modelName);
    var target = entry.instanceId != null
        ? 'instance:${entry.instanceId}'
        : entry.councilId != null
        ? 'council:${entry.councilId}'
        : '';
    var saving = false;
    String? error;
    try {
      final route = DialogRoute<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, refresh) {
            final instances =
                widget.controller.launchInstances?.definitions ?? [];
            final bindings = <String, String>{
              '': '未选择',
              for (final instance in instances)
                'instance:${instance.id}':
                    '实例 · ${instance.name} · ${instance.publicName}',
              for (final model in widget.controller.models.definitions)
                if (model.source == JevModelSource.council)
                  'council:${model.id}': '委员会 · ${model.name}',
            };
            if (target.isNotEmpty && !bindings.containsKey(target)) {
              bindings[target] = '绑定对象缺失';
            }
            return AlertDialog(
              title: const Text('编辑场景'),
              scrollable: true,
              content: SizedBox(
                width: MediaQuery.sizeOf(context).width * .7,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const Key('scenario-display-name'),
                      controller: displayName,
                      enabled: !saving,
                      decoration: const InputDecoration(labelText: '场景名称'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('scenario-model-name'),
                      controller: modelName,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: '模型名字',
                        helperText: 'HTTP 和 MCP 的 model 使用这个名字',
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: const Key('scenario-binding'),
                      initialValue: target,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '绑定实例／委员会'),
                      items: [
                        for (final binding in bindings.entries)
                          DropdownMenuItem(
                            value: binding.key,
                            child: Text(
                              binding.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) => refresh(() {
                              target = value ?? '';
                            }),
                    ),
                    if (error != null)
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
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
                          refresh(() => saving = true);
                          try {
                            await widget.controller.scenarios.save(
                              slot,
                              ModelScenario(
                                displayName: displayName.text,
                                modelName: modelName.text.trim().isEmpty
                                    ? ''
                                    : PublicModelNames.normalize(
                                        modelName.text,
                                      ),
                                instanceId: target.startsWith('instance:')
                                    ? target.substring('instance:'.length)
                                    : null,
                                councilId: target.startsWith('council:')
                                    ? target.substring('council:'.length)
                                    : null,
                                enabled: entry.enabled,
                              ),
                            );
                            if (mounted) setState(() => _error = null);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } catch (failure) {
                            if (dialogContext.mounted) {
                              refresh(() {
                                saving = false;
                                error = failure.toString();
                              });
                            }
                          }
                        },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      displayName.dispose();
      modelName.dispose();
    }
  }

  ({String label, bool missing}) _binding(ModelScenario entry) {
    if (entry.instanceId != null) {
      final instance = widget.controller.launchInstances?.find(
        entry.instanceId!,
      );
      return (label: instance?.name ?? '实例缺失', missing: instance == null);
    }
    if (entry.councilId != null) {
      final model = widget.controller.models.definitions
          .where(
            (model) =>
                model.source == JevModelSource.council &&
                model.id == entry.councilId,
          )
          .firstOrNull;
      return (
        label: model == null ? '委员会缺失' : '委员会 · ${model.name}',
        missing: model == null,
      );
    }
    return (label: '未选择实例／委员会', missing: false);
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.controller.scenarios.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text('场景模型', style: Theme.of(context).textTheme.titleMedium),
        const Text('模型名字用于 HTTP／MCP；场景文字仅作说明。绑定实例运行后才会返回。'),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (var slot = 0; slot < entries.length; slot++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entries[slot].displayName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entries[slot].modelName.isEmpty
                      ? '未配置'
                      : entries[slot].modelName,
                ),
                Text(
                  _binding(entries[slot]).label,
                  style: _binding(entries[slot]).missing
                      ? TextStyle(color: Theme.of(context).colorScheme.error)
                      : null,
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: entries[slot].enabled,
                  onChanged: _loading || _saving.contains(slot)
                      ? null
                      : (value) => _toggle(slot, entries[slot], value),
                ),
                OutlinedButton(
                  key: Key('edit-scenario-$slot'),
                  onPressed: _loading || _saving.contains(slot)
                      ? null
                      : () => _edit(slot),
                  child: const Text('编辑'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
