import 'dart:async';
import 'dart:math';

import 'decision_protocol.dart';
import 'engine_catalog.dart';
import 'engine_runtime.dart';
import 'llama_engine.dart';

export 'llama_engine.dart' show DecisionCancellation;

enum CouncilStatus { ok, partial, failed }

enum CouncilScope { ensemble, singleModel, none }

enum CouncilResultKind { choice, batch }

enum CouncilSeatStatus {
  ok,
  notReady,
  timedOut,
  cancelled,
  invalidResponse,
  failed,
}

String _seatStatusName(CouncilSeatStatus status) => switch (status) {
  CouncilSeatStatus.notReady => 'not_ready',
  CouncilSeatStatus.timedOut => 'timed_out',
  CouncilSeatStatus.invalidResponse => 'invalid_response',
  _ => status.name,
};

class CouncilSeat {
  const CouncilSeat({required this.engine, required this.instance});
  final EngineRegistration engine;
  final LlamaInstance instance;
  String get id => '${engine.id}/${instance.id}';
}

class CouncilOpinion {
  const CouncilOpinion({
    required this.seat,
    required this.status,
    required this.dispatchedAt,
    required this.completedAt,
    required this.dispatchedAfter,
    required this.completedAfter,
    this.result,
    this.batchResult,
    this.error,
    this.rawResponse,
  });
  final CouncilSeat seat;
  final CouncilSeatStatus status;
  final DateTime dispatchedAt;
  final DateTime completedAt;
  final Duration dispatchedAfter;
  final Duration completedAfter;
  final DecisionResult? result;
  final DecisionBatchResult? batchResult;
  final String? error;
  final String? rawResponse;
  Duration get elapsed => completedAfter - dispatchedAfter;

  Map<String, Object?> toJson({bool typed = false}) => {
    'seat_id': seat.id,
    'status': _seatStatusName(status),
    'engine': {
      'id': seat.engine.id,
      'name': seat.engine.name,
      'source': seat.engine.source.name,
      'version': seat.engine.version,
      'path': seat.engine.path,
      'sha256': seat.engine.sha256,
    },
    'instance': {
      'id': seat.instance.id,
      'endpoint': seat.instance.endpoint.toString(),
      'pid': seat.instance.pid,
      'ownership': 'managed',
    },
    'model': {
      'asset_id': seat.instance.asset.id,
      'name': seat.instance.asset.name,
      'architecture': seat.instance.asset.architecture,
      'repository': seat.instance.asset.repoId,
      'revision': seat.instance.asset.revision,
      'source_verified': seat.instance.asset.sourceVerified,
      'files': [
        for (final file in seat.instance.asset.files)
          {
            'path': file.path,
            'size_bytes': file.sizeBytes,
            'sha256': file.sha256,
          },
      ],
    },
    'dispatched_at': dispatchedAt.toIso8601String(),
    'completed_at': completedAt.toIso8601String(),
    'dispatched_after_us': dispatchedAfter.inMicroseconds,
    'completed_after_us': completedAfter.inMicroseconds,
    'elapsed_us': elapsed.inMicroseconds,
    if (!typed) 'choice': result?.choice,
    if (!typed) 'probabilities': result?.probabilities,
    if (typed)
      'answers': batchResult == null
          ? null
          : {
              for (final answer in batchResult!.answers.entries)
                answer.key: answer.value.toJson(),
            },
    'raw_response':
        batchResult?.rawResponse ?? result?.rawResponse ?? rawResponse,
    'error': error,
  };
}

