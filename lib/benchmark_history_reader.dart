part of 'benchmark_run_store.dart';

Future<List<String>> _historyRecordFilePaths((String, String) input) =>
    Isolate.run(() async {
      try {
        return await BenchmarkRunStore(directory: Directory(input.$1))
            ._recordFilePaths(input.$2);
      } catch (error) {
        throw _historySafeFailure(error, {
          'file': '${input.$1}/${input.$2}.json',
        });
      }
    });

Future<List<BenchmarkRun>> _historySummaryList(String directory) =>
    Isolate.run(() async {
      try {
        return await BenchmarkRunStore(directory: Directory(directory))
            ._listSummaries();
      } catch (error) {
        throw _historySafeFailure(error, {'file': directory});
      }
    });

// Top-level helpers capture only explicit path/ID values. An app-owned store
// can hold receive ports; those must never be captured by an Isolate.run closure.
Future<BenchmarkRun> _historyCompleteLoad((String, String) input) =>
    Isolate.run(() async {
      Map<String, Object?> progress = {'file': '${input.$1}/${input.$2}.json'};
      try {
        return await BenchmarkRunStore(directory: Directory(input.$1))._load(
          input.$2,
          details: true,
          onProgress: (value) => progress = value,
        );
      } catch (error) {
        throw _historySafeFailure(error, progress);
      }
    });

Future<List<int>> _historyExportBytes((String, String) input) =>
    Isolate.run(() async {
      Map<String, Object?> progress = {'file': '${input.$1}/${input.$2}.json'};
      try {
        final record = await BenchmarkRunStore(directory: Directory(input.$1))
            ._load(
              input.$2,
              details: true,
              onProgress: (value) => progress = value,
            );
        return utf8.encode(
          const JsonEncoder.withIndent('  ').convert(record.toJson()),
        );
      } catch (error) {
        throw _historySafeFailure(error, progress);
      }
    });

Future<List<String>> _historyDeletionFiles((String, String) input) =>
    Isolate.run(() async {
      try {
        return await BenchmarkRunStore(directory: Directory(input.$1))
            ._validatedDeletionFiles(input.$2);
      } catch (error) {
        throw _historySafeFailure(error, {
          'file': '${input.$1}/${input.$2}.json',
        });
      }
    });

/// Owns a verified historical record in a worker, never in the page's isolate.
/// Only summaries leave the worker, except a single explicitly requested game.
class BenchmarkHistorySession {
  BenchmarkHistorySession._(this._directory, this._id) {
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
    _messages.listen(_receive);
    _exits.listen((_) {
      if (!_exited.isCompleted) {
        _exited.complete();
      }
      if (!_closed) {
        _fail(StateError('历史工作任务已退出；完整内容见原记录文件。'));
      }
    });
    _errors.listen((_) => _fail(StateError('历史工作任务异常；完整内容见原记录文件。')));
    unawaited(_start());
  }

  final String _directory, _id;
  final _ready = Completer<BenchmarkRun>();
  final _started = Completer<void>();
  final _exited = Completer<void>();
  final _messages = ReceivePort();
  final _exits = ReceivePort();
  final _errors = ReceivePort();
  final _changes = StreamController<Map<String, Object?>>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  Isolate? _worker;
  SendPort? _commands;
  Map<String, Map<String, int>> _counts = const {};
  List<String> _journalPaths = const [];
  var _sequence = 0;
  bool _closed = false;
  Object? _failure;
  Future<void>? _closing;
  void Function()? _onClosed;
  Map<String, Object?> _progress = const {
    'phase': 'opening',
    'validated_items': 0,
    'total_items': null,
  };

  Future<BenchmarkRun> get ready => _ready.future;
  Stream<Map<String, Object?>> get changes => _changes.stream;
  Map<String, Object?> get progress => _progress;
  String get recordFilePath => '$_directory/$_id.json';
  List<String> get journalFilePaths => _journalPaths;
  int itemCount(String evaluationId) => _count(evaluationId, 'items');
  int groupCount(String evaluationId) => _count(evaluationId, 'groups');
  int warmupCount(String evaluationId) => _count(evaluationId, 'warmup');

