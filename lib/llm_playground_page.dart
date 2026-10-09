import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine_runtime.dart';
import 'jev_debug.dart';
import 'llm_playground.dart';
import 'public_gateway.dart';

class LlmPlaygroundPage extends StatefulWidget {
  const LlmPlaygroundPage({
    super.key,
    required this.gateway,
    this.active = true,
  });
  final PublicGatewayServer gateway;
  final bool active;

  @override
  State<LlmPlaygroundPage> createState() => _LlmPlaygroundPageState();
}

class _LlmPlaygroundPageState extends State<LlmPlaygroundPage> {
  static const _encoder = JsonEncoder.withIndent('  ');
  final _json = TextEditingController(
    text: _encoder.convert({
      'model': '',
      'messages': [
        {'role': 'user', 'content': '你好，请简单介绍自己。'},
      ],
      'stream': false,
      'max_tokens': 128,
    }),
  );
  late final _playground = LlmPlayground(baseUrl: () => widget.gateway.baseUrl);
  List<String> _models = [];
  StreamSubscription<PublicGatewayState>? _gatewayChanges;
  DecisionCancellation? _active;
  DecisionCancellation? _discoveryToken;
  Future<void>? _discoveryWork;
  LlmPlaygroundResult? _result;
  bool _jsonMode = false;
  bool _discovering = false;
  bool _discovered = false;
  int _discoveryGeneration = 0;
  int _formRevision = 0;
  String? _discoveryError;
  String _timeout = '120';
  String? _exportMessage;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _json.addListener(_changed);
    _gatewayChanges = widget.gateway.changes.listen((_) {
      if (mounted && widget.active) unawaited(_discover());
    });
    if (widget.active) unawaited(_discover());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant LlmPlaygroundPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _active?.cancel();
      _discoveryToken?.cancel();
      _discoveryGeneration++;
      _discovering = false;
    }
    if (!oldWidget.active && widget.active) unawaited(_discover());
  }

  @override
  void dispose() {
    _active?.cancel();
    _discoveryToken?.cancel();
    _discoveryGeneration++;
    unawaited(_gatewayChanges?.cancel());
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

  void _write(Map<String, Object?> document) {
    _json.text = _encoder.convert(document);
  }

  void _edit(String field, Object? value, {bool remove = false}) {
    final document = _document;
    if (document == null) return;
    if (remove) {
      document.remove(field);
    } else {
      document[field] = value;
    }
    _write(document);
  }

  void _editMessage(int index, String field, String value) {
    final document = _document;
    if (document == null) return;
    final messages = document['messages'];
    if (messages is! List || messages[index] is! Map) return;
    (messages[index] as Map)[field] = value;
    _write(document);
  }

  Future<void> _discover() async {
    final previous = _discoveryWork;
    _discoveryToken?.cancel();
    final token = DecisionCancellation();
    _discoveryToken = token;
    final generation = ++_discoveryGeneration;
    final timeout = _deadline;
    setState(() {
      _discovering = true;
      _discoveryError = null;
    });
    final work = () async {
      try {
        if (previous != null) await previous;
        if (!mounted || !widget.active || token.isCancelled) return;
        if (timeout == null) throw const FormatException('客户端期限必须为大于零的有效秒数');
        final models = await _playground.discover(
          cancellation: token,
          timeout: timeout,
        );
        if (mounted && generation == _discoveryGeneration) {
          setState(() {
            _models = models;
            _discovered = true;
          });
        }
      } catch (error) {
        if (mounted && generation == _discoveryGeneration) {
          setState(() {
            _models = [];
            _discoveryError = error.toString();
          });
        }
      } finally {
        if (mounted && generation == _discoveryGeneration) {
          setState(() => _discovering = false);
        }
      }
    }();
    _discoveryWork = work;
    await work;
    if (identical(_discoveryWork, work)) {
      _discoveryWork = null;
      _discoveryToken = null;
    }
  }

  Duration? get _deadline {
    final seconds = double.tryParse(_timeout);
    final micros = seconds == null
        ? null
        : seconds * Duration.microsecondsPerSecond;
    return micros == null || !micros.isFinite || micros < 1
        ? null
        : Duration(microseconds: micros.round());
  }

  Future<void> _run() async {
    final deadline = _deadline;
    if (_active != null || deadline == null) return;
    final cancellation = DecisionCancellation();
    setState(() {
      _active = cancellation;
      _result = null;
    });
    final result = await _playground.run(
      _json.text,
      cancellation: cancellation,
      timeout: deadline,
      onProgress: (progress) {
        if (mounted && identical(_active, cancellation)) {
          setState(() => _result = progress);
        }
      },
    );
    if (mounted && identical(_active, cancellation)) {
      setState(() {
        _result = result;
        _active = null;
      });
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final document = _json.text;
      final result = _result;
      final timeout = _deadline ?? const Duration(seconds: 120);
      var path = '';
      var dialogCompleted = false;
      void finishDialog(BuildContext dialogContext, [String? destination]) {
        if (dialogCompleted ||
            ModalRoute.of(dialogContext)?.isCurrent != true) {
          return;
        }
        dialogCompleted = true;
        Navigator.pop(dialogContext, destination);
      }

      final destination = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出基础测试 JSON'),
          content: SizedBox(
            width: 480,
            child: TextField(
              key: const Key('llm-export-path'),
              onChanged: (value) => path = value,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '文件完整绝对路径',
                helperText: '已有文件不会覆盖',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => finishDialog(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('llm-export-confirm'),
              onPressed: () => finishDialog(context, path),
              child: const Text('导出'),
            ),
          ],
        ),
      );
      if (destination == null || destination.isEmpty || !mounted) return;
      setState(() {
        _exportMessage = null;
      });
      try {
        await _playground.exportTo(
          File(destination),
          document: document,
          result: result,
          timeout: timeout,
        );
        if (mounted) setState(() => _exportMessage = '已导出：$destination');
      } catch (error) {
        if (mounted) setState(() => _exportMessage = '导出失败：$error');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _numberField(String field, Map<String, Object?> document) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('llm-$field-$_formRevision'),
      initialValue: document[field]?.toString() ?? '',
      decoration: InputDecoration(labelText: field),
      onChanged: (value) {
        final number = num.tryParse(value);
        _edit(
          field,
          number != null && number.isFinite ? number : value,
          remove: value.isEmpty,
        );
      },
    ),
  );

  Widget _form(Map<String, Object?>? document) {
    if (document == null) return const Text('JSON 格式无效，原文已保留。请切换 JSON 修正。');
    final messages = document['messages'];
    return Column(
      key: ValueKey('llm-form-$_formRevision'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (messages is List)
          for (var index = 0; index < messages.length; index++) ...[
            if (messages[index] is Map) ...[
              Text(
                '消息 ${index + 1}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: ValueKey('llm-role-$index-$_formRevision'),
                initialValue:
                    (messages[index] as Map)['role']?.toString() ?? '',
                decoration: const InputDecoration(
                  labelText: 'role · system / user / assistant',
                ),
                onChanged: (value) => _editMessage(index, 'role', value),
              ),
              const SizedBox(height: 8),
              if ((messages[index] as Map)['content'] is String)
                TextFormField(
                  key: Key('llm-message-$index'),
                  initialValue: (messages[index] as Map)['content'] as String,
                  decoration: const InputDecoration(labelText: 'content'),
                  minLines: 2,
                  maxLines: 5,
                  onChanged: (value) => _editMessage(index, 'content', value),
                )
              else
                const Text('此消息内容由完整 JSON 保留；当前接口仅支持文本。'),
              TextButton(
                onPressed: () {
                  messages.removeAt(index);
                  _formRevision++;
                  _write(document);
                },
                child: const Text('删除消息'),
              ),
            ] else
              const Text('此消息结构无法用表单编辑，请在 JSON 中修正。'),
          ]
        else
          const Text('messages 由完整 JSON 保留；请使用非空文本消息数组。'),
        TextButton.icon(
          onPressed: messages is! List
              ? null
              : () {
                  messages.add({'role': 'user', 'content': ''});
                  _formRevision++;
                  _write(document);
                },
          icon: const Icon(Icons.add),
          label: const Text('添加消息'),
        ),
        SwitchListTile(
          title: const Text('SSE 流式响应'),
          value: document['stream'] == true,
          onChanged: (value) => _edit('stream', value),
        ),
        for (final field in ['max_tokens', 'temperature', 'top_p'])
          _numberField(field, document),
        const Text('完整 JSON 保留其他字段；公开服务会明确返回不支持字段的错误。'),
      ],
    );
  }

  String _safeText(Object? value) {
    final safe = sealDebugJson({'value': value});
    return safe['value'] is String
        ? safe['value'] as String
        : _encoder.convert(safe['value']);
  }

  Widget _copySection(
    String title,
    String key,
    Object? value, {
    bool sealed = false,
  }) {
    final text = sealed
        ? (value is String ? value : _encoder.convert(value))
        : _safeText(value);
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
              label: const Text('复制'),
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
    final model = document?['model'];
    final selected = _models.contains(model) ? model as String : null;
    final result = _result;
    final evidence = result?.toJson();
    final input = sealDebugJson({
      'input': _json.text,
    }, projection: JevDebugProjection.llmEvidence)['input'];
    return SingleChildScrollView(
      key: const Key('llm-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '通用 LLM · 基础测试',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('通过公开 HTTP 使用已 Ready 的文本模型。输入与输出保留在当前会话；展示、复制时认证字段会脱敏。'),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: const Key('llm-model'),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '公开文本模型 · model'),
            items: [
              for (final id in _models)
                DropdownMenuItem(
                  value: id,
                  child: Text(id, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: document == null
                ? null
                : (value) => _edit('model', value),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('llm-discover'),
              onPressed: _discovering ? null : _discover,
              icon: const Icon(Icons.refresh),
              label: Text(_discovering ? '正在发现…' : '发现公开模型'),
            ),
          ),
          if (_discovered)
            Text(
              _models.isEmpty
                  ? '没有 Ready 且公开可调用的文本模型，请在引擎中准备。'
                  : '公开可调用文本模型：${_models.length}',
              key: const Key('llm-discovery'),
            ),
          if (_discoveryError != null)
            Text(
              _safeText(_discoveryError),
              key: const Key('llm-discovery-error'),
            ),
          if (model is String && model.isNotEmpty && selected == null)
            const Text('该 model 未在公开发现中可用。刷新发现或选择 Ready 文本模型。'),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                key: const Key('llm-form-mode'),
                onPressed: () => setState(() {
                  _jsonMode = false;
                  _formRevision++;
                }),
                child: const Text('表单'),
              ),
              TextButton(
                key: const Key('llm-json-mode'),
                onPressed: () => setState(() => _jsonMode = true),
                child: const Text('完整 JSON'),
              ),
            ],
          ),
          if (_jsonMode)
            TextField(
              key: const Key('llm-json'),
              controller: _json,
              minLines: 8,
              maxLines: 24,
              decoration: const InputDecoration(labelText: 'HTTP Chat JSON'),
            )
          else
            _form(document),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('llm-timeout'),
            initialValue: _timeout,
            decoration: InputDecoration(
              labelText: '客户端期限（秒）',
              errorText: _deadline == null ? '请输入大于零的有效秒数' : null,
            ),
            onChanged: (value) => setState(() => _timeout = value),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                key: const Key('llm-run'),
                onPressed:
                    _active != null || selected == null || _deadline == null
                    ? null
                    : _run,
                child: const Text('发送 HTTP 请求'),
              ),
              TextButton.icon(
                key: const Key('llm-export'),
                onPressed: _exporting ? null : _export,
                icon: const Icon(Icons.save_alt),
                label: Text(_exporting ? '正在导出…' : '导出 JSON'),
              ),
              TextButton(
                key: const Key('llm-cancel'),
                onPressed: _active?.cancel,
                child: const Text('取消'),
              ),
            ],
          ),
          if (_exportMessage != null)
            Text(
              _safeText(_exportMessage),
              key: const Key('llm-export-message'),
            ),
          const SizedBox(height: 12),
          _copySection(
            '请求预览 · ${widget.gateway.baseUrl?.resolve('/v1/chat/completions') ?? '服务未运行'}',
            'llm-request',
            input,
            sealed: true,
          ),
          if (result != null) ...[
            Text(
              result.completed
                  ? '已完成'
                  : result.timedOut
                  ? '客户端超时'
                  : result.cancelled
                  ? '已取消'
                  : result.interrupted
                  ? '流式中断'
                  : _active != null
                  ? '正在接收'
                  : '请求失败',
              key: Key(
                result.completed
                    ? 'llm-completed'
                    : result.timedOut
                    ? 'llm-timed-out'
                    : result.cancelled
                    ? 'llm-cancelled'
                    : result.interrupted
                    ? 'llm-interrupted'
                    : _active != null
                    ? 'llm-running'
                    : 'llm-failed',
              ),
            ),
            if (result.text.isNotEmpty)
              SelectableText(
                evidence!['text'] as String,
                key: const Key('llm-text'),
              ),
            _copySection(
              '返回原文',
              'llm-raw-response',
              evidence!['raw_response'],
              sealed: true,
            ),
            _copySection('解析结果与实际请求', 'llm-result', evidence, sealed: true),
          ],
        ],
      ),
    );
  }
}