class CouncilConsultation {
  CouncilConsultation._({
    required this.requestId,
    required this.status,
    required this.scope,
    required this.request,
    required this.startedAt,
    required this.completedAt,
    required this.elapsed,
    required List<CouncilOpinion> seats,
    Map<String, double>? aggregateScores,
    List<String>? topChoices,
    Map<String, int>? votes,
    this.disagreement,
  }) : seats = List.unmodifiable(seats),
       aggregateScores = aggregateScores == null
           ? null
           : Map.unmodifiable(aggregateScores),
       topChoices = topChoices == null ? null : List.unmodifiable(topChoices),
       votes = votes == null ? null : Map.unmodifiable(votes);
  final String requestId;
  final CouncilStatus status;
  final CouncilScope scope;
  final DecisionRequest request;
  final DateTime startedAt;
  final DateTime completedAt;
  final Duration elapsed;
  final List<CouncilOpinion> seats;
  final Map<String, double>? aggregateScores;
  final List<String>? topChoices;
  final Map<String, int>? votes;
  final double? disagreement;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'request_id': requestId,
    'status': status.name,
    'scope': scope == CouncilScope.singleModel ? 'single_model' : scope.name,
    'request': {
      'state': request.state,
      'instructions': request.instructions,
      'options': [
        for (final option in request.options.entries)
          {'id': option.key, 'text': option.value},
      ],
    },
    'started_at': startedAt.toIso8601String(),
    'completed_at': completedAt.toIso8601String(),
    'elapsed_us': elapsed.inMicroseconds,
    'seats': [for (final seat in seats) seat.toJson()],
    'aggregate_scores': aggregateScores,
    'top_choices': topChoices,
    'votes': votes,
    'disagreement': disagreement,
  };
}

/// A computed typed DTO, shared by text/structured callers without reaggregation.
class CouncilBatchConsultation {
  CouncilBatchConsultation._({
    required this.requestId,
    required this.status,
    required this.scope,
    required this.request,
    required this.startedAt,
    required this.completedAt,
    required this.elapsed,
    required List<CouncilOpinion> seats,
    required Map<String, Map<String, Object?>> aggregates,
  }) : seats = List.unmodifiable(seats),
       aggregates = Map.unmodifiable({
         for (final entry in aggregates.entries)
           entry.key: Map<String, Object?>.unmodifiable(entry.value),
       });
  final String requestId;
  final CouncilStatus status;
  final CouncilScope scope;
  final DecisionBatchRequest request;
  final DateTime startedAt;
  final DateTime completedAt;
  final Duration elapsed;
  final List<CouncilOpinion> seats;
  final Map<String, Map<String, Object?>> aggregates;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'request_id': requestId,
    'status': status.name,
    'scope': scope == CouncilScope.singleModel ? 'single_model' : scope.name,
    'request': request.toSystemone(),
    'started_at': startedAt.toIso8601String(),
    'completed_at': completedAt.toIso8601String(),
    'elapsed_us': elapsed.inMicroseconds,
    'seats': [for (final seat in seats) seat.toJson(typed: true)],
    'aggregates': aggregates,
  };
}

class CouncilState {
  const CouncilState({
    this.busy = false,
    this.lastResult,
    this.lastBatchResult,
    this.latestResultKind,
  });
  final CouncilResultKind? latestResultKind;
  final bool busy;
  final CouncilConsultation? lastResult;
  final CouncilBatchConsultation? lastBatchResult;
}

/// The desktop and MCP share this consultation entry point.
class CouncilController {
  CouncilController({required this.catalog}) {
    _subscription = catalog.changes.listen((_) => _publish());
  }
  final EngineCatalog catalog;
  final _changes = StreamController<CouncilState>.broadcast();
  late final StreamSubscription<EngineCatalogState> _subscription;
  List<CouncilSeat> _selected = const [];
  int _pending = 0;
  bool _shuttingDown = false;
  bool get isShuttingDown => _shuttingDown;
  final _active = <DecisionCancellation, Completer<void>>{};
  CouncilConsultation? _lastResult;
  CouncilBatchConsultation? _lastBatchResult;
  CouncilResultKind? _latestResultKind;
  Stream<CouncilState> get changes => _changes.stream;
  CouncilState get state => CouncilState(
    busy: _pending > 0,
    lastResult: _lastResult,
    lastBatchResult: _lastBatchResult,
    latestResultKind: _latestResultKind,
  );
  List<String> get selectedSeatIds =>
      List.unmodifiable(_selected.map((seat) => seat.id));
  List<CouncilSeat> get selectedSeats => _selected;
  List<CouncilSeat> get availableSeats => List.unmodifiable([
    for (final entry in catalog.state.entries)
      if (entry.family == EngineFamily.llamaCpp)
        for (final instance in catalog.providerFor(entry.id).state.instances)
          if (instance.status == LlamaInstanceStatus.ready &&
              instance.capabilities.contains(LlamaCapability.choiceProbability))
            CouncilSeat(engine: entry, instance: instance),
  ]);

