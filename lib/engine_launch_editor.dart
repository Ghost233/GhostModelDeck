import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine_launch_configuration.dart';
import 'engine_parameter_recognition.dart';
import 'engine_runtime.dart';

class EngineLaunchCommandView extends StatelessWidget {
  const EngineLaunchCommandView({
    super.key,
    required this.command,
    this.title = '完整启动命令',
  });

  final EngineLaunchCommand command;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                command.isConfigurationOnly ? '配置参数结果（当前不可执行）' : title,
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: command.isConfigurationOnly ? '复制配置参数' : '复制命令',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: command.displayText),
                );
              },
            ),
          ],
        ),
        if (command.isConfigurationOnly)
          const Text('生产模型运行尚未接通；配置保存和识别不表示参数已实际生效。'),
        if (command.provisional)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '占位字段将在启动时确定，预览包含占位说明。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        SelectableText(
          command.displayText,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
        for (final notice in command.notices)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(notice, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

class EngineLaunchEditor extends StatefulWidget {
  const EngineLaunchEditor({
    super.key,
    required this.title,
    required this.initialConfiguration,
    required this.onSave,
    this.executable,
    this.modelPath,
    this.recognition,
  });

  final String title;
  final EngineLaunchConfiguration initialConfiguration;
  final Future<void> Function(EngineLaunchConfiguration configuration) onSave;
  final String? executable;
  final String? modelPath;
  final EngineParameterRecognition? recognition;

  @override
  State<EngineLaunchEditor> createState() => _EngineLaunchEditorState();
}

class _EngineLaunchEditorState extends State<EngineLaunchEditor> {
  late final Map<String, TextEditingController> _controllers;
  late final TextEditingController _argumentText;
  bool _saving = false;
  String? _error;

  EngineLaunchConfiguration get _configuration => EngineLaunchConfiguration(
    family: widget.initialConfiguration.family,
    argumentText: _argumentText.text,
    formValues: {
      for (final entry in _controllers.entries)
        if (entry.value.text.isNotEmpty) entry.key: entry.value.text,
    },
  );

  @override
  void initState() {
    super.initState();
    _argumentText = TextEditingController(
      text: widget.initialConfiguration.argumentText,
    );
    _controllers = {
      for (final name in EngineLaunchConfiguration.labelsFor(
        widget.initialConfiguration.family,
      ).keys)
        name: TextEditingController(
          text: widget.initialConfiguration.formValues[name] ?? '',
        ),
    };
  }

  @override
  void dispose() {
    _argumentText.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_configuration);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    EngineLaunchCommand? command;
    String? argumentError;
    try {
      command = _configuration.command(
        executable: widget.executable ?? '<安装后确定的引擎路径>',
        modelPath: widget.modelPath ?? '<运行时选择的模型路径>',
        recognition: widget.recognition,
      );
    } on LaunchArgumentTextException catch (error) {
      argumentError = error.toString();
    }
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 520,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.initialConfiguration.family == EngineFamily.omlx
                        ? '仅保存配置；生产模型运行尚未接通。清空表单项不生成自定义参数。'
                        : '保存后用于后续启动。清空表单项将使用引擎自身默认值。',
                  ),
                  const SizedBox(height: 16),
                  if (widget.recognition?.version != null)
                    Text('参数帮助版本：${widget.recognition!.version}'),
                  if (command == null || widget.executable == null)
                    for (final notice
                        in command?.notices ??
                            widget.recognition?.notices ??
                            <String>[])
                      Text(notice),
                  for (final field in EngineLaunchConfiguration.labelsFor(
                    widget.initialConfiguration.family,
                  ).entries)
                    Padding(
                      key: ValueKey('engine-parameter-form:${field.key}'),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: _controllers[field.key],
                        enabled: !_saving,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: field.value,
                          helperText:
                              widget.recognition?.descriptionFor(field.key) ==
                                  null
                              ? field.key
                              : '${widget.recognition!.descriptionFor(field.key)!.names.join(', ')} · ${widget.recognition!.descriptionFor(field.key)!.description}',
                          helperMaxLines: 3,
                          errorText:
                              (command?.overriddenForm.contains(field.key) ??
                                  false)
                              ? '已被文本覆盖'
                              : null,
                        ),
                      ),
                    ),
                  TextField(
                    key: const ValueKey('engine-argument-text'),
                    controller: _argumentText,
                    enabled: !_saving,
                    minLines: 3,
                    maxLines: 6,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: '启动参数文本',
                      helperText: '仅填写参数；文本优先，表单值仍保留。',
                      errorText: argumentError,
                      errorMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (argumentError == null &&
                      (widget.executable != null ||
                          command!.isConfigurationOnly))
                    EngineLaunchCommandView(command: command!)
                  else if (argumentError == null)
                    const Text('安装或关联引擎后显示完整启动命令。'),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中' : '保存'),
          ),
        ],
      ),
    );
  }
}
