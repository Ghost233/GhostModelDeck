import 'dart:async';
import 'dart:convert';

import 'benchmark_game_work.dart';
import 'benchmark_run_store.dart';
import 'decidebench.dart';
import 'frozen_question_suite.dart';
import 'jev_models.dart';
import 'jev_playground.dart';

/// Application-owned evaluation over the normal public client graph.
class BenchmarkRunner {
  BenchmarkRunner({
    required this.client,
    required this.store,
    required this.models,
  });
  final JevPlayground client;
  final BenchmarkRunStore store;
  final JevModels models;
  final _changes = StreamController<BenchmarkRun>.broadcast();
  BenchmarkRun? current;
  Future<BenchmarkRun>? _operation;
  DecisionCancellation? _batchCancellation;
  BenchmarkRunStatus? _requestedStatus;
  bool _closed = false;
  Future<void>? _closing;
  ({Object error, StackTrace stack})? _terminalFailure;
  Stream<BenchmarkRun> get changes => _changes.stream;
  bool get running => _operation != null;

  Future<List<JevDiscoveredModel>> targets({
    DecisionCancellation? cancellation,
    JevPlaygroundMode channel = JevPlaygroundMode.http,
  }) async {
    if (_closed) throw StateError('评测执行器已关闭');
    return client.modelsFromDiscovery(
      await client.discover(channel, cancellation: cancellation),
    );
  }

  Future<BenchmarkRun> run({
    required DecideBenchSuite suite,
    String? model,
    List<String>? modelNames,
    List<JevPlaygroundMode> channels = const [JevPlaygroundMode.http],
    Duration timeout = const Duration(seconds: 30),
  }) => _start(
    suite: suite,
    model: model,
    modelNames: modelNames,
    channels: channels,
    timeout: timeout,
  );

  Future<BenchmarkRun> runQuestions({
    required FrozenQuestionSuite suite,
    String? model,
    List<String>? modelNames,
    List<JevPlaygroundMode> channels = const [JevPlaygroundMode.http],
    Duration timeout = const Duration(seconds: 30),
  }) => _start(
    suite: suite,
    model: model,
    modelNames: modelNames,
    channels: channels,
    timeout: timeout,
  );

  Future<BenchmarkRun> runJevman({
    required BenchmarkGameWork work,
    String? model,
    List<String>? modelNames,
    List<JevPlaygroundMode> channels = const [JevPlaygroundMode.http],
  }) => _start(
    suite: work,
    model: model,
    modelNames: modelNames,
    channels: channels,
    timeout: const Duration(seconds: 2),
  );

  Future<BenchmarkRun> _start({
    required Object suite,
    String? model,
    List<String>? modelNames,
    required List<JevPlaygroundMode> channels,
    required Duration timeout,
  }) {
    if (_closed) throw StateError('评测执行器已关闭');
    final previousFailure = _terminalFailure;
    if (previousFailure != null) {
      Error.throwWithStackTrace(previousFailure.error, previousFailure.stack);
    }
    if (_operation != null) throw StateError('已有评测批次在运行');
    final names = List<String>.unmodifiable(
      modelNames ?? (model == null ? const <String>[] : [model]),
    );
    final modes = List<JevPlaygroundMode>.unmodifiable(channels);
    final fullSuite = suite is DecideBenchSuite
        ? suite.items.length == 400
        : suite is BenchmarkGameWork
        ? suite.identity['games'] == 100
        : suite is FrozenQuestionSuite &&
              suite.tasks.length ==
                  switch (suite.identity['id']) {
                    'jeval' => 11257,
                    'coherence' => 10320,
                    'adversarial' => 11368,
                    _ => -1,
                  };
    if (!fullSuite ||
        timeout <= Duration.zero ||
        names.isEmpty ||
        names.any((name) => name.isEmpty) ||
        names.toSet().length != names.length ||
        modelNames != null && model != null ||
        modes.isEmpty ||
        modes.toSet().length != modes.length) {
      throw const FormatException('需要完整原题、唯一参赛对象/通道及正客户端期限');
    }
    _requestedStatus = null;
    final cancellation = DecisionCancellation();
    _batchCancellation = cancellation;
    final operation = _execute(
      suite,
      names,
      modes,
      timeout,
      cancellation,
      names.length * modes.length > 1,
    );
    _operation = operation;
    return operation.whenComplete(() {
      _operation = null;
      _batchCancellation = null;
    });
  }