  void selectSeats(Iterable<String> ids) {
    if (_shuttingDown) throw StateError('委员会正在退出');
    final chosen = ids.toList();
    if (chosen.toSet().length != chosen.length) {
      throw const DecisionProtocolException('同一实例不能重复占据席位');
    }
    final existing = {for (final seat in _selected) seat.id: seat};
    final available = {for (final seat in availableSeats) seat.id: seat};
    if (chosen.any(
      (id) => !available.containsKey(id) && !existing.containsKey(id),
    )) {
      throw const DecisionProtocolException('所选席位尚未就绪');
    }
    _selected = List.unmodifiable(
      chosen.map((id) => available[id] ?? existing[id]!),
    );
    _publish();
  }

  Future<CouncilConsultation> consult({
    required String state,
    required Map<String, String> options,
    String instructions = '根据上下文，从候选项中选择最合适的一项。',
    Duration timeout = const Duration(seconds: 10),
    DecisionCancellation? cancellation,
  }) async {
    if (_shuttingDown) throw StateError('委员会正在退出');
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', '截止预算必须大于零');
    }
    final request = DecisionRequest(
      state: state,
      instructions: instructions,
      options: options,
    );
    final available = {for (final seat in availableSeats) seat.id: seat};
    final selected = List<CouncilSeat>.unmodifiable(
      _selected.map((seat) => available[seat.id] ?? seat),
    );
    final requestId = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final startedAt = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    final token = DecisionCancellation();
    final drained = Completer<void>();
    _active[token] = drained;
    final removeCancellation = cancellation?.listen(token.cancel);
    _pending++;
    _publish();
    try {
      final opinions = await _round(selected, request, watch, timeout, token);
      final successful = opinions
          .where((opinion) => opinion.status == CouncilSeatStatus.ok)
          .toList();
      final ensemble = successful.length >= 2;
      final scores = ensemble
          ? <String, double>{
              for (final id in request.options.keys)
                id:
                    successful.fold(
                      0.0,
                      (sum, opinion) =>
                          sum + opinion.result!.probabilities[id]!,
                    ) /
                    successful.length,
            }
          : null;
      final votes = ensemble
          ? <String, int>{
              for (final id in request.options.keys)
                id: successful
                    .where((opinion) => opinion.result!.choice == id)
                    .length,
            }
          : null;
      final bestScore = scores?.values.reduce(max);
      final result = CouncilConsultation._(
        requestId: requestId,
        status: successful.isEmpty
            ? CouncilStatus.failed
            : successful.length == selected.length
            ? CouncilStatus.ok
            : CouncilStatus.partial,
        scope: ensemble
            ? CouncilScope.ensemble
            : successful.isEmpty
            ? CouncilScope.none
            : CouncilScope.singleModel,
        request: request,
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
        elapsed: watch.elapsed,
        seats: opinions,
        aggregateScores: scores,
        topChoices: scores == null
            ? null
            : [
                for (final entry in scores.entries)
                  if ((entry.value - bestScore!).abs() <= 1e-12) entry.key,
              ],
        votes: votes,
        disagreement: votes == null
            ? null
            : 1 - votes.values.reduce(max) / successful.length,
      );
      _lastResult = result;
      _latestResultKind = CouncilResultKind.choice;
      return result;
    } finally {
      removeCancellation?.call();
      _active.remove(token);
      drained.complete();
      _pending--;
      _publish();
    }
  }

  Future<CouncilBatchConsultation> consultBatch(
    DecisionBatchRequest request, {
    Duration timeout = const Duration(seconds: 10),
    DecisionCancellation? cancellation,
  }) async {
    if (_shuttingDown) throw StateError('委员会正在退出');
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', '截止预算必须大于零');
    }
    final available = {for (final seat in availableSeats) seat.id: seat};
    final selected = List<CouncilSeat>.unmodifiable(
      _selected.map((seat) => available[seat.id] ?? seat),
    );
    final requestId = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final startedAt = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    final token = DecisionCancellation();
    final drained = Completer<void>();
    _active[token] = drained;
    final removeCancellation = cancellation?.listen(token.cancel);
    _pending++;
    _publish();
    try {
      final opinions = await _round(
        selected,
        null,
        watch,
        timeout,
        token,
        batch: request,
      );
      final successful = opinions
          .where((s) => s.status == CouncilSeatStatus.ok)
          .toList();
      final result = CouncilBatchConsultation._(
        requestId: requestId,
        status: successful.isEmpty
            ? CouncilStatus.failed
            : successful.length == selected.length
            ? CouncilStatus.ok
            : CouncilStatus.partial,
        scope: successful.length >= 2
            ? CouncilScope.ensemble
            : successful.isEmpty
            ? CouncilScope.none
            : CouncilScope.singleModel,
        request: request,
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
        elapsed: watch.elapsed,
        seats: opinions,
        aggregates: {
          if (successful.length >= 2)
            for (final question in request.questions.entries)
              question.key: _aggregateQuestion(question.value, [
                for (final seat in successful)
                  seat.batchResult!.answers[question.key]!,
              ]),
        },
      );
      _lastBatchResult = result;
      _latestResultKind = CouncilResultKind.batch;
      return result;
    } finally {
      removeCancellation?.call();
      _active.remove(token);
      drained.complete();
      _pending--;
      _publish();
    }
  }

  Future<CouncilOpinion> _consultSeat(
    CouncilSeat seat,
    DecisionRequest? request,
    Stopwatch watch,
    Duration timeout,
    DecisionCancellation cancellation,
    _SeatDispatch dispatch, {
    DecisionBatchRequest? batch,
  }) async {
    DecisionResult? result;
    DecisionBatchResult? batchResult;
    String? error;
    String? rawResponse;
    var status = CouncilSeatStatus.ok;
    try {
      final engine = catalog.providerFor(seat.engine.id);
      if (batch != null) {
        batchResult = await engine.decideBatch(
          seat.instance.id,
          batch,
          timeout: timeout,
          cancellation: cancellation,
        );
      } else {
        result = await engine.decide(
          seat.instance.id,
          request!,
          timeout: timeout,
          cancellation: cancellation,
        );
      }
    } catch (failure) {
      error = failure.toString();
      status = failure is LlamaRequestException
          ? switch (failure.kind) {
              DecisionFailureKind.notReady => CouncilSeatStatus.notReady,
              DecisionFailureKind.timedOut => CouncilSeatStatus.timedOut,
              DecisionFailureKind.cancelled => CouncilSeatStatus.cancelled,
              DecisionFailureKind.invalidResponse =>
                CouncilSeatStatus.invalidResponse,
              DecisionFailureKind.failed => CouncilSeatStatus.failed,
            }
          : CouncilSeatStatus.failed;
      if (failure is LlamaRequestException) rawResponse = failure.rawResponse;
    }
    return CouncilOpinion(
      seat: seat,
      status: status,
      dispatchedAt: dispatch.at,
      completedAt: DateTime.now().toUtc(),
      dispatchedAfter: dispatch.after,
      completedAfter: watch.elapsed,
      result: result,
      batchResult: batchResult,
      error: error,
      rawResponse: rawResponse,
    );
  }

  Future<List<CouncilOpinion>> _round(
    List<CouncilSeat> selected,
    DecisionRequest? request,
    Stopwatch watch,
    Duration timeout,
    DecisionCancellation? external, {
    DecisionBatchRequest? batch,
  }) async {
    if (selected.isEmpty) return [];
    final token = DecisionCancellation();
    final done = Completer<void>();
    final received = List<CouncilOpinion?>.filled(selected.length, null);
    final dispatches = <_SeatDispatch>[];
    final workers = <Future<void>>[];
    CouncilSeatStatus? stopped;
    var sealed = false;
    void stop(CouncilSeatStatus reason) {
      if (sealed || done.isCompleted) return;
      stopped = reason;
      done.complete();
      token.cancel();
    }

    final timer = Timer(timeout, () => stop(CouncilSeatStatus.timedOut));
    final removeExternal = external?.listen(
      () => stop(CouncilSeatStatus.cancelled),
    );
    try {
      for (var index = 0; index < selected.length; index++) {
        final dispatch = _SeatDispatch(DateTime.now().toUtc(), watch.elapsed);
        dispatches.add(dispatch);
        if (stopped != null) continue;
        workers.add(
          _consultSeat(
            selected[index],
            request,
            watch,
            timeout - watch.elapsed,
            token,
            dispatch,
            batch: batch,
          ).then((opinion) {
            if (sealed || stopped != null) return;
            if (watch.elapsed >= timeout) {
              stop(CouncilSeatStatus.timedOut);
              return;
            }
            received[index] = opinion;
            if (received.every((value) => value != null)) done.complete();
          }),
        );
      }
      await done.future;
      sealed = true;
      final at = DateTime.now().toUtc();
      final after = watch.elapsed;
      return [
        for (var index = 0; index < selected.length; index++)
          received[index] ??
              CouncilOpinion(
                seat: selected[index],
                status: stopped!,
                dispatchedAt: dispatches[index].at,
                dispatchedAfter: dispatches[index].after,
                completedAt: at,
                completedAfter: after,
                error: stopped == CouncilSeatStatus.timedOut
                    ? '整轮咨询已截止'
                    : '本次咨询已取消',
              ),
      ];
    } finally {
      removeExternal?.call();
      sealed = true;
      timer.cancel();
      token.cancel();
      await Future.wait(workers);
    }
  }

  void beginShutdown() {
    _shuttingDown = true;
    for (final token in _active.keys.toList()) {
      token.cancel();
    }
  }

  Future<void> shutdown() async {
    beginShutdown();
    await Future.wait(_active.values.map((value) => value.future).toList());
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }

  void close() {
    _subscription.cancel();
    _changes.close();
  }
}

