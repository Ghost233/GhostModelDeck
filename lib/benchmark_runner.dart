import 'dart:async';
import 'dart:convert';

import 'benchmark_run_store.dart';
import 'decidebench.dart';
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
    if (suite.items.length != 400 ||
        timeout <= Duration.zero ||
        names.isEmpty ||
        names.any((name) => name.isEmpty) ||
        names.toSet().length != names.length ||
        modelNames != null && model != null ||
        modes.isEmpty ||
        modes.toSet().length != modes.length) {
      throw const FormatException('需要完整400题、唯一参赛对象/通道及正客户端期限');
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
    DecideBenchSuite suite,
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
            _Evaluation(
              suite: suite,
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
      Future<void> persist() async {
        applyCancellation();
        var record = snapshot();
        try {
          await store.save(record);
        } catch (error, stack) {
          _terminalFailure ??= (error: error, stack: stack);
          rethrow;
        }
        while (_requestedStatus != null && record.status != _requestedStatus) {
          applyCancellation();
          record = snapshot();
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
          for (final item in suite.items) {
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
                jsonEncode(item.request(evaluation.model)),
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

class _Evaluation {
  _Evaluation({
    required this.suite,
    required this.model,
    required this.channel,
    required this.declaredSource,
    required this.timeout,
    required this.started,
    required this.id,
  }) {
    for (final item in suite.items) {
      byPair.putIfAbsent(item.pairId, () => []).add(item);
    }
  }
  final DecideBenchSuite suite;
  final String model;
  final JevPlaygroundMode channel;
  final String declaredSource;
  JevEvaluationLock? selection;
  String get source =>
      selection?.identity['source'] as String? ?? declaredSource;
  final Duration timeout;
  final DateTime started;
  final String id;
  final results = <Map<String, Object?>>[];
  final predictions = <String, String?>{};
  final probabilities = <String, Map<String, double>>{};
  final byPair = <String, List<DecideBenchItem>>{};
  BenchmarkRunStatus status = BenchmarkRunStatus.running;
  String? failure;
  DateTime? finishedAt;
  BenchmarkRun? _terminalSnapshot;

  void record(DecideBenchItem item, JevPlaygroundResult reply) {
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
