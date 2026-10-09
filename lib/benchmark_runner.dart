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
  }) async {
    if (_closed) throw StateError('评测执行器已关闭');
    return client.modelsFromDiscovery(
      await client.discover(JevPlaygroundMode.http, cancellation: cancellation),
    );
  }

  Future<BenchmarkRun> run({
    required DecideBenchSuite suite,
    required String model,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_closed) throw StateError('评测执行器已关闭');
    final previousFailure = _terminalFailure;
    if (previousFailure != null) {
      Error.throwWithStackTrace(previousFailure.error, previousFailure.stack);
    }
    if (_operation != null) throw StateError('已有评测批次在运行');
    if (suite.items.length != 400 || timeout <= Duration.zero) {
      throw const FormatException('需要完整400题及正客户端期限');
    }
    _requestedStatus = null;
    final cancellation = DecisionCancellation();
    _batchCancellation = cancellation;
    final operation = _execute(suite, model, timeout, cancellation);
    _operation = operation;
    return operation.whenComplete(() {
      _operation = null;
      _batchCancellation = null;
    });
  }

  Future<BenchmarkRun> _execute(
    DecideBenchSuite suite,
    String model,
    Duration timeout,
    DecisionCancellation cancellation,
  ) async {
    final available = await targets(cancellation: cancellation);
    final target = available.where((entry) => entry.id == model).firstOrNull;
    if (target == null) throw StateError('对象未在公开 HTTP 入口中可调用');
    final selection = await models.lockForEvaluation(model);
    final started = DateTime.now().toUtc();
    final id = 'run-${started.microsecondsSinceEpoch}';
    final results = <Map<String, Object?>>[];
    final predictions = <String, String?>{};
    final probabilities = <String, Map<String, double>>{};
    final byPair = <String, List<DecideBenchItem>>{};
    for (final item in suite.items) {
      byPair.putIfAbsent(item.pairId, () => []).add(item);
    }
    var status = BenchmarkRunStatus.running;
    String? failure;

    BenchmarkRun snapshot() {
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
            result['http_status'] == 504 &&
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

      return BenchmarkRun.fromJson({
        'schema_version': 1,
        'id': id,
        'created_at': started.toIso8601String(),
        'finished_at': status == BenchmarkRunStatus.running
            ? null
            : DateTime.now().toUtc().toIso8601String(),
        'status': status.name,
        'model': model,
        'source': target.source,
        'channel': 'http',
        'timeout_us': timeout.inMicroseconds,
        'suite': suite.identity,
        'identity': selection.identity,
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
    }

    Future<void> persist() async {
      var record = snapshot();
      await store.save(record);
      // Cancellation can arrive while the final snapshot is being flushed.
      // Seal that accepted intent before publishing any terminal score.
      while (_requestedStatus != null && record.status != _requestedStatus) {
        status = _requestedStatus!;
        record = snapshot();
        await store.save(record);
      }
      current = record;
      _changes.add(record);
    }

    try {
      await persist();
      for (final item in suite.items) {
        if (_requestedStatus != null) {
          status = _requestedStatus!;
          break;
        }
        if (!selection.isCurrent) {
          status = BenchmarkRunStatus.targetUnavailable;
          failure = '参赛对象已不可用或运行身份已变化';
          break;
        }
        try {
          final publiclyCallable = await targets(cancellation: cancellation);
          if (!publiclyCallable.any(
            (entry) => entry.id == model && entry.source == target.source,
          )) {
            throw StateError('参赛对象已不在公开 HTTP 发现中');
          }
        } catch (error) {
          status = _requestedStatus ?? BenchmarkRunStatus.targetUnavailable;
          failure = _requestedStatus == null ? '公开 HTTP 对象不可用：$error' : null;
          break;
        }
        if (_requestedStatus != null) {
          status = _requestedStatus!;
          break;
        }
        final request = item.request(model);
        final reply = await client.run(
          JevPlaygroundMode.http,
          jsonEncode(request),
          timeout: timeout,
          cancellation: cancellation,
        );
        Object? output = reply.output;
        if (output == null && reply.rawResponse != null) {
          try {
            output = jsonDecode(reply.rawResponse!);
          } on FormatException {
            output = null;
          }
        }
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
        if (_requestedStatus != null) status = _requestedStatus!;
        await persist();
        if (status != BenchmarkRunStatus.running) break;
      }
      if (_requestedStatus != null) status = _requestedStatus!;
      if (status == BenchmarkRunStatus.running) {
        status = BenchmarkRunStatus.completed;
      }
      await persist();
      return current!;
    } catch (error, stack) {
      status = BenchmarkRunStatus.failed;
      failure = '执行或保存评测记录失败：$error';
      _terminalFailure ??= (error: error, stack: stack);
      current = snapshot();
      _changes.add(current!);
      Error.throwWithStackTrace(error, stack);
    } finally {
      selection.release();
    }
  }

  void cancel() {
    if (_operation == null) return;
    _requestedStatus ??= BenchmarkRunStatus.cancelled;
    _batchCancellation?.cancel();
  }

  void _requestInterruption() {
    if (_operation != null &&
        (current == null || current!.status == BenchmarkRunStatus.running)) {
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
