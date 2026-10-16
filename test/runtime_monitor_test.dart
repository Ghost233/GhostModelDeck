import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/runtime_monitor.dart';
import 'package:ghost_model_deck/runtime_monitor_controller.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/model_scenarios.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('finished Splash requests awaiting finalization do not occupy inference slots', () {
    final status = splashStatus();
    status['active_requests'] = [
      ...status['active_requests'] as List,
      {'id': 4, 'phase': 'completed'},
      {'id': 5, 'phase': 'cancelled'},
      {'id': 6, 'phase': 'failed'},
    ];
    final data = RuntimeTelemetry.splash(status);
    expect(data.running, 2);
    expect(data.requests.map((request) => request.id), ['1', '2', '3']);
  });
  test('only owned live instances become monitor targets while aliases and pending edits preserve their run identity', () async {
    final runtime = await CouncilRuntime.create(
      modelCount: 1,
      sourceSystemone: true,
    );
    addTearDown(runtime.close);
    runtime.io.capacityProperties = {
      'default_generation_settings': {'n_ctx': 4096},
      'total_slots': 2,
    };
    final instances = LaunchInstances(
      catalog: runtime.catalog,
      file: File('${runtime.root.path}/instances.json'),
    );
    addTearDown(instances.close);
    final first = await instances.save(
      name: 'First',
      artifactId: runtime.library.state.artifacts.single.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(
        formValues: {
          ...EngineLaunchConfiguration.initialValues,
          '--parallel': '2',
        },
      ),
    );
    final second = await instances.copy(first.id);
    await instances.copy(first.id);
    final council = CouncilController(
      catalog: runtime.catalog,
      launchInstances: instances,
    );
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'committee',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    await council.scenarios.save(
      0,
      ModelScenario(
        displayName: 'alias',
        modelName: 'virtual',
        instanceId: first.id,
      ),
    );
    final monitor = RuntimeMonitorController.forInstances(instances);
    addTearDown(monitor.dispose);
    expect(monitor.targets(), isEmpty);
    await instances.start(first.id);
    await instances.start(second.id);
    final targets = monitor.targets();
    expect(targets.map((target) => target.id).toSet(), {first.id, second.id});
    expect(
      targets.map((target) => target.publicName),
      isNot(contains('virtual')),
    );
    expect(targets.first.engineName, contains('llama.cpp'));
    expect(targets.first.run!.inferenceConcurrency, 2);
    final identity = targets.first.identity;
    await instances.save(
      id: first.id,
      name: first.name,
      artifactId: first.artifactId,
      engineId: first.engineId,
      configuration: EngineLaunchConfiguration(argumentText: '-np 4'),
    );
    final pending = monitor.targets().singleWhere(
      (target) => target.id == first.id,
    );
    expect(pending.identity, identity);
    expect(pending.configuredConcurrency, isNull);
    expect(pending.run!.inferenceConcurrency, 2);
    await instances.stop(first.id);
    expect(monitor.targets().map((target) => target.id), [second.id]);
    await instances.stop(second.id);
    expect(monitor.targets(), isEmpty);
    expect(runtime.io.requests, isEmpty);
  });
  test('Splash inference slots come from the native memory plan and never the HTTP admission limit', () {
    final status = splashStatus();
    status['memory_plan'] = {
      'budget': {'maximum_batch_width': 4},
    };
    status['http'] = {
      'requests': {'capacity': 256},
    };
    expect(RuntimeTelemetry.splash(status).capacity, 4);
    status.remove('memory_plan');
    expect(RuntimeTelemetry.splash(status).capacity, isNull);
  });
  test(
    'unreported active requests stay unknown while explicit zero stays zero',
    () {
      final status = <String, Object?>{
        'ready': true,
        'scheduler': {
          'queued': 0,
          'waiting_resources': 0,
          'waiting_prefix': 0,
          'waiting_mask': 0,
        },
        'metrics': {'prefill_input_tokens': 0},
      };
      expect(RuntimeTelemetry.splash(status).running, isNull);
      status['active_requests'] = <Object?>[];
      expect(RuntimeTelemetry.splash(status).running, 0);
      expect(RuntimeTelemetry.splash(status).queued, 0);
    },
  );
  test('oMLX global totals do not become the selected instance totals', () {
    final data = RuntimeTelemetry.omlx({
      'total_requests': 1000,
      'total_prompt_tokens': 900000,
      'total_completion_tokens': 600000,
      'avg_generation_tps': 999,
      'active_models': {
        'models': [
          {'id': 'selected', 'active_requests': 0},
          {'id': 'other', 'active_requests': 7},
        ],
      },
    }, 'selected');
    expect(data.promptTokens, isNull);
    expect(data.generatedTokens, isNull);
    expect(data.totalRequests, isNull);
    expect(data.decodePerSecond, isNull);
  });
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
    expect(data.prefillSeconds, 6);
    expect(data.decodeSeconds, 12);
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
      metrics: 'llamacpp:requests_deferred 2\nllamacpp:prompt_tokens_total 1200\nllamacpp:tokens_predicted_total 600\nllamacpp:prompt_tokens_seconds 200\nllamacpp:predicted_tokens_seconds 50\nllamacpp:prompt_seconds_total 6\nllamacpp:tokens_predicted_seconds_total 12\n',
    );
    expect(complete.queued, 2);
    expect(complete.generatedTokens, 600);
    expect(complete.decodePerSecond, 50);
    expect(complete.prefillSeconds, 6);
    expect(complete.decodeSeconds, 12);
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
    expect(data.totalRequests, isNull);
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
  test('one page polls at most 20 instances, minute buffers are bounded and inactive pages do not poll', () async {
    var now = DateTime.utc(2026, 10, 17);
    final source = TestMonitorSource()
      ..response = RuntimeTelemetry(
        promptTokens: 0,
        generatedTokens: 0,
        prefillSeconds: 0,
        decodeSeconds: 0,
      );
    final controller = RuntimeMonitorController(
      targets: () => [for (var i = 0; i < 25; i++) target('$i', source)],
      interval: const Duration(hours: 1),
      now: () => now,
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
      now = now.add(const Duration(seconds: 1));
      source.response = RuntimeTelemetry(
        promptTokens: (i + 1) * 100,
        generatedTokens: (i + 1) * 20,
        prefillSeconds: (i + 1).toDouble(),
        decodeSeconds: (i + 1).toDouble(),
      );
      await controller.refresh();
    }
    expect(
      controller.bufferedSampleCount,
      lessThanOrEqualTo(25 * 2 * RuntimeMonitorController.minuteSampleLimit),
    );
    expect(controller.bufferedSampleCount, greaterThan(125));
    expect(controller.readings.first.minutePrefillPerSecond, 100);
    expect(controller.readings.first.minuteDecodePerSecond, 20);
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
    expect(controller.readings.first.minutePrefillPerSecond, isNull);
    final buffered = controller.bufferedSampleCount;
    source.gate = Completer<RuntimeTelemetry>();
    final pending = controller.refresh();
    controller.setActive(false);
    source.gate!.complete(RuntimeTelemetry(decodePerSecond: 888));
    await pending;
    expect(controller.bufferedSampleCount, buffered);
    expect(controller.readings.first.telemetry!.decodePerSecond, 50);
  });
  test('failed reads clear current minute metrics without turning missing data into zero', () async {
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
    expect(controller.readings.first.minutePrefillPerSecond, isNull);
    expect(controller.readings.first.minuteDecodePerSecond, isNull);
  });
}

Map<String, Object?> splashStatus() => {
  'memory_plan': {
    'budget': {'maximum_batch_width': 4},
  },
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
    'prefill_wall_ms': 6000,
    'decode_wall_ms': 12000,
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
    inferenceConcurrency: 4,
  ),
);

class TestMonitorSource implements RuntimeMonitorSource {
  int calls = 0, active = 0, maxActive = 0;
  bool fail = false;
  RuntimeTelemetry? response;
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
          ? response ?? RuntimeTelemetry.splash(splashStatus())
          : await gate!.future;
    } finally {
      active--;
    }
  }
}
