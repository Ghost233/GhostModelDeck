import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine_launch_configuration.dart';
import 'engine_parameter_recognition.dart';
import 'parameter_editor.dart';

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
          const Text('当前编辑引擎默认参数；模型目录和运行地址在实例启动时确定。'),
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
  late final _argumentText = TextEditingController(
    text: widget.initialConfiguration.argumentText,
  );
  late final _values = Map<String, String>.from(
    widget.initialConfiguration.formValues,
  );
  bool _saving = false;
  String? _error;
  EngineLaunchConfiguration get _configuration => EngineLaunchConfiguration(
    family: widget.initialConfiguration.family,
    formValues: _values,
    argumentText: _argumentText.text,
  );
  @override
  void dispose() {
    _argumentText.dispose();
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
      if (mounted) setState(() => _error = '$error');
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
      argumentError = '$error';
    } on FormatException catch (error) {
      argumentError = error.message;
    }
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1080,
          height: (MediaQuery.sizeOf(context).height - 90)
              .clamp(380, 800)
              .toDouble(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text('保存引擎启动默认值；已保存的实例保留自己的参数快照。'),
                const SizedBox(height: 14),
                Expanded(
                  child: ParameterEditor(
                    family: _configuration.family,
                    formValues: _values,
                    initialFormValues: widget.initialConfiguration.formValues,
                    generationValues: const {},
                    initialGenerationValues: const {},
                    onGenerationChanged: (_) {},
                    onDrafterChanged: (_) {},
                    showGeneration: false,
                    showDrafter: false,
                    recognition: widget.recognition,
                    command: command,
                    enabled: !_saving,
                    onFormChanged: (values) => setState(() {
                      _values
                        ..clear()
                        ..addAll(values);
                    }),
                    argumentEditor: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const ValueKey('engine-argument-text'),
                          controller: _argumentText,
                          enabled: !_saving,
                          minLines: 3,
                          maxLines: 7,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: '可选启动参数文本',
                            helperText: '同名调优项仍为文本优先；常用及已知参数均可在分组中配置。',
                            errorText: argumentError,
                            errorMaxLines: 3,
                          ),
                        ),
                        const SizedBox(height: 15),
                        if (command != null)
                          EngineLaunchCommandView(command: command),
                      ],
                    ),
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Divider(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '保存中' : '保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
