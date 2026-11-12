import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'model_routers.dart';
import 'public_gateway.dart';

class ModelRoutersPage extends StatefulWidget {
  const ModelRoutersPage({
    super.key,
    required this.routers,
    required this.gateway,
  });

  final ModelRouters routers;
  final PublicGatewayServer gateway;

  @override
  State<ModelRoutersPage> createState() => _ModelRoutersPageState();
}

class _ModelRoutersPageState extends State<ModelRoutersPage> {
  late final StreamSubscription<void> _routes;
  late final StreamSubscription<void> _instances;
  bool _busy = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _routes = widget.routers.changes.listen((_) => _refresh());
    _instances = widget.routers.instances.changes.listen((_) => _refresh());
    unawaited(_run(widget.routers.load));
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_routes.cancel());
    unawaited(_instances.cancel());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      _error = error;
    } finally {
      _busy = false;
      _refresh();
    }
  }

  Future<void> _edit([ModelRouter? router]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RouterEditor(routers: widget.routers, router: router),
    );
  }

  Future<void> _delete(ModelRouter router) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型路由'),
        content: Text('删除「${router.name}」的调用入口？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _run(() => widget.routers.delete(router.name));
    }
  }

  Widget _row(ModelRouter router) {
    final instances = widget.routers.instances;
    final current = instances.find(router.currentInstanceId);
    final ready = widget.gateway.readyTextModel(router.name) != null;
    final status = current == null
        ? '当前实例缺失'
        : ready
        ? '已就绪'
        : instances.isStarting(current.id)
        ? '启动中'
        : '未就绪';
    return JevSurface(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [SelectableText(router.name), Text(status)],
            ),
          ),
          Flexible(
            flex: 2,
            child: DropdownButton<String>(
              key: ValueKey('router-current:${router.name}'),
              isExpanded: true,
              value: router.currentInstanceId,
              items: [
                for (final id in router.candidateIds)
                  DropdownMenuItem(
                    value: id,
                    enabled: switch (instances.find(id)) {
                      final instance? => widget.routers.isCandidate(instance),
                      null => false,
                    },
                    child: Text(
                      instances.find(id)?.name ?? '实例缺失',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (id) {
                      if (id != null) {
                        unawaited(
                          _run(() => widget.routers.select(router.name, id)),
                        );
                      }
                    },
            ),
          ),
          IconButton(
            tooltip: '编辑候选',
            onPressed: _busy ? null : () => _edit(router),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '删除路由',
            onPressed: _busy ? null : () => _delete(router),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.routers.entries;
    final loadError = widget.routers.loadError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JevPageHeader(
          title: '模型路由',
          action: FilledButton(
            onPressed: _busy || loadError != null ? null : _edit,
            child: const Text('创建路由'),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error ?? loadError case final error?)
          Text(
            '$error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (loadError != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : () => _run(widget.routers.load),
              child: const Text('重新读取'),
            ),
          ),
        if (!_busy && loadError == null && entries.isEmpty)
          const JevSurface(child: Text('还没有模型路由。')),
        if (entries.isNotEmpty)
          Expanded(
            child: ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, index) => _row(entries[index]),
            ),
          ),
      ],
    );
  }
}

class _RouterEditor extends StatefulWidget {
  const _RouterEditor({required this.routers, this.router});

  final ModelRouters routers;
  final ModelRouter? router;

  @override
  State<_RouterEditor> createState() => _RouterEditorState();
}

class _RouterEditorState extends State<_RouterEditor> {
  late final _name = TextEditingController(text: widget.router?.name);
  late final _candidates = {...?widget.router?.candidateIds};
  late String? _current = widget.router?.currentInstanceId;
  Object? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final router = ModelRouter(
        name: _name.text.trim(),
        candidateIds: _candidates,
        currentInstanceId: _current!,
      );
      await (widget.router == null
          ? widget.routers.create(router)
          : widget.routers.update(router));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = {
      for (final instance in widget.routers.instances.definitions)
        if (widget.routers.isCandidate(instance)) instance.id: instance.name,
    };
    final selectable = options.keys.toSet();
    for (final id in _candidates) {
      options.putIfAbsent(id, () => '实例缺失或不可用于聊天');
    }
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.router == null ? '创建路由' : '编辑路由候选'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                readOnly: widget.router != null,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: '调用名',
                  hintText: 'model_router',
                ),
              ),
              const SizedBox(height: 16),
              const Text('候选实例'),
              if (options.isEmpty) const Text('请先在「实例」页保存聊天实例。'),
              for (final option in options.entries)
                CheckboxListTile(
                  title: Text(option.value),
                  value: _candidates.contains(option.key),
                  onChanged: _saving
                      ? null
                      : (selected) {
                          setState(() {
                            if (selected == true) {
                              _candidates.add(option.key);
                            } else {
                              _candidates.remove(option.key);
                              if (_current == option.key) _current = null;
                            }
                          });
                        },
                ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(labelText: '当前实例'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _current,
                    hint: const Text('请选择'),
                    isExpanded: true,
                    items: [
                      for (final id in _candidates)
                        DropdownMenuItem(
                          value: id,
                          enabled: selectable.contains(id),
                          child: Text(
                            options[id]!,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (id) => setState(() => _current = id),
                  ),
                ),
              ),
              if (_error case final error?)
                Text(
                  '$error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving || _current == null ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
