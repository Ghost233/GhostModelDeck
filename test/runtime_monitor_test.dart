import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/runtime_monitor.dart';
import 'package:ghost_model_deck/runtime_monitor_controller.dart';

void main() {
  test('Splash keeps engine totals separate from active request progress and rejects stale status', () {
    final status = splashStatus();
    final data = RuntimeTelemetry.splash(status);
    expect(data.running, 2);
    expect(data.queued, 1);
    expect(data.capacity, 4);
    expect(data.prefilling, 1);
    expect(data.decoding, 1);
    expect(data.requests.map((r) => r.phase), [
      RequestPhase.prefill,
      RequestPhase.decode,
      RequestPhase.queued,
    ]);
    expect(data.requests.first.processedTokens, 32);
    expect(data.promptTokens, 1200);
    expect(data.generatedTokens, 600);
    expect(data.prefillPerSecond, 200);
    expect(data.decodePerSecond, 50);
    status['transport'] = {'status_stale': true};
    expect(() => RuntimeTelemetry.splash(status), throwsFormatException);
  });
  test('llama exposes independent slot phases and metrics without inventing missing queue data', () {
    final slots = [
      {
        'id': 0,
        'is_processing': true,
        'n_prompt_tokens': 100,
        'n_prompt_tokens_processed': 40,
        'next_token': [
          {'n_decoded': 0},
        ],
      },
      {
        'id': 1,
        'is_processing': true,
        'next_token': [
          {'n_decoded': 6},
        ],
      },
      {
        'id': 2,
        'is_processing': false,
        'next_token': [
          {'n_decoded': 99},
        ],
      },
    ];
    final partial = RuntimeTelemetry.llama(slots: slots);
    expect(partial.capacity, 3);
    expect(partial.running, 2);
    expect(partial.requests.map((r) => r.phase), [
      RequestPhase.prefill,
      RequestPhase.decode,
    ]);
    expect(partial.queued, isNull);
    expect(partial.generatedTokens, isNull);
    expect(partial.notice, contains('--metrics'));
    final complete = RuntimeTelemetry.llama(
      slots: slots,
      metrics: 'llamacpp:requests_deferred 2\nllamacpp:prompt_tokens_total 1200\nllamacpp:tokens_predicted_total 600\nllamacpp:prompt_tokens_seconds 200\nllamacpp:predicted_tokens_seconds 50\n',
    );
    expect(complete.queued, 2);
    expect(complete.generatedTokens, 600);
    expect(complete.decodePerSecond, 50);
    expect(() => RuntimeTelemetry.llama(), throwsFormatException);
  });
  test('oMLX filters the selected model and handles waiting, prefill and decode rows', () {
    final data = RuntimeTelemetry.omlx({
      'total_requests': 3,
      'total_prompt_tokens': 1200,
      'total_completion_tokens': 600,
      'avg_prefill_tps': 200,
      'avg_generation_tps': 50,
      'active_models': {
        'models': [
          {'id': 'other', 'active_requests': 99},
          {
            'id': 'selected',
            'active_requests': 2,
            'waiting_requests': 1,
            'waiting': [
              {'request_id': 'a', 'prompt_tokens': 100},
            ],
            'prefilling': [
              {'request_id': 'b', 'total': 100, 'processed': 32, 'speed': 200},
            ],
            'generating': [
              {
                'request_id': 'c',
                'prompt_tokens': 100,
                'generated_tokens': 6,
                'max_tokens': 100,
                'tokens_per_second': 50,
              },
            ],
          },
        ],
      },
    }, 'selected');
    expect(data.capacity, isNull);
    expect(data.running, 2);
    expect(data.queued, 1);
    expect(data.requests.map((r) => r.id), ['a', 'b', 'c']);
    expect(data.requests.last.generatedTokens, 6);
    expect(data.totalRequests, 3);
  });
  test(
    'HTTP monitoring cancels a pending response and enforces the body limit',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final entered = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/hold') {
          entered.complete();
          await release.future;
        }
        try {
          request.response.write(
            request.uri.path == '/large'
                ? List.filled(2 * 1024 * 1024 + 1, 'x').join()
                : jsonEncode(splashStatus()),
          );
          await request.response.close();
        } on IOException {
          /* The cancelled client owns its close. */
        }
      });
      final cancellation = DecisionCancellation();
      final pending = readMonitorHttp(
        Uri.parse('http://127.0.0.1:${server.port}/hold'),
        cancellation: cancellation,
      );
      final rejected = expectLater(pending, throwsA(anything));
      await entered.future;
      cancellation.cancel();
      await rejected;
      release.complete();
      await expectLater(
        readMonitorHttp(
          Uri.parse('http://127.0.0.1:${server.port}/large'),
          cancellation: DecisionCancellation(),
        ),
        throwsFormatException,
      );
    },
  );
  test('one page polls at most 20 instances, histories are bounded and inactive pages do not poll', () async {
    final source = TestMonitorSource();
    final controller = RuntimeMonitorController(
      targets: () => [for (var i = 0; i < 25; i++) target('$i', source)],
      interval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    controller.setActive(true);
    await Future<void>.delayed(Duration.zero);
    expect(source.calls, 20);
    expect(source.maxActive, lessThanOrEqualTo(4));
    expect(controller.readings.length, 20);
    controller.setPage(1);
    await Future<void>.delayed(Duration.zero);
    expect(controller.readings.length, 5);
    expect(source.calls, 25);
    for (var i = 0; i < 125; i++) {
      await controller.refresh();
    }
    expect(
      controller.readings.first.history.length,
      RuntimeMonitorController.historyLimit,
    );
    controller.setActive(false);
    final calls = source.calls;
    await controller.refresh();
    expect(source.calls, calls);
  });
  test('late results from a replaced generation or hidden page are never published', () async {
    final source = TestMonitorSource()..gate = Completer<RuntimeTelemetry>();
    var generation = 1;
    final controller = RuntimeMonitorController(
      targets: () => [target('a', source, generation: generation)],
      interval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    controller.setActive(true);
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    source.gate!.complete(RuntimeTelemetry(decodePerSecond: 999));
    await Future<void>.delayed(Duration.zero);
    expect(controller.readings.first.telemetry, isNull);
    source.gate = null;
    await controller.refresh();
    expect(controller.readings.first.target.run!.generation, 2);
    expect(controller.readings.first.history.length, 1);
    source.gate = Completer<RuntimeTelemetry>();
    final pending = controller.refresh();
    controller.setActive(false);
    source.gate!.complete(RuntimeTelemetry(decodePerSecond: 888));
    await pending;
    expect(controller.readings.first.history.length, 1);
    expect(controller.readings.first.telemetry!.decodePerSecond, 50);
  });
  test('failed reads clear current metrics and add a chart gap', () async {
    final source = TestMonitorSource();
    final controller = RuntimeMonitorController(
      targets: () => [target('a', source)],
      interval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    controller.setActive(true);
    await Future<void>.delayed(Duration.zero);
    source.fail = true;
    await controller.refresh();
    expect(controller.readings.first.telemetry, isNull);
    expect(controller.readings.first.error, contains('failed'));
    expect(controller.readings.first.history.last.decode, isNull);
  });
}

Map<String, Object?> splashStatus() => {
  'transport': {'status_stale': false},
  'http': {
    'requests': {'capacity': 4},
  },
  'scheduler': {
    'queued': 1,
    'waiting_resources': 0,
    'waiting_prefix': 0,
    'waiting_mask': 0,
    'prefilling': 1,
    'decoding': 1,
  },
  'requests': {'submitted': 10},
  'metrics': {
    'prefill_input_tokens': 1200,
    'decode_output_tokens': 600,
    'prefill_tokens_per_second': 200,
    'decode_tokens_per_second': 50,
  },
  'active_requests': [
    {
      'id': 1,
      'phase': 'prefill',
      'prompt_tokens': 100,
      'prompt_processed': 32,
      'generated_tokens': 0,
      'max_new_tokens': 100,
    },
    {
      'id': 2,
      'phase': 'decode',
      'prompt_tokens': 100,
      'prompt_processed': 100,
      'generated_tokens': 6,
      'max_new_tokens': 100,
    },
    {'id': 3, 'phase': 'queued', 'prompt_tokens': 100},
  ],
};

MonitorTarget target(
  String id,
  RuntimeMonitorSource source, {
  int generation = 1,
}) => MonitorTarget(
  id: id,
  name: 'instance $id',
  publicName: 'instance-$id',
  status: '运行中',
  source: source,
  run: RuntimeInstance(
    id: 'run-$id',
    artifactId: 'asset-$id',
    status: RuntimeInstanceStatus.ready,
    generation: generation,
    activeRequests: 0,
    acceptingRequests: true,
    hasLiveProcess: true,
    capabilities: {RuntimeCapability.textGeneration},
  ),
);

class TestMonitorSource implements RuntimeMonitorSource {
  int calls = 0, active = 0, maxActive = 0;
  bool fail = false;
  Completer<RuntimeTelemetry>? gate;
  @override
  Future<RuntimeTelemetry> readTelemetry(
    String instanceId, {
    required DecisionCancellation cancellation,
  }) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (fail) throw StateError('failed');
      return gate == null
          ? RuntimeTelemetry.splash(splashStatus())
          : await gate!.future;
    } finally {
      active--;
    }
  }
}