  int _count(String id, String field) {
    final counts = _counts[id];
    if (counts == null) {
      throw StateError('历史摘要尚未就绪或对象不存在');
    }
    return counts[field]!;
  }

  Future<void> _start() async {
    try {
      _worker = await Isolate.spawn(
        _historyReaderWorker,
        {'directory': _directory, 'id': _id, 'reply': _messages.sendPort},
        onExit: _exits.sendPort,
        onError: _errors.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      _fail(StateError('历史工作任务无法启动；完整内容见原记录文件。'));
      if (!_exited.isCompleted) {
        _exited.complete();
      }
    } finally {
      _started.complete();
    }
  }

  void _receive(Object? message) {
    if (_closed) {
      return;
    }
    if (message is! Map) {
      _fail(const FormatException('历史工作任务响应无效'));
      return;
    }
    try {
      if (message['type'] == 'control') {
        _commands = message['port'] as SendPort;
      } else if (message['type'] == 'progress') {
        _progress = Map<String, Object?>.unmodifiable(
          Map<String, Object?>.from(message['value'] as Map),
        );
        _changes.add(_progress);
      } else if (message['type'] == 'ready') {
        final record = message['record'];
        final counts = message['counts'];
        final journals = message['journals'];
        if (record is! BenchmarkRun || counts is! Map || journals is! List) {
          throw const FormatException('历史摘要响应无效');
        }
        _counts = Map<String, Map<String, int>>.unmodifiable({
          for (final entry in counts.entries)
            entry.key as String: Map<String, int>.unmodifiable(
              Map<String, int>.from(entry.value as Map),
            ),
        });
        _journalPaths = List<String>.unmodifiable(journals.cast<String>());
        _progress = Map<String, Object?>.unmodifiable({
          'phase': 'ready',
          'validated_items': record.summary['attempted'],
          'total_items': record.summary['attempted'],
        });
        _ready.complete(record);
        _changes.add(_progress);
      } else if (message['type'] == 'failed') {
        _fail(message['error'] as Object);
      } else if (message['type'] == 'response') {
        final pending = _pending.remove(message['request']);
        if (message['error'] != null) {
          pending?.completeError(message['error'] as Object);
        } else {
          pending?.complete(message['value']);
        }
      }
    } catch (_) {
      _fail(const FormatException('历史工作任务响应无效；完整内容见原记录文件。'));
    }
  }

  void _fail(Object error) {
    _failure = error;
    if (!_ready.isCompleted) {
      _ready.completeError(error);
    }
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    if (!_closed) {
      _progress = Map<String, Object?>.unmodifiable({
        ..._progress,
        'phase': 'failed',
        'message': error.toString(),
      });
      _changes.add(_progress);
    }
  }

  Future<Object?> _request(
    String operation,
    Map<String, Object?> arguments,
  ) async {
    if (_closed) {
      throw StateError('历史读取已关闭');
    }
    await ready;
    if (_closed) {
      throw StateError('历史读取已关闭');
    }
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    final request = ++_sequence;
    final result = Completer<Object?>();
    _pending[request] = result;
    _commands!.send({'request': request, 'operation': operation, ...arguments});
    return result.future;
  }

  Future<List<Map<String, Object?>>> items({
    required String evaluationId,
    required int offset,
    int limit = 20,
  }) => _page('items', evaluationId, offset, limit);
  Future<List<Map<String, Object?>>> groups({
    required String evaluationId,
    required int offset,
    int limit = 20,
  }) => _page('groups', evaluationId, offset, limit);
  Future<List<Map<String, Object?>>> warmupCalls({
    required String evaluationId,
    required int offset,
    int limit = 20,
  }) => _page('warmup', evaluationId, offset, limit);

  Future<List<Map<String, Object?>>> _page(
    String kind,
    String evaluationId,
    int offset,
    int limit,
  ) async {
    if (offset < 0 || limit < 1 || limit > 20) {
      throw RangeError('历史摘要页只接受非负位置及1至20条');
    }
    final result = await _request(kind, {
      'evaluationId': evaluationId,
      'offset': offset,
      'limit': limit,
    });
    return List<Map<String, Object?>>.unmodifiable(
      (result as List).map(
        (row) => freezeDebugJson(row) as Map<String, Object?>,
      ),
    );
  }

  Future<Map<String, Object?>> game({
    required String evaluationId,
    required String gameId,
  }) async {
    final result = await _request('game', {
      'evaluationId': evaluationId,
      'gameId': gameId,
    });
    return freezeDebugJson(result) as Map<String, Object?>;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _fail(StateError('历史读取已关闭'));
    await _started.future;
    _worker?.kill(priority: Isolate.immediate);
    await _exited.future;
    _messages.close();
    _exits.close();
    _errors.close();
    _onClosed?.call();
    await _changes.close();
  }
}

Future<void> _historyReaderWorker(Map<String, Object?> arguments) async {
  final reply = arguments['reply'] as SendPort;
  final commands = ReceivePort();
  reply.send({'type': 'control', 'port': commands.sendPort});
  final store = BenchmarkRunStore(
    directory: Directory(arguments['directory'] as String),
  );
  final id = arguments['id'] as String;
  Map<String, Object?> progress = const {'phase': 'opening'};
  try {
    // Use the complete existing external-data boundary. Hash raw rows before
    // validating and globally sealing; no per-row credential domain is lost.
    final record = await store._load(
      id,
      details: true,
      onProgress: (value) {
        progress = value;
        reply.send({'type': 'progress', 'value': value});
      },
    );
    final evaluations = {
      for (final evaluation in record.evaluations) evaluation.id: evaluation,
    };
    reply.send({
      'type': 'ready',
      'record': _historyLightRecord(record),
      'counts': {
        for (final evaluation in evaluations.values)
          evaluation.id: {
            'items': evaluation.items.length,
            'groups': evaluation.groups.length,
            'warmup': evaluation.isGameRun
                ? (evaluation.toJson()['warmup_calls'] as List).length
                : 0,
          },
      },
      'journals': [
        if (record.usesJournal)
          for (var index = 0; index < evaluations.length; index++)
            if (record.evaluations[index].usesJournal)
              store._journalFile(id, index).absolute.path,
      ],
    });
    await for (final incoming in commands) {
      if (incoming is! Map || incoming['request'] is! int) {
        continue;
      }
      try {
        final evaluation = evaluations[incoming['evaluationId']];
        if (evaluation == null) {
          throw StateError('历史对象不存在');
        }
        final operation = incoming['operation'];
        Object? value;
        if (operation == 'game') {
          if (!evaluation.isGameRun) {
            throw StateError('该对象不是游戏记录');
          }
          value = evaluation.items.firstWhere(
            (game) => game['id'] == incoming['gameId'],
          );
        } else {
          final rows = switch (operation) {
            'items' => evaluation.items,
            'groups' => evaluation.groups,
            'warmup' =>
              evaluation.isGameRun
                  ? evaluation.toJson()['warmup_calls'] as List
                  : const [],
            _ => throw StateError('历史摘要请求无效'),
          };
          final offset = incoming['offset'];
          final limit = incoming['limit'];
          if (offset is! int ||
              offset < 0 ||
              limit is! int ||
              limit < 1 ||
              limit > 20) {
            throw RangeError('历史摘要页无效');
          }
          value = [
            for (final row in rows.skip(offset).take(limit))
              _historyRowSummary(
                Map<String, Object?>.from(row as Map),
                operation as String,
                game: evaluation.isGameRun,
              ),
          ];
        }
        reply.send({
          'type': 'response',
          'request': incoming['request'],
          'value': value,
        });
      } catch (error) {
        reply.send({
          'type': 'response',
          'request': incoming['request'],
          'error': _historySafeFailure(error, progress),
        });
      }
    }
  } catch (error) {
    reply.send({
      'type': 'failed',
      'error': _historySafeFailure(error, progress),
    });
    commands.close();
  }
}

Object _historySafeFailure(Object error, Map<String, Object?> progress) {
  // JSON FormatException.source can contain an entire raw credential-bearing
  // row. Never send the exception object, raw context or secret sets to UI.
  final position = progress['line'] is int ? '（日志第${progress['line']}行）' : '';
  final suffix = '$position；完整内容见原记录文件。';
  final reason =
      error is FormatException &&
          _historySafeFormatReasons.contains(error.message)
      ? error.message
      : '历史格式、完整性或公开响应校验失败';
  return switch (error) {
    FormatException() => FormatException('$reason$suffix'),
    FileSystemException() => FileSystemException(
      '历史文件不存在、不是普通文件或读写失败$suffix',
      progress['file'] as String?,
    ),
    RangeError() => RangeError('历史摘要页位置或数量无效$suffix'),
    _ => StateError('历史读取失败或对象不存在$suffix'),
  };
}

final _historySafeFormatReasons = <String>{
  '原题逐行内容摘要或请求 ID 无效',
  '评测摘要进度、完成状态或错误说明无效',
  for (final key in const [
    'expected',
    'expected_pairs',
    'missing',
    'valid',
    'failures',
    'timeouts',
    'client_timeouts',
    'server_timeouts',
    'probability_coverage',
    'unusable',
    'correct',
    'pairs_correct',
  ])
    '评测摘要计数无效：$key',
  for (final key in const [
    'accuracy',
    'pair_accuracy',
    'brier',
    'ece',
    'latency_success_p50_ms',
    'latency_success_p95_ms',
  ])
    '评测摘要数字无效：$key',
};

String? _historyErrorSummary(Object? error) {
  if (error == null) {
    return null;
  }
  if (error is String &&
      (error == 'HTTP 服务未运行' ||
          error.startsWith('HTTP 服务未运行：') ||
          error.startsWith('Bad state: HTTP 服务未运行：') ||
          error.startsWith('执行或保存评测记录失败：Bad state: HTTP 服务未运行：'))) {
    return 'HTTP 服务未运行；完整错误见原记录文件。';
  }
  return '批次有错误；完整错误见原记录文件。';
}

BenchmarkRun _historyLightRecord(BenchmarkRun record) {
  final value = record.toJson();
  final allowed = <String, Object?>{
    ..._historyPick(value, const [
      'schema_version',
      'id',
      'created_at',
      'finished_at',
      'status',
      'model',
      'source',
      'channel',
      'timeout_us',
    ]),
    // Fixed source/scoring identity is metadata, not question or trace data.
    // Keep all hashes, licenses, source conditions and module versions intact.
    'suite': record.suite,
    'identity': _historyPick(record.identity, const [
      'model',
      'source',
      'generation',
      'selection_status',
      'api_key',
    ]),
    'summary':
        _historyPick(record.summary, const [
          'expected',
          'expected_pairs',
          'attempted',
          'missing',
          'complete',
          'valid',
          'failures',
          'client_timeouts',
          'server_timeouts',
          'timeouts',
          'latency_success_p50_ms',
          'latency_success_p95_ms',
          'accuracy',
          'pair_accuracy',
          'correct',
          'pairs_correct',
          'unusable',
          'probability_coverage',
          'brier',
          'ece',
          'label_source',
          'evaluations',
        ])..addAll({
          if (record.summary.containsKey('error'))
            'error': _historyErrorSummary(record.summary['error']),
        }),
    'source_summary': _historyScoreSummary(
      record.isQuestionRun || record.isGameRun
          ? value['source_summary'] as Map? ?? {}
          : {},
    ),
    'client_summary': _historyPick(
      record.isGameRun ? value['client_summary'] as Map? ?? {} : {},
      const [
        'calls',
        'successes',
        'unknown_outcome',
        'client_timeouts',
        'server_timeouts',
        'game_successes',
        'latency_success_samples',
        'latency_success_coverage',
        'latency_success_scope',
        'latency_time_source',
      ],
    ),
    'items': <Object?>[],
    'groups': <Object?>[],
    if (record.isGameRun) 'warmup_calls': <Object?>[],
    if (record.isBatch)
      'evaluations': [
        for (final evaluation in record.evaluations)
          _historyLightRecord(evaluation).toJson(),
      ],
  };
  return BenchmarkRun._(freezeDebugJson(allowed) as Map<String, Object?>);
}

Map<String, Object?> _historyPick(Map value, List<String> keys) => {
  for (final key in keys)
    if (value.containsKey(key) &&
        (value[key] == null ||
            value[key] is num ||
            value[key] is bool ||
            value[key] is String))
      key: value[key] is String && (value[key] as String).length > 512
          ? '${(value[key] as String).substring(0, 512)}…（完整内容见原记录文件）'
          : value[key],
};

Map<String, Object?> _historyScoreSummary(Map value) {
  const keys = [
    'complete',
    'expectedGames',
    'status',
    'accuracy',
    'scoreMae',
    'probabilityCount',
    'classificationTotal',
    'brier',
    'ece',
    'overall',
    'judged_tests',
    'unscored_tests',
    'model',
    'name',
    'games',
    'meanScore',
    'bestScore',
    'scoreStdError',
    'meanSurvivedSeconds',
    'meanPellets',
    'pelletsPerLife',
    'meanGhostsEaten',
    'fruitEaten',
    'bestLevel',
    'fallbackRate',
    'meanLatencyMs',
    'costPerGame',
  ];
  return {
    ..._historyPick(value, keys),
    for (final key in const ['summary', 'originalSummary', 'graded'])
      if (value[key] is Map) key: _historyPick(value[key] as Map, keys),
  };
}

Map<String, Object?> _historyRowSummary(
  Map<String, Object?> row,
  String kind, {
  required bool game,
}) {
  if (kind == 'groups') {
    return _historyPick(row, const [
      'id',
      'pair_id',
      'dimension',
      'group',
      'category',
      'relation',
      'kind',
      'name',
      'family',
      'attempted',
      'expected',
      'planned',
      'total',
      'n',
      'valid',
      'missing',
      'failures',
      'complete',
      'correct',
      'accuracy',
      'score',
      'overall',
      'mean',
      'std',
      'mae',
      'brier',
      'ece',
    ]);
  }
  if (kind == 'warmup') {
    final result = row['result'];
    return {
      ..._historyPick(row, const [
        'id',
        'phase',
        'channel',
        'elapsed_us',
        'status',
      ]),
      if (result is Map) ..._historyPick(result, const ['status']),
    };
  }
  final summary = _historyPick(row, const [
    'id',
    'status',
    'index',
    'complete',
    'costKnown',
    'category',
    'difficulty',
    'gold',
    'prediction',
    'elapsed_us',
  ]);
  if (row['error'] != null) {
    summary['error'] = '调用失败；完整错误见原记录文件。';
  }
  final metadata = row['metadata'];
  if (metadata is Map) {
    summary['metadata'] = _historyPick(metadata, const [
      'source',
      'category',
      'case',
      'question_type',
      'primitive',
    ]);
  }
  if (game && row['result'] is Map) {
    summary['result'] = {
      for (final key in const [
        'score',
        'pellets',
        'deaths',
        'level',
        'calls',
        'decisions',
        'fallbacks',
        'survived',
        'latencyMsSum',
        'cost',
        'fruitSpawned',
        'fruitEaten',
        'ghostsEaten',
      ])
        if ((row['result'] as Map).containsKey(key))
          key: (row['result'] as Map)[key],
    };
  }
  return summary;
}
