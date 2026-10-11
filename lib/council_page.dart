import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'council.dart';
import 'decision_protocol.dart';
import 'jev_models.dart';

class CouncilPage extends StatefulWidget {
  const CouncilPage({
    super.key,
    required this.controller,
    required this.onOpenLibrary,
  });
  final CouncilController controller;
  final VoidCallback onOpenLibrary;
  @override
  State<CouncilPage> createState() => _CouncilPageState();
}

class _CouncilPageState extends State<CouncilPage> {
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.controller.models.load().catchError((Object error) {
        if (mounted) setState(() => _error = error.toString());
      }),
    );
  }

  Future<void> _editModel([JevModelDefinition? existing]) async {
    await showDialog<String>(
      context: context,
      builder: (context) =>
          _ModelEditor(models: widget.controller.models, existing: existing),
    );
  }

  Future<void> _deleteModel(String name) async {
    try {
      await widget.controller.models.delete(name);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.controller.models.changes,
    builder: (context, snapshot) {
      final models = widget.controller.models.configuredModels;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JevPageHeader(
            title: '委员会配置',
            action: TextButton.icon(
              onPressed: widget.onOpenLibrary,
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: const Text('模型库'),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  JevSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(child: Text('命名 JEV 模型')),
                            TextButton.icon(
                              onPressed: () => _editModel(),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('创建模型'),
                            ),
                          ],
                        ),
                        if (models.isEmpty)
                          const Text('创建委员会配置或原生调用名。配置不会自动加载模型。'),
                        for (final model in models)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${model.definition.name} · ${model.definition.source == JevModelSource.council ? '委员会' : '原生 JEV'}',
                            ),
                            subtitle: Text(
                              widget.controller.models.isEvaluationLocked(
                                    model.definition.name,
                                  )
                                  ? '评测中 · 配置与调用名已锁定'
                                  : model.available
                                  ? model.reason == null
                                        ? '可调用 · ${model.definition.bindings.length} 个绑定'
                                        : '可调用 · 部分绑定未就绪 · ${model.reason}'
                                  : '未就绪 · ${model.reason}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: Key(
                                    'edit-model-${model.definition.name}',
                                  ),
                                  tooltip: '编辑模型配置',
                                  onPressed:
                                      widget.controller.models
                                          .isEvaluationLocked(
                                            model.definition.name,
                                          )
                                      ? null
                                      : () => _editModel(model.definition),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  key: Key(
                                    'delete-model-${model.definition.name}',
                                  ),
                                  tooltip: '删除模型配置',
                                  onPressed:
                                      widget.controller.models
                                          .isEvaluationLocked(
                                            model.definition.name,
                                          )
                                      ? null
                                      : () =>
                                            _deleteModel(model.definition.name),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        key: const Key('council-config-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _ModelEditor extends StatefulWidget {
  const _ModelEditor({required this.models, this.existing});
  final JevModels models;
  final JevModelDefinition? existing;
  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<_ModelEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _timeout = TextEditingController(
    text: '${(widget.existing?.timeout.inMicroseconds ?? 10000000) / 1000000}',
  );
  late JevModelSource _source =
      widget.existing?.source ?? JevModelSource.council;
  late final List<JevModelBinding> _bindings = {
    for (final binding in widget.models.availableBindings) binding.id: binding,
    for (final binding in widget.existing?.bindings ?? <JevModelBinding>[])
      binding.id: binding,
  }.values.toList();
  late final Set<String> _chosen = {
    for (final b in widget.existing?.bindings ?? <JevModelBinding>[]) b.id,
  };
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _timeout.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final seats = _bindings.where((b) => _chosen.contains(b.id)).toList();
      final seconds = double.tryParse(_timeout.text);
      if (_source == JevModelSource.council &&
          (seconds == null || !seconds.isFinite || seconds <= 0)) {
        throw const DecisionProtocolException('整轮超时需要是正数');
      }
      if (_source == JevModelSource.native && seats.length != 1) {
        throw const DecisionProtocolException('原生模型需要一个资产与引擎绑定');
      }
      final definition = _source == JevModelSource.council
          ? JevModelDefinition.council(
              name: _name.text.trim(),
              seats: seats,
              timeout: Duration(microseconds: (seconds! * 1000000).round()),
            )
          : JevModelDefinition.native(
              name: _name.text.trim(),
              binding: seats.single,
            );
      await widget.models.save(definition, replacing: widget.existing?.name);
      if (mounted) Navigator.of(context).pop(definition.name);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bindings = _bindings;
    return AlertDialog(
      title: Text(widget.existing == null ? '创建 JEV 模型' : '编辑 JEV 模型'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('jev-model-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: '调用名'),
              ),
              DropdownButton<JevModelSource>(
                key: const Key('jev-model-source'),
                value: _source,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: JevModelSource.council,
                    child: Text('委员会'),
                  ),
                  DropdownMenuItem(
                    value: JevModelSource.native,
                    child: Text('原生 JEV'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _source = value!;
                        if (_source == JevModelSource.native &&
                            _chosen.length > 1) {
                          final first = _chosen.first;
                          _chosen
                            ..clear()
                            ..add(first);
                        }
                      }),
              ),
              if (_source == JevModelSource.council)
                TextField(
                  key: const Key('jev-model-timeout'),
                  controller: _timeout,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '整轮超时（秒）'),
                ),
              const SizedBox(height: 12),
              const Text('绑定已登记的本机模型与引擎；保存不启动模型。'),
              for (final binding in bindings)
                CheckboxListTile(
                  value: _chosen.contains(binding.id),
                  title: Text(widget.models.bindingLabel(binding)),
                  subtitle: Text(widget.models.bindingReason(binding) ?? '可调用'),
                  contentPadding: EdgeInsets.zero,
                  onChanged: _saving
                      ? null
                      : (checked) => setState(() {
                          if (_source == JevModelSource.native) _chosen.clear();
                          checked!
                              ? _chosen.add(binding.id)
                              : _chosen.remove(binding.id);
                        }),
                ),
              if (bindings.isEmpty) const Text('模型库中尚无已登记的 JEV 模型。'),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中' : '保存'),
        ),
      ],
    );
  }
}
