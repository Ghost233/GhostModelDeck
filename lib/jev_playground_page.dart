import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'council.dart';
import 'council_mcp.dart';
import 'decision_protocol.dart';
import 'jev_debug.dart';
import 'jev_models.dart';
import 'jev_playground.dart';
import 'public_gateway.dart';

class JevPlaygroundPage extends StatefulWidget {
  const JevPlaygroundPage({
    super.key,
    required this.controller,
    required this.gateway,
    required this.mcp,
    this.active = true,
  });
  final CouncilController controller;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;
  final bool active;
  @override
  State<JevPlaygroundPage> createState() => _JevPlaygroundPageState();
}

class _JevPlaygroundPageState extends State<JevPlaygroundPage> {
  static const _encoder = JsonEncoder.withIndent('  ');
  final _json = TextEditingController(
    text: _encoder.convert({
      'state': '',
      'questions': {
        'route': {
          'type': 'choice',
          'instructions': '选择最合适的一项。',
          'criteria': {'a': 'A', 'b': 'B'},
        },
      },
    }),
  );
  late final _playground = JevPlayground(
    controller: widget.controller,
    gateway: widget.gateway,
    mcp: widget.mcp,
  );
  final _subscriptions = <StreamSubscription<Object?>>[];
  JevPlaygroundMode _mode = JevPlaygroundMode.native;
  JevNativeSource? _nativeSource;
  bool _jsonMode = false;
  DecisionCancellation? _active;
  JevPlaygroundResult? _result;
  Map<String, Object?>? _discovery;
  String? _discoveryError;
  bool _discovering = false;
  DecisionCancellation? _discoveryToken;

  @override
  void initState() {
    super.initState();
    _json.addListener(_changed);
    _subscriptions.add(
      widget.controller.models.changes.listen((_) => _changed()),
    );
    _subscriptions.add(widget.gateway.changes.listen((_) => _changed()));
    _subscriptions.add(widget.mcp.changes.listen((_) => _changed()));
    unawaited(
      widget.controller.models.load().catchError((Object error) {
        if (mounted) setState(() => _discoveryError = error.toString());
      }),
    );
  }

