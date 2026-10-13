import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'benchmark_game_work.dart';
import 'benchmark_resources.dart';
import 'benchmark_runner.dart';
import 'benchmark_run_store.dart';
import 'jev_playground.dart';
import 'jevman_viewer.dart';

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
  final _timeout = TextEditingController(text: '60');
  late final StreamSubscription<BenchmarkRun> _subscription;
  late final StreamSubscription<BenchmarkResourceProgress?>
  _resourceSubscription;
  StreamSubscription<Map<String, Object?>>? _gameSubscription;
  List<JevDiscoveredModel> _targets = const [];
  String? _model;
  final _selected = <String>{};
  String _channelChoice = 'http';
  String _suiteChoice = 'decidebench';
  final _selectedSuites = <String>{'decidebench'};
  List<String> get _batchSuites =>
      _suiteNames.keys.where(_selectedSuites.contains).toList();
  bool get _onlyGames =>
      _batchSuites.length == 1 && _batchSuites.single == 'jevman';
  String get _batchScale => _batchSuites
      .map(
        (id) =>
            '${_batchSuites.length > 1 ? '${_suiteNames[id]} ' : ''}${switch (id) {
              'jevman' => '100 局',
              'jeval' => '11257 题',
              'coherence' => '10320 请求',
              'adversarial' => '11368 请求',
              _ => '400 题',
            }}',
      )
      .join(' · ');

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
  int _resultPage = 0;
  int _comparisonPage = 0;
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
  String? _historyListError;
  String? _historyError;
  bool _viewingHistory = false;
  int _historySelection = 0;
  int _detail = 0;
  static const _pageSize = 20;
  int _detailPage = 0;
  int _historyPage = 0;
  int _detailGeneration = 0;
  BenchmarkHistorySession? _historySession;
  StreamSubscription<Object?>? _historyProgressSubscription;
  String? _historyOwnerId;
  bool _historyDetailsLoading = false;
  bool _detailLoading = false;
  List<Map<String, Object?>> _detailRows = const [];
  List<String> _sourceFiles = const [];
  int _sourcePage = 0;
  int _sourceSelection = 0;
  String? _exportedFile;
  String? _activeFilesId;
  List<String> _activeFiles = const [];
  int _filesGeneration = 0;
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
    if (widget.runner.selectedSuiteIds.isNotEmpty) {
      _selectedSuites
        ..clear()
        ..addAll(widget.runner.selectedSuiteIds);
    }

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
    _resourceSubscription = widget.resources.changes.listen((_) {
      _changed();
      if (!widget.resources.preparing) unawaited(_loadSourceFiles());
    });
    _gameSubscription = widget.gameWork?.changes.listen((_) => _changed());
    _subscription = widget.runner.changes.listen((record) {
      if (mounted) {
        setState(() {
          if (!_viewingHistory) _record = record;
        });
        if (!_viewingHistory &&
            _historySession == null &&
            _activeFilesId != record.id) {
          unawaited(_loadActiveFiles(record));
        }
        if (record.status != BenchmarkRunStatus.running) {
          unawaited(_loadHistory());
          if (!_viewingHistory && _historyOwnerId != record.id) {
            unawaited(_view(record));
          }
        }
      }
    });
    _timeout.addListener(_changed);
    unawaited(_discover());
    unawaited(_loadHistory());
    unawaited(_loadSourceFiles());
    if (_record != null && _record!.status == BenchmarkRunStatus.running) {
      unawaited(_loadActiveFiles(_record!));
    }
    if (_record != null && _record!.status != BenchmarkRunStatus.running) {
      unawaited(_view(_record!));
    }
  }

  Future<void> _loadSuiteMetadata(String id) async {
    if (id == 'decidebench') {
      setState(() {
        _suiteMetadata = BenchmarkResources.identity;
        _metadataLoading = false;
        _metadataError = null;
      });
      unawaited(_loadSourceFiles());
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
        unawaited(_loadSourceFiles());
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
    final suiteIds = _batchSuites;
    final channels = _channels;
    final deadline = _onlyGames ? const Duration(seconds: 2) : _deadline;
    if (_busy || names.isEmpty || suiteIds.isEmpty || deadline == null) return;
    final resources = widget.resources;
    final runner = widget.runner;
    setState(() {
      _starting = true;
      _error = null;
      _historySelection++;
      _viewingHistory = false;
      _record = null;
      _fileStatus = null;
      _detail = 0;
      _evaluationIndex = 0;
      _resultPage = 0;
      _comparisonPage = 0;
      _detailPage = 0;
      _exportedFile = null;
      _activeFilesId = null;
      _activeFiles = const [];
      _filesGeneration++;
    });
    unawaited(
      _closeHistory().catchError((Object error) {
        if (mounted) setState(() => _historyError = '历史读取收尾失败：$error');
      }),
    );
    try {
      await runner.runSelected(
        suiteIds: suiteIds,
        resources: resources,
        gameWork: widget.gameWork,
        modelNames: names,
        channels: channels,
        timeout: deadline,
      );
    } on BenchmarkResourceCancelled {
      // The resource owner publishes its terminal cancellation to every page.
    } catch (error) {
      if (mounted) {
        setState(() {
          _error =
              resources.status == BenchmarkResourceStatus.failed ||
                  widget.gameWork?.status ==
                      BenchmarkGamePreparationStatus.failed
              ? '无法开始准备：$error'
              : '评测失败：$error';
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
          _historyListError = null;
          final lastPage = history.isEmpty
              ? 0
              : (history.length - 1) ~/ _pageSize;
          if (_historyPage > lastPage) _historyPage = lastPage;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _historyListError = '历史读取失败：$error');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _view(BenchmarkRun selected) async {
    final selection = ++_historySelection;
    try {
      final closing = _closeHistory();
      if (mounted && selection == _historySelection) {
        setState(() {
          _viewingHistory = true;
          _record = null;
          _historyDetailsLoading = true;
          _historyError = null;
        });
      }
      await closing;
    } catch (error) {
      if (mounted && selection == _historySelection) {
        setState(() {
          _historyDetailsLoading = false;
          _historyError = '历史读取收尾失败：$error';
        });
      }
      return;
    }
    if (!mounted || selection != _historySelection) return;
    final active = widget.runner.current;
    if (active != null &&
        widget.runner.running &&
        active.status == BenchmarkRunStatus.running &&
        active.id == selected.id) {
      setState(() {
        _viewingHistory = false;
        _record = active;
        _historyError = null;
        _detail = 0;
        _detailPage = 0;
        _evaluationIndex = 0;
      });
      if (_activeFilesId != active.id || _activeFiles.isEmpty) {
        unawaited(_loadActiveFiles(active));
      }
      return;
    }
    final session = widget.runner.store.openHistory(selected.id);
    _historySession = session;
    _historyOwnerId = selected.id;
    setState(() {
      _viewingHistory = true;
      _record = null;
      _historyDetailsLoading = true;
      _historyError = null;
      _detail = 0;
      _detailPage = 0;
      _evaluationIndex = 0;
      _fileStatus = null;
    });
    _historyProgressSubscription = session.changes.listen((_) {
      if (mounted && selection == _historySelection) _changed();
    });
    try {
      final record = await session.ready;
      if (mounted && selection == _historySelection) {
        setState(() {
          _record = record;
          _historyDetailsLoading = false;
          _detail = 0;
          _evaluationIndex = 0;
          _fileStatus = null;
          _historyError = null;
        });
      }
    } catch (error) {
      if (mounted && selection == _historySelection) {
        setState(() {
          _historyDetailsLoading = false;
          _historyError = '记录读取失败：$error';
        });
      }
    }
  }

  Future<void> _closeHistory() async {
    final session = _historySession;
    final subscription = _historyProgressSubscription;
    _historySession = null;
    _historyProgressSubscription = null;
    _historyOwnerId = null;
    _historyDetailsLoading = false;
    _detailGeneration++;
    _filesGeneration++;
    _detailLoading = false;
    _detailRows = const [];
    await subscription?.cancel();
    await session?.close();
  }

  Future<void> _loadActiveFiles(BenchmarkRun record) async {
    final generation = ++_filesGeneration;
    final selection = _historySelection;
    _activeFilesId = record.id;
    _activeFiles = const [];
    try {
      final files = await widget.runner.store.recordFilePaths(record.id);
      if (mounted &&
          generation == _filesGeneration &&
          selection == _historySelection &&
          !_viewingHistory &&
          _historySession == null &&
          _record?.id == record.id) {
        setState(() => _activeFiles = files);
      }
    } catch (error) {
      if (mounted &&
          generation == _filesGeneration &&
          selection == _historySelection) {
        setState(() => _fileStatus = '评测文件地址读取失败：$error');
      }
    }
  }

  BenchmarkRun? get _evaluation {
    final record = _record;
    if (record == null) return null;
    if (!record.isBatch) return record;
    return record.evaluations[_evaluationIndex.clamp(
      0,
      record.evaluations.length - 1,
    )];
  }

  Future<void> _selectDetail(int value, {int page = 0}) async {
    final generation = ++_detailGeneration;
    final selection = _historySelection;
    setState(() {
      _detail = value;
      _detailPage = page;
      _detailRows = const [];
      _detailLoading = value != 0 && _historySession != null;
    });
    final record = _evaluation;
    final session = _historySession;
    if (record == null || session == null || value == 0) return;
    try {
      final rows = value == 1
          ? await session.items(
              evaluationId: record.id,
              offset: page * _pageSize,
            )
          : record.isGameRun
          ? await session.warmupCalls(
              evaluationId: record.id,
              offset: page * _pageSize,
            )
          : await session.groups(
              evaluationId: record.id,
              offset: page * _pageSize,
            );
      if (mounted &&
          selection == _historySelection &&
          generation == _detailGeneration) {
        setState(() {
          _detailRows = rows;
          _detailLoading = false;
        });
      }
    } catch (error) {
      if (mounted &&
          selection == _historySelection &&
          generation == _detailGeneration) {
        setState(() {
          _detailLoading = false;
          _historyError = '明细读取失败：$error';
        });
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
      if (mounted) {
        setState(() {
          _fileStatus = '已导出：$destination';
          _exportedFile = destination;
        });
      }
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
      await _closeHistory();
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

  Widget _facts(Map<String, Object?> values) {
    final scalars = values.entries
        .where(
          (entry) =>
              entry.value is String ||
              entry.value is num ||
              entry.value is bool,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in scalars.take(_pageSize))
          Text(
            '${entry.key}：${_summaryText(entry.value.toString())}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        if (scalars.length > _pageSize) const Text('完整字段保留在记录文件中。'),
      ],
    );
  }

  String _summaryText(String value) => value.length <= 512
      ? value
      : '${String.fromCharCodes(value.runes.take(512))}…（完整内容见文件）';

  Map<String, Object?> _rowSummary(
    BenchmarkRun record,
    Map<String, Object?> row,
  ) => {
    for (final key in const [
      'id',
      'index',
      'status',
      'category',
      'difficulty',
      'gold',
      'prediction',
      'elapsed_us',
      'error',
      'complete',
      'costKnown',
      'pair_id',
      'dimension',
      'group',
      'relation',
      'kind',
      'attempted',
      'total',
      'expected',
      'planned',
      'n',
      'correct',
      'accuracy',
      'scoreMae',
      'brier',
      'ece',
      'http_status',
      'phase',
    ])
      if (row.containsKey(key)) key: row[key],
    if (row['metadata'] is Map)
      'metadata': {
        for (final key in const [
          'source',
          'category',
          'case',
          'question_type',
          'primitive',
        ])
          if ((row['metadata'] as Map).containsKey(key))
            key: (row['metadata'] as Map)[key],
      },
    if (record.isGameRun && row['result'] is Map)
      'result': {
        for (final entry in (row['result'] as Map).entries)
          if (entry.value is num || entry.value is bool)
            entry.key as String: entry.value,
      },
  };

  Future<void> _loadSourceFiles() async {
    final selection = ++_sourceSelection;
    final id = _suiteChoice;
    final metadata = _suiteMetadata;
    if (metadata == null) return;
    final files = [...await widget.resources.sourceFilePaths(id, metadata)];
    if (id == 'jevman' && widget.gameWork != null) {
      files.addAll(await widget.gameWork!.sourceFilePaths());
    }
    if (mounted &&
        id == _suiteChoice &&
        selection == _sourceSelection &&
        identical(metadata, _suiteMetadata)) {
      setState(() {
        _sourceFiles = files;
        _sourcePage = 0;
      });
    }
  }

  Future<void> _reveal(String path) async {
    try {
      await const MethodChannel('com.ghost233.ghostmodeldeck/native')
          .invokeMethod<void>('revealInFinder', {'path': path});
    } catch (error) {
      if (mounted) setState(() => _fileStatus = 'Finder 定位失败：$error');
    }
  }

  Widget _path(String label, String path, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(label),
          TextButton.icon(
            key: Key(key),
            onPressed: () => _reveal(path),
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('在 Finder 中显示'),
          ),
        ],
      ),
      SelectableText(path),
    ],
  );

  Widget _recordFiles(BenchmarkRun owner) {
    final session = _historySession;
    final active = _activeFilesId == owner.id ? _activeFiles : const <String>[];
    final journals = session?.journalFilePaths ?? active.skip(1).toList();
    final path =
        session?.recordFilePath ??
        active.firstOrNull ??
        File('${widget.runner.store.directory.path}/${owner.id}.json')
            .absolute
            .path;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('完整输入、响应、分组、运行身份和原始录像保留在文件中；页面只显示摘要。'),
        _path('评测记录', path, 'benchmark-record-reveal'),
        for (final entry in journals.indexed)
          _path(
            '逐项日志 ${entry.$1 + 1}',
            entry.$2,
            'benchmark-journal-reveal-${entry.$1}',
          ),
        if (_exportedFile != null)
          _path('完整导出', _exportedFile!, 'benchmark-export-reveal'),
      ],
    );
  }

  int _rowCount(BenchmarkRun record) {
    final session = _historySession;
    if (session != null) {
      return _detail == 1
          ? session.itemCount(record.id)
          : record.isGameRun
          ? session.warmupCount(record.id)
          : session.groupCount(record.id);
    }
    if (_detail == 1) return record.items.length;
    if (record.isGameRun) {
      return (record.toJson()['warmup_calls'] as List).length;
    }
    return record.groups.length;
  }

  List<Map<String, Object?>> _visibleRows(BenchmarkRun record) {
    if (_historySession != null) return _detailRows;
    final rows = _detail == 1
        ? record.items
        : record.isGameRun
        ? (record.toJson()['warmup_calls'] as List).cast<Map<String, Object?>>()
        : record.groups;
    return rows
        .skip(_detailPage * _pageSize)
        .take(_pageSize)
        .map((row) => _rowSummary(record, row))
        .toList();
  }

  Widget _pagination(int count) => Wrap(
    spacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        '第 ${_detailPage + 1} / ${count == 0 ? 1 : (count + _pageSize - 1) ~/ _pageSize} 页 · 共 $count 条 · 每页 $_pageSize 条',
        key: const Key('benchmark-detail-pagination'),
      ),
      TextButton(
        key: const Key('benchmark-detail-previous'),
        onPressed: _detailLoading || _detailPage == 0
            ? null
            : () => _selectDetail(_detail, page: _detailPage - 1),
        child: const Text('上一页'),
      ),
      TextButton(
        key: const Key('benchmark-detail-next'),
        onPressed: _detailLoading || (_detailPage + 1) * _pageSize >= count
            ? null
            : () => _selectDetail(_detail, page: _detailPage + 1),
        child: const Text('下一页'),
      ),
    ],
  );

  Widget _detailList(BenchmarkRun record) {
    final rows = _visibleRows(record);
    final question = record.isQuestionRun;
    final items = _detail == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pagination(_rowCount(record)),
        if (_detailLoading) const LinearProgressIndicator(),
        if (_detailLoading) const Text('后台读取并核对当前页摘要…'),
        SizedBox(
          height: 430,
          child: ListView.builder(
            key: ValueKey(
              '${items ? 'benchmark-items' : 'benchmark-groups'}-${record.id}',
            ),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              final id = items
                  ? row['id'] as String
                  : record.isGameRun
                  ? '${row['id'] ?? index}'
                  : question
                  ? _sourceGroupId(row, _detailPage * _pageSize + index)
                  : row['pair_id'] as String;
              return ExpansionTile(
                key: Key('benchmark-${items ? 'item' : 'group'}-$id'),
                title: Text(
                  items
                      ? record.isGameRun
                            ? '第 ${row['index']} 局 · ${row['complete'] == true ? '完整' : '部分录像'}'
                            : '$id · ${row['status']}'
                      : record.isGameRun
                      ? '预热调用 $id · ${row['http_status'] ?? row['error'] ?? '已记录'}'
                      : question
                      ? '${row['dimension'] ?? row['kind'] ?? row['relation'] ?? '原分组'} · ${row['group'] ?? row['category'] ?? id}'
                      : '$id · ${row['attempted']} / 2',
                ),
                subtitle: items && !record.isGameRun
                    ? Text(
                        question
                            ? '${_sourceItemDescription(row)} · ${row['elapsed_us']} μs'
                            : '${row['category']} · ${row['difficulty']} · 原标签 ${row['gold']} · 预测 ${row['prediction'] ?? '无有效预测'} · ${row['elapsed_us']} μs',
                      )
                    : null,
                children: [
                  _facts(row),
                  if (row['result'] is Map)
                    _facts(Map<String, Object?>.from(row['result'] as Map)),
                  if (items && record.isGameRun && widget.gameWork != null)
                    TextButton.icon(
                      key: Key('benchmark-game-replay-$id'),
                      onPressed: () => _replay(record, id),
                      icon: const Icon(Icons.replay),
                      label: const Text('回放本局 / 独立核对'),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _replay(BenchmarkRun record, String id) async {
    final selection = _historySelection;
    try {
      final session = _historySession;
      final game = session == null
          ? record.items.singleWhere((row) => row['id'] == id)
          : await session.game(evaluationId: record.id, gameId: id);
      if (mounted && selection == _historySelection) {
        await _watchGame(game: game, identity: record.suite);
      }
    } catch (error) {
      if (mounted && selection == _historySelection) {
        setState(() => _fileStatus = '回放读取失败：$error');
      }
    }
  }

  Widget _report(BenchmarkRun record) {
    if (!record.isBatch) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _evaluationReport(record, owner: record),
          _recordFiles(record),
        ],
      );
    }
    final evaluations = record.evaluations;
    final comparisons = record.comparisons;
    final resultPage = _resultPage.clamp(
      0,
      (evaluations.length - 1) ~/ _pageSize,
    );
    final comparisonPage = _comparisonPage.clamp(
      0,
      comparisons.isEmpty ? 0 : (comparisons.length - 1) ~/ _pageSize,
    );
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
          '${record.model} · 已执行 ${record.summary['attempted']} / ${record.summary['expected']} · 按对象、基准和通道顺序',
        ),
        if (record.status == BenchmarkRunStatus.running)
          LinearProgressIndicator(
            value:
                (record.summary['attempted'] as int) /
                (record.summary['expected'] as int),
          ),
        _summaryPages(
          'benchmark-results',
          evaluations.length,
          resultPage,
          (page) => setState(() => _resultPage = page),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (
              var index = resultPage * _pageSize;
              index < evaluations.length &&
                  index < (resultPage + 1) * _pageSize;
              index++
            )
              ChoiceChip(
                key: Key('benchmark-result-$index'),
                label: Text(
                  '${evaluations[index].model} · ${_suiteNames[evaluations[index].suite['id']] ?? evaluations[index].suite['id']} · ${evaluations[index].channel.toUpperCase()} · ${_status(evaluations[index].status)}',
                ),
                selected: index == _evaluationIndex,
                onSelected: (_) => setState(() {
                  _evaluationIndex = index;
                  _detail = 0;
                  _detailPage = 0;
                  _detailGeneration++;
                  _detailRows = const [];
                }),
              ),
          ],
        ),
        const Text('委员会收益与代价：仅比较同批完整结果及同一通道；名称不代表速度、难度或质量。'),
        if (comparisons.isEmpty) const Text('选择同批原生模型及委员会后可显示对照。'),
        _summaryPages(
          'benchmark-comparisons',
          comparisons.length,
          comparisonPage,
          (page) => setState(() => _comparisonPage = page),
        ),
        for (final comparison
            in comparisons.skip(comparisonPage * _pageSize).take(_pageSize))
          Text(
            '${comparison['suite']} · ${comparison['council']} 对 ${comparison['native']} · ${(comparison['channel'] as String).toUpperCase()} · '
            '${comparison['comparable'] == true ? "accuracy Δ ${comparison['accuracy_delta']} / pair accuracy Δ ${comparison['pair_accuracy_delta']} · P50 Δ ${comparison['latency_success_p50_ms_delta']} ms / P95 Δ ${comparison['latency_success_p95_ms_delta']} ms · 失败 Δ ${comparison['failures_delta']}" : "未完成，不能计算完整成绩差值"}',
          ),
        const Text('成功席位覆盖：未在性能请求中取得公开席位证据，未知；配置成员数不表示成功席位数。'),
        const SizedBox(height: 12),
        _evaluationReport(selected, owner: record),
        _recordFiles(record),
      ],
    );
  }

  Widget _summaryPages(
    String key,
    int total,
    int page,
    void Function(int) select,
  ) => total <= _pageSize
      ? const SizedBox.shrink()
      : Wrap(
          spacing: 12,
          children: [
            Text('第 ${page + 1} 页 · 共 $total 项'),
            TextButton(
              key: Key('$key-previous'),
              onPressed: page == 0 ? null : () => select(page - 1),
              child: const Text('上一页'),
            ),
            TextButton(
              key: Key('$key-next'),
              onPressed: (page + 1) * _pageSize >= total
                  ? null
                  : () => select(page + 1),
              child: const Text('下一页'),
            ),
          ],
        );

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
                onSelected: (_) => _selectDetail(entry.$1),
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
            title: const Text('固定来源 / 原评分 / 运行身份摘要'),
            children: [
              _facts(record.suite),
              _facts(record.identity),
              _facts(summary),
              if (question) _facts(sourceSummary),
            ],
          ),
        if (_detail != 0) _detailList(record),
        if (_fileStatus != null)
          Text(_fileStatus!, key: const Key('benchmark-file-status')),
      ],
    );
  }

  Widget _gameReport(BenchmarkRun record, {required BenchmarkRun owner}) {
    final summary = record.summary;
    final source = record.toJson()['source_summary'];
    final client = record.toJson()['client_summary'] as Map;
    final activeTarget = widget.gameWork?.activeTarget;
    final live =
        owner.id == widget.runner.current?.id &&
        widget.runner.running &&
        record.status == BenchmarkRunStatus.running &&
        activeTarget?['model'] == record.model &&
        activeTarget?['channel'] == record.channel;
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
        if (live && widget.gameWork != null)
          TextButton.icon(
            key: const Key('benchmark-game-watch'),
            onPressed: () => _watchGame(),
            icon: const Icon(Icons.visibility),
            label: const Text('观看当前实际游戏'),
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
                onSelected: (_) => _selectDetail(entry.$1),
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
            title: const Text('固定游戏 / 原独立成绩 / 运行身份摘要'),
            children: [
              _facts(record.suite),
              _facts(record.identity),
              _facts(summary),
              if (source is Map) _facts(Map<String, Object?>.from(source)),
              _facts(Map<String, Object?>.from(client)),
            ],
          ),
        if (_detail != 0) _detailList(record),
        if (_fileStatus != null)
          Text(_fileStatus!, key: const Key('benchmark-file-status')),
      ],
    );
  }

  Future<void> _watchGame({
    Map<String, Object?>? game,
    Map<String, Object?>? identity,
  }) async {
    var completed = false;
    await showDialog<void>(
      context: context,
      builder: (context) {
        final route = ModalRoute.of(context);
        void close() {
          if (completed || !context.mounted || route?.isCurrent != true) {
            return;
          }
          completed = true;
          Navigator.of(context).pop();
        }

        return Dialog(
          child: SizedBox(
            width: 760,
            height: 780,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '关闭观看',
                      onPressed: close,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Expanded(
                    child: JevmanViewer(
                      work: widget.gameWork!,
                      recording: game?['recording'],
                      identity: identity,
                      complete: game?['complete'] == true,
                      gameIndex: game?['index'] as int?,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _cancel() {
    widget.runner.cancel();
    if (widget.gameWork?.status == BenchmarkGamePreparationStatus.preparing) {
      widget.gameWork!.cancelPreparation();
    } else if (_preparing) {
      widget.resources.cancelPreparation();
    }
  }

  @override
  void dispose() {
    _discoveryToken?.cancel();
    unawaited(_subscription.cancel());
    unawaited(_resourceSubscription.cancel());
    unawaited(_gameSubscription?.cancel());
    _timeout.dispose();
    unawaited(
      _closeHistory().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            context: ErrorDescription('关闭历史分页读取'),
          ),
        );
      }),
    );
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
    final metadata = item['metadata'] is Map
        ? item['metadata'] as Map
        : const {};
    return _summaryText(
      '${metadata['source'] ?? metadata['category'] ?? metadata['case'] ?? '原任务'} · ${metadata['question_type'] ?? metadata['primitive'] ?? '原请求组'}',
    );
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
          const Text('本批完整基准（按以下顺序执行）'),
          for (final entry in _suiteNames.entries)
            CheckboxListTile(
              key: Key('benchmark-suite-select-${entry.key}'),
              title: Text(entry.value),
              value: _selectedSuites.contains(entry.key),
              onChanged: _busy
                  ? null
                  : (selected) => setState(() {
                      if (selected == true) {
                        _selectedSuites.add(entry.key);
                      } else {
                        _selectedSuites.remove(entry.key);
                      }
                    }),
            ),
          const Text('按对象 → 基准 → 通道执行；每项完整规模与原评分独立保留。'),
          DropdownButtonFormField<String>(
            key: const Key('benchmark-suite'),
            initialValue: _suiteChoice,
            decoration: const InputDecoration(labelText: '查看题源摘要'),
            items: [
              for (final entry in _suiteNames.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _busy
                ? null
                : (id) {
                    if (id == null) return;
                    setState(() {
                      _suiteChoice = id;
                      _sourceFiles = const [];
                      _sourcePage = 0;
                    });
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
            KeyedSubtree(
              key: const Key('benchmark-suite-metadata'),
              child: _facts(identity),
            ),
            if (_suiteChoice == 'decidebench')
              const Text('297 条原示例 / 63 个原模板；保留原始语言、内容、标签及配对结构。'),
            ExpansionTile(
              title: const Text('实际题源文件与 Finder'),
              children: [
                if (_sourceFiles.isEmpty) const Text('题源文件尚未准备；准备后显示真实文件地址。'),
                for (final file
                    in _sourceFiles
                        .skip(_sourcePage * _pageSize)
                        .take(_pageSize)
                        .indexed)
                  _path(
                    '题源文件 ${file.$1 + 1}',
                    file.$2,
                    'benchmark-source-reveal-${file.$1}',
                  ),
                if (_sourceFiles.length > _pageSize)
                  Wrap(
                    spacing: 12,
                    children: [
                      Text(
                        '题源文件第 ${_sourcePage + 1} 页 · 共 ${_sourceFiles.length} 个实际路径',
                      ),
                      TextButton(
                        key: const Key('benchmark-source-previous'),
                        onPressed: _sourcePage == 0
                            ? null
                            : () => setState(() => _sourcePage--),
                        child: const Text('上一页'),
                      ),
                      TextButton(
                        key: const Key('benchmark-source-next'),
                        onPressed:
                            (_sourcePage + 1) * _pageSize >= _sourceFiles.length
                            ? null
                            : () => setState(() => _sourcePage++),
                        child: const Text('下一页'),
                      ),
                    ],
                  ),
              ],
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
          if (_onlyGames)
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
                helperText: '默认 60 秒；题源准备不计入模型端到端耗时。',
              ),
            ),
          if (!_onlyGames && _deadline == null) const Text('客户端期限必须为有效正秒数。'),
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
                        _selectedSuites.isEmpty ||
                        (!_onlyGames && _deadline == null)
                    ? null
                    : _start,
                child: Text('完整评测 · $_batchScale'),
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
          if (_historyLoading || _historyDetailsLoading)
            const LinearProgressIndicator(),
          if (_historyDetailsLoading)
            Text(
              '后台校验历史与准备摘要 · ${_historySession?.progress['phase'] ?? 'opening'} · 已核对 ${_historySession?.progress['validated_items'] ?? 0} / ${_historySession?.progress['total_items'] ?? '读取中'} 行',
              key: const Key('benchmark-history-progress'),
            ),
          if (_historyListError != null) Text(_historyListError!),
          if (_historyError != null) Text(_historyError!),
          if (!_historyLoading && _history.isEmpty) const Text('暂无评测历史'),
          if (_history.isNotEmpty)
            SizedBox(
              height: 260,
              child: ListView.builder(
                itemCount: (_history.length - _historyPage * _pageSize).clamp(
                  0,
                  _pageSize,
                ),
                itemBuilder: (context, index) {
                  final saved = _history[_historyPage * _pageSize + index];
                  return ListTile(
                    key: Key('benchmark-history-${saved.id}'),
                    title: Text('${saved.model} · ${_status(saved.status)}'),
                    subtitle: Text(
                      '${saved.createdAt.toLocal()} · ${saved.isBatch ? '独立通道对照' : saved.channel.toUpperCase()} · ${saved.summary['attempted']} / ${saved.summary['expected'] ?? 400} · ${saved.suite['pin'] ?? '多基准；逐项版本见报告'}',
                    ),
                    selected: saved.id == (_historyOwnerId ?? _record?.id),
                    onTap: () => _view(saved),
                  );
                },
              ),
            ),
          if (_history.length > _pageSize)
            Wrap(
              spacing: 12,
              children: [
                Text('历史第 ${_historyPage + 1} 页 · 共 ${_history.length} 批'),
                TextButton(
                  key: const Key('benchmark-history-previous'),
                  onPressed: _historyPage == 0
                      ? null
                      : () => setState(() => _historyPage--),
                  child: const Text('上一页'),
                ),
                TextButton(
                  key: const Key('benchmark-history-next'),
                  onPressed: (_historyPage + 1) * _pageSize >= _history.length
                      ? null
                      : () => setState(() => _historyPage++),
                  child: const Text('下一页'),
                ),
              ],
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
