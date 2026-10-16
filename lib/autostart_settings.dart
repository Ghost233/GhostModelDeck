import 'dart:async';

import 'package:flutter/material.dart';

import 'launch_instances.dart';
import 'management_table.dart';
import 'sdk_service.dart';

class AutostartSettings extends StatefulWidget {
  const AutostartSettings({
    super.key,
    required this.settings,
    required this.instances,
  });
  final StartupModelSet settings;
  final LaunchInstances instances;

  @override
  State<AutostartSettings> createState() => _AutostartSettingsState();
}

class _AutostartSettingsState extends State<AutostartSettings> {
  bool _loading = true;
  final _saving = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await widget.settings.load();
      await widget.instances.load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(String key, Future<void> Function() operation) async {
    if (!_saving.add(key)) return;
    setState(() => _error = null);
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '自启动设置保存失败：$error');
    } finally {
      _saving.remove(key);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.settings.changes,
    builder: (context, _) => StreamBuilder<void>(
      stream: widget.instances.changes,
      builder: (context, _) {
        final settings = widget.settings;
        final instances = widget.instances;
        final ids = {
          for (final definition in instances.definitions) definition.id,
          for (final selected in settings.entries) selected.instanceId,
        }.toList();
        String name(String id) => instances.find(id)?.name ?? '已删除的实例 ($id)';
        String status(String id) {
          final definition = instances.find(id);
          return definition == null
              ? '实例已删除'
              : instances.missingReason(definition) ?? '配置已保存';
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('启动', style: Theme.of(context).textTheme.headlineSmall),
            SwitchListTile.adaptive(
              key: const Key('autostart-master'),
              contentPadding: EdgeInsets.zero,
              title: const Text('启动 GMD 时开启引擎总开关'),
              subtitle: const Text('不恢复上次开关状态。保存设置不启停当前实例。'),
              value: settings.autoOpenEngines,
              onChanged: _loading || _saving.contains('master')
                  ? null
                  : (enabled) => _save(
                      'master',
                      () => settings.saveAutoOpenEngines(enabled),
                    ),
            ),
            const Text('总开关开启后并发启动勾选的实例；其余实例手动运行。'),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: ManagementTable<String>(
                id: 'autostart-instances',
                items: ids,
                rowKey: (id) => id,
                searchText: (id) =>
                    '${name(id)} ${instances.find(id)?.publicName ?? ''}',
                status: status,
                emptyLabel: '创建实例后可选择自启动',
                columns: [
                  ManagementColumn(
                    label: '自启动',
                    minWidth: 100,
                    flex: 0,
                    cell: (id) => Checkbox(
                      key: ValueKey('settings-autostart:$id'),
                      value: settings.contains(id),
                      onChanged: _loading || _saving.contains(id)
                          ? null
                          : (selected) => _save(
                              id,
                              () => selected == true
                                  ? settings.add(id)
                                  : settings.remove(id),
                            ),
                    ),
                  ),
                  ManagementColumn(
                    label: '实例名称',
                    minWidth: 200,
                    compare: (a, b) => name(a).compareTo(name(b)),
                    cell: (id) => Text(
                      name(id),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ManagementColumn(
                    label: '模型名字',
                    minWidth: 180,
                    cell: (id) => Text(
                      instances.find(id)?.publicName ?? '—',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ManagementColumn(
                    label: '资源状态',
                    minWidth: 180,
                    cell: (id) => Text(
                      status(id),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: status(id) == '配置已保存'
                            ? null
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
