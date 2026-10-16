import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine_runtime.dart';
import 'launch_instances.dart';
import 'runtime_monitor.dart';
import 'engine_labels.dart';

class MonitorTarget {
  const MonitorTarget({
    required this.id,
    required this.name,
    required this.publicName,
    required this.status,
    this.run,
    this.source,
    this.engineName = '—',
    this.configuredConcurrency,
  });
  final String id;
  final String name;
  final String publicName;
  final String status;
  final RuntimeInstance? run;
  final RuntimeMonitorSource? source;
  final String engineName;
  final int? configuredConcurrency;
  String get identity => '$id/${run?.id}/${run?.generation}';
}

class MonitorReading {
  MonitorReading(
    this.target, {
    this.telemetry,
    this.error,
    this.updatedAt,
    this.minutePrefillPerSecond,
    this.minuteDecodePerSecond,
  });
  final MonitorTarget target;
  final RuntimeTelemetry? telemetry;
  final String? error;
  final DateTime? updatedAt;
  final double? minutePrefillPerSecond;
  final double? minuteDecodePerSecond;
}

class RuntimeMonitorController extends ChangeNotifier {
  RuntimeMonitorController({
    required this.targets,
    this.interval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  factory RuntimeMonitorController.forInstances(LaunchInstances instances) =>
      RuntimeMonitorController(
        targets: () {
          final running = <String, (EngineRuntime, RuntimeInstance)>{};
          for (final runtime in instances.catalog.runtimes) {
            for (final run in runtime.runtimeInstances) {
              if (run.launchInstanceId != null && run.hasLiveProcess) {
                running.putIfAbsent(
                  run.launchInstanceId!,
                  () => (runtime, run),
                );
              }
            }
          }
          return [
            for (final definition in instances.definitions)
              if (running.containsKey(definition.id) ||
                  instances.isStarting(definition.id))
                (() {
                  final owner = running[definition.id]?.$1;
                  final run = running[definition.id]?.$2;
                  final status = run == null
                      ? instances.isStarting(definition.id)
                            ? '启动中'
                            : instances.missingReason(definition) ?? '已保存'
                      : switch (run.status) {
                          RuntimeInstanceStatus.starting => '启动中',
                          RuntimeInstanceStatus.ready => '运行中',
                          RuntimeInstanceStatus.stopping => '停止中',
                          RuntimeInstanceStatus.stopped => '已停止',
                          RuntimeInstanceStatus.failed => '失败',
                        };
                  return MonitorTarget(
                    id: definition.id,
                    name: definition.name,
                    publicName: definition.publicName,
                    status: status,
                    run: run,
                    engineName: instances.runningOrigin(definition.id) == null
                        ? '—'
                        : engineDisplayName(
                            instances.runningOrigin(definition.id)!,
                          ),
                    configuredConcurrency:
                        run?.launchRevision == definition.revision
                        ? definition.configuration.inferenceConcurrency
                        : null,
                    source: owner is RuntimeMonitorSource
                        ? owner as RuntimeMonitorSource
                        : null,
                  );
                })(),
          ];
        },
      );

  static const pageSize = 20;
  static const minuteSampleLimit = 64;
  final List<MonitorTarget> Function() targets;
  final Duration interval;
  final DateTime Function() now;
  final _windows = <String, _MinuteWindows>{};
  int get bufferedSampleCount => _windows.values.fold(
    0,
    (sum, window) =>
        sum + window.prefill.sampleCount + window.decode.sampleCount,
  );
  final _readings = <String, MonitorReading>{};
  List<MonitorTarget> _targets = [];
  List<MonitorTarget> get allTargets => List.unmodifiable(_targets);
  List<MonitorReading> get readings => [
    for (final target in _targets.skip(_page * pageSize).take(pageSize))
      _readings[target.id] ?? MonitorReading(target),
  ];
  int _page = 0;
  int get page => _page;
  int get pageCount => (_targets.length / pageSize).ceil().clamp(1, 1 << 30);
  Timer? _timer;
  DecisionCancellation? _cancellation;
  bool _active = false;
  bool _busy = false;
  bool _disposed = false;
  int _epoch = 0;

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _epoch++;
    _cancellation?.cancel();
    _timer?.cancel();
    if (active) {
      unawaited(refresh());
      _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
    }
  }

  void setPage(int page) {
    _page = page.clamp(0, pageCount - 1);
    _epoch++;
    _cancellation?.cancel();
    notifyListeners();
    if (_active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed || !_active || _busy) return;
    _busy = true;
    final epoch = _epoch;
    final cancellation = DecisionCancellation();
    _cancellation = cancellation;
    try {
      _targets = targets();
      _page = _page.clamp(0, pageCount - 1);
      _readings.removeWhere((id, _) => !_targets.any((t) => t.id == id));
      _windows.removeWhere((id, _) => !_targets.any((t) => t.id == id));
      final visible = _targets.skip(_page * pageSize).take(pageSize).toList();
      for (final target in visible) {
        final previous = _readings[target.id];
        if (previous == null ||
            previous.target.identity != target.identity ||
            target.run?.status != RuntimeInstanceStatus.ready) {
          _readings[target.id] = MonitorReading(target);
          _windows.remove(target.id);
        }
      }
      notifyListeners();
      // At most four instances per batch; one refresh owns the whole page.
      for (
        var offset = 0;
        offset < visible.length && !cancellation.isCancelled;
        offset += 4
      ) {
        await Future.wait(
          visible.skip(offset).take(4).map((target) async {
            if (target.run?.status != RuntimeInstanceStatus.ready ||
                target.source == null) {
              return;
            }
            RuntimeTelemetry? telemetry;
            String? error;
            try {
              telemetry = await target.source!.readTelemetry(
                target.run!.id,
                cancellation: cancellation,
              );
            } catch (failure) {
              error = '$failure'.split('\n').first;
              if (error.length > 180) error = '${error.substring(0, 180)}…';
            }
            if (_disposed ||
                !_active ||
                epoch != _epoch ||
                cancellation.isCancelled) {
              return;
            }
            final current = targets()
                .where((t) => t.id == target.id)
                .singleOrNull;
            if (current == null ||
                current.identity != target.identity ||
                current.run?.status != RuntimeInstanceStatus.ready) {
              _readings.remove(target.id);
              _windows.remove(target.id);
              return;
            }
            final time = now();
            final windows = _windows.putIfAbsent(target.id, _MinuteWindows.new);
            final prefill = windows.prefill.observe(
              time,
              telemetry?.promptTokens,
              telemetry?.prefillSeconds,
            );
            final decode = windows.decode.observe(
              time,
              telemetry?.generatedTokens,
              telemetry?.decodeSeconds,
            );
            _readings[target.id] = MonitorReading(
              current,
              telemetry: telemetry,
              error: error,
              updatedAt: time,
              minutePrefillPerSecond: prefill,
              minuteDecodePerSecond: decode,
            );
          }),
        );
      }
      if (!_disposed && _active && epoch == _epoch) notifyListeners();
    } finally {
      _busy = false;
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _epoch++;
    _timer?.cancel();
    _cancellation?.cancel();
    _windows.clear();
    super.dispose();
  }
}

class _MinuteWindows {
  final prefill = _StageWindow();
  final decode = _StageWindow();
}

class _StagePoint {
  const _StagePoint(this.time, this.tokens, this.seconds);
  final DateTime time;
  final int tokens;
  final double seconds;
}

/// Bounded native counter observations, never averages of session speed gauges.
class _StageWindow {
  static const duration = Duration(seconds: 60);
  final _points = <_StagePoint>[];
  int get sampleCount => _points.length;

  void _prune(DateTime time) {
    final cutoff = time.subtract(duration);
    while (_points.length > 2 && !_points[1].time.isAfter(cutoff)) {
      _points.removeAt(0);
    }
    if (_points.length > RuntimeMonitorController.minuteSampleLimit) {
      _points.removeRange(
        0,
        _points.length - RuntimeMonitorController.minuteSampleLimit,
      );
    }
  }

  double? observe(DateTime time, int? tokens, double? seconds) {
    if (_points.isNotEmpty) {
      final previous = _points.last;
      if (time.isBefore(previous.time) ||
          time.difference(previous.time) > duration ||
          tokens != null && tokens < previous.tokens ||
          seconds != null && seconds < previous.seconds) {
        _points.clear();
      }
    }
    if (tokens == null ||
        tokens < 0 ||
        seconds == null ||
        !seconds.isFinite ||
        seconds < 0) {
      _prune(time);
      return null;
    }
    final point = _StagePoint(time, tokens, seconds);
    // Keep the first baseline and the latest observation in a one-second bucket.
    // Extra refreshes cannot grow the minute window without bound.
    if (_points.isNotEmpty && _points.last.time == time ||
        _points.length > 1 &&
            _points.last.time.microsecondsSinceEpoch ~/
                    Duration.microsecondsPerSecond ==
                time.microsecondsSinceEpoch ~/ Duration.microsecondsPerSecond) {
      _points[_points.length - 1] = point;
    } else {
      _points.add(point);
    }
    _prune(time);
    if (_points.length < 2) return null;
    final first = _points.first;
    var baselineTokens = first.tokens.toDouble();
    var baselineSeconds = first.seconds;
    final cutoff = time.subtract(duration);
    if (first.time.isBefore(cutoff)) {
      final next = _points[1];
      final fraction =
          cutoff.difference(first.time).inMicroseconds /
          next.time.difference(first.time).inMicroseconds;
      baselineTokens += (next.tokens - first.tokens) * fraction;
      baselineSeconds += (next.seconds - first.seconds) * fraction;
    }
    final elapsed = seconds - baselineSeconds;
    if (elapsed <= 0) return null;
    final rate = (tokens - baselineTokens) / elapsed;
    return rate.isFinite && rate >= 0 ? rate : null;
  }
}
