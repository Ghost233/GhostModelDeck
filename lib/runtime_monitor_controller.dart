import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine_runtime.dart';
import 'launch_instances.dart';
import 'runtime_monitor.dart';

class MonitorTarget {
  const MonitorTarget({
    required this.id,
    required this.name,
    required this.publicName,
    required this.status,
    this.run,
    this.source,
  });
  final String id;
  final String name;
  final String publicName;
  final String status;
  final RuntimeInstance? run;
  final RuntimeMonitorSource? source;
  String get identity => '$id/${run?.id}/${run?.generation}';
}

class SpeedSample {
  const SpeedSample(this.time, this.prefill, this.decode);
  final DateTime time;
  final double? prefill;
  final double? decode;
}

class MonitorReading {
  MonitorReading(
    this.target, {
    this.telemetry,
    this.error,
    this.updatedAt,
    List<SpeedSample> history = const [],
  }) : history = List.unmodifiable(history);
  final MonitorTarget target;
  final RuntimeTelemetry? telemetry;
  final String? error;
  final DateTime? updatedAt;
  final List<SpeedSample> history;
}

class RuntimeMonitorController extends ChangeNotifier {
  RuntimeMonitorController({
    required this.targets,
    this.interval = const Duration(seconds: 1),
  });
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
                  source: owner is RuntimeMonitorSource
                      ? owner as RuntimeMonitorSource
                      : null,
                );
              })(),
          ];
        },
      );

  static const pageSize = 20;
  static const historyLimit = 120;
  final List<MonitorTarget> Function() targets;
  final Duration interval;
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
      final visible = _targets.skip(_page * pageSize).take(pageSize).toList();
      for (final target in visible) {
        final previous = _readings[target.id];
        if (previous == null ||
            previous.target.identity != target.identity ||
            target.run?.status != RuntimeInstanceStatus.ready) {
          _readings[target.id] = MonitorReading(target);
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
              return;
            }
            final time = DateTime.now();
            final history = <SpeedSample>[
              ...?_readings[target.id]?.history,
              SpeedSample(
                time,
                telemetry?.prefillPerSecond,
                telemetry?.decodePerSecond,
              ),
            ];
            if (history.length > historyLimit) {
              history.removeRange(0, history.length - historyLimit);
            }
            _readings[target.id] = MonitorReading(
              current,
              telemetry: telemetry,
              error: error,
              updatedAt: time,
              history: history,
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
    super.dispose();
  }
}
