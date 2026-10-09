import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'council_mcp.dart';
import 'jev_debug.dart';
import 'jev_playground.dart';
import 'public_gateway.dart';

class JevPlaygroundPage extends StatefulWidget {
  const JevPlaygroundPage({
    super.key,
    required this.gateway,
    required this.mcp,
    this.active = true,
  });
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
    gateway: widget.gateway,
    mcp: widget.mcp,
  );
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _timeout = TextEditingController(text: '30');
  String? _exportStatus;
  bool _exporting = false;
  JevPlaygroundMode _mode = JevPlaygroundMode.http;
  bool _jsonMode = false;
  DecisionCancellation? _active;
  JevPlaygroundResult? _result;
  Map<String, Object?>? _discovery;
  String? _discoveryError;
  bool _discovering = false;
  bool _refreshPending = false;
  DecisionCancellation? _discoveryToken;

  @override
  void initState() {
    super.initState();
    _json.addListener(_changed);
    _timeout.addListener(_changed);
    final models = widget.gateway.jevModels;
    if (models != null) {
      _subscriptions.add(
        models.changes.listen((_) {
          // Notifications only invalidate cached discovery; never substitute an
          // internal registry list for the public HTTP/MCP discovery response.
          if (!widget.active) {
            _invalidateDiscovery();
            _changed();
          } else if (_active != null || _discovering) {
            _refreshPending = true;
          } else {
            unawaited(_discover());
          }
        }),
      );
    }
    _subscriptions.add(widget.gateway.changes.listen((_) => _serviceChanged()));
    _subscriptions.add(widget.mcp.changes.listen((_) => _serviceChanged()));
  }

  @override
  void didUpdateWidget(covariant JevPlaygroundPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _active?.cancel();
      _invalidateDiscovery();
    }
  }

  void _invalidateDiscovery() {
    _discoveryToken?.cancel();
    _discoveryToken = null;
    _discovering = false;
    _refreshPending = false;
    _discovery = null;
    _discoveryError = null;
  }

  void _serviceChanged() {
    if (_mode == JevPlaygroundMode.http
        ? widget.gateway.state != PublicGatewayState.running
        : widget.mcp.state.status != CouncilMcpStatus.running) {
      _invalidateDiscovery();
    }
    _changed();
  }

  Duration? get _clientDeadline {
    final seconds = double.tryParse(_timeout.text);
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    final micros = seconds * Duration.microsecondsPerSecond;
    if (!micros.isFinite || micros < 1 || micros >= 9223372036854775807) {
      return null;
    }
    return Duration(microseconds: micros.round());
  }

  void _changed() {
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
    _timeout.dispose();
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
    Object? cursor = document;
    for (final key in path.take(path.length - 1)) {
      cursor = switch (cursor) {
        Map() => cursor[key],
        List() => cursor[int.parse(key)],
        _ => null,
      };
    }
    if (cursor is Map) {
      cursor[path.last] = value;
    } else if (cursor is List) {
      cursor[int.parse(path.last)] = value;
    } else {
      return;
    }
    _json.text = _encoder.convert(document);
  }

  void _addQuestion(String type) {
    final questions = _document?['questions'];
    if (questions is! Map) return;
    var index = 1;
    while (questions.containsKey('question_$index')) {
      index++;
    }
    _edit(
      ['questions', 'question_$index'],
      {
        'type': type,
        'instructions': switch (type) {
          'score' => '选择合适的级别。',
          'noul' => '判断条件是否成立。',
          _ => '选择最合适的一项。',
        },
        if (type == 'choice') 'criteria': {'a': 'A', 'b': 'B'},
        if (type == 'score') 'criteria': ['低', '高'],
      },
    );
  }

  void _select(String? model) {
    if (model == null) return;
    _edit(['model'], model);
  }

  Future<void> _run() async {
    if (_active != null || _clientDeadline == null) return;
    final token = DecisionCancellation();
    final mode = _mode;
    final document = _json.text;
    final deadline = _clientDeadline!;
    setState(() {
      _active = token;
      _result = null;
    });
    final result = await _playground.run(
      mode,
      document,
      cancellation: token,
      timeout: deadline,
    );
    if (mounted && identical(_active, token)) {
      setState(() {
        _result = result;
        _active = null;
        final error = result.output?['error'];
        if (error is Map &&
            const {
              'model_not_ready',
              'model_not_found',
              'route_conflict',
            }.contains(error['code'])) {
          _invalidateDiscovery();
        }
      });
      if (_refreshPending && widget.active && !_discovering) {
        _refreshPending = false;
        unawaited(_discover());
      }
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
      _playground.modelsFromDiscovery(result);
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
        if (_refreshPending && widget.active && _active == null) {
          _refreshPending = false;
          unawaited(_discover());
        }
      }
    }
  }

  Future<void> _export() async {
    var path = '';
    final destination = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出本次测试 JSON'),
        content: TextField(
          key: const Key('playground-export-path'),
          onChanged: (value) => path = value,
          decoration: const InputDecoration(
            labelText: '完整文件路径',
            helperText: '保存到新文件；已有文件不会覆盖。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('playground-export-save'),
            onPressed: () => Navigator.pop(context, path.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (destination == null || !mounted) return;
    setState(() {
      _exporting = true;
      _exportStatus = null;
    });
    try {
      await _playground.exportTo(
        File(destination),
        document: _json.text,
        result: _result,
        mode: _mode,
        timeout: _clientDeadline ?? const Duration(seconds: 30),
      );
      if (mounted) setState(() => _exportStatus = '已导出：$destination');
    } catch (error) {
      if (mounted) setState(() => _exportStatus = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _textBlock(String title, String text, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          TextButton.icon(
            key: Key('$key-copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制原文'),
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
              if (entry.value['criteria'] is List)
                for (
                  var index = 0;
                  index < (entry.value['criteria'] as List).length;
                  index++
                )
                  _field(
                    '级别 $index',
                    ['questions', entry.key as String, 'criteria', '$index'],
                    (entry.value['criteria'] as List)[index],
                    'playground-score-${entry.key}-$index',
                  ),
              if (entry.value['criteria'] is! Map &&
                  entry.value['criteria'] is! List &&
                  entry.value['type'] != 'noul')
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('复杂 Criteria 或省略字段请在 JSON 中编辑。'),
                ),
            ],
        if (questions is Map)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final type in ['choice', 'score', 'noul'])
                TextButton.icon(
                  key: Key('playground-add-$type'),
                  onPressed: () => _addQuestion(type),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text('添加 $type 题'),
                ),
            ],
          ),
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
    String? validation;
    Map<String, Object?>? preview;
    try {
      preview = _playground.preview(_mode, _json.text);
    } catch (error) {
      validation = error.toString();
    }
    final model = document?['model'];
    final models = _discovery == null
        ? <JevDiscoveredModel>[]
        : _playground.modelsFromDiscovery(_discovery!);
    final names = models.map((entry) => entry.id).toList();
    final selected = names.contains(model) ? model as String : null;
    if (selected == null) {
      validation ??= '请通过所选公开入口发现并选择可调用的 Ready 模型。测试场不会加载模型。';
    }
    final deadline = _clientDeadline;
    if (deadline == null) validation ??= '客户端期限需要是可表示的正秒数。';
    final result = _result;
    return SingleChildScrollView(
      key: const Key('playground-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('JEV 推理测试场', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            '通过真实 HTTP/MCP 发现 Ready 原生模型或委员会，再检查实际请求与结果。展示和复制时，认证字段以 [redacted] 呈现。',
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
                    JevPlaygroundMode.http => 'Jev HTTP · 本机服务',
                    JevPlaygroundMode.mcp => 'MCP · 本机服务',
                  }),
                ),
            ],
            onChanged: (mode) {
              if (mode != null) {
                setState(() {
                  _mode = mode;
                  _invalidateDiscovery();
                });
              }
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('playground-model-${_mode.name}'),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '公开调用名 · model'),
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
          for (final source in models)
            Text(source.label, style: Theme.of(context).textTheme.bodySmall),
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
          TextField(
            key: const Key('playground-timeout'),
            controller: _timeout,
            enabled: _active == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '客户端期限（秒）',
              helperText: '默认 30 秒；只控制本次客户端请求，不修改模型或委员会预算。',
            ),
          ),
          const SizedBox(height: 12),
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
                onPressed:
                    _active == null && validation == null && widget.active
                    ? _run
                    : null,
                child: Text(_active == null ? '提交测试' : '测试中'),
              ),
              TextButton.icon(
                key: const Key('playground-export'),
                onPressed: _exporting ? null : _export,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出 JSON'),
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
          if (_exportStatus != null)
            Text(_exportStatus!, key: const Key('playground-export-status')),
          if (result != null) ...[
            Text(result.message, key: const Key('playground-status')),
            Text(
              '${result.mode.name.toUpperCase()} · ${result.diagnostic ? '公开 debug 诊断' : '性能调用'} · 客户端期限 ${result.timeout.inMilliseconds} ms · 端到端 ${result.elapsed.inMilliseconds} ms${result.httpStatus == null ? '' : ' · HTTP ${result.httpStatus}'}',
              key: const Key('playground-result-meta'),
            ),
            if (result.requestBody != null)
              ExpansionTile(
                title: const Text('本次实际发送 JSON'),
                children: [
                  _textBlock(
                    '请求快照',
                    result.requestBody!,
                    'playground-sent-request',
                  ),
                ],
              ),
            if (result.rawResponse != null)
              _textBlock(
                result.mode == JevPlaygroundMode.http
                    ? 'HTTP 返回原文'
                    : 'MCP 工具返回原文',
                result.rawResponse!,
                'playground-raw-response',
              ),
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
