import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'council_mcp.dart';
import 'engine_runtime.dart';
import 'launch_instances.dart';
import 'public_gateway.dart';

class ModelConnectionsPage extends StatefulWidget {
  const ModelConnectionsPage({
    super.key,
    required this.instances,
    required this.gateway,
    required this.mcp,
  });

  final LaunchInstances instances;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;

  @override
  State<ModelConnectionsPage> createState() => _ModelConnectionsPageState();
}

class _ModelConnectionsPageState extends State<ModelConnectionsPage> {
  final _subscriptions = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subscriptions.addAll([
      widget.instances.changes.listen(refresh),
      widget.gateway.changes.listen(refresh),
      widget.mcp.changes.listen(refresh),
      widget.mcp.controller.models.changes.listen(refresh),
    ]);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Widget _copyRow(String label, String? value, {required String id}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 125, child: Text(label)),
        Expanded(
          child: SelectableText(value ?? '启动后分配地址', key: Key('connection:$id')),
        ),
        if (value != null)
          IconButton(
            tooltip: '复制$label',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          ),
      ],
    ),
  );

  Widget _parameters(
    RuntimeInstance? run,
    LaunchInstance? instance, {
    required bool text,
  }) {
    final context = run?.capacity?.contextPerSlot;
    final slots = run?.capacity?.slotCount ?? run?.inferenceConcurrency;
    String generationValue(String name) {
      final values = instance?.configuration.generation.values;
      if (values == null || !values.containsKey(name)) return '继承引擎默认';
      return values[name]?.toString() ?? '关闭';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('上下文（每槽）：${context ?? '未知'}　并发槽位：${slots ?? '未知'}'),
        if (text && instance != null) ...[
          const Text('实例生成默认值（请求可覆盖）'),
          Text(
            '温度：${generationValue('temperature')}　Top P：${generationValue('top_p')}　Top K：${generationValue('top_k')}',
          ),
          Text(
            'Min P：${generationValue('min_p')}　输出上限：${generationValue('max_tokens')}',
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final httpRunning = widget.gateway.state == PublicGatewayState.running;
    final mcpRunning = widget.mcp.state.status == CouncilMcpStatus.running;
    final http = httpRunning ? widget.gateway.baseUrl : null;
    final mcp = mcpRunning ? widget.mcp.endpoint : null;
    final configuredHttp = widget.gateway.port > 0
        ? Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: widget.gateway.port,
            path: '/v1/',
          )
        : null;
    final configuredMcp = widget.mcp.port > 0
        ? Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: widget.mcp.port,
            path: '/mcp',
          )
        : null;
    final textNames = http == null
        ? <String>[]
        : widget.gateway.readyTextModelNames;
    final embeddingNames = http == null
        ? <String>[]
        : widget.gateway.readyEmbeddingModelNames;
    final httpJev = http == null
        ? <String>[]
        : [
            for (final model in widget.gateway.jevModels?.callableModels ?? [])
              model.definition.name,
          ];
    final mcpJev = mcp == null
        ? <String>[]
        : [
            for (final model in widget.mcp.controller.models.callableModels)
              model.definition.name,
          ];
    final names = {
      ...textNames,
      ...embeddingNames,
      ...httpJev,
      ...mcpJev,
    }.toList()..sort();
    final httpStatus = switch (widget.gateway.state) {
      PublicGatewayState.stopped => '未启动',
      PublicGatewayState.starting => '启动中',
      PublicGatewayState.running => '运行中',
      PublicGatewayState.stopping => '停止中',
      PublicGatewayState.failed => '启动失败',
    };
    final mcpStatus = switch (widget.mcp.state.status) {
      CouncilMcpStatus.stopped => '未启动',
      CouncilMcpStatus.starting => '启动中',
      CouncilMcpStatus.running => '运行中',
      CouncilMcpStatus.stopping => '停止中',
      CouncilMcpStatus.failed => '启动失败',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const JevPageHeader(title: '模型连接'),
        Expanded(
          child: ListView(
            children: [
              JevSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '统一入口',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('HTTP API：$httpStatus'),
                    _copyRow(
                      'OpenAI 基础地址',
                      (http?.resolve('/v1/') ?? configuredHttp)?.toString(),
                      id: 'overview-http',
                    ),
                    Text('MCP：$mcpStatus'),
                    _copyRow(
                      'MCP 服务地址',
                      (mcp ?? configuredMcp)?.toString(),
                      id: 'overview-mcp',
                    ),
                    const Text('服务未运行时显示配置地址。地址由模型共享；客户端通过模型调用名选择模型。'),
                    const Text(
                      'HTTP 支持 OpenAI Chat、Embeddings 和 JEV；MCP 目前用于 JEV 决策，不提供普通文本生成。',
                    ),
                    const Text('MCP 默认发现列出已启用的可用场景；其他可调用的 JEV 模型可按名称直接使用。'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '已可用模型（${names.length}）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (names.isEmpty)
                const JevSurface(child: Text('当前没有可通过已启动服务调用的模型。')),
              for (final name in names) ...[
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final target =
                        widget.gateway.readyTextModel(name) ??
                        widget.gateway.readyEmbeddingModel(name);
                    final jev = widget.mcp.controller.models.callableModels
                        .where((model) => model.definition.name == name)
                        .firstOrNull;
                    final instanceId =
                        target?.instance.launchInstanceId ??
                        jev?.definition.bindings.singleOrNull?.instanceId;
                    final instance = instanceId == null
                        ? null
                        : widget.instances.find(instanceId);
                    final asset = instance == null
                        ? null
                        : widget.instances.catalog.library.state.artifacts
                              .where((item) => item.id == instance.artifactId)
                              .firstOrNull;
                    final runs = instanceId == null
                        ? <RuntimeInstance>[]
                        : widget.instances
                              .runsFor(instanceId)
                              .where(
                                (run) =>
                                    run.status == RuntimeInstanceStatus.ready &&
                                    run.acceptingRequests &&
                                    run.hasLiveProcess,
                              )
                              .toList();
                    final protocols = [
                      if (textNames.contains(name)) 'OpenAI Chat',
                      if (embeddingNames.contains(name)) 'OpenAI Embeddings',
                      if (httpJev.contains(name)) 'JEV HTTP',
                      if (mcpJev.contains(name)) 'MCP · JEV',
                    ];
                    return JevSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _copyRow('模型调用名', name, id: 'available:$name'),
                          if (instance != null) Text('实例：${instance.name}'),
                          if (instance != null)
                            Text('模型：${asset?.name ?? '模型信息未找到'}'),
                          Text('协议：${protocols.join('、')}'),
                          _parameters(
                            target?.instance ?? runs.singleOrNull,
                            instance,
                            text: textNames.contains(name),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
