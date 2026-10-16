import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/runtime_monitor.dart';
import 'package:ghost_model_deck/runtime_monitor_controller.dart';

import 'runtime_monitor_test.dart' show target, TestMonitorSource;

RuntimeTelemetry counters(
  int input,
  double prefill, {
  int output = 0,
  double decode = 0,
}) => RuntimeTelemetry(
  promptTokens: input,
  prefillSeconds: prefill,
  generatedTokens: output,
  decodeSeconds: decode,
  prefillPerSecond: 9999,
  decodePerSecond: 8888,
);

void main() {
  test('minute averages use stage counter deltas, expire old work and interpolate the boundary', () async {
    var now = DateTime.utc(2026, 10, 17);
    final origin = now;
    final source = TestMonitorSource()
      ..response = counters(10000, 100, output: 5000, decode: 100);
    final monitor = RuntimeMonitorController(
      targets: () => [target('a', source)],
      interval: const Duration(days: 1),
      now: () => now,
    );
    addTearDown(monitor.dispose);
    monitor.setActive(true);
    await Future<void>.delayed(Duration.zero);
    expect(monitor.readings.single.minutePrefillPerSecond, isNull);
    now = origin.add(const Duration(seconds: 10));
    source.response = counters(11000, 101, output: 5500, decode: 105);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, 1000);
    expect(monitor.readings.single.minuteDecodePerSecond, 100);
    now = origin.add(const Duration(seconds: 30));
    source.response = counters(13000, 105, output: 6500, decode: 115);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, 600);
    expect(monitor.readings.single.minuteDecodePerSecond, 100);
    now = origin.add(const Duration(seconds: 70));
    source.response = counters(15000, 115, output: 7500, decode: 125);
    await monitor.refresh();
    expect(
      monitor.readings.single.minutePrefillPerSecond,
      closeTo(4000 / 14, 1e-9),
    );
    expect(monitor.readings.single.minuteDecodePerSecond, 100);
    now = origin.add(const Duration(seconds: 100));
    source.response = counters(18000, 118, output: 8000, decode: 130);
    await monitor.refresh();
    expect(
      monitor.readings.single.minutePrefillPerSecond,
      closeTo(4500 / 10.5, 1e-9),
    );
    expect(monitor.readings.single.minuteDecodePerSecond, 100);
    expect(monitor.readings.single.telemetry!.promptTokens, 18000);
  });
  test('minute data distinguishes zero, missing counters, failures, resets and a gap longer than the window', () async {
    var now = DateTime.utc(2026, 10, 17);
    final source = TestMonitorSource()..response = counters(0, 0);
    final monitor = RuntimeMonitorController(
      targets: () => [target('a', source)],
      interval: const Duration(days: 1),
      now: () => now,
    );
    addTearDown(monitor.dispose);
    monitor.setActive(true);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(seconds: 1));
    source.response = counters(0, 1, decode: 1);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, 0);
    expect(monitor.readings.single.minuteDecodePerSecond, 0);
    now = now.add(const Duration(seconds: 1));
    source.response = RuntimeTelemetry(
      promptTokens: 250,
      generatedTokens: 20,
      prefillPerSecond: 9999,
      decodePerSecond: 8888,
    );
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, isNull);
    expect(monitor.readings.single.minuteDecodePerSecond, isNull);
    now = now.add(const Duration(seconds: 1));
    source.fail = true;
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, isNull);
    expect(monitor.readings.single.telemetry, isNull);
    expect(monitor.readings.single.error, contains('failed'));
    now = now.add(const Duration(seconds: 1));
    source.fail = false;
    source.response = counters(400, 4, output: 40, decode: 4);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, 100);
    expect(monitor.readings.single.minuteDecodePerSecond, 10);
    now = now.add(const Duration(seconds: 1));
    source.response = counters(1, 0.1, output: 2, decode: 0.1);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, isNull);
    expect(monitor.readings.single.minuteDecodePerSecond, isNull);
    now = now.add(const Duration(seconds: 1));
    source.response = counters(11, 0.2, output: 12, decode: 0.2);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, closeTo(100, 1e-9));
    now = now.add(const Duration(seconds: 61));
    source.response = counters(1000, 100, output: 1000, decode: 100);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, isNull);
    expect(monitor.readings.single.minuteDecodePerSecond, isNull);
    now = now.subtract(const Duration(seconds: 2));
    source.response = counters(1010, 101, output: 1010, decode: 101);
    await monitor.refresh();
    expect(monitor.readings.single.minutePrefillPerSecond, isNull);
  });
  test('minute windows isolate instances and generations and discard hidden late reads', () async {
    var now = DateTime.utc(2026, 10, 17);
    var generation = 1;
    final first = TestMonitorSource()..response = counters(0, 0);
    final second = TestMonitorSource()..response = counters(0, 0);
    final monitor = RuntimeMonitorController(
      targets: () => [
        target('a', first, generation: generation),
        target('b', second),
      ],
      interval: const Duration(days: 1),
      now: () => now,
    );
    addTearDown(monitor.dispose);
    monitor.setActive(true);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(seconds: 10));
    first.response = counters(1000, 10);
    second.response = counters(2000, 2);
    await monitor.refresh();
    expect(monitor.readings[0].minutePrefillPerSecond, 100);
    expect(monitor.readings[1].minutePrefillPerSecond, 1000);
    first.gate = Completer<RuntimeTelemetry>();
    now = now.add(const Duration(seconds: 5));
    final late = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    first.gate!.complete(counters(999999, 1));
    await late;
    expect(monitor.readings[0].minutePrefillPerSecond, isNull);
    first.gate = null;
    first.response = counters(5000, 50);
    now = now.add(const Duration(seconds: 1));
    await monitor.refresh();
    expect(monitor.readings[0].minutePrefillPerSecond, isNull);
    now = now.add(const Duration(seconds: 1));
    first.response = counters(5100, 51);
    await monitor.refresh();
    expect(monitor.readings[0].minutePrefillPerSecond, 100);
    expect(monitor.readings[1].minutePrefillPerSecond, 1000);
    final buffered = monitor.bufferedSampleCount;
    first.gate = Completer<RuntimeTelemetry>();
    final hidden = monitor.refresh();
    monitor.setActive(false);
    first.gate!.complete(counters(999999, 1));
    await hidden;
    expect(monitor.bufferedSampleCount, buffered);
    expect(monitor.readings[0].minutePrefillPerSecond, 100);
  });
}
