import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'launch_instances.dart';
import 'engine_runtime.dart';
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
        Text(
          '已注册 ${all.length} · 运行实例 ${all.where((t) => t.run?.status == RuntimeInstanceStatus.ready).length}',
        ),
        const SizedBox(height: 6),
        const Text('读取本页引擎的实际状态；平均速度来自当前引擎会话。未提供的字段显示 —。'),
        const SizedBox(height: 16),
        Expanded(
          child: all.isEmpty
              ? const Center(child: Text('暂无已保存实例'))
              : ListView.builder(
                  itemCount: _controller.readings.length,
                  itemBuilder: (context, index) {
                    final reading = _controller.readings[index];
                    return _InstanceMonitor(
                      key: ValueKey(reading.target.id),
                      reading: reading,
                    );
                  },
                ),
        ),
        Row(
          children: [
            Text(
              '第 ${_controller.page + 1} / ${_controller.pageCount} 页 · 每页 ${RuntimeMonitorController.pageSize} 个实例',
            ),
            const Spacer(),
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

class _InstanceMonitor extends StatefulWidget {
  const _InstanceMonitor({super.key, required this.reading});
  final MonitorReading reading;
  @override
  State<_InstanceMonitor> createState() => _InstanceMonitorState();
}

class _InstanceMonitorState extends State<_InstanceMonitor> {
  int _requestPage = 0;
  static const requestPageSize = 8;
  @override
  Widget build(BuildContext context) {
    final reading = widget.reading;
    final data = reading.telemetry;
    final requestCount = data?.requests.length ?? 0;
    final pages = (requestCount / requestPageSize).ceil().clamp(1, 1 << 30);
    final page = _requestPage.clamp(0, pages - 1);
    final scheme = Theme.of(context).colorScheme;
    final chartMaximum = reading.history
        .expand((s) => [s.prefill, s.decode])
        .whereType<double>()
        .fold<double>(1, math.max);
    return Card(
      child: ExpansionTile(
        title: Text(
          reading.target.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${reading.target.publicName} · ${reading.target.status}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text('并发 ${_count(data?.running)} / ${_count(data?.capacity)}'),
                Text('排队 ${_count(data?.queued)}'),
                Text('prefill ${_count(data?.prefilling)}'),
                Text('decode ${_count(data?.decoding)}'),
                Text('输入 ${_count(data?.promptTokens)} token'),
                Text('输出 ${_count(data?.generatedTokens)} token'),
                Text('总请求 ${_count(data?.totalRequests)}'),
              ],
            ),
            Wrap(
              spacing: 16,
              children: [
                Text('平均 prefill ${_rate(data?.prefillPerSecond)}'),
                Text('平均 decode ${_rate(data?.decodePerSecond)}'),
              ],
            ),
            if (reading.error != null)
              Text(
                '读取失败：${reading.error}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.error),
              ),
            if (reading.target.run != null && reading.target.source == null)
              const Text('当前引擎未提供监控接口'),
            if (data?.notice != null)
              Text(data!.notice!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        childrenPadding: const EdgeInsets.all(16),
        children: [
          if (reading.history.isNotEmpty) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('平均速度变化 · 最近 120 个采样点'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('纵轴上限 ${chartMaximum.toStringAsFixed(1)} tokens/s'),
            ),
            Row(
              children: [
                Icon(Icons.show_chart, color: scheme.primary, size: 16),
                const Text(' prefill   '),
                Icon(Icons.show_chart, color: scheme.tertiary, size: 16),
                const Text(' decode · tokens/s'),
              ],
            ),
            SizedBox(
              height: 120,
              width: double.infinity,
              child: CustomPaint(
                painter: _SpeedChart(
                  reading.history,
                  scheme.primary,
                  scheme.tertiary,
                  scheme.outlineVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (requestCount == 0)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('当前没有引擎提供的请求明细'),
            ),
          for (final request
              in data?.requests
                      .skip(page * requestPageSize)
                      .take(requestPageSize) ??
                  <RequestProgress>[])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_phaseName(request.phase)} · ${request.id}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Wrap(
                    spacing: 16,
                    children: [
                      Text(
                        '输入 ${_count(request.processedTokens)} / ${_count(request.promptTokens)} token',
                      ),
                      Text(
                        '输出 ${_count(request.generatedTokens)} / ${_count(request.maxTokens)} token',
                      ),
                      if (request.tokensPerSecond != null)
                        Text(_rate(request.tokensPerSecond)),
                    ],
                  ),
                  if (request.phase == RequestPhase.prefill &&
                      (request.promptTokens ?? 0) > 0 &&
                      request.processedTokens != null)
                    LinearProgressIndicator(
                      value: (request.processedTokens! / request.promptTokens!)
                          .clamp(0, 1),
                    ),
                ],
              ),
            ),
          if (pages > 1)
            Row(
              children: [
                Text('请求 ${page + 1} / $pages 页 · 共 $requestCount 个'),
                const Spacer(),
                IconButton(
                  tooltip: '上一组请求',
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _requestPage = page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: '下一组请求',
                  onPressed: page + 1 >= pages
                      ? null
                      : () => setState(() => _requestPage = page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _count(int? value) => value?.toString() ?? '—';
String _rate(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)} tokens/s';
String _phaseName(RequestPhase phase) => switch (phase) {
  RequestPhase.queued => '排队中',
  RequestPhase.prefill => 'prefill',
  RequestPhase.decode => 'decode',
  RequestPhase.running => '运行中',
};

class _SpeedChart extends CustomPainter {
  _SpeedChart(this.samples, this.prefill, this.decode, this.grid);
  final List<SpeedSample> samples;
  final Color prefill, decode, grid;
  @override
  void paint(Canvas canvas, Size size) {
    final high = samples
        .expand((s) => [s.prefill, s.decode])
        .whereType<double>()
        .fold<double>(1, math.max);
    final start = samples.first.time;
    final span = math.max(
      1,
      samples.last.time.difference(start).inMilliseconds,
    );
    final stroke = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var line = 0; line < 4; line++) {
      final y = size.height * line / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), stroke);
    }
    for (final isPrefill in [true, false]) {
      final path = Path();
      var linked = false;
      for (final sample in samples) {
        final value = isPrefill ? sample.prefill : sample.decode;
        if (value == null) {
          linked = false;
          continue;
        }
        final x =
            size.width *
            (sample.time.difference(start).inMilliseconds / span).clamp(0, 1);
        final y = size.height * (1 - value / high);
        if (linked) {
          path.lineTo(x, y);
        } else {
          path.moveTo(x, y);
        }
        linked = true;
        canvas.drawCircle(
          Offset(x, y),
          2,
          Paint()..color = isPrefill ? prefill : decode,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = isPrefill ? prefill : decode
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedChart oldDelegate) =>
      samples != oldDelegate.samples ||
      prefill != oldDelegate.prefill ||
      decode != oldDelegate.decode ||
      grid != oldDelegate.grid;
}
