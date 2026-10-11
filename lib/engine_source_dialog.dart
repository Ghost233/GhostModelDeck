import 'dart:async';

import 'package:flutter/material.dart';

import 'engine_catalog.dart';
import 'engine_runtime.dart';
import 'engine_source_build.dart';
import 'jev_debug.dart';

class EngineSourceDialog extends StatefulWidget {
  const EngineSourceDialog({super.key, required this.catalog});
  final EngineCatalog catalog;
  @override
  State<EngineSourceDialog> createState() => _EngineSourceDialogState();
}

class _EngineSourceDialogState extends State<EngineSourceDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _source = TextEditingController();
  final _ref = TextEditingController();
  final _cmake = TextEditingController(text: 'cmake');
  StreamSubscription<EngineSourceBuildProgress>? _changes;
  DecisionCancellation? _cancellation;
  EngineSourceBuildProgress? _progress;
  EngineSourceToolchain? _tools;
  EngineRegistration? _registered;
  String? _error;
  bool _building = false;
  bool _checking = false;
  bool _cancelRequested = false;

  bool get _busy => _building || _checking;

  @override
  void initState() {
    super.initState();
    _changes = widget.catalog.sourceBuilder?.changes.listen((progress) {
      if (mounted && _building) setState(() => _progress = progress);
    });
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    unawaited(_changes?.cancel());
    _name.dispose();
    _source.dispose();
    _ref.dispose();
    _cmake.dispose();
    super.dispose();
  }

  String? get _cmakePath =>
      _cmake.text.trim().isEmpty ? null : _cmake.text.trim();

  Future<void> _checkTools() async {
    final builder = widget.catalog.sourceBuilder;
    if (_busy || builder == null) return;
    final cancellation = DecisionCancellation();
    setState(() {
      _checking = true;
      _cancelRequested = false;
      _cancellation = cancellation;
      _error = null;
      _tools = null;
    });
    try {
      final tools = await builder.preflight(
        cmakePath: _cmakePath,
        cancellation: cancellation,
      );
      if (mounted) {
        setState(() {
          if (cancellation.isCancelled) {
            _error = tools.missing.isEmpty
                ? '编译工具检查已取消'
                : '编译工具检查已取消：${tools.missing.join('\n')}';
          } else {
            _tools = tools;
          }
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _cancelRequested = false;
          _cancellation = null;
        });
      }
    }
  }

  Future<void> _build() async {
    if (_busy || _form.currentState?.validate() != true) return;
    final cancellation = DecisionCancellation();
    setState(() {
      _building = true;
      _cancelRequested = false;
      _cancellation = cancellation;
      _registered = null;
      _progress = null;
      _error = null;
    });
    try {
      final registered = await widget.catalog.buildFromSource(
        EngineSourceBuildRequest(
          source: _source.text.trim(),
          name: _name.text.trim(),
          ref: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
          cmakePath: _cmakePath,
        ),
        cancellation: cancellation,
      );
      if (mounted) setState(() => _registered = registered);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _building = false;
          _cancellation = null;
        });
      }
    }
  }

  void _cancel() {
    setState(() => _cancelRequested = true);
    _cancellation?.cancel();
  }

  String _phase(EngineSourceBuildPhase phase) => switch (phase) {
    EngineSourceBuildPhase.validating => '检查仓库与编译工具',
    EngineSourceBuildPhase.cloning => '获取源码',
    EngineSourceBuildPhase.checkout => '选择源码版本',
    EngineSourceBuildPhase.configuring => '准备编译',
    EngineSourceBuildPhase.building => '编译引擎',
    EngineSourceBuildPhase.inspecting => '核验编译结果',
    EngineSourceBuildPhase.complete => '构建完成',
    EngineSourceBuildPhase.failed => '构建失败',
    EngineSourceBuildPhase.cancelled => '构建已取消',
  };

  String _safe(String value) =>
      sealDebugJson({'message': value})['message'] as String;

  @override
  Widget build(BuildContext context) {
    final tools = _tools;
    final registered = _registered;
    final progress = _progress;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('从 Git 构建引擎'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('获取源码，在此 Mac 上编译并登记新的 llama.cpp 引擎。'),
                  const SizedBox(height: 6),
                  const Text('登记后可在模型库选择新引擎；已有模型继续使用当前引擎运行。'),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('engine-source-name'),
                    controller: _name,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '引擎名称'),
                    validator: (value) =>
                        value?.trim().isNotEmpty == true ? null : '请输入引擎名称',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('engine-source-address'),
                    controller: _source,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: '本地 Git 仓库路径或 GitHub 地址',
                    ),
                    validator: (value) =>
                        value?.trim().isNotEmpty == true ? null : '请输入仓库路径或地址',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('engine-source-ref'),
                    controller: _ref,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: '分支、标签或提交（可选）',
                      helperText: '留空使用仓库默认版本',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('engine-source-cmake'),
                    controller: _cmake,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'CMake 名称或可执行文件路径',
                      helperText: '可填写本机 CMake 路径；留空自动查找',
                    ),
                    onChanged: (_) => setState(() => _tools = null),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('engine-source-check-tools'),
                      onPressed: _busy ? null : _checkTools,
                      icon: const Icon(Icons.checklist),
                      label: Text(_checking ? '正在检查工具…' : '检查编译工具'),
                    ),
                  ),
                  if (tools != null) ...[
                    Text(
                      tools.available ? '编译工具检查通过' : '缺少编译工具',
                      key: const Key('engine-source-tools-status'),
                    ),
                    for (final missing in tools.missing) Text(_safe(missing)),
                    if (tools.executables.isNotEmpty)
                      ExpansionTile(
                        title: const Text('工具信息'),
                        children: [
                          for (final entry in tools.executables.entries)
                            ListTile(
                              title: Text(entry.key),
                              subtitle: SelectableText(
                                _safe(
                                  '${entry.value}\n${tools.versions[entry.key] ?? ''}',
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                  if (_busy) const LinearProgressIndicator(),
                  if (_busy)
                    Text(
                      _cancelRequested
                          ? '正在取消并收尾…'
                          : _checking
                          ? '检查编译工具…'
                          : progress == null
                          ? '准备构建…'
                          : _phase(progress.phase),
                      key: const Key('engine-source-phase'),
                    ),
                  if (_error != null)
                    Text(
                      _safe(_error!),
                      key: const Key('engine-source-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (registered != null) ...[
                    Text(
                      '已登记引擎：${registered.name}',
                      key: const Key('engine-source-success'),
                    ),
                    if (registered.path != null)
                      SelectableText(registered.path!),
                  ],
                  if (progress != null && progress.logText.isNotEmpty)
                    ExpansionTile(
                      key: const Key('engine-source-log'),
                      title: const Text('构建日志'),
                      children: [
                        SizedBox(
                          height: 200,
                          child: SingleChildScrollView(
                            child: SelectableText(_safe(progress.logText)),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (_busy)
            TextButton(
              key: const Key('engine-source-cancel'),
              onPressed: _cancelRequested ? null : _cancel,
              child: Text(_checking ? '取消检查' : '取消构建'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(registered == null ? '关闭' : '完成'),
            ),
          if (registered == null)
            FilledButton(
              key: const Key('engine-source-build'),
              onPressed: _busy ? null : _build,
              child: const Text('构建并登记'),
            ),
        ],
      ),
    );
  }
}