  @override
  void didUpdateWidget(covariant JevPlaygroundPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _active?.cancel();
      _discoveryToken?.cancel();
    }
  }

  void _changed() {
    final model = _document?['model'];
    if (_nativeSource?.model != model) {
      final matching = _playground.nativeSources
          .where((s) => s.model == model)
          .toList();
      _nativeSource = matching.length == 1 ? matching.single : null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _active?.cancel();
    _discoveryToken?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _json.dispose();
    super.dispose();
  }

  Map<String, Object?>? get _document {
    try {
      final value = jsonDecode(_json.text);
      return value is Map ? Map<String, Object?>.from(value) : null;
    } on FormatException {
      return null;
    }
  }

  void _edit(List<String> path, Object? value) {
    final document = _document;
    if (document == null) return;
    Map cursor = document;
    for (final key in path.take(path.length - 1)) {
      cursor = cursor[key] as Map;
    }
    cursor[path.last] = value;
    _json.text = _encoder.convert(document);
  }

  void _select(String? model) {
    if (model == null) return;
    if (_mode == JevPlaygroundMode.native) {
      _nativeSource = _playground.nativeSources.singleWhere(
        (s) => s.model == model,
      );
    }
    _edit(['model'], model);
  }

  Future<void> _run() async {
    if (_active != null) return;
    final token = DecisionCancellation();
    final mode = _mode;
    final document = _json.text;
    final source = _nativeSource;
    setState(() {
      _active = token;
      _result = null;
    });
    final result = await _playground.run(
      mode,
      document,
      nativeSource: source,
      cancellation: token,
    );
    if (mounted && identical(_active, token)) {
      setState(() {
        _result = result;
        _active = null;
      });
    }
  }

  Future<void> _discover() async {
    final token = DecisionCancellation();
    final mode = _mode;
    setState(() {
      _discoveryToken = token;
      _discovering = true;
      _discovery = null;
      _discoveryError = null;
    });
    try {
      final result = await _playground.discover(mode, cancellation: token);
      if (mounted && identical(_discoveryToken, token)) {
        setState(() => _discovery = result);
      }
    } catch (error) {
      if (mounted && identical(_discoveryToken, token)) {
        setState(() => _discoveryError = error.toString());
      }
    } finally {
      if (mounted && identical(_discoveryToken, token)) {
        setState(() {
          _discovering = false;
          _discoveryToken = null;
        });
      }
    }
  }

  Widget _field(String label, List<String> path, Object? value, String key) {
    if (value is! String) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text('$label：结构化值或省略字段，请在 JSON 中编辑。'),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey(key),
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        minLines: 1,
        maxLines: 4,
        onChanged: (text) => _edit(path, text),
      ),
    );
  }

  Widget _form(Map<String, Object?>? document) {
    if (document == null) return const Text('JSON 格式无效，原文已保留。请切换 JSON 修正。');
    final questions = document['questions'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field('State', ['state'], document['state'], 'playground-state'),
        if (questions is Map)
          for (final entry in questions.entries)
            if (entry.value is Map) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${entry.key} · ${entry.value['type']}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              _field(
                'Instructions',
                ['questions', entry.key as String, 'instructions'],
                entry.value['instructions'],
                'playground-instructions-${entry.key}',
              ),
              if (entry.value['criteria'] is Map)
                for (final option in (entry.value['criteria'] as Map).entries)
                  _field(
                    '${option.key}',
                    [
                      'questions',
                      entry.key as String,
                      'criteria',
                      option.key as String,
                    ],
                    option.value,
                    'playground-option-${entry.key}-${option.key}',
                  ),
              if (entry.value['criteria'] is! Map)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Criteria 数组、复杂值与题型在 JSON 中编辑。'),
                ),
            ],
      ],
    );
  }

  Widget _jsonBlock(
    String title,
    Object value,
    String key, {
    JevDebugProjection projection = JevDebugProjection.generic,
  }) {
    // Every display/copy projection crosses the credential redaction boundary.
    final safe = value is Map
        ? sealDebugJson(
            Map<String, Object?>.from(value),
            projection: projection,
          )
        : freezeDebugJson(value);
    final text = _encoder.convert(safe);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            TextButton.icon(
              key: Key('$key-copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制 JSON'),
            ),
          ],
        ),
        SelectableText(
          text,
          key: Key(key),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    DecisionBatchRequest? request;
    String? validation;
    Map<String, Object?>? preview;
    try {
      request = _playground.parse(_json.text).request;
      preview = _playground.preview(
        _mode,
        _json.text,
        nativeSource: _nativeSource,
      );
    } catch (error) {
      validation = error.toString();
    }
    final model = document?['model'];
    final native = _playground.nativeSources;
    final named = widget.controller.models.configuredModels;
    final names = _mode == JevPlaygroundMode.native
        ? native.map((s) => s.model).toList()
        : named.map((s) => s.definition.name).toList();
    final selected = names.contains(model) ? model as String : null;
    if (_mode != JevPlaygroundMode.native &&
        model is String &&
        !names.contains(model)) {
      validation ??= '调用模型名不存在，请显式选择已配置名称。提交会由本机服务返回本次错误。';
    }
    final result = _result;
    return SingleChildScrollView(
      key: const Key('playground-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('JEV 推理测试场', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            '复用 Ready 实例。选择原生实例或固定调用名，然后检查本次实际请求与结果。展示和复制时，认证字段以 [redacted] 呈现。',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<JevPlaygroundMode>(
            key: const Key('playground-mode'),
            initialValue: _mode,
            decoration: const InputDecoration(labelText: '调用入口'),
            isExpanded: true,
            items: [
              for (final mode in JevPlaygroundMode.values)
                DropdownMenuItem(
                  value: mode,
                  child: Text(switch (mode) {
                    JevPlaygroundMode.native => '原生 JEV · 受管实例',
                    JevPlaygroundMode.http => 'Jev HTTP · 本机服务',
                    JevPlaygroundMode.mcp => 'MCP · 本机服务',
                  }),
                ),
            ],
            onChanged: (mode) {
              if (mode != null) {
                setState(() {
                  _mode = mode;
                  _discoveryToken?.cancel();
                  _discoveryToken = null;
                  _discovering = false;
                  _discovery = null;
                  _discoveryError = null;
                });
              }
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('playground-model-${_mode.name}'),
            initialValue: selected,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: _mode == JevPlaygroundMode.native
                  ? '实际原生 alias'
                  : '固定调用名 · model',
            ),
            items: [
              for (final name in names)
                DropdownMenuItem(
                  value: name,
                  child: Text(name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: document == null ? null : _select,
          ),
          const SizedBox(height: 8),
          if (_mode == JevPlaygroundMode.native)
            for (final source in native)
              Text(
                '${source.label}\n${source.reason(request) ?? 'Ready · 本次能力可用'}',
                style: Theme.of(context).textTheme.bodySmall,
              )
          else
            for (final source in named)
              Text(
                '${source.definition.name} · ${source.definition.source == JevModelSource.council ? '委员会' : '固定原生名'} · ${source.reason ?? 'Ready'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          if (_mode != JevPlaygroundMode.native)
            Text(
              _mode == JevPlaygroundMode.http
                  ? 'HTTP：${widget.gateway.baseUrl ?? widget.gateway.state.name}'
                  : 'MCP：${widget.mcp.endpoint ?? widget.mcp.state.status.name}',
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('playground-discover'),
              onPressed: _discovering ? null : _discover,
              child: Text(_discovering ? '发现中' : '通过所选入口发现模型'),
            ),
          ),
          if (_discoveryError != null)
            Text(
              _discoveryError!,
              key: const Key('playground-discovery-error'),
            ),
          if (_discovery != null)
            _jsonBlock(
              '本次发现',
              _discovery!,
              'playground-discovery',
              projection: JevDebugProjection.discovery,
            ),
          Wrap(
            spacing: 12,
            children: [
              ChoiceChip(
                key: const Key('playground-form-mode'),
                label: const Text('表单'),
                selected: !_jsonMode,
                onSelected: (_) => setState(() => _jsonMode = false),
              ),
              ChoiceChip(
                key: const Key('playground-json-mode'),
                label: const Text('JSON'),
                selected: _jsonMode,
                onSelected: (_) => setState(() => _jsonMode = true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_jsonMode)
            TextField(
              key: const Key('playground-json'),
              controller: _json,
              minLines: 8,
              maxLines: 18,
              decoration: const InputDecoration(labelText: '完整请求 JSON'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
            )
          else
            _form(document),
          CheckboxListTile(
            key: const Key('playground-debug'),
            contentPadding: EdgeInsets.zero,
            title: const Text('本次请求显式 debug'),
            value: document?['debug'] == true,
            onChanged: document == null
                ? null
                : (value) => _edit(['debug'], value == true),
          ),
          if (validation != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                validation,
                key: const Key('playground-validation'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (preview != null)
            ExpansionTile(
              key: const Key('playground-preview-expand'),
              title: const Text('实际发送 JSON'),
              children: [
                _jsonBlock(
                  '发送内容',
                  preview,
                  'playground-preview',
                  projection: JevDebugProjection.request,
                ),
              ],
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('playground-submit'),
                onPressed: _active == null ? _run : null,
                child: Text(_active == null ? '提交测试' : '测试中'),
              ),
              if (_active != null)
                TextButton(
                  key: const Key('playground-cancel'),
                  onPressed: _active!.cancel,
                  child: const Text('取消本次调用'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (result != null) ...[
            Text(result.message, key: const Key('playground-status')),
            if (result.output != null)
              _jsonBlock(
                '本次结果',
                result.output!,
                'playground-output',
                projection: JevDebugProjection.response,
              ),
            if (result.debug != null)
              ExpansionTile(
                key: const Key('playground-debug-expand'),
                title: const Text('本次 debug · 来源 / 配置 / IO / 转换 / 耗时'),
                children: [
                  _jsonBlock(
                    'Debug',
                    result.debug!,
                    'playground-debug-output',
                    projection: JevDebugProjection.debug,
                  ),
                ],
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
