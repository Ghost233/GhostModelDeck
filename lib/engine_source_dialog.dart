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
  DecisionCancellation? _cancellation;
  EngineSourceToolchain? _tools;
  String? _error;
  bool _checking = false;
  bool _cancelRequested = false;
  bool _supportsSystemone = true;

  bool get _busy => _checking;

  @override
  void dispose() {
    _cancellation?.cancel();
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

  void _build() {
    if (_busy || _form.currentState?.validate() != true) return;
    try {
      final operation = widget.catalog.buildFromSource(
        EngineSourceBuildRequest(
          source: _source.text.trim(),
          name: _name.text.trim(),
          ref: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
          cmakePath: _cmakePath,
          supportsSystemone: _supportsSystemone,
        ),
      );
      // The catalog owns the job and its error state after this form closes.
      unawaited(
        operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      Navigator.pop(context, true);
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  void _cancel() {
    setState(() => _cancelRequested = true);
    _cancellation?.cancel();
  }

  String _safe(String value) =>
      sealDebugJson({'message': value})['message'] as String;

  @override
  Widget build(BuildContext context) {
    final tools = _tools;
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
                  const Text('构建任务在下载页显示；登记后可给实例选择新引擎。'),
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
                  CheckboxListTile(
                    key: const Key('engine-source-systemone'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('此仓库与版本声明支持原生 JEV 接口'),
                    subtitle: const Text('通过 /v1/systemone 调用；实际不支持时显示引擎错误。'),
                    value: _supportsSystemone,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _supportsSystemone = value!;
                          }),
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
                      _cancelRequested ? '正在取消并收尾…' : '检查编译工具…',
                      key: const Key('engine-source-phase'),
                    ),
                  if (_error != null)
                    Text(
                      _safe(_error!),
                      key: const Key('engine-source-error'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
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
              child: const Text('取消检查'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
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
