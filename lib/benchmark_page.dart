import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'benchmark_game_work.dart';
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
    this.gameWork,
  });
  final BenchmarkResources resources;
  final BenchmarkRunner runner;
  final BenchmarkGameWork? gameWork;

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _timeout = TextEditingController(text: '30');
  late final StreamSubscription<BenchmarkRun> _subscription;
  late final StreamSubscription<BenchmarkResourceProgress?>
  _resourceSubscription;
  StreamSubscription<Map<String, Object?>>? _gameSubscription;
  List<JevDiscoveredModel> _targets = const [];
  String? _model;
  final _selected = <String>{};
  String _channelChoice = 'http';
  String _suiteChoice = 'decidebench';
  Map<String, Object?>? _suiteMetadata = BenchmarkResources.identity;
  bool _metadataLoading = false;
  String? _metadataError;
  static const _questionNames = {
    'decidebench': 'DecideBench',
    'jeval': 'JEVal',
    'coherence': '一致性 JevBench',
    'adversarial': 'JevAdvBench',
  };
  Map<String, String> get _suiteNames => {
    ..._questionNames,
    if (widget.gameWork != null) 'jevman': 'Jevman',
  };
  bool get _gameMode => _suiteChoice == 'jevman';
  String get _fullScale => switch (_suiteChoice) {
    'jevman' => '100 局',
    'jeval' => '11257 题',
    'coherence' => '10320 请求',
    'adversarial' => '11368 请求',
    _ => '400 题',
  };
  String get _scaleDescription => switch (_suiteChoice) {
    'jevman' => '100 局 · 原局时限 300 秒 · 决策 2 秒 / warmup 30 秒',
    'jeval' => '11257 题 · 58 个原来源 · choice / noul / score',
    'coherence' => '10320 原冻结请求 · 12000 关系测试 · 240 案例 / 50 关系',
    'adversarial' => '11368 请求 · 812 干净题 / 9744 原扰动 / 812 重复控制',
    _ => '400 题 / 200 对 · 默认上游 JEV 示例模板',
  };
  int _evaluationIndex = 0;
  List<JevPlaygroundMode> get _channels => switch (_channelChoice) {
    'mcp' => [JevPlaygroundMode.mcp],
    'both' => [JevPlaygroundMode.http, JevPlaygroundMode.mcp],
    _ => [JevPlaygroundMode.http],
  };
  bool _discovering = true;
  bool _starting = false;
  BenchmarkRun? _record;
  List<BenchmarkRun> _history = const [];
  bool _historyLoading = true;
  String? _historyError;
  bool _viewingHistory = false;
  int _historySelection = 0;
  int _detail = 0;
  bool _fileBusy = false;
  String? _fileStatus;
  String? _error;
  DecisionCancellation? _discoveryToken;

  String get _resourceStatus => _gameMode
      ? _gameResourceStatus
      : switch (widget.resources.status) {
          BenchmarkResourceStatus.idle => '固定原题尚未准备；开始时下载或重新核验缓存。',
          BenchmarkResourceStatus.preparing =>
            '资源准备中 · ${_progress?.currentPath ?? '校验固定版本原题'}',
          BenchmarkResourceStatus.ready =>
            widget.resources.suiteId == _suiteChoice
                ? '原题及摘要核验完成 · $_fullScale；新批次会重新校验缓存。'
                : '此题集尚未重新核验；开始时校验固定版本原题缓存。',
          BenchmarkResourceStatus.cancelled => '资源准备已取消；未开始模型评测。',
          BenchmarkResourceStatus.failed =>
            '准备失败（未计入模型失败）：${widget.resources.lastError}',
        };
  String get _gameResourceStatus => switch (widget.gameWork?.status) {
    BenchmarkGamePreparationStatus.preparing =>
      '游戏资源准备中 · ${widget.gameWork?.progress?.phase ?? "核验固定原版本"}',
    BenchmarkGamePreparationStatus.ready => '固定游戏及 Mac arm64 运行时摘要核验完成 · 100 局',
    BenchmarkGamePreparationStatus.cancelled => '游戏资源准备已取消；未开始模型评测。',
    BenchmarkGamePreparationStatus.failed =>
      '游戏准备失败（未计入模型失败）：${widget.gameWork?.lastError}',
    _ => '固定游戏及 Mac arm64 运行时尚未准备；开始时下载或核验缓存。',
  };
  bool get _preparing =>
      widget.resources.preparing ||
      widget.gameWork?.status == BenchmarkGamePreparationStatus.preparing;
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
    final activeSuite =
        widget.gameWork?.status == BenchmarkGamePreparationStatus.preparing
        ? 'jevman'
        : widget.resources.preparing
        ? widget.resources.suiteId
        : _record?.suite['id'];
    if (activeSuite is String && _suiteNames.containsKey(activeSuite)) {
      _suiteChoice = activeSuite;
      if (activeSuite != 'decidebench') {
        unawaited(_loadSuiteMetadata(activeSuite));
      }
    }
    _resourceSubscription = widget.resources.changes.listen((_) => _changed());
    _gameSubscription = widget.gameWork?.changes.listen((_) => _changed());
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

  Future<void> _loadSuiteMetadata(String id) async {
    if (id == 'decidebench') {
      setState(() {
        _suiteMetadata = BenchmarkResources.identity;
        _metadataLoading = false;
        _metadataError = null;
      });
      return;
    }
    setState(() {
      _suiteMetadata = null;
      _metadataLoading = true;
      _metadataError = null;
    });
    try {
      final metadata = await BenchmarkResources.questionManifest(id);
      if (mounted && _suiteChoice == id) {
        setState(() => _suiteMetadata = metadata);
      }
    } catch (error) {
      if (mounted && _suiteChoice == id) {
        setState(() => _metadataError = '无法读取固定题源元信息：$error');
      }
    } finally {
      if (mounted && _suiteChoice == id) {
        setState(() => _metadataLoading = false);
      }
    }
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
      List<JevDiscoveredModel>? targets;
      for (final channel in _channels) {
        final found = await widget.runner.targets(
          channel: channel,
          cancellation: token,
        );
        targets = targets == null
            ? found
            : targets
                  .where(
                    (target) => found.any(
                      (other) =>
                          other.id == target.id &&
                          other.source == target.source,
                    ),
                  )
                  .toList();
      }
      if (mounted && identical(token, _discoveryToken)) {
        setState(() {
          _targets = targets ?? const [];
          _selected.removeWhere(
            (name) => !_targets.any((target) => target.id == name),
          );
          if (!_targets.any((target) => target.id == _model)) _model = null;
        });
      }
    } catch (error) {
      if (mounted && identical(token, _discoveryToken)) {
        setState(() {
          _targets = const [];
          _model = null;
          _selected.clear();
          _error = '所选公开通道发现失败：$error';
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
    final names = _selected.toList();
    final suiteId = _suiteChoice;
    final channels = _channels;
    final deadline = _gameMode ? const Duration(seconds: 2) : _deadline;
    if (_busy || names.isEmpty || deadline == null) return;
    final resources = widget.resources;
    final runner = widget.runner;
    final token = DecisionCancellation();
    var preparingStage = true;
    setState(() {
      _starting = true;
      _error = null;
      _historySelection++;
      _viewingHistory = false;
      _record = null;
      _detail = 0;
      _evaluationIndex = 0;
    });
    try {
      // Leaving this page does not abandon the prepared application batch.
      if (suiteId == 'jevman') {
        final work = widget.gameWork!;
        await work.prepare(token);
        preparingStage = false;
        await runner.runJevman(
          work: work,
          modelNames: names,
          channels: channels,
        );
      } else if (suiteId == 'decidebench') {
        final suite = await resources.prepareSuite(token);
        preparingStage = false;
        await runner.run(
          suite: suite,
          modelNames: names,
          channels: channels,
          timeout: deadline,
        );
      } else {
        final suite = await resources.prepareQuestions(suiteId, token);
        preparingStage = false;
        await runner.runQuestions(
          suite: suite,
          modelNames: names,
          channels: channels,
          timeout: deadline,
        );
      }
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
    final selection = ++_historySelection;
    try {
      final active = widget.runner.current;
      final record =
          active != null &&
              widget.runner.running &&
              active.status == BenchmarkRunStatus.running &&
              active.id == selected.id
          ? active
          : await widget.runner.store.load(selected.id);
      if (mounted && selection == _historySelection) {
        setState(() {
          final current = widget.runner.current;
          _viewingHistory = current?.id != record.id;
          _record = _viewingHistory ? record : current;
          _detail = 0;
          _evaluationIndex = 0;
          _fileStatus = null;
          _historyError = null;
        });
      }
    } catch (error) {
      if (mounted && selection == _historySelection) {
        setState(() => _historyError = '记录读取失败：$error');
      }
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
    if (!record.isBatch) return _evaluationReport(record, owner: record);
    final evaluations = record.evaluations;
    final selected =
        evaluations[_evaluationIndex.clamp(0, evaluations.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '对照批次 · ${_status(record.status)}',
          key: const Key('benchmark-batch-status'),
        ),
        Text(
          '${record.model} · 已执行 ${record.summary['attempted']} / ${record.summary['expected']} · 按对象和通道顺序',
        ),
        if (record.status == BenchmarkRunStatus.running)
          LinearProgressIndicator(
            value:
                (record.summary['attempted'] as int) /
                (record.summary['expected'] as int),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < evaluations.length; index++)
              ChoiceChip(
                key: Key('benchmark-result-$index'),
                label: Text(
                  '${evaluations[index].model} · ${evaluations[index].channel.toUpperCase()} · ${_status(evaluations[index].status)}',
                ),
                selected: index == _evaluationIndex,
                onSelected: (_) => setState(() {
                  _evaluationIndex = index;
                  _detail = 0;
                }),
              ),
          ],
        ),
        const Text('委员会收益与代价：仅比较同批完整结果及同一通道；名称不代表速度、难度或质量。'),
        if (record.comparisons.isEmpty) const Text('选择同批原生模型及委员会后可显示对照。'),
        for (final comparison in record.comparisons)
          Text(
            '${comparison['council']} 对 ${comparison['native']} · ${(comparison['channel'] as String).toUpperCase()} · '
            '${comparison['comparable'] == true ? "accuracy Δ ${comparison['accuracy_delta']} / pair accuracy Δ ${comparison['pair_accuracy_delta']} · P50 Δ ${comparison['latency_success_p50_ms_delta']} ms / P95 Δ ${comparison['latency_success_p95_ms_delta']} ms · 失败 Δ ${comparison['failures_delta']}" : "未完成，不能计算完整成绩差值"}',
          ),
        const Text('成功席位覆盖：未在性能请求中取得公开席位证据，未知；配置成员数不表示成功席位数。'),
        const SizedBox(height: 12),
        _evaluationReport(selected, owner: record),
      ],
    );
  }

  Widget _evaluationReport(BenchmarkRun record, {required BenchmarkRun owner}) {
    if (record.isGameRun) return _gameReport(record, owner: owner);
    final summary = record.summary;
    final completed = summary['complete'] == true;
    final question = record.isQuestionRun;
    final expected = summary['expected'] ?? 400;
    final sourceSummary = question
        ? record.toJson()['source_summary'] as Map<String, Object?>
        : const <String, Object?>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('批次报告', style: Theme.of(context).textTheme.titleLarge),
        Text(
          '${record.model} · ${record.channel.toUpperCase()} · ${_status(record.status)}',
          key: const Key('benchmark-current-status'),
        ),
        Text(
          '批次：${record.id} · ${record.createdAt.toLocal()} · 客户端期限 ${record.timeout.inMilliseconds} ms',
        ),
        Text(
          '${completed ? '完整执行' : '未完成'} · 已执行 ${summary['attempted']} / $expected · 有效 ${summary['valid']} · 失败 ${summary['failures']} · 缺失 ${summary['missing']}',
          key: const Key('benchmark-coverage'),
        ),
        if (record.status == BenchmarkRunStatus.running)
          LinearProgressIndicator(
            value: (summary['attempted'] as int) / (expected as int),
          ),
        if (!question) ...[
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
        ] else ...[
          ..._sourceMetrics(record.suite['id'] as String, sourceSummary),
          Text(
            '客户端超时 ${summary['timeouts']}（客户端 ${summary['client_timeouts']} / 服务端 ${summary['server_timeouts']}）；原评分适用失败与协议失败在原分组中分别保留。',
          ),
          Text(
            '成功返回端到端 P50 ${summary['latency_success_p50_ms'] ?? "不可用"} ms · P95 ${summary['latency_success_p95_ms'] ?? "不可用"} ms',
          ),
          const Text('完整成绩使用固定原题分母；未完成不发布完整分数，原字段、失败与来源分组均保留。'),
        ],
        if (summary['error'] != null) Text('批次错误：${summary['error']}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final entry in [
              (0, 'benchmark-detail-summary', '身份与摘要'),
              (1, 'benchmark-detail-items', '逐题记录'),
              (2, 'benchmark-detail-groups', question ? '原分组' : '成对记录'),
            ])
              ChoiceChip(
                key: Key(entry.$2),
                label: Text(entry.$3),
                selected: _detail == entry.$1,
                onSelected: (_) => setState(() => _detail = entry.$1),
              ),
            TextButton.icon(
              key: const Key('benchmark-export'),
              onPressed: _fileBusy || owner.status == BenchmarkRunStatus.running
                  ? null
                  : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('导出 JSON'),
            ),
            TextButton.icon(
              key: const Key('benchmark-delete'),
              onPressed: _fileBusy || owner.status == BenchmarkRunStatus.running
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
                if (question) 'source_summary': sourceSummary,
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
                    question
                        ? '${_sourceItemDescription(item)} · ${item['elapsed_us']} μs'
                        : '${item['category']} · ${item['difficulty']} · 原标签 ${item['gold']} · 预测 ${item['prediction'] ?? '无有效预测'} · ${item['elapsed_us']} μs',
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
                final id = question
                    ? _sourceGroupId(group, index)
                    : group['pair_id'] as String;
                return ExpansionTile(
                  key: Key('benchmark-group-$id'),
                  title: Text(
                    question
                        ? '${group['dimension'] ?? group['kind'] ?? group['relation'] ?? "原分组"} · ${group['group'] ?? group['category'] ?? id} · ${group['attempted'] ?? group['n'] ?? "未知"} / ${group['total'] ?? group['expected'] ?? group['planned'] ?? "未知"}'
                        : '$id · ${group['attempted']} / 2',
                  ),
                  subtitle: Text(
                    question
                        ? '固定原分组；指标定义及适用覆盖见完整 JSON'
                        : group['complete'] == true
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

  Widget _gameReport(BenchmarkRun record, {required BenchmarkRun owner}) {
    final summary = record.summary;
    final source = record.toJson()['source_summary'];
    final client = record.toJson()['client_summary'] as Map;
    final live = owner.id == widget.runner.current?.id && widget.runner.running;
    final frame = live ? widget.gameWork?.latestFrame : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Jevman 原100局报告', style: Theme.of(context).textTheme.titleLarge),
        Text(
          '${record.model} · ${record.channel.toUpperCase()} · ${_status(record.status)}',
          key: const Key('benchmark-current-status'),
        ),
        Text(
          '批次：${record.id} · ${record.createdAt.toLocal()} · 决策固定2秒 / warmup30秒',
        ),
        Text(
          '${summary['complete'] == true ? '完整执行' : '未完成'} · 已执行 ${summary['attempted']} / 100 · 完整局 ${summary['valid']} · 部分录像 ${summary['failures']} · 缺失 ${summary['missing']}',
          key: const Key('benchmark-coverage'),
        ),
        if (record.status == BenchmarkRunStatus.running)
          LinearProgressIndicator(value: (summary['attempted'] as int) / 100),
        if (frame != null)
          Text(
            '当前第 ${frame['game']} 局 · 帧 ${frame['frame']} · 原playingSeconds ${frame['playingSeconds']} · ${frame['status']}',
            key: const Key('benchmark-game-live-progress'),
          ),
        const Text('模型决策与greedy fallback分别统计；未完成不发布完整100局成绩。时间、用量、费用未知项保持未知。'),
        Text(
          '辅助指标：正式局成功公开调用端到端 P50 ${summary['latency_success_p50_ms'] ?? '不可用'} ms · P95 ${summary['latency_success_p95_ms'] ?? '不可用'} ms · 耗时样本 ${client['latency_success_samples'] ?? '未知'} / ${client['game_successes'] ?? '未知'} 次成功调用 · 覆盖率 ${client['latency_success_coverage'] ?? '未知'}（包含发现与请求；排除预热、失败和超时）',
          key: const Key('benchmark-game-latency-distribution'),
        ),
        if (summary['error'] != null) Text('批次错误：${summary['error']}'),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final entry in const [
              (0, 'benchmark-detail-summary', '身份与原成绩'),
              (1, 'benchmark-detail-items', '逐局记录'),
              (2, 'benchmark-detail-groups', '预热与公开调用'),
            ])
              ChoiceChip(
                key: Key(entry.$2),
                label: Text(entry.$3),
                selected: _detail == entry.$1,
                onSelected: (_) => setState(() => _detail = entry.$1),
              ),
            TextButton.icon(
              key: const Key('benchmark-export'),
              onPressed: _fileBusy || owner.status == BenchmarkRunStatus.running
                  ? null
                  : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('导出 JSON'),
            ),
            TextButton.icon(
              key: const Key('benchmark-delete'),
              onPressed: _fileBusy || owner.status == BenchmarkRunStatus.running
                  ? null
                  : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除历史'),
            ),
          ],
        ),
        if (_detail == 0)
          ExpansionTile(
            title: const Text('固定游戏 / 原独立成绩 / 运行身份'),
            children: [
              _json({
                'suite': record.suite,
                'identity': record.identity,
                'summary': summary,
                'source_summary': source,
                'client_summary': record.toJson()['client_summary'],
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
                final game = record.items[index];
                final id = game['id'] as String;
                return ExpansionTile(
                  key: Key('benchmark-item-$id'),
                  title: Text(
                    '第 ${game['index']} 局 · ${game['complete'] == true ? '完整' : '部分录像'}',
                  ),
                  subtitle: Text('原游戏结果、决策、fallback、完整公开calls与逐帧录像'),
                  children: [_json(game, 'benchmark-item-json-$id')],
                );
              },
            ),
          ),
        if (_detail == 2)
          _json({
            'warmup_calls': record.toJson()['warmup_calls'],
            'client_summary': record.toJson()['client_summary'],
          }, 'benchmark-game-calls-json'),
        if (_fileStatus != null)
          Text(_fileStatus!, key: const Key('benchmark-file-status')),
      ],
    );
  }

  void _cancel() {
    if (widget.gameWork?.status == BenchmarkGamePreparationStatus.preparing) {
      widget.gameWork!.cancelPreparation();
    } else if (_preparing) {
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
    unawaited(_gameSubscription?.cancel());
    _timeout.dispose();
    // The application closes its runner/resources at explicit quit.
    super.dispose();
  }

  List<Widget> _sourceMetrics(
    String id,
    Map<String, Object?> score,
  ) => switch (id) {
    'jeval' => [
      Text(
        '原 accuracy：${_percent(score['accuracy'])}',
        key: const Key('benchmark-accuracy'),
      ),
      Text('原 score MAE：${score['scoreMae'] ?? '未完成或无有效 score 判断'}'),
      Text(
        '分类概率覆盖 ${score['probabilityCount'] ?? '未封存'} / ${score['classificationTotal'] ?? '原分类分母'} · Brier ${score['brier'] ?? '未完成或无适用分布'} · ECE ${score['ece'] ?? '未完成或无适用分布'}',
      ),
      const Text('返回 score、众数、概率期望与四舍五入分别保留；MAE使用原返回值。'),
    ],
    'coherence' => [
      Text('原一致性（binary）：${_percent(score['overall'])}'),
      Text(
        '原一致性（graded）：${_percent(score['graded'] is Map ? (score['graded'] as Map)['overall'] : null)}',
      ),
      Text(
        '关系已评分 ${score['judged_tests'] ?? '未封存'} / 12000 · 未评分 ${score['unscored_tests'] ?? '未封存'}；完整容差、适用覆盖及各维度原分数见身份与摘要。',
      ),
      const Text('一致性分与准确率、校准、实时性能分别表达。'),
    ],
    'adversarial' => [
      const Text('原扰动指标：干净 / 已发布攻击 / 独立重复控制；翻转、偏移、噪声及注入槽分别保留。'),
      const Text('人工复核标签与模型共识标签分开；共识不是独立正确率真值，协议拒绝不计抗扰动成功。'),
    ],
    _ => const [],
  };

  String _sourceItemDescription(Map<String, Object?> item) {
    final metadata = item['metadata'] as Map;
    return '${metadata['source'] ?? metadata['category'] ?? metadata['case'] ?? '原任务'} · ${metadata['question_type'] ?? metadata['primitive'] ?? '原请求组'}';
  }

  String _sourceGroupId(Map<String, Object?> group, int index) {
    if (group['dimension'] is String && group['group'] is String) {
      return '${group['dimension']}/${group['group']}';
    }
    if (group['relation'] is String) return group['relation'] as String;
    return 'original-$index';
  }

  @override
  Widget build(BuildContext context) {
    final identity = _suiteMetadata;
    final progress = _progress;
    final record = _record;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('benchmark-suite'),
            initialValue: _suiteChoice,
            decoration: const InputDecoration(labelText: '完整原题基准'),
            items: [
              for (final entry in _suiteNames.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _busy
                ? null
                : (id) {
                    if (id == null) return;
                    setState(() => _suiteChoice = id);
                    unawaited(_loadSuiteMetadata(id));
                  },
          ),
          const SizedBox(height: 12),
          Text(
            '${_suiteNames[_suiteChoice]} 基准评测',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text('完整原题：$_scaleDescription'),
          if (_metadataLoading) const Text('读取固定题源元信息…'),
          if (_metadataError != null) Text(_metadataError!),
          if (identity != null) ...[
            SelectableText(
              const JsonEncoder.withIndent('  ').convert({
                for (final entry in identity.entries)
                  if (entry.value is! List && entry.value is! Map)
                    entry.key: entry.value,
              }),
              key: const Key('benchmark-suite-metadata'),
            ),
            if (_suiteChoice == 'decidebench') ...[
              const Text('297 条原示例 / 63 个原模板；保留原始语言、内容、标签及配对结构。'),
            ],
            ExpansionTile(
              title: const Text('原来源条件、署名、文件摘要与评分版本'),
              children: [_json(identity, 'benchmark-source-metadata-json')],
            ),
          ],
          const Text('固定题源版本随应用更新；原版本缓存与历史独立保留，不隐式更新正在运行的批次。'),
          const SizedBox(height: 12),
          Text(_resourceStatus, key: const Key('benchmark-resource-status')),
          if (_gameMode &&
              widget.gameWork?.status ==
                  BenchmarkGamePreparationStatus.preparing) ...[
            LinearProgressIndicator(
              value: widget.gameWork?.progress == null
                  ? null
                  : widget.gameWork!.progress!.downloadedBytes /
                        widget.gameWork!.progress!.totalBytes,
            ),
          ] else if (_preparing) ...[
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
          const Text('多个 Ready 对象 · 普通公开 HTTP / MCP；不启动模型，不修改服务端预算。'),
          DropdownButtonFormField<String>(
            key: const Key('benchmark-channels'),
            initialValue: _channelChoice,
            decoration: const InputDecoration(labelText: '评测通道'),
            items: const [
              DropdownMenuItem(value: 'http', child: Text('HTTP')),
              DropdownMenuItem(value: 'mcp', child: Text('MCP')),
              DropdownMenuItem(value: 'both', child: Text('HTTP / MCP 分别评测')),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    setState(() => _channelChoice = value!);
                    unawaited(_discover());
                  },
          ),
          if (_discovering)
            const LinearProgressIndicator()
          else
            DropdownButtonFormField<String>(
              key: const Key('benchmark-target'),
              initialValue: _model,
              decoration: const InputDecoration(labelText: '选择一个对象或在下方多选'),
              isExpanded: true,
              items: [
                for (final target in _targets)
                  DropdownMenuItem(value: target.id, child: Text(target.id)),
              ],
              onChanged: _busy
                  ? null
                  : (model) => setState(() {
                      _model = model;
                      _selected.clear();
                      if (model != null) _selected.add(model);
                    }),
            ),
          for (final target in _targets)
            CheckboxListTile(
              key: Key('benchmark-select-${target.id}'),
              title: Text(target.label),
              value: _selected.contains(target.id),
              onChanged: _busy
                  ? null
                  : (selected) => setState(() {
                      if (selected == true) {
                        _selected.add(target.id);
                      } else {
                        _selected.remove(target.id);
                      }
                    }),
            ),
          const Text('所选对象须在每个所选通道中公开可调用；运行全程锁定所有参赛名称与配置。'),
          if (!_discovering && _targets.isEmpty)
            const Text('没有 Ready 且公开可调用的 JEV 对象，请在引擎中准备。'),
          TextButton(
            key: const Key('benchmark-discover'),
            onPressed: _busy || _discovering ? null : _discover,
            child: const Text('重新公开发现对象'),
          ),
          if (_gameMode)
            const Text('原游戏客户端决策期限固定 2 秒；warmup 固定 30 秒，不修改服务端预算。')
          else
            TextField(
              key: const Key('benchmark-timeout'),
              controller: _timeout,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '客户端期限（秒）',
                helperText: '默认 30 秒；题源准备不计入模型端到端耗时。',
              ),
            ),
          if (!_gameMode && _deadline == null) const Text('客户端期限必须为有效正秒数。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                key: const Key('benchmark-run'),
                onPressed:
                    _busy ||
                        _metadataLoading ||
                        _metadataError != null ||
                        _selected.isEmpty ||
                        (!_gameMode && _deadline == null)
                    ? null
                    : _start,
                child: Text('完整评测 · $_fullScale'),
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
                      '${saved.createdAt.toLocal()} · ${saved.isBatch ? '独立通道对照' : saved.channel.toUpperCase()} · ${saved.summary['attempted']} / ${saved.summary['expected'] ?? 400} · ${saved.suite['pin']}',
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