  Future<BenchmarkRun> _execute(
    Object suite,
    List<String> names,
    List<JevPlaygroundMode> channels,
    Duration timeout,
    DecisionCancellation cancellation,
    bool batch,
  ) async {
    final selections = <String, JevEvaluationLock>{};
    final evaluations = <_Evaluation>[];
    final started = DateTime.now().toUtc();
    final id = 'run-${started.microsecondsSinceEpoch}';
    var status = BenchmarkRunStatus.running;
    try {
      await models.load();
      for (final name in names) {
        final definition = models.definitions
            .where((entry) => entry.name == name)
            .firstOrNull;
        if (definition == null) throw StateError('$name 未在模型注册配置中');
        for (final channel in channels) {
          evaluations.add(
            suite is DecideBenchSuite
                ? _DecideEvaluation(
                    suite: suite,
                    model: name,
                    channel: channel,
                    declaredSource: definition.source.name,
                    timeout: timeout,
                    started: started,
                    id: batch ? '$id-${evaluations.length}' : id,
                  )
                : suite is BenchmarkGameWork
                ? _GameEvaluation(
                    work: suite,
                    model: name,
                    channel: channel,
                    declaredSource: definition.source.name,
                    timeout: timeout,
                    started: started,
                    id: batch ? '$id-${evaluations.length}' : id,
                  )
                : _QuestionEvaluation(
                    suite: suite as FrozenQuestionSuite,
                    model: name,
                    channel: channel,
                    declaredSource: definition.source.name,
                    timeout: timeout,
                    started: started,
                    id: batch ? '$id-${evaluations.length}' : id,
                  ),
          );
        }
      }
      var preparing = true;

      void applyCancellation() {
        if (_requestedStatus == null) return;
        status = _requestedStatus!;
        for (final evaluation in evaluations) {
          if (evaluation.status == BenchmarkRunStatus.running) {
            evaluation.status = _requestedStatus!;
          }
        }
        // An intent accepted during the final flush also seals the last
        // object's full score, rather than presenting cancellation as success.
        if (evaluations.isNotEmpty &&
            evaluations.last.status == BenchmarkRunStatus.completed) {
          evaluations.last.status = _requestedStatus!;
        }
      }

      BenchmarkRun snapshot() => batch
          ? BenchmarkRun.batch(
              id: id,
              createdAt: started,
              status: status,
              evaluations: [
                for (final evaluation in evaluations) evaluation.snapshot(),
              ],
            )
          : evaluations.single.snapshot();
      Future<BenchmarkRun> scoredSnapshot() async {
        while (true) {
          applyCancellation();
          final statuses = [
            for (final evaluation in evaluations) evaluation.status,
          ];
          for (final evaluation in evaluations) {
            await evaluation.prepareTerminalScore();
          }
          applyCancellation();
          if (Iterable<int>.generate(evaluations.length)
              .every((index) => statuses[index] == evaluations[index].status)) {
            return snapshot();
          }
        }
      }

      Future<void> persist() async {
        var record = await scoredSnapshot();
        try {
          await store.save(record);
        } catch (error, stack) {
          _terminalFailure ??= (error: error, stack: stack);
          rethrow;
        }
        while (_requestedStatus != null && record.status != _requestedStatus) {
          record = await scoredSnapshot();
          try {
            await store.save(record);
          } catch (error, stack) {
            _terminalFailure ??= (error: error, stack: stack);
            rethrow;
          }
        }
        current = record;
        _changes.add(record);
      }

      try {
        // Persist an honest zero-execution plan before asynchronous admission.
        // A source here describes registered kind, not public readiness.
        await persist();
        for (final name in names) {
          if (_requestedStatus != null) break;
          final selection = await models.lockForEvaluation(name);
          selections[name] = selection;
          for (final evaluation in evaluations.where(
            (entry) => entry.model == name,
          )) {
            evaluation.selection = selection;
          }
        }
        for (final channel in channels) {
          if (_requestedStatus != null) break;
          final available = await targets(
            channel: channel,
            cancellation: cancellation,
          );
          for (final evaluation in evaluations.where(
            (entry) => entry.channel == channel,
          )) {
            if (!available.any(
              (entry) =>
                  entry.id == evaluation.model &&
                  entry.source == evaluation.source,
            )) {
              throw StateError(
                '${evaluation.model} 未在公开 ${channel.name.toUpperCase()} 入口中可调用',
              );
            }
          }
        }
        preparing = false;
        final unavailable = <String>{};
        for (final evaluation in evaluations) {
          if (_requestedStatus != null) break;
          if (unavailable.contains(evaluation.model)) {
            evaluation.status = BenchmarkRunStatus.targetUnavailable;
            evaluation.failure = '同批对象此前已不可用；未执行此通道';
            await persist();
            continue;
          }
          if (evaluation is _GameEvaluation) {
            final terminal = await evaluation.work.play(
              client: client,
              model: evaluation.model,
              channel: evaluation.channel,
              cancellation: cancellation,
              isCurrent: () => evaluation.selection!.isCurrent,
              onGameCommitted: (game) async {
                evaluation.recordGame(game);
                await persist();
              },
            );
            evaluation.finish(terminal);
            if (_requestedStatus == null &&
                terminal['status'] == 'targetUnavailable') {
              evaluation.status = BenchmarkRunStatus.targetUnavailable;
              evaluation.failure = '参赛对象已不可用或运行身份已变化';
            } else if (_requestedStatus == null &&
                terminal['status'] != 'completed') {
              evaluation.status = BenchmarkRunStatus.failed;
              evaluation.failure = '原游戏运行未正常完成：${terminal['status']}';
            }
          }
          for (final item in evaluation.tasks) {
            if (_requestedStatus != null) break;
            if (!evaluation.selection!.isCurrent) {
              evaluation.status = BenchmarkRunStatus.targetUnavailable;
              evaluation.failure = '参赛对象已不可用或运行身份已变化';
              break;
            }
            try {
              final available = await targets(
                channel: evaluation.channel,
                cancellation: cancellation,
              );
              if (!available.any(
                (entry) =>
                    entry.id == evaluation.model &&
                    entry.source == evaluation.source,
              )) {
                throw StateError('参赛对象已不在公开发现中');
              }
            } catch (error) {
              if (_requestedStatus == null) {
                evaluation.status = BenchmarkRunStatus.targetUnavailable;
                evaluation.failure =
                    '公开 ${evaluation.channel.name.toUpperCase()} 对象不可用：$error';
              }
              break;
            }
            if (_requestedStatus != null) break;
            // A question deadline ends that ordinary request, not the batch.
            // Explicit batch cancellation still reaches the active request.
            final requestCancellation = DecisionCancellation();
            final remove = cancellation.listen(requestCancellation.cancel);
            late JevPlaygroundResult reply;
            try {
              reply = await client.run(
                evaluation.channel,
                evaluation.requestDocument(item),
                validateBeforeSend: evaluation.validateBeforeSend,
                timeout: timeout,
                cancellation: requestCancellation,
              );
            } finally {
              remove();
            }
            evaluation.record(item, reply);
            if (!evaluation.selection!.isCurrent && _requestedStatus == null) {
              evaluation.status = BenchmarkRunStatus.targetUnavailable;
              evaluation.failure = '参赛对象已不可用或运行身份已变化；本次响应已留存';
            }
            await persist();
            if (evaluation.status != BenchmarkRunStatus.running) break;
          }
          if (_requestedStatus != null) break;
          if (evaluation.status == BenchmarkRunStatus.running) {
            evaluation.status = BenchmarkRunStatus.completed;
          }
          if (evaluation.status == BenchmarkRunStatus.targetUnavailable) {
            unavailable.add(evaluation.model);
          }
          await persist();
        }
        status =
            _requestedStatus ??
            (evaluations.every(
                  (entry) => entry.status == BenchmarkRunStatus.completed,
                )
                ? BenchmarkRunStatus.completed
                : BenchmarkRunStatus.targetUnavailable);
        await persist();
        return current!;
      } catch (error, stack) {
        if (preparing && _requestedStatus != null && _terminalFailure == null) {
          await persist();
          return current!;
        }
        status = BenchmarkRunStatus.failed;
        for (final evaluation in evaluations) {
          if (evaluation.status == BenchmarkRunStatus.running ||
              evaluations.length == 1) {
            evaluation.status = BenchmarkRunStatus.failed;
            evaluation.failure = '执行或保存评测记录失败：$error';
          }
        }
        if (!preparing) _terminalFailure ??= (error: error, stack: stack);
        current = snapshot();
        if (preparing && _terminalFailure == null) {
          try {
            await store.save(current!);
          } catch (saveError, saveStack) {
            // Retain the original admission error; shutdown also reports
            // the separate persistence failure instead of calling it sealed.
            _terminalFailure = (error: saveError, stack: saveStack);
          }
        }
        _changes.add(current!);
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      for (final selection in selections.values) {
        selection.release();
      }
    }
  }

  void cancel() {
    if (_operation == null) return;
    _requestedStatus ??= BenchmarkRunStatus.cancelled;
    _batchCancellation?.cancel();
  }

  void _requestInterruption() {
    if (_operation != null) {
      _requestedStatus = BenchmarkRunStatus.interrupted;
      _batchCancellation?.cancel();
    }
  }

  Future<void> interrupt() {
    _requestInterruption();
    final operation = _operation;
    if (operation != null) return operation.then<void>((_) {});
    final failure = _terminalFailure;
    return failure == null
        ? Future<void>.value()
        : Future<void>.error(failure.error, failure.stack);
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    // Seal and cancel synchronously, before shutdown waits for persistence.
    _closed = true;
    _requestInterruption();
    return _closing = _finishClosing(_operation);
  }

  Future<void> _finishClosing(Future<BenchmarkRun>? operation) async {
    try {
      if (operation != null) await operation;
      final failure = _terminalFailure;
      if (failure != null) {
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
    } finally {
      await _changes.close();
    }
  }
}

abstract class _Evaluation {
  _Evaluation({
    required this.model,
    required this.channel,
    required this.declaredSource,
    required this.timeout,
    required this.started,
    required this.id,
  });
  final String model;
  final JevPlaygroundMode channel;
  final String declaredSource;
  JevEvaluationLock? selection;
  String get source =>
      selection?.identity['source'] as String? ?? declaredSource;
  final Duration timeout;
  final DateTime started;
  final String id;
  BenchmarkRunStatus status = BenchmarkRunStatus.running;
  String? failure;
  DateTime? finishedAt;
  BenchmarkRun? _terminalSnapshot;
  Iterable<Object> get tasks;
  bool get validateBeforeSend => true;
  String requestDocument(Object task);
  void record(Object task, JevPlaygroundResult reply);
  Future<void> prepareTerminalScore() async {}
  BenchmarkRun snapshot();
}

class _DecideEvaluation extends _Evaluation {
  _DecideEvaluation({
    required this.suite,
    required super.model,
    required super.channel,
    required super.declaredSource,
    required super.timeout,
    required super.started,
    required super.id,
  }) {
    for (final item in suite.items) {
      byPair.putIfAbsent(item.pairId, () => []).add(item);
    }
  }
  final DecideBenchSuite suite;
  @override
  Iterable<Object> get tasks => suite.items;
  @override
  String requestDocument(Object task) =>
      jsonEncode((task as DecideBenchItem).request(model));
  final results = <Map<String, Object?>>[];
  final predictions = <String, String?>{};
  final probabilities = <String, Map<String, double>>{};
  final byPair = <String, List<DecideBenchItem>>{};
  @override
  void record(Object task, JevPlaygroundResult reply) {
    final item = task as DecideBenchItem;
    // Only typed success may contribute predictions or probabilities.
    final output = reply.status == JevPlaygroundStatus.success
        ? reply.output
        : null;
    final choice = item.extractChoice(output);
    final distribution = item.extractProbabilities(output);
    predictions[item.id] = choice;
    if (distribution != null) probabilities[item.id] = distribution;
    results.add({
      'id': item.id,
      'pair_id': item.pairId,
      'category': item.category,
      'difficulty': item.difficulty,
      'gold': item.gold,
      'prediction': choice,
      'status': reply.status.name,
      'elapsed_us': reply.elapsed.inMicroseconds,
      'request': reply.request,
      'request_json': reply.requestBody,
      'result': reply.toJson(),
      'error': reply.status == JevPlaygroundStatus.success
          ? null
          : reply.message,
    });
  }

  @override
  BenchmarkRun snapshot() {
    final terminal = _terminalSnapshot;
    if (status != BenchmarkRunStatus.running && terminal?.status == status) {
      return terminal!;
    }
    final score = suite.score(predictions, probabilities: probabilities);
    final complete = status == BenchmarkRunStatus.completed && score.complete;
    final successful = results
        .where((row) => row['status'] == 'success')
        .toList();
    final clientTimeouts = results
        .where((row) => row['status'] == JevPlaygroundStatus.timedOut.name)
        .length;
    final serverTimeouts = results.where((row) {
      final result = row['result'] as Map;
      final output = result['output'];
      return row['status'] == JevPlaygroundStatus.businessError.name &&
          output is Map &&
          output['error'] is Map &&
          (output['error'] as Map)['code'] == 'timed_out';
    }).length;
    final latency = [for (final row in successful) row['elapsed_us'] as int]
      ..sort();
    double? percentile(double q) {
      if (latency.isEmpty) return null;
      final position = (latency.length - 1) * q;
      final low = position.floor(), high = position.ceil();
      return (latency[low] +
              (latency[high] - latency[low]) * (position - low)) /
          1000;
    }

    final record = BenchmarkRun.fromJson({
      'schema_version': 1,
      'id': id,
      'created_at': started.toIso8601String(),
      'finished_at': status == BenchmarkRunStatus.running
          ? null
          : (finishedAt ??= DateTime.now().toUtc()).toIso8601String(),
      'status': status.name,
      'model': model,
      'source': source,
      'channel': channel.name,
      'timeout_us': timeout.inMicroseconds,
      'suite': suite.identity,
      'identity': selection?.identity ?? {'selection_status': 'not_acquired'},
      'items': results,
      'groups': [
        for (final pair in byPair.entries)
          {
            'pair_id': pair.key,
            'members': [for (final item in pair.value) item.id],
            'attempted': pair.value
                .where((item) => predictions.containsKey(item.id))
                .length,
            'complete': pair.value.every(
              (item) => predictions.containsKey(item.id),
            ),
            'correct': pair.value.every(
              (item) => predictions[item.id] == item.gold,
            ),
          },
      ],
      'summary': {
        'expected': 400,
        'expected_pairs': 200,
        'attempted': results.length,
        'missing': 400 - results.length,
        'complete': complete,
        'valid': successful.length,
        'failures': results.length - successful.length,
        'client_timeouts': clientTimeouts,
        'server_timeouts': serverTimeouts,
        'timeouts': clientTimeouts + serverTimeouts,
        'probability_coverage': probabilities.length,
        'accuracy': complete ? score.accuracy : null,
        'pair_accuracy': complete ? score.pairAccuracy : null,
        'unusable': score.unusable,
        'correct': score.correct,
        'pairs_correct': score.pairsCorrect,
        'brier': complete ? score.brier : null,
        'ece': complete ? score.ece : null,
        'label_source': 'original upstream gold',
        'latency_success_p50_ms': percentile(0.5),
        'latency_success_p95_ms': percentile(0.95),
        'error': failure,
      },
    });
    if (status != BenchmarkRunStatus.running) _terminalSnapshot = record;
    return record;
  }
}

class _QuestionEvaluation extends _Evaluation {
  _QuestionEvaluation({
    required this.suite,
    required super.model,
    required super.channel,
    required super.declaredSource,
    required super.timeout,
    required super.started,
    required super.id,
  }) : accumulator = suite.createAccumulator();
  final FrozenQuestionSuite suite;
  final FrozenQuestionAccumulator accumulator;
  final results = <Map<String, Object?>>[];
  final _latencies = <int>[];
  int _valid = 0, _clientTimeouts = 0, _serverTimeouts = 0;
  FrozenQuestionScore? _score;
  BenchmarkRunStatus? _scoreStatus;
  @override
  Iterable<Object> get tasks => suite.tasks;
  @override
  bool get validateBeforeSend => false;
  @override
  String requestDocument(Object task) =>
      (task as FrozenQuestionTask).requestDocument(model);

  @override
  void record(Object value, JevPlaygroundResult reply) {
    final task = value as FrozenQuestionTask;
    final sourceResult = accumulator.record(task, reply);
    final successful = reply.status == JevPlaygroundStatus.success;
    if (successful) {
      _valid++;
      _latencies.add(reply.elapsed.inMicroseconds);
    }
    if (reply.status == JevPlaygroundStatus.timedOut) _clientTimeouts++;
    final error = reply.output?['error'];
    if (reply.status == JevPlaygroundStatus.businessError &&
        error is Map &&
        error['code'] == 'timed_out') {
      _serverTimeouts++;
    }
    // Prepared input does not establish physical delivery. Only an ordinary
    // public reply is positive delivery evidence; transport cancellation is unknown.
    final dispatched = reply.rawResponse != null
        ? true
        : reply.request == null
        ? false
        : null;
    results.add(
      BenchmarkRun.questionItem(
        {
          'id': task.id,
          'metadata': task.metadata,
          'source_result': sourceResult,
          'status': reply.status.name,
          'elapsed_us': reply.elapsed.inMicroseconds,
          'request': task.request(model),
          'request_json':
              reply.requestBody ??
              (channel == JevPlaygroundMode.http
                  ? task.requestDocument(model)
                  : jsonEncode(task.request(model))),
          'original_request_json': task.requestDocument(model),
          'request_representation': channel == JevPlaygroundMode.http
              ? 'original-json'
              : 'mcp-object',
          'dispatched': dispatched,
          'result': reply.toJson(),
          'error': successful ? null : reply.message,
        },
        model: model,
        channel: channel.name,
        identity: selection?.identity ?? {'selection_status': 'not_acquired'},
      ),
    );
  }

  @override
  Future<void> prepareTerminalScore() async {
    if (status == BenchmarkRunStatus.running || _scoreStatus == status) return;
    _score = accumulator.snapshot(
      complete: status == BenchmarkRunStatus.completed,
    );
    _scoreStatus = status;
  }

  @override
  BenchmarkRun snapshot() {
    final terminal = _terminalSnapshot;
    if (status != BenchmarkRunStatus.running && terminal?.status == status) {
      return terminal!;
    }
    final finalScore = _scoreStatus == status ? _score : null;
    final latency = status == BenchmarkRunStatus.running
        ? const <int>[]
        : ([..._latencies]..sort());
    double? percentile(double q) {
      if (latency.isEmpty) return null;
      final position = (latency.length - 1) * q;
      final low = position.floor(), high = position.ceil();
      return (latency[low] +
              (latency[high] - latency[low]) * (position - low)) /
          1000;
    }

    final complete =
        status == BenchmarkRunStatus.completed &&
        results.length == suite.tasks.length &&
        finalScore?.summary['complete'] == true;
    final record = BenchmarkRun.questionSnapshot(
      header: {
        'schema_version': 3,
        'id': id,
        'created_at': started.toIso8601String(),
        'finished_at': status == BenchmarkRunStatus.running
            ? null
            : (finishedAt ??= DateTime.now().toUtc()).toIso8601String(),
        'status': status.name,
        'model': model,
        'source': source,
        'channel': channel.name,
        'timeout_us': timeout.inMicroseconds,
        'suite': suite.identity,
        'identity': selection?.identity ?? {'selection_status': 'not_acquired'},
        'groups': finalScore?.groups ?? const <Map<String, Object?>>[],
        'source_summary': finalScore?.summary ?? const {'complete': false},
        'summary': {
          'expected': suite.tasks.length,
          'attempted': results.length,
          'missing': suite.tasks.length - results.length,
          'complete': complete,
          'valid': _valid,
          'failures': results.length - _valid,
          'client_timeouts': _clientTimeouts,
          'server_timeouts': _serverTimeouts,
          'timeouts': _clientTimeouts + _serverTimeouts,
          'latency_success_p50_ms': percentile(.5),
          'latency_success_p95_ms': percentile(.95),
          'error': failure,
        },
      },
      items: results,
    );
    if (status != BenchmarkRunStatus.running) _terminalSnapshot = record;
    return record;
  }
}

class _GameEvaluation extends _Evaluation {
  _GameEvaluation({
    required this.work,
    required super.model,
    required super.channel,
    required super.declaredSource,
    required super.timeout,
    required super.started,
    required super.id,
  }) : suite = work.identity;
  final BenchmarkGameWork work;
  final Map<String, Object?> suite;
  final results = <Map<String, Object?>>[];
  Map<String, Object?>? _terminal;
  final _gameSuccessLatencies = <int>[];
  int _gameSuccesses = 0;
  int _clientTimeouts = 0,
      _serverTimeouts = 0,
      _publicCalls = 0,
      _successfulCalls = 0,
      _unknownCalls = 0;
  @override
  Iterable<Object> get tasks => const [];
  @override
  String requestDocument(Object task) => throw StateError('游戏请求由原调度器创建');
  @override
  void record(Object task, JevPlaygroundResult reply) =>
      throw StateError('游戏按原局提交记录');

  void recordGame(Map<String, Object?> game) {
    if (game['index'] != results.length + 1 || results.length >= 100) {
      throw const FormatException('原游戏局号必须唯一连续且固定100局');
    }
    for (final call in game['calls'] as List) {
      _countCall(call as Map);
    }
    results.add(
      BenchmarkRun.gameItem(
        {...game, 'id': 'game-${game['index']}'},
        model: model,
        channel: channel.name,
        identity: selection?.identity ?? {'selection_status': 'not_acquired'},
      ),
    );
    _terminalSnapshot = null;
  }

  void finish(Map<String, Object?> terminal) {
    final games = terminal['games'];
    if (terminal['expectedGames'] != 100 ||
        games is! List ||
        games.length != results.length ||
        terminal['model'] != model ||
        terminal['channel'] != channel.name) {
      throw const FormatException('原游戏终态与逐局已提交日志不一致');
    }
    for (final call in terminal['calls'] as List) {
      if ((call as Map)['phase'] == 'warmup') _countCall(call);
    }
    _terminal = terminal;
    _terminalSnapshot = null;
  }

  void _countCall(Map call) {
    _publicCalls++;
    final result = call['result'];
    final status = result is Map ? result['status'] : call['status'];
    if (status == JevPlaygroundStatus.success.name) _successfulCalls++;
    if (call['phase'] == 'game' &&
        result is Map &&
        result['status'] == JevPlaygroundStatus.success.name) {
      _gameSuccesses++;
      final elapsed = call['elapsed_us'];
      if (elapsed is int && elapsed >= 0) {
        _gameSuccessLatencies.add(elapsed);
      }
    }
    if (status == JevPlaygroundStatus.timedOut.name) _clientTimeouts++;
    if (result is Map && status == JevPlaygroundStatus.businessError.name) {
      final output = result['output'];
      if (output is Map &&
          output['error'] is Map &&
          (output['error'] as Map)['code'] == 'timed_out') {
        _serverTimeouts++;
      }
    }
    if (status == null && call['error'] == null) _unknownCalls++;
  }

  @override
  BenchmarkRun snapshot() {
    final cached = _terminalSnapshot;
    if (status != BenchmarkRunStatus.running && cached?.status == status) {
      return cached!;
    }
    final completed = results.where((game) => game['complete'] == true).length;
    final complete =
        status == BenchmarkRunStatus.completed &&
        completed == 100 &&
        results.length == 100 &&
        _terminal?['complete'] == true;
    final terminal = _terminal;
    final calls = terminal?['calls'] as List? ?? const [];
    final warmup = [
      for (final value in calls)
        if ((value as Map)['phase'] == 'warmup') value,
    ];
    final sourceSummary = <String, Object?>{
      if (terminal != null)
        for (final entry in terminal.entries)
          if (!const {
            'games',
            'calls',
            'summary',
            'originalSummary',
            'complete',
          }.contains(entry.key))
            entry.key: entry.value,
      'complete': complete,
      'summary': complete ? (terminal?['summary']) : null,
      'originalSummary': complete ? (terminal?['originalSummary']) : null,
    };
    final latency = status == BenchmarkRunStatus.running
        ? const <int>[]
        : (_gameSuccessLatencies.toList()..sort());
    double? percentile(double q) {
      if (latency.isEmpty) return null;
      final position = (latency.length - 1) * q;
      final low = position.floor(), high = position.ceil();
      return (latency[low] +
              (latency[high] - latency[low]) * (position - low)) /
          1000;
    }

    final record = BenchmarkRun.gameSnapshot(
      header: {
        'schema_version': 5,
        'id': id,
        'created_at': started.toIso8601String(),
        'finished_at': status == BenchmarkRunStatus.running
            ? null
            : (finishedAt ??= DateTime.now().toUtc()).toIso8601String(),
        'status': status.name,
        'model': model,
        'source': source,
        'channel': channel.name,
        'timeout_us': 2000000,
        'suite': suite,
        'identity': selection?.identity ?? {'selection_status': 'not_acquired'},
        'source_summary': sourceSummary,
        'warmup_calls': warmup,
        'client_summary': {
          'calls': _publicCalls,
          'successes': _successfulCalls,
          'unknown_outcome': _unknownCalls,
          'client_timeouts': _clientTimeouts,
          'server_timeouts': _serverTimeouts,
          'game_successes': _gameSuccesses,
          'latency_success_samples': _gameSuccessLatencies.length,
          'latency_success_coverage': _gameSuccesses == 0
              ? null
              : _gameSuccessLatencies.length / _gameSuccesses,
          'latency_success_scope': 'formal_game_successful_public_calls',
          'latency_time_source': 'outer_elapsed_us_discovery_and_request',
        },
        'groups': const <Map<String, Object?>>[],
        'summary': {
          'expected': 100,
          'attempted': results.length,
          'missing': 100 - results.length,
          'complete': complete,
          'valid': completed,
          'failures': results.length - completed,
          'client_timeouts': _clientTimeouts,
          'server_timeouts': _serverTimeouts,
          'timeouts': _clientTimeouts + _serverTimeouts,
          'latency_success_p50_ms': percentile(.5),
          'latency_success_p95_ms': percentile(.95),
          'error': failure,
        },
      },
      items: results,
    );
    if (status != BenchmarkRunStatus.running) _terminalSnapshot = record;
    return record;
  }
}
