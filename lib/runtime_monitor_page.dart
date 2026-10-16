import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import 'launch_instances.dart';
import 'runtime_monitor.dart';
import 'runtime_monitor_controller.dart';

class RuntimeMonitorPage extends StatefulWidget {
  const RuntimeMonitorPage({
    super.key,
    required this.instances,
    required this.active,
    this.controller,
  });
  final LaunchInstances instances;
  final bool active;
  final RuntimeMonitorController? controller;
  @override
  State<RuntimeMonitorPage> createState() => _RuntimeMonitorPageState();
}

class _RuntimeMonitorPageState extends State<RuntimeMonitorPage> {
  late final RuntimeMonitorController _controller;
  StreamSubscription<void>? _subscription;
  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        RuntimeMonitorController.forInstances(widget.instances);
    _controller.addListener(_changed);
    _subscription = widget.instances.changes.listen(
      (_) => unawaited(_controller.refresh()),
    );
    _controller.setActive(widget.active);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant RuntimeMonitorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.setActive(widget.active);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _controller.removeListener(_changed);
    _controller.setActive(false);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = _controller.allTargets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('运行监控', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text('运行实例 ${all.length}'),
        const SizedBox(height: 6),
        const Text('按原生推理槽位显示阶段；速度为最近一分钟平均 token/s。未提供的字段显示 —。'),
        const SizedBox(height: 16),
        Expanded(
          child: all.isEmpty
              ? const Center(child: Text('暂无运行实例'))
              : ListView.builder(
                  itemCount: _controller.readings.length,
                  itemBuilder: (context, index) {
                    final reading = _controller.readings[index];
                    return _InstanceMonitor(
                      key: ValueKey(reading.target.identity),
                      reading: reading,
                    );
                  },
                ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '第 ${_controller.page + 1} / ${_controller.pageCount} 页 · 每页 ${RuntimeMonitorController.pageSize} 个实例',
              ),
            ),
            IconButton(
              tooltip: '上一页',
              onPressed: _controller.page == 0
                  ? null
                  : () => _controller.setPage(_controller.page - 1),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: '下一页',
              onPressed: _controller.page + 1 >= _controller.pageCount
                  ? null
                  : () => _controller.setPage(_controller.page + 1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }
}

class _InstanceMonitor extends StatelessWidget {
  const _InstanceMonitor({super.key, required this.reading});
  final MonitorReading reading;

  @override
  Widget build(BuildContext context) {
    final data = reading.telemetry;
    final target = reading.target;
    final capacity =
        data?.capacity ??
        target.run?.inferenceConcurrency ??
        target.configuredConcurrency;
    final scale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(12) / 12,
    );
    final active =
        data?.requests
            .where((request) => request.phase != RequestPhase.queued)
            .toList() ??
        <RequestProgress>[];
    final assigned = <int, RequestProgress>{};
    final unassigned = <RequestProgress>[];
    if (capacity != null) {
      for (final request in active) {
        final slot = request.slotIndex;
        if (slot != null &&
            slot >= 0 &&
            slot < capacity &&
            !assigned.containsKey(slot)) {
          assigned[slot] = request;
        } else {
          unassigned.add(request);
        }
      }
      var slot = 0;
      for (final request in unassigned) {
        while (slot < capacity && assigned.containsKey(slot)) {
          slot++;
        }
        if (slot >= capacity) break;
        assigned[slot++] = request;
      }
    }
    final running = data?.running;
    final unreported = capacity == null || running == null
        ? 0
        : math.max(0, math.min(capacity, running) - assigned.length);
    final idleKnown =
        capacity != null &&
        running != null &&
        running >= active.length &&
        running <= capacity;
    final theme = Theme.of(context);
    return Container(
      key: Key('monitor-instance:${target.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            key: Key('monitor-slots:${target.id}'),
            children: [
              Text('并发 ${capacity ?? '—'}', style: theme.textTheme.bodySmall),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 56 * scale,
                  child: capacity == null
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            reading.error == null ? '槽位 —' : '读取失败',
                            style: theme.textTheme.bodySmall,
                          ),
                        )
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                          itemCount: capacity,
                          itemBuilder: (context, index) {
                            var request = assigned[index];
                            final gap =
                                index -
                                assigned.keys
                                    .where((slot) => slot < index)
                                    .length;
                            if (request == null && gap < unreported) {
                              request = RequestProgress(
                                id: 'unreported-$index',
                                phase: RequestPhase.running,
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: SizedBox(
                                width: 100 * scale,
                                child: _Slot(
                                  key: Key('monitor-slot:${target.id}:$index'),
                                  request: request,
                                  idle: request == null && idleKnown,
                                  unknownLabel: target.status,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '排队 ${data?.queued ?? '—'}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              key: Key('monitor-summary:${target.id}'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  SizedBox(
                    width: constraints.maxWidth * .22,
                    child: Tooltip(
                      message: '${target.name} · ${target.publicName}',
                      child: Text(
                        target.publicName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: constraints.maxWidth * .18,
                    child: Tooltip(
                      message: target.engineName,
                      child: Text(
                        target.engineName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '输入 ${data?.promptTokens ?? '—'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '输出 ${data?.generatedTokens ?? '—'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'prefill ${_rate(reading.minutePrefillPerSecond)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'decode ${_rate(reading.minuteDecodePerSecond)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (reading.error != null || data?.notice != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                        message: reading.error ?? data!.notice!,
                        child: Icon(
                          Icons.info_outline,
                          size: 16,
                          color: reading.error == null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    super.key,
    required this.request,
    required this.idle,
    required this.unknownLabel,
  });
  final RequestProgress? request;
  final bool idle;
  final String unknownLabel;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = request?.phase;
    final label = idle
        ? '空闲'
        : phase == RequestPhase.prefill
        ? 'prefill'
        : phase == RequestPhase.decode
        ? 'decode'
        : unknownLabel;
    final amount = request == null
        ? null
        : phase == RequestPhase.prefill
        ? request!.promptTokens == null
              ? '${request!.processedTokens ?? '—'} token'
              : '${request!.processedTokens ?? '—'} / ${request!.promptTokens}'
        : phase == RequestPhase.decode
        ? '${request!.generatedTokens ?? '—'} token'
        : '—';
    final active =
        phase == RequestPhase.prefill || phase == RequestPhase.decode;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        border: Border.all(
          color: active
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            if (amount != null)
              Text(
                amount,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

String _rate(double? value) => value == null || !value.isFinite || value < 0
    ? '—'
    : value.toStringAsFixed(1);
