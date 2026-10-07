import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/llama_engine.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('typed deadlines and cancellation seal late seats without killing or contaminating the next round', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    final lateId = council.selectedSeats.last.instance.id;
    final arrival = Completer<void>();
    final release = Completer<void>();
    final lateReturned = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var count = 0;
    runtime.io.respond = (request, raw) async {
      if (++count == 2) arrival.complete();
      if (request['model'] == lateId) {
        await release.future;
        lateReturned.complete();
      }
      return raw;
    };
    final request = DecisionBatchRequest(
      state: 'typed deadline',
      questions: {
        'rank': ScoreQuestion(instructions: 'Rank', levels: ['Low', 'High']),
        'valid': NoulQuestion(
          instructions: 'Valid',
          falseText: 'False',
          trueText: 'True',
        ),
      },
    );
    final pending = council.consultBatch(
      request,
      timeout: const Duration(milliseconds: 250),
    );
    await arrival.future.timeout(const Duration(seconds: 2));
    final timed = await pending;
    expect(timed.scope, CouncilScope.singleModel);
    expect(timed.aggregates, isEmpty);
    expect(timed.seats.map((seat) => seat.status), [
      CouncilSeatStatus.ok,
      CouncilSeatStatus.timedOut,
    ]);
    final sealed = jsonEncode(timed.toJson());
    release.complete();
    await lateReturned.future.timeout(const Duration(seconds: 2));
    runtime.io.respond = null;
    runtime.io.holdConsultation();
    final token = DecisionCancellation();
    final cancelled = council.consultBatch(request, cancellation: token);
    await runtime.io.bothArrived!.future.timeout(const Duration(seconds: 2));
    token.cancel();
    final none = await cancelled;
    expect(none.scope, CouncilScope.none);
    expect(
      none.seats.every((seat) => seat.status == CouncilSeatStatus.cancelled),
      isTrue,
    );
    runtime.io.release!.complete();
    final recovered = await council.consultBatch(request);
    expect(recovered.scope, CouncilScope.ensemble);
    expect(council.state.lastBatchResult, same(recovered));
    expect(jsonEncode(timed.toJson()), sealed);
    expect(runtime.io.killedChildren, 0);
  });

  test('mixed typed council independently aggregates ordinal and scalar answers with coverage', () async {
    final runtime = await CouncilRuntime.create(modelCount: 3);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((s) => s.id));
    final ids = council.selectedSeats.map((s) => s.instance.id).toList();
    final request = DecisionBatchRequest(
      state: 'same context',
      questions: {
        'rank': ScoreQuestion(instructions: 'Rank', levels: ['Low', 'High']),
        'valid': NoulQuestion(
          instructions: 'Valid',
          falseText: 'False',
          trueText: 'True',
        ),
      },
    );
    var successful = 3;
    runtime.io.respond = (req, raw) async {
      final body = jsonDecode(raw) as Map;
      final index = ids.indexOf(req['model'] as String);
      if (index == 1) {
        body['answers']['rank']['probabilities'] = {'0': 0.75, '1': 0.25};
        body['answers']['rank']['score'] = 0.25;
        body['answers']['valid'] = {'type': 'noul', 'noul': 0.2};
      }
      if (index >= successful) body['answers'].remove('valid');
      return jsonEncode(body);
    };
    final all = await council.consultBatch(request);
    expect(all.status, CouncilStatus.ok);
    expect(all.scope, CouncilScope.ensemble);
    successful = 2;
    final partial = await council.consultBatch(request);
    expect(partial.status, CouncilStatus.partial);
    expect(partial.scope, CouncilScope.ensemble);
    expect(partial.aggregates['rank'], {
      'type': 'score',
      'legend': {'0': 'Low', '1': 'High'},
      'probabilities': {'0': 0.5, '1': 0.5},
      'score': 0.5,
      'confidence': 0.0,
      'ordinal_spread': 0.5,
    });
    expect(partial.aggregates['valid'], {
      'type': 'noul',
      'noul': 0.5,
      'scalar_spread': closeTo(0.6, 1e-12),
    });
    expect(partial.seats.last.status, CouncilSeatStatus.invalidResponse);
    expect(partial.toJson()['request'], request.toSystemone());
    successful = 1;
    final single = await council.consultBatch(request);
    expect(single.scope, CouncilScope.singleModel);
    expect(single.aggregates, isEmpty);
    expect(single.seats.first.batchResult!.answers['valid']!.toJson(), {
      'type': 'noul',
      'noul': 0.8,
    });
    successful = 0;
    final none = await council.consultBatch(request);
    expect(none.status, CouncilStatus.failed);
    expect(none.scope, CouncilScope.none);
    expect(none.aggregates, isEmpty);
    expect(runtime.io.killedChildren, 0);
  });

  test(
    'a failed third seat preserves the two valid opinions and their aggregate',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 3);
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      council.selectSeats(council.availableSeats.map((seat) => seat.id));
      final failing = council.availableSeats.singleWhere(
        (seat) => seat.instance.asset.files.first.path.contains('/Third/'),
      );
      runtime.io.respond = (request, response) async {
        if (request['model'] != failing.instance.id) return response;
        final body = jsonDecode(response) as Map;
        body['answers']['council_choice']['probabilities'] = {
          'accept': 999,
          'reject': 0,
        };
        return jsonEncode(body);
      };
      final result = await council.consult(
        state: 'two-valid',
        options: {'accept': '接受', 'reject': '拒绝'},
      );
      expect(result.status, CouncilStatus.partial);
      expect(result.scope, CouncilScope.ensemble);
      expect(result.seats, hasLength(3));
      expect(result.aggregateScores, {'accept': 0.5, 'reject': 0.5});
      expect(result.topChoices, ['accept', 'reject']);
      expect(result.votes, {'accept': 1, 'reject': 1});
      expect(result.disagreement, 0.5);
      expect(
        result.seats
            .singleWhere((opinion) => opinion.seat.id == failing.id)
            .status,
        CouncilSeatStatus.invalidResponse,
      );
      expect(runtime.io.killedChildren, 0);
    },
  );

  test('HTTP and connection failures are explicit without terminating a resident instance', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    runtime.io.consultationStatus = 503;
    final unavailable = await council.consult(
      state: 'HTTP unavailable',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    expect(unavailable.status, CouncilStatus.failed);
    expect(unavailable.scope, CouncilScope.none);
    expect(
      unavailable.seats.every((seat) => seat.error!.contains('HTTP 503')),
      isTrue,
    );
    expect(
      unavailable.seats.every((seat) => seat.toJson()['raw_response'] != null),
      isTrue,
    );
    expect(runtime.io.killedChildren, 0);
    runtime.io.consultationStatus = 200;
    final recovered = await council.consult(
      state: 'HTTP recovered',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    expect(recovered.scope, CouncilScope.ensemble);
    final disconnected = council.availableSeats.first;
    await runtime.io.closeEndpoint(disconnected.instance.id);
    final partial = await council.consult(
      state: 'connection lost',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    expect(partial.status, CouncilStatus.partial);
    expect(partial.scope, CouncilScope.singleModel);
    expect(
      partial.seats
          .singleWhere((seat) => seat.seat.id == disconnected.id)
          .status,
      CouncilSeatStatus.failed,
    );
    expect(partial.aggregateScores, isNull);
    expect(runtime.io.killedChildren, 0);
  });
  test('the default round budget expires after ten seconds with no fabricated opinion', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    runtime.io.holdConsultation();
    final pending = council.consult(
      state: 'default deadline',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    await runtime.io.bothArrived!.future.timeout(const Duration(seconds: 2));
    final result = await pending.timeout(const Duration(seconds: 12));
    runtime.io.release!.complete();
    expect(
      result.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 9900)),
    );
    expect(result.elapsed, lessThan(const Duration(seconds: 11)));
    expect(result.status, CouncilStatus.failed);
    expect(result.scope, CouncilScope.none);
    expect(result.seats.map((opinion) => opinion.status), [
      CouncilSeatStatus.timedOut,
      CouncilSeatStatus.timedOut,
    ]);
    expect(result.aggregateScores, isNull);
    expect(result.topChoices, isNull);
    expect(result.votes, isNull);
    expect(result.disagreement, isNull);
    expect(runtime.io.killedChildren, 0);
  });
  test('invalid external opinions remain raw failures and never enter the valid peer result', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    var mode = 0;
    String? badRaw;
    var failBoth = false;
    runtime.io.respond = (request, response) async {
      final value = jsonDecode(response) as Map;
      final answer = value['answers']['council_choice'] as Map;
      if (answer['choice'] != 'accept' && !failBoth) return response;
      switch (mode) {
        case 0:
          answer['probabilities'] = {'accept': 1.0};
        case 1:
          answer['probabilities'] = {'unrequested': 0.75, 'reject': 0.25};
        case 2:
          answer['probabilities'] = {'accept': -0.1, 'reject': 1.1};
        case 3:
          answer['probabilities'] = {'accept': 0.3, 'reject': 0.3};
        case 4:
          answer['probabilities'] = {'accept': '0.75', 'reject': 0.25};
        case 5:
          answer['type'] = 'score';
        case 6:
          answer.remove('probabilities');
          answer['confidence'] = 0.9;
        case 7:
          answer['choice'] = 'unrequested';
        case 8:
          value['model'] = 'different-instance';
        case 9:
          value['usage']['output_tokens'] = 1;
      }
      badRaw = mode == 10 ? '{broken json' : jsonEncode(value);
      return badRaw!;
    };
    for (mode = 0; mode <= 10; mode++) {
      final result = await council.consult(
        state: 'invalid-$mode',
        options: {'accept': '接受', 'reject': '拒绝'},
      );
      expect(result.status, CouncilStatus.partial, reason: 'invalid-$mode');
      expect(result.scope, CouncilScope.singleModel);
      expect(result.aggregateScores, isNull);
      expect(result.votes, isNull);
      final invalid = result.seats.singleWhere(
        (opinion) => opinion.result == null,
      );
      expect(invalid.status, CouncilSeatStatus.invalidResponse);
      expect(invalid.toJson()['raw_response'], badRaw);
      expect(invalid.toJson()['probabilities'], isNull);
      expect(runtime.io.killedChildren, 0);
    }
    mode = 10;
    failBoth = true;
    final none = await council.consult(
      state: 'all-invalid',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    expect(none.status, CouncilStatus.failed);
    expect(none.scope, CouncilScope.none);
    expect(none.seats, hasLength(2));
    expect(
      none.seats.every(
        (seat) => seat.status == CouncilSeatStatus.invalidResponse,
      ),
      isTrue,
    );
    expect(none.aggregateScores, isNull);
    expect(none.topChoices, isNull);
    expect(none.disagreement, isNull);
    runtime.io.respond = null;
    final next = await council.consult(
      state: 'valid-again',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    expect(next.scope, CouncilScope.ensemble);
    expect(next.status, CouncilStatus.ok);
  });
  test('cancelling one concurrent consultation cannot cancel its peer or stop resident instances', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    final pids = runtime.engine.state.instances
        .map((instance) => instance.pid)
        .toList();
    final cancel = DecisionCancellation();
    final arrivedA = Completer<void>(), arrivedB = Completer<void>();
    final releaseA = Completer<void>(), releaseB = Completer<void>();
    final late = Completer<void>();
    var a = 0, b = 0, lateCount = 0;
    runtime.io.respond = (request, response) async {
      if (request['state'] == 'cancel') {
        if (++a == 2) arrivedA.complete();
        await releaseA.future;
        if (++lateCount == 2) late.complete();
      } else {
        if (++b == 2) arrivedB.complete();
        await releaseB.future;
      }
      return response;
    };
    final first = council.consult(
      state: 'cancel',
      options: {'accept': '接受', 'reject': '拒绝'},
      cancellation: cancel,
    );
    final peer = council.consult(
      state: 'peer',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    await Future.wait([arrivedA.future, arrivedB.future])
        .timeout(const Duration(seconds: 2));
    cancel.cancel();
    final cancelled = await first.timeout(const Duration(seconds: 2));
    expect(cancelled.status, CouncilStatus.failed);
    expect(cancelled.scope, CouncilScope.none);
    expect(
      (cancelled.toJson()['seats'] as List).map(
        (seat) => (seat as Map)['status'],
      ),
      ['cancelled', 'cancelled'],
    );
    expect(cancelled.aggregateScores, isNull);
    expect(council.state.busy, isTrue);
    final frozen = jsonEncode(cancelled.toJson());
    releaseB.complete();
    final successful = await peer.timeout(const Duration(seconds: 2));
    expect(successful.scope, CouncilScope.ensemble);
    expect(successful.status, CouncilStatus.ok);
    releaseA.complete();
    await late.future.timeout(const Duration(seconds: 2));
    expect(jsonEncode(cancelled.toJson()), frozen);
    expect(council.state.lastResult, same(successful));
    expect(council.state.busy, isFalse);
    expect(runtime.io.killedChildren, 0);
    expect(
      runtime.engine.state.instances.map((instance) => instance.pid),
      pids,
    );
    expect(
      runtime.engine.state.instances.every(
        (instance) => instance.status == LlamaInstanceStatus.ready,
      ),
      isTrue,
    );
  });
  test(
    'one round deadline returns the completed opinion and seals its late peer',
    () async {
      final runtime = await CouncilRuntime.create();
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      council.selectSeats(council.availableSeats.map((seat) => seat.id));
      final arrived = Completer<void>();
      final lateReturned = Completer<void>();
      final release = Completer<void>();
      runtime.io.respond = (request, response) async {
        if ((jsonDecode(response)
                    as Map)['answers']['council_choice']['choice'] ==
                'reject' &&
            request['state'] == 'held') {
          arrived.complete();
          await release.future;
          lateReturned.complete();
        }
        return response;
      };
      final pending = council.consult(
        state: 'held',
        options: {'accept': '接受', 'reject': '拒绝'},
        timeout: const Duration(milliseconds: 200),
      );
      await arrived.future.timeout(const Duration(seconds: 2));
      final result = await pending.timeout(const Duration(seconds: 2));
      expect(result.status, CouncilStatus.partial);
      expect(result.scope, CouncilScope.singleModel);
      expect(
        result.seats.where((opinion) => opinion.result != null),
        hasLength(1),
      );
      expect(
        (result.toJson()['seats'] as List).map(
          (seat) => (seat as Map)['status'],
        ),
        contains('timed_out'),
      );
      expect(result.aggregateScores, isNull);
      expect(runtime.io.killedChildren, 0);
      final frozen = jsonEncode(result.toJson());
      release.complete();
      await lateReturned.future.timeout(const Duration(seconds: 2));
      expect(jsonEncode(result.toJson()), frozen);
      expect(council.state.lastResult, same(result));
      final next = await council.consult(
        state: 'next',
        options: {'accept': '接受', 'reject': '拒绝'},
      );
      expect(next.scope, CouncilScope.ensemble);
      expect(next.status, CouncilStatus.ok);
      expect(runtime.io.killedChildren, 0);
    },
  );
  test(
    'a timed-out decision preserves its resident instance for the next request',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      addTearDown(runtime.close);
      final instance = runtime.engine.state.instances.single;
      final arrived = Completer<void>();
      final release = Completer<void>();
      runtime.io.respond = (request, response) async {
        if (request['state'] == 'held') {
          arrived.complete();
          await release.future;
        }
        return response;
      };
      final first = runtime.engine.decide(
        instance.id,
        DecisionRequest(
          state: 'held',
          instructions: '选择候选',
          options: {'accept': '接受', 'reject': '拒绝'},
        ),
        timeout: const Duration(milliseconds: 150),
      );
      final fails = expectLater(first, throwsA(isA<Exception>()));
      await arrived.future.timeout(const Duration(seconds: 2));
      await fails;
      release.complete();

      expect(runtime.io.killedChildren, 0);
      expect(
        runtime.engine.state.instances.single.status,
        LlamaInstanceStatus.ready,
      );
      expect(runtime.engine.state.instances.single.pid, instance.pid);
      final next = await runtime.engine.decide(
        instance.id,
        DecisionRequest(
          state: 'next',
          instructions: '选择候选',
          options: {'accept': '接受', 'reject': '拒绝'},
        ),
      );
      expect(next.choice, 'accept');
    },
  );
  test('one consultation concurrently reaches two ready instances and preserves their tied opinions', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    council.selectSeats(council.availableSeats.map((seat) => seat.id));
    runtime.io.holdConsultation();

    final pending = council.consult(
      state: '明确规则：允许时接受，否则拒绝。',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    // Neither server may respond until both requests have arrived.
    await runtime.io.bothArrived!.future.timeout(const Duration(seconds: 3));
    runtime.io.release!.complete();
    final result = await pending;

    expect(result.status, CouncilStatus.ok);
    expect(result.elapsed, lessThan(const Duration(seconds: 2)));
    expect(result.scope, CouncilScope.ensemble);
    expect(result.aggregateScores, {'accept': 0.5, 'reject': 0.5});
    expect(result.topChoices, ['accept', 'reject']);
    expect(result.votes, {'accept': 1, 'reject': 1});
    expect(result.disagreement, 0.5);
    expect(result.seats, hasLength(2));
    for (final opinion in result.seats) {
      expect(opinion.result!.model, opinion.seat.instance.id);
      expect(opinion.seat.instance.asset.fingerprintsVerified, isTrue);
      expect(opinion.seat.engine.version, contains('build 11381'));
      expect(opinion.dispatchedAt.isBefore(opinion.completedAt), isTrue);
      expect(opinion.elapsed, greaterThan(Duration.zero));
      final raw = jsonDecode(opinion.result!.rawResponse) as Map;
      expect(
        raw['answers']['council_choice']['choice'],
        opinion.result!.choice,
      );
    }
    expect(runtime.io.requests.map((request) => request['state']).toSet(), {
      '明确规则：允许时接受，否则拒绝。',
    });
  });

  test('candidate order and later configuration changes cannot alter an in-flight consultation', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final seats = council.availableSeats;
    council.selectSeats(seats.map((seat) => seat.id));
    final options = {'reject': '拒绝', 'accept': '接受'};
    runtime.io.holdConsultation();

    final pending = council.consult(state: '旧上下文', options: options);
    council.selectSeats([seats.first.id]);
    options.clear();
    await runtime.io.bothArrived!.future.timeout(const Duration(seconds: 3));
    runtime.io.release!.complete();
    final result = await pending;

    expect(
      result.seats.map((opinion) => opinion.seat.id),
      seats.map((seat) => seat.id),
    );
    expect(result.request.options, {'reject': '拒绝', 'accept': '接受'});
    expect(result.aggregateScores, {'reject': 0.5, 'accept': 0.5});
    expect(result.topChoices, ['reject', 'accept']);
    expect(result.toJson()['scope'], 'ensemble');
    expect(result.toJson()['schema_version'], 1);

    final single = await council.consult(
      state: '新上下文',
      options: {'accept': '接受', 'reject': '拒绝'},
    );
    expect(single.scope, CouncilScope.singleModel);
    expect(single.seats.single.seat.id, seats.first.id);
    expect(single.toJson()['scope'], 'single_model');
    expect(single.aggregateScores, isNull);
    expect(single.votes, isNull);
    expect(single.disagreement, isNull);
    expect(single.requestId, isNot(result.requestId));
  });

  test('a stopped selected instance is reported and cannot be replaced by a different running instance', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final seats = council.availableSeats;
    expect(
      () => council.selectSeats([seats.first.id, seats.first.id]),
      throwsA(isA<Exception>()),
    );
    council.selectSeats(seats.map((seat) => seat.id));
    await runtime.engine.stop(seats.first.instance.id);

    final result = await council.consult(
      state: '模型停止后的咨询',
      options: {'accept': '接受', 'reject': '拒绝'},
    );

    expect(result.status, CouncilStatus.partial);
    expect(result.scope, CouncilScope.singleModel);
    expect(
      result.seats.map((opinion) => opinion.seat.id),
      seats.map((seat) => seat.id),
    );
    expect(result.seats.first.result, isNull);
    expect(result.seats.first.error, contains('尚未就绪'));
    expect(result.seats.last.result!.model, seats.last.instance.id);
    expect(result.aggregateScores, isNull);
    expect(runtime.io.requests, hasLength(1));
    expect(council.availableSeats, hasLength(1));
    expect(council.selectedSeatIds, hasLength(2));
  });
}
