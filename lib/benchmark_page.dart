import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'benchmark_resources.dart';
import 'benchmark_runner.dart';
import 'benchmark_run_store.dart';
import 'jev_playground.dart';

/// The application owns resources and batches; this page only observes them.
class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({
    super.key,
    required this.resources,
    required this.runner,
  });
  final BenchmarkResources resources;
  final BenchmarkRunner runner;

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _timeout = TextEditingController(text: '30');
  late final StreamSubscription<BenchmarkRun> _subscription;
  late final StreamSubscription<BenchmarkResourceProgress?>
  _resourceSubscription;
  List<JevDiscoveredModel> _targets = const [];
  String? _model;
  bool _discovering = true;
  bool _starting = false;
  BenchmarkRun? _record;
  List<BenchmarkRun> _history = const [];
  bool _historyLoading = true;
  String? _historyError;
  bool _viewingHistory = false;
  int _detail = 0;
  bool _fileBusy = false;
  String? _fileStatus;
  String? _error;
  DecisionCancellation? _discoveryToken;

  String get _resourceStatus => switch (widget.resources.status) {
    BenchmarkResourceStatus.idle => '固定原题尚未准备；开始时下载或重新核验缓存。',
    BenchmarkResourceStatus.preparing =>
      '资源准备中 · ${_progress?.currentPath ?? '校验固定版本原题'}',
    BenchmarkResourceStatus.ready => '原题及摘要核验完成 · 400 题 / 200 对；新批次会重新校验缓存。',
    BenchmarkResourceStatus.cancelled => '资源准备已取消；未开始模型评测。',
    BenchmarkResourceStatus.failed =>
      '准备失败（未计入模型失败）：${widget.resources.lastError}',
  };
  bool get _preparing => widget.resources.preparing;
  BenchmarkResourceProgress? get _progress => widget.resources.progress;
  bool get _busy => _starting || _preparing || widget.runner.running;
  Duration? get _deadline {
    final seconds = double.tryParse(_timeout.text);
    final micros = seconds == null
        ? null
        : seconds * Duration.microsecondsPerSecond;
    if (micros == null || !micros.isFinite || micros < 1) return null;
    return Duration(microseconds: micros.round());
  }

  @override
  void initState() {
    super.initState();
    _record = widget.runner.current;
    _resourceSubscription = widget.resources.changes.listen((_) => _changed());
    _subscription = widget.runner.changes.listen((record) {
      if (mounted) {
        setState(() {
          if (!_viewingHistory) _record = record;
        });
        if (record.status != BenchmarkRunStatus.running) {
          unawaited(_loadHistory());
        }
      }
    });
    _timeout.addListener(_changed);
    unawaited(_discover());
    unawaited(_loadHistory());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _discover() async {
    _discoveryToken?.cancel();
    final token = DecisionCancellation();
    _discoveryToken = token;
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final targets = await widget.runner.targets(cancellation: token);
      if (mounted && identical(token, _discoveryToken)) {
        setState(() {
          _targets = targets;
          if (!targets.any((target) => target.id == _model)) _model = null;
        });
      }
    } catch (error) {
      if (mounted && identical(token, _discoveryToken)) {
        setState(() {
          _targets = const [];
          _model = null;
          _error = '公开 HTTP 发现失败：$error';
        });
      }
    } finally {
      if (mounted && identical(token, _discoveryToken)) {
        setState(() => _discovering = false);
        _discoveryToken = null;
      }
    }
  }

  Future<void> _start() async {
    final model = _model;
    final deadline = _deadline;
    if (_busy || model == null || deadline == null) return;
    final resources = widget.resources;
    final runner = widget.runner;
    final token = DecisionCancellation();
    var preparingStage = true;
    setState(() {
      _starting = true;
      _error = null;
      _viewingHistory = false;
      _detail = 0;
    });
    try {
      final suite = await resources.prepareSuite(token);
      preparingStage = false;
      // Leaving this page does not abandon the prepared application batch.
      await runner.run(suite: suite, model: model, timeout: deadline);
    } on BenchmarkResourceCancelled {
      // The resource owner publishes its terminal cancellation to every page.
    } catch (error) {
      if (mounted &&
          (!preparingStage ||
              resources.status != BenchmarkResourceStatus.failed)) {
        setState(() {
          _error = preparingStage ? '无法开始准备：$error' : '评测失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _loadHistory() async {
    try {
      final history = await widget.runner.store.list();
      if (mounted) {
        setState(() {
          _history = history;
          _historyError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _historyError = '历史读取失败：$error');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _view(BenchmarkRun selected) async {
    try {
      final record = await widget.runner.store.load(selected.id);
      if (mounted) {
        setState(() {
          final current = widget.runner.current;
          _viewingHistory = current?.id != record.id;
          _record = _viewingHistory ? record : current;
          _detail = 0;
          _fileStatus = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _historyError = '记录读取失败：$error');
    }
  }

  Future<void> _export() async {
    final record = _record;
    if (_fileBusy ||
        record == null ||
        record.status == BenchmarkRunStatus.running) {
      return;
    }
    setState(() {
      _fileBusy = true;
      _fileStatus = null;
    });
    try {
      var path = '';
      var done = false;
      void finish(BuildContext dialogContext, [String? value]) {
        if (done || ModalRoute.of(dialogContext)?.isCurrent != true) return;
        done = true;
        Navigator.pop(dialogContext, value);
      }

      final destination = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出评测记录'),
          content: TextField(
            key: const Key('benchmark-export-path'),
            onChanged: (value) => path = value,
            decoration: const InputDecoration(
              labelText: '完整文件路径',
              helperText: '保存逐题/配对/身份与原分数；已有文件不会覆盖。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => finish(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('benchmark-export-save'),
              onPressed: () => finish(context, path.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (destination == null) return;
      await widget.runner.store.exportTo(record.id, File(destination));
      if (mounted) setState(() => _fileStatus = '已导出：$destination');
    } catch (error) {
      if (mounted) setState(() => _fileStatus = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _fileBusy = false);
    }
  }

  Future<void> _delete() async {
    final record = _record;
    if (_fileBusy ||
        record == null ||
        record.status == BenchmarkRunStatus.running) {
      return;
    }
    setState(() {
      _fileBusy = true;
      _fileStatus = null;
    });
    try {
      var done = false;
      void finish(BuildContext dialogContext, bool confirmed) {
        if (done || ModalRoute.of(dialogContext)?.isCurrent != true) return;
        done = true;
        Navigator.pop(dialogContext, confirmed);
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除本批历史记录'),
          content: Text(
            '${record.model} · ${record.id}\n删除这份记录，模型、题库和其他批次不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => finish(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('benchmark-delete-confirm'),
              onPressed: () => finish(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await widget.runner.store.delete(record.id);
      if (mounted) {
        setState(() {
          _record = null;
          _viewingHistory = false;
          _fileStatus = '已删除本批记录';
        });
      }
      await _loadHistory();
    } catch (error) {
      if (mounted) setState(() => _fileStatus = '删除失败：$error');
    } finally {
      if (mounted) setState(() => _fileBusy = false);
    }
  }

  String _status(BenchmarkRunStatus status) => switch (status) {
    BenchmarkRunStatus.running => '运行中',
    BenchmarkRunStatus.completed => '完整执行',
    BenchmarkRunStatus.failed => '失败',
    BenchmarkRunStatus.cancelled => '已取消 · 未完成',
    BenchmarkRunStatus.interrupted => '已中断 · 未完成',
    BenchmarkRunStatus.targetUnavailable => '对象不可用 · 未完成',
  };

  String _percent(Object? value) =>
      value is num ? '${(value * 100).toStringAsFixed(2)}%' : '未完成，不发布完整分数';

  Widget _json(Object? value, String key) {
    // The store has already validated and sealed all known task/evidence roles.
    // Reapplying generic credential rules here would corrupt legal task data.
    final text = const JsonEncoder.withIndent('  ').convert(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: Key('$key-copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制 JSON'),
          ),
        ),
        SelectableText(
          text,
          key: Key(key),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontFamily: 'monospace'),
        ),
      ],
    );
  }

  Widget _report(BenchmarkRun record) {
    final summary = record.summary;
    final completed = summary['complete'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('批次报告', style: Theme.of(context).textTheme.titleLarge),
        Text(
          '${record.model} · HTTP · ${_status(record.status)}',
          key: const Key('benchmark-current-status'),
        ),
        Text(
          '批次：${record.id} · ${record.createdAt.toLocal()} · 客户端期限 ${record.timeout.inMilliseconds} ms',
        ),
        Text(
          '${completed ? '完整执行' : '未完成'} · 已执行 ${summary['attempted']} / 400 · 有效 ${summary['valid']} · 失败 ${summary['failures']} · 缺失 ${summary['missing']}',
          key: const Key('benchmark-coverage'),
        ),
        if (record.status == BenchmarkRunStatus.running)
          LinearProgressIndicator(value: (summary['attempted'] as int) / 400),
        Text(
          '原 accuracy：${_percent(summary['accuracy'])}',
          key: const Key('benchmark-accuracy'),
        ),
        Text(
          '原 pair accuracy：${_percent(summary['pair_accuracy'])}',
          key: const Key('benchmark-pair-accuracy'),
        ),
        const Text('完整成绩使用全部 400 题及 200 对作为分母；失败回答仍计入覆盖，两个题都正确才计成对正确。'),
        Text(
          '超时 ${summary['timeouts']}（客户端 ${summary['client_timeouts'] ?? '未记录'} / 服务端 ${summary['server_timeouts'] ?? '未记录'}） · 不可用回答 ${summary['unusable']} · 正确 ${summary['correct']} / 400 · 成对正确 ${summary['pairs_correct']} / 200',
        ),
        Text(
          '辅助指标：成功返回端到端 P50 ${summary['latency_success_p50_ms'] ?? '不可用'} ms · P95 ${summary['latency_success_p95_ms'] ?? '不可用'} ms',
        ),
        Text(
          '概率覆盖 ${summary['probability_coverage']} / 400 · 标签来源：${summary['label_source']}',
        ),
        if (completed && summary['brier'] != null)
          Text('辅助概率指标 Brier：${summary['brier']} · ECE：${summary['ece']}'),
        if (summary['error'] != null) Text('批次错误：${summary['error']}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final entry in const [
              (0, 'benchmark-detail-summary', '身份与摘要'),
              (1, 'benchmark-detail-items', '逐题记录'),
              (2, 'benchmark-detail-groups', '成对记录'),
            ])
              ChoiceChip(
                key: Key(entry.$2),
                label: Text(entry.$3),
                selected: _detail == entry.$1,
                onSelected: (_) => setState(() => _detail = entry.$1),
              ),
            TextButton.icon(
              key: const Key('benchmark-export'),
              onPressed:
                  _fileBusy || record.status == BenchmarkRunStatus.running
                  ? null
                  : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('导出 JSON'),
            ),
            TextButton.icon(
              key: const Key('benchmark-delete'),
              onPressed:
                  _fileBusy || record.status == BenchmarkRunStatus.running
                  ? null
                  : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除历史'),
            ),
          ],
        ),
        if (_detail == 0)
          ExpansionTile(
            title: const Text('固定来源 / 原评分 / 运行身份'),
            children: [
              _json({
                'suite': record.suite,
                'identity': record.identity,
                'summary': summary,
              }, 'benchmark-summary-json'),
            ],
          ),
        if (_detail == 1)
          SizedBox(
            height: 430,
            child: ListView.builder(
              key: ValueKey('benchmark-items-${record.id}'),
              itemCount: record.items.length,
              itemBuilder: (context, index) {
                final item = record.items[index];
                final id = item['id'] as String;
                return ExpansionTile(
                  key: Key('benchmark-item-$id'),
                  title: Text('$id · ${item['status']}'),
                  subtitle: Text(
                    '${item['category']} · ${item['difficulty']} · 原标签 ${item['gold']} · 预测 ${item['prediction'] ?? '无有效预测'} · ${item['elapsed_us']} μs',
                  ),
                  children: [_json(item, 'benchmark-item-json-$id')],
                );
              },
            ),
          ),
        if (_detail == 2)
          SizedBox(
            height: 430,
            child: ListView.builder(
              key: ValueKey('benchmark-groups-${record.id}'),
              itemCount: record.groups.length,
              itemBuilder: (context, index) {
                final group = record.groups[index];
                final id = group['pair_id'] as String;
                return ExpansionTile(
                  key: Key('benchmark-group-$id'),
                  title: Text('$id · ${group['attempted']} / 2'),
                  subtitle: Text(
                    group['complete'] == true
                        ? (group['correct'] == true
                              ? '两个题都正确'
                              : '完整执行，有错误或无效回答')
                        : '未完成',
                  ),
                  children: [_json(group, 'benchmark-group-json-$id')],
                );
              },
            ),
          ),
        if (_fileStatus != null)
          Text(_fileStatus!, key: const Key('benchmark-file-status')),
      ],
    );
  }

  void _cancel() {
    if (_preparing) {
      widget.resources.cancelPreparation();
    } else {
      widget.runner.cancel();
    }
  }

  @override
  void dispose() {
    _discoveryToken?.cancel();
    unawaited(_subscription.cancel());
    unawaited(_resourceSubscription.cancel());
    _timeout.dispose();
    // The application closes its runner/resources at explicit quit.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = BenchmarkResources.identity;
    final progress = _progress;
    final record = _record;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'DecideBench 基准评测',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text('完整原题：400 题 / 200 对 · 默认上游 JEV 示例模板'),
          SelectableText('固定提交：${BenchmarkResources.pin}'),
          SelectableText('来源：${BenchmarkResources.sourceUrl}'),
          Text('代码：${identity['codeLicense']} · 数据：${identity['dataLicense']}'),
          Text('${identity['citation']}'),
          const Text('297 条原示例 / 63 个原模板；保留原始语言、内容、标签及配对结构。'),
          Text(
            '请求版本：${identity['requestVersion']} · 评分版本：${identity['scoringVersion']}',
          ),
          const SizedBox(height: 12),
          Text(_resourceStatus, key: const Key('benchmark-resource-status')),
          if (_preparing) ...[
            LinearProgressIndicator(
              value: progress == null
                  ? null
                  : (progress.verifiedBytes + progress.downloadedBytes) /
                        progress.totalBytes,
            ),
            if (progress != null)
              Text(
                '${progress.completedFiles} / ${progress.totalFiles} 个文件 · ${progress.verifiedBytes + progress.downloadedBytes} / ${progress.totalBytes} 字节\n${progress.currentPath}',
              ),
          ],
          const SizedBox(height: 16),
          const Text('单个 Ready 对象 · 普通公开 HTTP；不启动模型，不修改服务端预算。'),
          if (_discovering)
            const LinearProgressIndicator()
          else
            DropdownButtonFormField<String>(
              key: const Key('benchmark-target'),
              initialValue: _model,
              decoration: const InputDecoration(labelText: '公开 HTTP 评测对象'),
              isExpanded: true,
              items: [
                for (final target in _targets)
                  DropdownMenuItem(value: target.id, child: Text(target.id)),
              ],
              onChanged: _busy
                  ? null
                  : (model) => setState(() => _model = model),
            ),
          if (!_discovering && _targets.isEmpty)
            const Text('没有 Ready 且公开可调用的 JEV 对象，请在引擎中准备。'),
          TextButton(
            key: const Key('benchmark-discover'),
            onPressed: _busy || _discovering ? null : _discover,
            child: const Text('重新公开发现对象'),
          ),
          TextField(
            key: const Key('benchmark-timeout'),
            controller: _timeout,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '客户端期限（秒）',
              helperText: '默认 30 秒；题源准备不计入模型端到端耗时。',
            ),
          ),
          if (_deadline == null) const Text('客户端期限必须为有效正秒数。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                key: const Key('benchmark-run'),
                onPressed: _busy || _model == null || _deadline == null
                    ? null
                    : _start,
                child: const Text('完整评测 · 400 题'),
              ),
              if (_busy)
                TextButton(
                  key: const Key('benchmark-cancel'),
                  onPressed: _cancel,
                  child: const Text('取消整批'),
                ),
            ],
          ),
          if (_error != null) Text(_error!, key: const Key('benchmark-error')),
          if (record != null) ...[const SizedBox(height: 16), _report(record)],
          const SizedBox(height: 20),
          Text('评测历史', style: Theme.of(context).textTheme.titleLarge),
          const Text('历史仅查看，不自动续跑；题库版本、配置或通道不同的记录不混算成绩。'),
          TextButton(
            key: const Key('benchmark-history-refresh'),
            onPressed: _loadHistory,
            child: const Text('刷新历史'),
          ),
          if (_historyLoading) const LinearProgressIndicator(),
          if (_historyError != null) Text(_historyError!),
          if (!_historyLoading && _history.isEmpty) const Text('暂无评测历史'),
          if (_history.isNotEmpty)
            SizedBox(
              height: 260,
              child: ListView.builder(
                itemCount: _history.length,
                itemBuilder: (context, index) {
                  final saved = _history[index];
                  return ListTile(
                    key: Key('benchmark-history-${saved.id}'),
                    title: Text('${saved.model} · ${_status(saved.status)}'),
                    subtitle: Text(
                      '${saved.createdAt.toLocal()} · HTTP · ${saved.summary['attempted']} / 400 · ${saved.suite['pin']}',
                    ),
                    selected: saved.id == _record?.id,
                    onTap: () => _view(saved),
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
