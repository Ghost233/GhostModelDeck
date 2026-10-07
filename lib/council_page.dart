import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final _context = TextEditingController();
  final _options = [_OptionFields(1), _OptionFields(2)];
  int _nextOption = 3;
  DecisionPrimitive _primitive = DecisionPrimitive.choice;
  int get _maxOptions => switch (_primitive) {
    DecisionPrimitive.choice => 255,
    DecisionPrimitive.score => 10,
    DecisionPrimitive.noul => 2,
  };
  Iterable<_OptionFields> get _visibleOptions =>
      _primitive == DecisionPrimitive.noul ? _options.take(2) : _options;
  String? _error;
  DecisionCancellation? _activeCancellation;
  String? _model;
  bool _debug = false;
  Map<String, Object?>? _response;
  bool get _busy => _activeCancellation != null;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.controller.models.load().catchError((Object error) {
        if (mounted) setState(() => _error = error.toString());
      }),
    );
  }

  @override
  void dispose() {
    _activeCancellation?.cancel();
    _context.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  bool get _validOptions =>
      _visibleOptions.length >= 2 &&
      _visibleOptions.length <= _maxOptions &&
      (_primitive != DecisionPrimitive.choice ||
          _options.every(
                (option) =>
                    option.id.text.trim().isNotEmpty &&
                    option.text.text.trim().isNotEmpty,
              ) &&
              _options.map((option) => option.id.text.trim()).toSet().length ==
                  _options.length) &&
      _visibleOptions.every((option) => option.text.text.trim().isNotEmpty);

  Future<void> _consult() async {
    final model = _model;
    if (model == null) return;
    final cancellation = DecisionCancellation();
    final debug = _debug;
    setState(() {
      _error = null;
      _response = null;
      _debug = false;
      _activeCancellation = cancellation;
    });
    try {
      final descriptions = _visibleOptions
          .map((option) => option.text.text.trim())
          .toList();
      final DecisionQuestion question = switch (_primitive) {
        DecisionPrimitive.choice => ChoiceQuestion(
          instructions: '根据上下文，从候选项中选择最合适的一项。',
          options: {
            for (final option in _options)
              option.id.text.trim(): option.text.text.trim(),
          },
        ),
        DecisionPrimitive.score => ScoreQuestion(
          instructions: '根据上下文，按从低到高的有序等级评分。',
          levels: descriptions,
        ),
        DecisionPrimitive.noul => NoulQuestion(
          instructions: '根据上下文判断描述。',
          falseText: descriptions[0],
          trueText: descriptions[1],
        ),
      };
      final result = await widget.controller.models.decide(
        model,
        DecisionBatchRequest(
          state: _context.text,
          questions: {'council_choice': question},
        ),
        cancellation: cancellation,
        debug: debug,
      );
      if (mounted) setState(() => _response = result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          if (error is JevRequestException) _response = error.toJson();
        });
      }
    } finally {
      if (mounted) setState(() => _activeCancellation = null);
    }
  }

  Future<void> _editModel([JevModelDefinition? existing]) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          _ModelEditor(models: widget.controller.models, existing: existing),
    );
    if (mounted && name != null) setState(() => _model = name);
  }

  Future<void> _deleteModel(String name) async {
    try {
      await widget.controller.models.delete(name);
      if (mounted && _model == name) setState(() => _model = null);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.controller.models.changes,
    builder: (context, snapshot) {
      final models = widget.controller.models.configuredModels;
      final selected = models.any((m) => m.definition.name == _model)
          ? _model
          : null;
      final json = _response == null
          ? null
          : const JsonEncoder.withIndent('  ').convert(_response);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JevPageHeader(
            title: '委员会',
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
                              model.available
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
                                  onPressed: () => _editModel(model.definition),
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
                                  onPressed: () =>
                                      _deleteModel(model.definition.name),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        DropdownButton<String>(
                          key: const Key('council-model'),
                          value: selected,
                          hint: const Text('选择调用模型'),
                          isExpanded: true,
                          items: [
                            for (final m in models)
                              DropdownMenuItem(
                                value: m.definition.name,
                                child: Text(m.definition.name),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _model = value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _input(context, modelSelected: selected != null),
                  if (json != null) ...[
                    const SizedBox(height: 16),
                    JevSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(child: Text('标准 JEV 结果')),
                              IconButton(
                                tooltip: '复制结果',
                                onPressed: () => Clipboard.setData(
                                  ClipboardData(text: json),
                                ),
                                icon: const Icon(Icons.copy_outlined, size: 18),
                              ),
                            ],
                          ),
                          SelectableText(
                            json,
                            key: const Key('jev-standard-output'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _input(BuildContext context, {required bool modelSelected}) {
    final theme = Theme.of(context);
    return JevSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          DropdownButton<DecisionPrimitive>(
            key: const Key('council-primitive'),
            value: _primitive,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: DecisionPrimitive.choice,
                child: Text('Choice · 候选选择'),
              ),
              DropdownMenuItem(
                value: DecisionPrimitive.score,
                child: Text('Score · 有序评分'),
              ),
              DropdownMenuItem(
                value: DecisionPrimitive.noul,
                child: Text('Noul · true-head'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _primitive = value!),
          ),
          const SizedBox(height: 12),
          Text('上下文', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            key: const Key('council-context'),
            controller: _context,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(hintText: '输入本次判断的上下文'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(switch (_primitive) {
                  DecisionPrimitive.choice => '候选项',
                  DecisionPrimitive.score => '等级 · 从低到高（2–10）',
                  DecisionPrimitive.noul => '描述 · false / true',
                }, style: theme.textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: _busy || _options.length >= _maxOptions
                    ? null
                    : () => setState(
                        () => _options.add(_OptionFields(_nextOption++)),
                      ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final option in _visibleOptions)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: _primitive != DecisionPrimitive.choice
                        ? Text(
                            _primitive == DecisionPrimitive.score
                                ? '${_options.indexOf(option)}'
                                : (_options.indexOf(option) == 0
                                      ? 'false'
                                      : 'true'),
                          )
                        : TextField(
                            key: Key('council-id-${option.number}'),
                            controller: option.id,
                            enabled: !_busy,
                            decoration: const InputDecoration(hintText: 'ID'),
                            onChanged: (_) => setState(() {}),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: Key('council-option-${option.number}'),
                      controller: option.text,
                      enabled: !_busy,
                      decoration: const InputDecoration(hintText: '候选内容'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '删除候选项',
                    onPressed:
                        _busy ||
                            _options.length <= 2 ||
                            _primitive == DecisionPrimitive.noul
                        ? null
                        : () {
                            setState(() => _options.remove(option));
                            option.dispose();
                          },
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          CheckboxListTile(
            key: const Key('jev-debug'),
            value: _debug,
            contentPadding: EdgeInsets.zero,
            title: const Text('本次附带 debug 依据'),
            onChanged: _busy
                ? null
                : (value) => setState(() => _debug = value!),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Spacer(),
              if (_activeCancellation != null) ...[
                TextButton(
                  onPressed: _activeCancellation!.cancel,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton(
                onPressed: _busy || !modelSelected || !_validOptions
                    ? null
                    : _consult,
                child: Text(_busy ? '咨询中' : '咨询'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OptionFields {
  _OptionFields(this.number)
    : id = TextEditingController(text: 'option_$number');
  final int number;
  final TextEditingController id;
  final text = TextEditingController();
  void dispose() {
    id.dispose();
    text.dispose();
  }
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
