import 'dart:async';

import 'package:flutter/material.dart';

import 'engine_logs.dart';

class EngineLogsPanel extends StatefulWidget {
  const EngineLogsPanel({
    super.key,
    required this.sources,
    required this.active,
  });
  final Iterable<EngineLogSource> sources;
  final bool active;

  @override
  State<EngineLogsPanel> createState() => _EngineLogsPanelState();
}

class _EngineLogsPanelState extends State<EngineLogsPanel> {
  final _feed = EngineLogFeed();
  late final StreamSubscription<void> _subscription;

  @override
  void initState() {
    super.initState();
    _feed.attach(widget.sources);
    _subscription = _feed.changes.listen((_) {
      if (mounted && widget.active) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant EngineLogsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _feed.attach(widget.sources);
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    unawaited(_feed.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _feed.entries;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('引擎日志', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            const Tooltip(
              message: '混合显示各引擎的 stdout / stderr；每个引擎及此处最多保留最近 1,000 条。\n仅保存在内存中，重启应用后清空。',
              child: Icon(Icons.info_outline, size: 16),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: entries.isEmpty
                ? const Center(child: Text('暂无引擎日志；引擎产生新输出后显示在这里'))
                : SelectionArea(
                    child: ListView.builder(
                      key: const Key('engine-log-list'),
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[entries.length - 1 - index];
                        final time = entry.time;
                        String pad(int value, [int width = 2]) =>
                            value.toString().padLeft(width, '0');
                        final stamp =
                            '${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}.${pad(time.millisecond, 3)}';
                        return Padding(
                          key: ValueKey(entry.sequence),
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      '$stamp [${entry.engine}] [${entry.instance}] ${entry.channel}\n',
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                TextSpan(text: entry.message),
                              ],
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
