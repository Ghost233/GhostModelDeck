import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'embedding_playground.dart';
import 'engine_runtime.dart';
import 'jev_debug.dart';
import 'public_gateway.dart';

class EmbeddingPage extends StatefulWidget {
  const EmbeddingPage({super.key, required this.gateway, this.active = true});
  final PublicGatewayServer gateway;
  final bool active;
  @override
  State<EmbeddingPage> createState() => _EmbeddingPageState();
}

class _EmbeddingPageState extends State<EmbeddingPage> {
  static const _encoder = JsonEncoder.withIndent('  ');
  final _json = TextEditingController(
    text: _encoder.convert({
      'model': '',
      'input': ['query: 苹果是一种水果', 'passage: 苹果与香蕉都是水果'],
      'encoding_format': 'float',
    }),
  );
  late final _playground = EmbeddingPlayground(
    baseUrl: () => widget.gateway.baseUrl,
  );
  StreamSubscription<PublicGatewayState>? _gatewayChanges;
  DecisionCancellation? _active;
  DecisionCancellation? _discoveryToken;
  Future<void>? _discoveryWork;
  EmbeddingPlaygroundResult? _result;
  List<String> _models = [];
  int _discoveryGeneration = 0;
  bool _discovering = false;
  bool _exporting = false;
  String? _discoveryError;
  String? _exportMessage;
  String _timeout = '120';

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
  void didUpdateWidget(covariant EmbeddingPage oldWidget) {
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

  Duration? get _deadline {
    final seconds = double.tryParse(_timeout);
    final micros = seconds == null
        ? null
        : seconds * Duration.microsecondsPerSecond;
    return micros == null || !micros.isFinite || micros < 1
        ? null
        : Duration(microseconds: micros.round());
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
          setState(() => _models = models);
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

  Future<void> _run() async {
    final timeout = _deadline;
    if (_active != null || timeout == null) return;
    final token = DecisionCancellation();
    setState(() {
      _active = token;
      _result = null;
      _exportMessage = null;
    });
    final result = await _playground.run(
      _json.text,
      cancellation: token,
      timeout: timeout,
    );
    if (mounted && identical(_active, token)) {
      setState(() {
        _result = result;
        _active = null;
      });
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final document = _json.text;
    final result = _result;
    final timeout = _deadline ?? const Duration(seconds: 120);
    var path = '';
    var completed = false;
    void closeDialog(BuildContext context, [String? path]) {
      if (completed || ModalRoute.of(context)?.isCurrent != true) return;
      completed = true;
      Navigator.pop(context, path);
    }

    try {
      final destination = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出嵌入测试 JSON'),
          content: SizedBox(
            width: 480,
            child: TextField(
              key: const Key('embedding-export-path'),
              autofocus: true,
              onChanged: (value) => path = value,
              decoration: const InputDecoration(
                labelText: '文件完整绝对路径',
                helperText: '已有文件不会覆盖',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => closeDialog(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('embedding-export-confirm'),
              onPressed: () => closeDialog(context, path),
              child: const Text('导出'),
            ),
          ],
        ),
      );
      if (destination == null || destination.isEmpty || !mounted) return;
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

  Widget _evidence(String label, String key, Object? value) {
    final text = value is String ? value : _encoder.convert(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
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
    final vectors = result?.result;
    final evidence = result?.toJson();
    final safeInput = sealDebugJson({
      'input': _json.text,
    }, projection: JevDebugProjection.embeddingEvidence)['input'];
    return SingleChildScrollView(
      key: const Key('embedding-scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('嵌入 · 基础测试', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('通过公开 HTTP 生成文本向量。query/passage 前缀按模型要求填写；相似度只表示本次向量关系。'),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: const Key('embedding-model'),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '公开嵌入模型 · model'),
            items: [
              for (final id in _models)
                DropdownMenuItem(
                  value: id,
                  child: Text(id, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: document == null || _active != null
                ? null
                : (value) {
                    setState(() => _result = null);
                    _json.text = _encoder.convert({
                      ...document,
                      'model': value,
                    });
                  },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('embedding-discover'),
              onPressed: _discovering ? null : _discover,
              icon: const Icon(Icons.refresh),
              label: Text(_discovering ? '正在发现…' : '发现公开模型'),
            ),
          ),
          if (!_discovering && _discoveryError == null)
            Text(
              _models.isEmpty
                  ? '没有 Ready 且公开可调用的嵌入模型，请在引擎中准备。'
                  : '公开可调用嵌入模型：${_models.length}',
              key: const Key('embedding-discovery'),
            ),
          if (_discoveryError != null)
            Text(
              sealDebugJson({'error': _discoveryError})['error'].toString(),
              key: const Key('embedding-discovery-error'),
            ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('embedding-json'),
            controller: _json,
            minLines: 6,
            maxLines: 20,
            decoration: const InputDecoration(
              labelText: 'HTTP Embeddings JSON · 文本或文本数组',
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('embedding-timeout'),
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
                key: const Key('embedding-run'),
                onPressed:
                    _active != null ||
                        selected == null ||
                        _deadline == null ||
                        !widget.active
                    ? null
                    : _run,
                child: const Text('发送 HTTP 请求'),
              ),
              if (_active != null)
                TextButton(
                  key: const Key('embedding-cancel'),
                  onPressed: _active?.cancel,
                  child: const Text('取消请求'),
                ),
              TextButton.icon(
                key: const Key('embedding-export'),
                onPressed: _exporting ? null : _export,
                icon: const Icon(Icons.save_alt),
                label: const Text('导出 JSON'),
              ),
            ],
          ),
          if (_active != null)
            const Text('正在生成嵌入…', key: Key('embedding-running')),
          if (result != null) ...[
            Text(
              result.completed
                  ? '嵌入完成'
                  : result.cancelled
                  ? '本次请求已取消'
                  : result.timedOut
                  ? '客户端请求超时'
                  : '嵌入失败',
              key: Key(
                result.completed
                    ? 'embedding-completed'
                    : result.cancelled
                    ? 'embedding-cancelled'
                    : result.timedOut
                    ? 'embedding-timed-out'
                    : 'embedding-failed',
              ),
            ),
            Text(
              'HTTP ${result.statusCode ?? '未发送'} · ${(result.elapsed.inMicroseconds / 1000000).toStringAsFixed(3)} 秒',
            ),
          ],
          if (_exportMessage != null)
            Text(
              sealDebugJson({'message': _exportMessage})['message'].toString(),
              key: const Key('embedding-export-message'),
            ),
          const SizedBox(height: 16),
          if (vectors != null) ...[
            Text(
              '向量数量：${vectors.vectors.length} · 维度：${vectors.dimensions}',
              key: const Key('embedding-dimensions'),
            ),
            for (var index = 0; index < vectors.vectors.length; index++)
              Text(
                '输入 $index · 范数 ${vectors.norm(index).toStringAsPrecision(6)} · 前 ${vectors.dimensions < 8 ? vectors.dimensions : 8} 项：${vectors.vectors[index].take(8).toList()}',
                key: Key('embedding-vector-$index'),
              ),
            if (vectors.vectors.length == 2)
              Text(
                '两条输入余弦相似度：${vectors.cosineSimilarity(0, 1)?.toStringAsFixed(6) ?? '零向量不可计算'}',
                key: const Key('embedding-similarity'),
              ),
            const SizedBox(height: 16),
          ],
          _evidence('当前输入', 'embedding-input', safeInput),
          if (evidence != null)
            _evidence('实际请求与原始响应', 'embedding-result', evidence),
        ],
      ),
    );
  }
}
