import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'council_mcp.dart';

class McpPage extends StatefulWidget {
  const McpPage({super.key, required this.server});
  final CouncilMcpServer server;
  @override
  State<McpPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpPage> {
  bool _working = false;
  Future<void> _run(Future<void> Function() operation) async {
    setState(() => _working = true);
    try {
      await operation();
    } catch (_) {
      /* The server publishes its failure. */
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<CouncilMcpState>(
    stream: widget.server.changes,
    initialData: widget.server.state,
    builder: (context, snapshot) {
      final state = snapshot.data!;
      final running = state.status == CouncilMcpStatus.running;
      final busy =
          _working ||
          state.status == CouncilMcpStatus.starting ||
          state.status == CouncilMcpStatus.stopping;
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JevPageHeader(
            title: 'MCP',
            action: FilledButton(
              onPressed: busy
                  ? null
                  : () => _run(
                      running ? widget.server.stop : widget.server.start,
                    ),
              child: Text(running ? '停止' : '启动'),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: JevSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hub_outlined,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '本机 HTTP MCP',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          JevStatusChip(
                            label: switch (state.status) {
                              CouncilMcpStatus.stopped => '未启动',
                              CouncilMcpStatus.starting => '启动中',
                              CouncilMcpStatus.running => '运行中',
                              CouncilMcpStatus.stopping => '停止中',
                              CouncilMcpStatus.failed => '启动失败',
                            },
                            tone: state.status == CouncilMcpStatus.failed
                                ? JevStatusTone.error
                                : running
                                ? JevStatusTone.success
                                : JevStatusTone.neutral,
                          ),
                        ],
                      ),
                      if (busy) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(minHeight: 2),
                      ],
                      if (state.endpoint != null) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                state.endpoint!.toString(),
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            IconButton(
                              tooltip: '复制地址',
                              onPressed: () => Clipboard.setData(
                                ClipboardData(text: state.endpoint!.toString()),
                              ),
                              icon: const Icon(Icons.copy_outlined, size: 16),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Text(
                              '${state.activeRequests} 个进行中的咨询',
                              style: theme.textTheme.bodySmall,
                            ),
                            const Spacer(),
                            OutlinedButton.icon(
                              onPressed: () => Clipboard.setData(
                                ClipboardData(text: widget.server.codexConfig),
                              ),
                              icon: const Icon(Icons.copy_outlined, size: 16),
                              label: const Text('复制 Codex 配置'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ExpansionTile(
                          dense: true,
                          tilePadding: EdgeInsets.zero,
                          title: Text('配置', style: theme.textTheme.bodySmall),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: SelectableText(
                                widget.server.codexConfig,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            state.error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