Map<String, Object?> _aggregateQuestion(
  DecisionQuestion question,
  List<DecisionAnswer> answers,
) {
  if (question is NoulQuestion) {
    final values = answers.cast<NoulAnswer>().map((a) => a.noul).toList();
    return {
      'type': 'noul',
      'noul': values.reduce((a, b) => a + b) / values.length,
      'scalar_spread': values.reduce(max) - values.reduce(min),
    };
  }
  final distributions = [
    for (final answer in answers)
      if (answer is ChoiceAnswer)
        answer.probabilities
      else
        (answer as ScoreAnswer).probabilities,
  ];
  final mean = Map<String, double>.unmodifiable({
    for (final id in distributions.first.keys)
      id: distributions.fold(0.0, (sum, p) => sum + p[id]!) / answers.length,
  });
  if (question is ScoreQuestion) {
    final values = answers.cast<ScoreAnswer>().map((a) => a.score).toList();
    return {
      'type': 'score',
      'legend': question.legend,
      'probabilities': mean,
      'score': ordinalExpectation(mean),
      'ordinal_spread': values.reduce(max) - values.reduce(min),
    };
  }
  final choices = answers.cast<ChoiceAnswer>();
  final votes = Map<String, int>.unmodifiable({
    for (final id in mean.keys) id: choices.where((a) => a.choice == id).length,
  });
  final best = mean.values.reduce(max);
  return {
    'type': 'choice',
    'probabilities': mean,
    'top_choices': List<String>.unmodifiable([
      for (final entry in mean.entries)
        if ((entry.value - best).abs() <= 1e-12) entry.key,
    ]),
    'votes': votes,
    'disagreement': 1 - votes.values.reduce(max) / answers.length,
  };
}

class _SeatDispatch {
  const _SeatDispatch(this.at, this.after);
  final DateTime at;
  final Duration after;
}
