import 'dart:convert';

import 'package:flutter/material.dart';

import 'drafter_configuration.dart';
import 'engine_launch_configuration.dart'
    show EngineLaunchCommand, LaunchArgumentTextException;
import 'engine_parameter_definitions.dart';
import 'engine_parameter_recognition.dart';
import 'engine_runtime.dart';
import 'generation_configuration.dart';
import 'parameter_value_field.dart';

const _generationFields = <EngineParameterDefinition>[
  EngineParameterDefinition(
    'temperature',
    '温度',
    'generation-basic',
    ParameterKind.decimal,
    initial: '1',
  ),
  EngineParameterDefinition(
    'max_tokens',
    '生成长度上限',
    'generation-basic',
    ParameterKind.integer,
    help: '继承当前默认，或明确关闭限制；关闭后由引擎按上下文决定。',
  ),
  EngineParameterDefinition(
    'seed',
    '随机种子',
    'generation-basic',
    ParameterKind.integer,
    help: '留空由引擎决定；-1 为随机种子。',
  ),
  EngineParameterDefinition(
    'top_k',
    'Top K 采样',
    'generation-sampling',
    ParameterKind.integer,
    initial: '20',
    help: '0 或 -1 关闭 Top K。',
  ),
  EngineParameterDefinition(
    'top_p',
    'Top P 采样',
    'generation-sampling',
    ParameterKind.decimal,
    initial: '0.95',
    help: '恢复默认可移除本项覆盖。',
  ),
  EngineParameterDefinition(
    'min_p',
    'Min P 采样',
    'generation-sampling',
    ParameterKind.decimal,
    initial: '0',
  ),
  EngineParameterDefinition(
    'repeat_penalty',
    '重复惩罚',
    'generation-sampling',
    ParameterKind.decimal,
    initial: '1',
    help: '1 表示不增加重复惩罚。',
  ),
  EngineParameterDefinition(
    'presence_penalty',
    '存在惩罚',
    'generation-sampling',
    ParameterKind.decimal,
    initial: '0',
  ),
  EngineParameterDefinition(
    'frequency_penalty',
    '频率惩罚',
    'generation-sampling',
    ParameterKind.decimal,
    initial: '0',
  ),
  EngineParameterDefinition(
    'stop',
    '停止字符串',
    'generation-output',
    ParameterKind.list,
    help: '逐项添加；当前 Splash 最多 4 个非空字符串。',
  ),
  EngineParameterDefinition(
    'ignore_eos',
    '忽略 EOS',
    'generation-output',
    ParameterKind.flag,
  ),
  EngineParameterDefinition(
    'response_format',
    '结构化输出',
    'generation-output',
    ParameterKind.choice,
    choices: ['text', 'json_object', 'json_schema'],
  ),
  EngineParameterDefinition(
    'reasoning_effort',
    '思考强度',
    'generation-thinking',
    ParameterKind.choice,
    choices: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
  ),
  EngineParameterDefinition(
    'thinking_token_budget',
    '思考 token 预算',
    'generation-thinking',
    ParameterKind.integer,
    help: 'Splash：-1 明确不限，0 不分配思考预算；缺省继承实例或已启动服务。需模板支持。',
  ),
  EngineParameterDefinition(
    'reasoning_budget_tokens',
    '思考 token 预算',
    'generation-thinking',
    ParameterKind.integer,
    help: 'llama.cpp：-1 继承已启动服务预算，0 不分配思考预算；不限需将服务预算设为 -1 后重启。需模板及思考结束标记支持。',
  ),
  EngineParameterDefinition(
    'preserve_reasoning',
    '保留历史思考',
    'generation-thinking',
    ParameterKind.flag,
    help: '写入模板 preserve_reasoning；是否生效取决于模板能力。',
  ),
  EngineParameterDefinition(
    'preserve_thinking',
    '保留历史思考',
    'generation-thinking',
    ParameterKind.flag,
  ),
  EngineParameterDefinition(
    'enable_thinking',
    '模板思考模式',
    'generation-thinking',
    ParameterKind.flag,
  ),
  EngineParameterDefinition(
    'priority',
    '请求优先级',
    'generation-request',
    ParameterKind.choice,
    choices: ['foreground', 'normal', 'background'],
  ),
  EngineParameterDefinition(
    'timeout',
    '单次请求时限（秒）',
    'generation-request',
    ParameterKind.decimal,
    help: '原生按请求时限与已启动服务上限的较短值执行；客户端或网关期限也可能先结束。',
  ),
  EngineParameterDefinition(
    'cache_salt',
    '缓存隔离标识',
    'generation-request',
    ParameterKind.text,
    help: '继承实例默认、明确使用共享缓存，或指定非空标识隔离缓存。',
  ),
];
const _llamaGenerationOnly = {'reasoning_budget_tokens', 'preserve_reasoning'};
const _splashGenerationOnly = {
  'thinking_token_budget',
  'preserve_thinking',
  'priority',
  'timeout',
  'cache_salt',
};
const _generationGroups = {
  'generation-basic': '基本生成',
  'generation-sampling': '采样与惩罚',
  'generation-output': '停止与输出',
  'generation-thinking': '思考与模板',
  'generation-request': '请求与调度',
};

List<EngineParameterDefinition> generationFields(EngineFamily family) =>
    _generationFields
        .where(
          (f) => family == EngineFamily.omlx
              ? ['temperature', 'top_p', 'max_tokens'].contains(f.name)
              : family == EngineFamily.splash
              ? !_llamaGenerationOnly.contains(f.name)
              : !_splashGenerationOnly.contains(f.name),
        )
        .toList();

/// Used by instance defaults and the ordinary HTTP playground overrides.
class GenerationSettingsFields extends StatelessWidget {
  const GenerationSettingsFields({
    super.key,
    required this.family,
    required this.values,
    required this.onChanged,
    this.group,
    this.query = '',
    this.enabled = true,
    this.parameterPrefix = 'generation',
    this.collapsed = false,
    this.inheritLabel = '继承引擎默认',
    this.inheritedValues = const {},
  });
  final EngineFamily family;
  final Map<String, Object?> values;
  final ValueChanged<Map<String, Object?>> onChanged;
  final String? group;
  final String query, parameterPrefix, inheritLabel;
  final Map<String, Object?> inheritedValues;
  final bool enabled, collapsed;

  void _set(String key, Object? value, {bool explicitNull = false}) {
    final next = Map<String, Object?>.from(values);
    if (value == null && !explicitNull) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    onChanged(next);
  }

  Map<String, Object?> get _template => values['chat_template_kwargs'] is Map
      ? Map<String, Object?>.from(values['chat_template_kwargs'] as Map)
      : !values.containsKey('chat_template_kwargs') &&
            inheritedValues['chat_template_kwargs'] is Map
      ? Map<String, Object?>.from(
          inheritedValues['chat_template_kwargs'] as Map,
        )
      : {};
  Widget _field(EngineParameterDefinition f) {
    Object? value = values[f.name];
    if (['enable_thinking', 'preserve_reasoning'].contains(f.name)) {
      value = values['chat_template_kwargs'] is Map ? _template[f.name] : null;
    }
    if (f.name == 'preserve_thinking' &&
        _template.containsKey('preserve_thinking')) {
      value = _template['preserve_thinking'];
    }
    if (f.name == 'response_format') {
      value = values['response_format'] is Map
          ? (values['response_format'] as Map)['type']
          : null;
    }
    final bounded = switch (f.name) {
      'temperature' => (0.0, 2.0),
      'top_p' => (
        family == EngineFamily.splash
            ? GenerationConfiguration.minPositiveFloat32
            : 0.0,
        1.0,
      ),
      'min_p' => (0.0, 1.0),
      'presence_penalty' || 'frequency_penalty' => (-2.0, 2.0),
      'repeat_penalty' => (GenerationConfiguration.minPositiveFloat32, 2.0),
      _ => (null, null),
    };
    final budget = GenerationConfiguration.disabledThinkingValues.containsKey(
      f.name,
    );
    final nativeDefault = GenerationConfiguration.nativeDefaultValues.contains(
      f.name,
    );
    final optional =
        family != EngineFamily.omlx &&
        (f.name == 'max_tokens' ||
            budget ||
            nativeDefault ||
            GenerationConfiguration.disabledSamplingValues.containsKey(f.name));
    final mode = !optional
        ? null
        : !values.containsKey(f.name)
        ? ParameterValueMode.inherit
        : value == null
        ? ParameterValueMode.off
        : budget && value == -1
        ? family == EngineFamily.splash
              ? ParameterValueMode.unlimited
              : ParameterValueMode.nativeDefault
        : ParameterValueMode.custom;
    final neutral =
        GenerationConfiguration.disabledSamplingValues[f.name] ??
        GenerationConfiguration.disabledThinkingValues[f.name];
    final templateFlag = [
      'enable_thinking',
      'preserve_reasoning',
    ].contains(f.name);
    final templateControl = templateFlag || f.name == 'preserve_thinking';
    final inherited = templateFlag
        ? (inheritedValues['chat_template_kwargs'] is Map
              ? (inheritedValues['chat_template_kwargs'] as Map)[f.name]
              : null)
        : inheritedValues[f.name];
    return ParameterValueField(
      key: ValueKey('$parameterPrefix:${f.name}'),
      id: '$parameterPrefix:${f.name}',
      definition: f,
      value: mode == ParameterValueMode.off ? neutral : value,
      valueMode: mode,
      valueModeChoices: budget
          ? [
              (ParameterValueMode.inherit, inheritLabel),
              (ParameterValueMode.off, '不分配思考 token（0）'),
              if (family == EngineFamily.splash)
                (ParameterValueMode.unlimited, '不限（-1）')
              else
                (ParameterValueMode.nativeDefault, '继承服务预算（-1）'),
              (ParameterValueMode.custom, '指定预算'),
            ]
          : nativeDefault
          ? [
              (ParameterValueMode.inherit, inheritLabel),
              (
                ParameterValueMode.off,
                f.name == 'cache_salt' ? '共享缓存（不隔离）' : '使用服务时限',
              ),
              (
                ParameterValueMode.custom,
                f.name == 'cache_salt' ? '指定隔离标识' : '指定秒数',
              ),
            ]
          : null,
      onModeChanged: (mode) {
        switch (mode) {
          case ParameterValueMode.inherit:
            _set(f.name, null);
          case ParameterValueMode.off:
            _set(f.name, null, explicitNull: true);
          case ParameterValueMode.unlimited:
          case ParameterValueMode.nativeDefault:
            _set(f.name, -1);
          case ParameterValueMode.custom:
            _set(
              f.name,
              f.name == 'cache_salt'
                  ? (value is String
                        ? value
                        : inherited is String
                        ? inherited
                        : '')
                  : budget
                  ? (value is num && value > 0
                        ? value
                        : inherited is num && inherited > 0
                        ? inherited
                        : 1)
                  : value ??
                        (inherited is num
                            ? inherited
                            : num.tryParse(f.initial) ?? 1),
            );
        }
      },
      inheritLabel: templateFlag && values.containsKey('chat_template_kwargs')
          ? '继承服务模板默认'
          : inheritLabel,
      inheritedValue: inherited,
      disabled:
          !enabled ||
          templateControl &&
              values.containsKey('chat_template_kwargs') &&
              values['chat_template_kwargs'] is! Map,
      sliderMin: bounded.$1,
      sliderMax: bounded.$2,
      sliderStep: bounded.$1 == null ? null : .01,
      onChanged: (v) {
        if (templateFlag) {
          final map = _template;
          if (v == null) {
            map.remove(f.name);
          } else {
            map[f.name] = v;
          }
          if (v != null || values.containsKey('chat_template_kwargs')) {
            _set('chat_template_kwargs', map);
          }
        } else if (f.name == 'preserve_thinking' &&
            _template.containsKey('preserve_thinking')) {
          final next = Map<String, Object?>.from(values);
          next['chat_template_kwargs'] = _template..remove('preserve_thinking');
          if (v == null) {
            next.remove(f.name);
          } else {
            next[f.name] = v;
          }
          onChanged(next);
        } else if (f.name == 'response_format') {
          final previous = values[f.name];
          if (previous is Map && previous['type'] == v) return;
          if (v == null) {
            _set(f.name, null);
            return;
          }
          _set(f.name, {
            'type': v,
            if (v == 'json_schema')
              'json_schema': {
                'name': 'response',
                'schema': <String, Object?>{},
              },
          });
        } else {
          _set(f.name, v);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = generationFields(family)
        .where(
          (f) =>
              (group == null || f.group == group) &&
              (query.isEmpty ||
                  '${f.label} ${f.name}'.toLowerCase().contains(
                    query.toLowerCase(),
                  )),
        )
        .toList();
    final widgets = <Widget>[];
    for (final key in _generationGroups.keys) {
      final selected = all.where((f) => f.group == key).toList();
      if (selected.isEmpty) continue;
      final rows = <Widget>[for (final f in selected) _field(f)];
      if (key == 'generation-output' &&
          values['response_format'] is Map &&
          (values['response_format'] as Map)['type'] == 'json_schema') {
        final format = values['response_format'] as Map;
        final config = format['json_schema'];
        final schema = config is Map ? config['schema'] : null;
        rows.add(
          ParameterObjectField(
            key: ValueKey('$parameterPrefix:schema'),
            id: '$parameterPrefix:schema',
            label: 'JSON Schema',
            value: schema,
            disabled: !enabled,
            onChanged: (v) => _set('response_format', {
              ...Map<String, Object?>.from(format),
              'type': 'json_schema',
              'json_schema': {
                if (config is Map) ...Map<String, Object?>.from(config),
                'name': config is Map
                    ? config['name'] ?? 'response'
                    : 'response',
                'schema': v,
              },
            }),
          ),
        );
      }
      if (key == 'generation-thinking' && family != EngineFamily.omlx) {
        rows.add(
          Text(
            family == EngineFamily.splash
                ? '模板 enable_thinking 的显式值优先于思考强度；历史思考和模板选项是否生效取决于模板能力。'
                : 'llama.cpp 的 reasoning_effort=none 会关闭模板思考；预算 -1 继承已启动服务预算。模板选项是否生效取决于模板能力。',
          ),
        );
        rows.add(
          ParameterObjectField(
            id: '$parameterPrefix:template',
            label: '模板附加字段',
            value: values['chat_template_kwargs'],
            disabled: !enabled,
            onChanged: (v) => _set('chat_template_kwargs', v),
          ),
        );
      }
      if (collapsed) {
        widgets.add(
          ExpansionTile(
            title: Text(_generationGroups[key]!),
            initiallyExpanded: key == 'generation-basic',
            children: rows,
          ),
        );
      } else {
        widgets.addAll(rows);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }
}

class ParameterEditor extends StatefulWidget {
  const ParameterEditor({
    super.key,
    required this.family,
    required this.formValues,
    required this.onFormChanged,
    required this.generationValues,
    required this.onGenerationChanged,
    required this.onDrafterChanged,
    this.onDrafterSourceConfirmed,
    this.drafter,
    this.check,
    this.actualDrafter,
    this.actualCompact,
    this.onCheckDrafter,
    this.recognition,
    this.command,
    this.argumentEditor,
    this.initialFormValues = const {},
    this.initialGenerationValues = const {},
    this.initialDrafter,
    this.capacityChanges = const [],
    this.enabled = true,
    this.showGeneration = true,
    this.showDrafter = true,
    this.decisionModel = false,
    this.legacyDrafter = false,
  });
  final EngineFamily family;
  final Map<String, String> formValues, initialFormValues;
  final Map<String, Object?> generationValues, initialGenerationValues;
  final ValueChanged<Map<String, String>> onFormChanged;
  final ValueChanged<Map<String, Object?>> onGenerationChanged;
  final DrafterConfiguration? drafter;
  final DrafterConfiguration? initialDrafter;
  final List<({String label, int? before, int? after})> capacityChanges;
  final ValueChanged<DrafterConfiguration> onDrafterChanged;
  final VoidCallback? onDrafterSourceConfirmed;
  final DrafterCheck? check, actualDrafter;
  final String? actualCompact;
  final Future<void> Function()? onCheckDrafter;
  final EngineParameterRecognition? recognition;
  final EngineLaunchCommand? command;
  final Widget? argumentEditor;
  final bool enabled, showGeneration, showDrafter, decisionModel, legacyDrafter;
  @override
  State<ParameterEditor> createState() => _ParameterEditorState();
}

class _ParameterEditorState extends State<ParameterEditor> {
  String? _selected;
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  int _capacityPage = 0;
  static const _invertedFlags = {'--disable-ane', '--no-webui'};
  List<EngineParameterDefinition> get _definitions =>
      EngineParameterDefinitions.forEngine(
        widget.family,
        recognition: widget.recognition,
      );
  Map<String, String> get _groups => {
    if (widget.showGeneration)
      for (final key in _generationGroups.keys)
        if (generationFields(widget.family).any((f) => f.group == key))
          key: _generationGroups[key]!,
    for (final key in EngineParameterDefinitions.groupLabels.keys)
      if ((key != 'draft' || widget.showDrafter) &&
              _definitions.any((f) => f.group == key) ||
          key == 'draft' && widget.showDrafter)
        key: key == 'compute' && widget.family == EngineFamily.splash
            ? '计算与 ANE'
            : EngineParameterDefinitions.groupLabels[key]!,
    if (widget.argumentEditor != null) 'command': '参数文本与命令',
  };
  void _setForm(String key, Object? value) {
    final next = Map<String, String>.from(widget.formValues);
    if (value == null) {
      next.remove(key);
    } else if (value is List) {
      next[key] = jsonEncode(value);
    } else if (_invertedFlags.contains(key) && value is bool) {
      next[key] = '${!value}';
    } else {
      next[key] = '$value';
    }
    widget.onFormChanged(next);
  }

  bool _matches(EngineParameterDefinition f) =>
      _query.isEmpty ||
      '${f.label} ${f.name} ${f.help}'.toLowerCase().contains(
        _query.toLowerCase(),
      );
  String? _loadingValue(String name) {
    final arguments = widget.command?.arguments;
    String canonical(String option) =>
        widget.recognition?.canonicalName(option) ?? option;
    if (arguments != null &&
        (widget.command!.overriddenForm.contains(name) ||
            !(widget.formValues[name]?.isNotEmpty ?? false))) {
      if (['--persistent-cache', '--disable-ane'].contains(name)) {
        return '${arguments.any((argument) => canonical(argument.split('=').first) == name)}';
      }
      for (var index = arguments.length - 1; index >= 0; index--) {
        final argument = arguments[index];
        final separator = argument.indexOf('=');
        final option = separator < 0
            ? argument
            : argument.substring(0, separator);
        if (canonical(option) != name) continue;
        if (separator >= 0) return argument.substring(separator + 1);
        if (index + 1 < arguments.length) return arguments[index + 1];
      }
    }
    return widget.formValues[name] ??
        _definitions.where((field) => field.name == name).firstOrNull?.initial;
  }

  String? _loadingNotice(EngineParameterDefinition field) {
    if (widget.family != EngineFamily.splash) return null;
    if (field.name == '--prompt-lookup-min-match') {
      return _loadingValue('--prompt-lookup') == 'off'
          ? '提示查找关闭，本项当前不适用；已填值会保留。'
          : '匹配长度仅在原生提示查找可用时生效；保存配置不能证明实际匹配命中。';
    }
    if (field.name == '--prompt-lookup') {
      if (_loadingValue(field.name) == 'on') {
        return widget.drafter?.enabled == true
            ? '提示查找已请求开启，实际使用需要原生草稿验证路径；是否命中须看原生报告。'
            : '下次启动未选择草稿验证路径，提示查找不会实际使用；保留请求设置供后续启用。';
      }
      return '下次启动关闭提示查找；最小匹配设置仍保留。';
    }
    if (field.name == '--fast-topk') {
      if (_loadingValue(field.name) != 'on') {
        return '下次启动关闭 Fast Top K；通用采样参数仍独立生效。';
      }
      num? configured(String key) {
        if (!widget.generationValues.containsKey(key)) return null;
        final value = widget.generationValues[key];
        return value is num
            ? value
            : value == null
            ? GenerationConfiguration.disabledSamplingValues[key]
            : null;
      }

      final topK = configured('top_k');
      final minP = configured('min_p');
      final unavailable =
          topK != null && (topK < 1 || topK > 32) ||
          minP != null && minP != 0 ||
          widget.generationValues['temperature'] == 0;
      return '${unavailable ? '实例默认不满足快速路径条件，相关请求正常使用常规路径。' : ''}'
          '仅采样 lane、Top K 1～32 且 Min P 0 可使用；单次覆盖以实际请求为准。实际命中未知，须读取原生选择和回退计数。';
    }
    if (field.name == '--encoder-option-queries' && !widget.decisionModel) {
      return '仅适用于 ModernBERT 决策编码器；当前配置未指定决策用途，不据此声明该能力已启用。';
    }
    if (field.name == '--persistent-cache' &&
        _loadingValue('--persistent-cache') == 'true' &&
        _loadingValue('--max-cache-disk') == '0') {
      return '持久缓存需要启用磁盘缓存；请改为自动或指定非零容量，或关闭持久缓存。';
    }
    if (field.name == '--ane-ffn-minimum-rows' &&
        (widget.formValues[field.name]?.isNotEmpty ?? false) &&
        ['auto', null, ''].contains(_loadingValue('--ane-ffn-share'))) {
      return 'ANE 最小提交行数需要固定 FFN 分担比例；请指定份额，或清除行数以继承原生默认。';
    }
    if (field.name == '--ane-recovery-max-power-percent' &&
        _loadingValue('--ane-power-recovery') == 'on' &&
        (widget.formValues[field.name]?.isNotEmpty ?? false) &&
        ['off', null, ''].contains(_loadingValue('--ane-power-reference'))) {
      return '功耗百分比需要有效功耗参考；请选择自动或指定瓦数，或清除百分比以使用绝对阈值。';
    }
    return null;
  }

  String? _compactNotice(EngineParameterDefinition field) {
    if (widget.family != EngineFamily.splash ||
        field.name != '--compact-draft-head') {
      return null;
    }
    if (widget.drafter?.enabled != true) {
      return '草稿模型已关闭；保留 compact 设置，不读取 ranking 或应用草稿优化。';
    }
    if (_loadingValue(field.name) != 'on') {
      return 'compact 已关闭；ranking 和容量不适用，原值保留。留空继承当前引擎默认关闭。';
    }
    return 'compact 已请求开启；文件检查和原生验证分别记录，实际使用仍取决于原生请求条件。';
  }

  Widget _parameter(EngineParameterDefinition f) {
    if (f.kind == ParameterKind.tuple) {
      final raw = widget.formValues[f.name];
      List<String> values;
      try {
        values = raw == null || raw.isEmpty ? [] : f.tupleValues(raw);
      } on FormatException {
        values = [raw!];
      } on LaunchArgumentTextException {
        values = [raw!];
      }
      final parts = [
        for (var index = 0; index < f.valueHints.length; index++)
          index < values.length ? values[index] : '',
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(f.label),
          for (final (index, hint) in f.valueHints.indexed)
            ParameterValueField(
              key: ValueKey('loading:${f.name}:$index'),
              id: '${f.name}:$index',
              definition: EngineParameterDefinition(
                f.name,
                hint,
                f.group,
                RegExp(r'^(START|END|N|INT|COUNT|TOKENS)$').hasMatch(hint)
                    ? ParameterKind.integer
                    : ParameterKind.text,
                help: f.help,
              ),
              value: parts[index],
              disabled:
                  !widget.enabled ||
                  f.managed ||
                  f.group == 'draft' &&
                      (widget.drafter?.enabled != true ||
                          (widget.family == EngineFamily.splash &&
                              widget.decisionModel)),
              overridden:
                  widget.command?.overriddenForm.contains(f.name) ?? false,
              onChanged: (value) {
                final next = [...parts];
                next[index] = value?.toString() ?? '';
                _setForm(
                  f.name,
                  next.every((part) => part.isEmpty) ? null : next,
                );
              },
            ),
        ],
      );
    }
    Object? value = widget.formValues[f.name];
    if (_invertedFlags.contains(f.name) && ['true', 'false'].contains(value)) {
      value = value != 'true';
    }
    if (f.kind == ParameterKind.list && value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        value = [value];
      }
    }
    final disabled =
        !widget.enabled ||
        f.managed ||
        f.group == 'draft' &&
            (widget.drafter?.enabled != true ||
                (widget.family == EngineFamily.splash &&
                    widget.decisionModel)) ||
        f.name == '--spec-type' && widget.drafter?.enabled == true ||
        widget.family == EngineFamily.splash &&
            {
              '--compact-draft-ranking',
              '--compact-draft-capacity',
            }.contains(f.name) &&
            _loadingValue('--compact-draft-head') != 'on';
    final notice = _compactNotice(f) ?? _loadingNotice(f);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ParameterValueField(
          key: ValueKey('loading:${f.name}'),
          id: f.name,
          definition: f,
          sliderStep: f.name == '--compact-draft-capacity' ? 256 : null,
          value: value,
          disabled: disabled,
          overridden: widget.command?.overriddenForm.contains(f.name) ?? false,
          onChanged: (v) => _setForm(f.name, v),
        ),
        if (notice != null) _notice(notice),
      ],
    );
  }

  void _setDraft({
    bool? enabled,
    String? path,
    String? mode,
    bool clearPath = false,
    bool sourceConfirmed = false,
  }) {
    if (sourceConfirmed || enabled == false) {
      widget.onDrafterSourceConfirmed?.call();
    }
    widget.onDrafterChanged(
      DrafterConfiguration(
        enabled: enabled ?? widget.drafter?.enabled ?? false,
        path: clearPath || widget.legacyDrafter && enabled == false
            ? null
            : path ?? widget.drafter?.path,
        mode: mode ?? widget.drafter?.mode,
      ),
    );
  }

  Widget _draftBody() {
    final d = widget.drafter;
    final splash = widget.family == EngineFamily.splash;
    final unsupported = splash && widget.decisionModel;
    final nativeHelp = switch (d?.mode) {
      'draft-mtp' => '可留空，使用目标模型内嵌 MTP；也可选择独立 GGUF。留空时设备与线程随目标模型。',
      'draft-eagle3' => '选择 EAGLE3 专用草稿 GGUF；兼容性由 llama.cpp 加载时判断。',
      'draft-dflash' => '选择 DFlash 草稿 GGUF；兼容性由 llama.cpp 加载时判断。',
      'draft-dspark' => '选择 DSpark 草稿 GGUF；兼容性由 llama.cpp 加载时判断。',
      _ => '选择独立草稿 GGUF；分片模型选择首片，兼容性由 llama.cpp 加载时判断。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.legacyDrafter)
          _notice('旧草稿绑定待确认或修复。请选择本地来源，或在支持的模型上关闭草稿。', error: true),
        if (unsupported)
          _notice('当前决策路径不支持草稿模型。保存的来源不会自动应用。')
        else
          _notice(
            splash
                ? '原生检查决定当前模型是否允许关闭草稿，以及所选 DFlash / DFlash2 是否匹配。'
                : '按所选草稿模式生成启动参数，实际支持与运行结果由 llama.cpp 判断。',
          ),
        SwitchListTile(
          key: const Key('splash-drafter-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('使用草稿模型'),
          value: d?.enabled ?? false,
          onChanged: !widget.enabled || unsupported
              ? null
              : (v) => _setDraft(enabled: v),
        ),
        ParameterValueField(
          id: 'drafter-path',
          definition: EngineParameterDefinition(
            'drafter-path',
            splash
                ? '草稿模型目录'
                : d?.mode == 'draft-mtp'
                ? '独立 GGUF 草稿模型（可选）'
                : 'GGUF 草稿模型',
            'draft',
            splash ? ParameterKind.directory : ParameterKind.file,
            help: splash
                ? '选择包含 config.json 和原始 safetensors 权重的目录。'
                : nativeHelp,
          ),
          value: d?.path,
          disabled: !widget.enabled || d?.enabled != true || unsupported,
          onChanged: (v) => _setDraft(
            path: v as String?,
            clearPath: v == null,
            sourceConfirmed: true,
          ),
        ),
        if (!splash)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const Expanded(child: Text('草稿模式')),
                SizedBox(
                  width: 230,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 1,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: const Key('drafter-mode'),
                        isExpanded: true,
                        value: d?.mode ?? '',
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('请选择草稿模式'),
                          ),
                          for (final mode in DrafterConfiguration.modes.entries)
                            DropdownMenuItem(
                              value: mode.key,
                              child: Text(mode.value),
                            ),
                        ],
                        onChanged:
                            !widget.enabled || d?.enabled != true || unsupported
                            ? null
                            : (v) {
                                if (v != null && v.isNotEmpty) {
                                  _setDraft(mode: v);
                                }
                              },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (splash)
          const Text('草稿执行长度由实际引擎编译定义。', style: TextStyle(fontSize: 12)),
        ..._definitionRows(
          _definitions.where((f) => f.group == 'draft').toList(),
        ),
        const SizedBox(height: 15),
        const Text('启动检查列表', style: TextStyle(fontWeight: FontWeight.w600)),
        _statusRow('请求开关', d?.enabled == true ? '开启' : '关闭'),
        _statusRow('上次实际阶段', widget.check?.label ?? '尚未检查'),
        _statusRow(
          '来源',
          d?.enabled == true
              ? widget.check?.source ??
                    d?.path ??
                    (!splash && d?.usesEmbeddedTarget == true
                        ? '目标模型内嵌 MTP'
                        : '未选择')
              : '不加载草稿资源',
        ),
        _statusRow('类型 / 模式', widget.check?.type ?? d?.mode ?? '尚未核验'),
        if (widget.check?.error != null)
          _notice(widget.check!.error!, error: true),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: widget.enabled ? widget.onCheckDrafter : null,
            child: Text(splash ? '检查模型与草稿准备' : '检查所选资源'),
          ),
        ),
      ],
    );
  }

  Widget _notice(String text, {bool error = false}) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: error
          ? Theme.of(context).colorScheme.error.withValues(alpha: .07)
          : Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: error ? Theme.of(context).colorScheme.error : null),
    ),
  );
  Widget _statusRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
  List<Widget> _definitionRows(List<EngineParameterDefinition> fields) {
    final filtered = fields.where(_matches).toList();
    return [
      for (final f in filtered.where((f) => !f.advanced)) _parameter(f),
      if (widget.recognition?.hasObservedHelp == true &&
          filtered.any((f) => !widget.recognition!.recognizes(f.name)))
        _notice('本组含当前版本帮助尚未确认的选项；留空继承默认，指定值会在启动时由引擎校验。'),
      if (filtered.any((f) => f.advanced))
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('更多参数', style: TextStyle(fontSize: 13)),
          initiallyExpanded: _query.isNotEmpty,
          children: [
            for (final f in filtered.where((f) => f.advanced)) _parameter(f),
          ],
        ),
    ];
  }

  Widget _groupBody(String id) {
    if (id.startsWith('generation-')) {
      if (widget.decisionModel) return _notice('当前决策路径不使用普通文本生成参数。');
      return GenerationSettingsFields(
        family: widget.family,
        values: widget.generationValues,
        onChanged: widget.onGenerationChanged,
        group: id,
        query: _query,
        enabled: widget.enabled,
      );
    }
    if (id == 'draft') return _draftBody();
    if (id == 'command') {
      return widget.argumentEditor ?? const SizedBox.shrink();
    }
    if (id == 'managed') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _notice('监听、模型身份、原生程序和运行目录由软件分配；实际命令在启动时记录。'),
          for (final f in _definitions.where((f) => f.managed && _matches(f)))
            _statusRow(f.label, f.help.isEmpty ? '由 GMD 管理' : f.help),
        ],
      );
    }
    if (id == 'lookup' &&
        widget.family == EngineFamily.llamaCpp &&
        widget.drafter?.enabled == true) {
      return Column(
        children: [
          _notice('本次只运行所选草稿模式。ngram 的配置保留，关闭草稿后可生效。'),
          ..._definitionRows(_definitions.where((f) => f.group == id).toList()),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _definitionRows(
        _definitions.where((f) => f.group == id && !f.managed).toList(),
      ),
    );
  }

  Widget _section(String id) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              _groups[id] ?? id,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Text(
            id.startsWith('generation-') ? '下次请求生效' : '重启后生效',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: id.startsWith('generation-')
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _groupBody(id),
    ],
  );
  List<String> get _changes => [
    if (jsonEncode(widget.drafter?.toJson()) !=
        jsonEncode(widget.initialDrafter?.toJson()))
      '加载 · 草稿模型配置',
    for (final key in {
      ...widget.formValues.keys,
      ...widget.initialFormValues.keys,
    })
      if ((widget.formValues[key] ?? '') !=
          (widget.initialFormValues[key] ?? ''))
        '加载 · ${_definitions.where((f) => f.name == key).firstOrNull?.label ?? key}',
    for (final key in {
      ...widget.generationValues.keys,
      ...widget.initialGenerationValues.keys,
    })
      if (jsonEncode(widget.generationValues[key]) !=
          jsonEncode(widget.initialGenerationValues[key]))
        '生成 · ${_generationFields.where((f) => f.name == key).firstOrNull?.label ?? key}',
  ];
  Widget _summary() {
    final pages = (widget.capacityChanges.length / 5).ceil();
    final page = _capacityPage.clamp(0, pages == 0 ? 0 : pages - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('修改与生效', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        Text(
          _changes.isEmpty ? '当前参数与初始值一致' : '${_changes.length} 项参数已修改',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        for (final text in _changes.take(12))
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        const Divider(height: 26),
        _notice('单次请求显式值 → 实例生成默认值 → 引擎默认值'),
        Text(
          '加载与草稿资源：重启后生效。\n生成默认值：保存后用于下一次请求。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (widget.showDrafter) ...[
          const Divider(height: 26),
          _statusRow('草稿', widget.drafter?.enabled == true ? '已请求开启' : '关闭'),
          _statusRow('检查', widget.check?.label ?? '尚未检查'),
          _statusRow('当前运行', widget.actualDrafter?.label ?? '无就绪运行实例'),
          if (widget.actualDrafter?.source != null)
            _statusRow('实际来源', widget.actualDrafter!.source!),
          if (widget.actualDrafter?.type != null)
            _statusRow('实际类型', widget.actualDrafter!.type!),
          if (widget.actualCompact != null)
            _statusRow('compact 实际状态', widget.actualCompact!),
        ],
        if (widget.capacityChanges.isNotEmpty) ...[
          const Divider(height: 26),
          const Text('容量预览（重启生效）'),
          for (final change in widget.capacityChanges.skip(page * 5).take(5))
            Text(
              '${change.label}：${change.before ?? '未指定'} → ${change.after ?? '未指定'}',
              key: ValueKey('context-preview:${change.label}'),
            ),
          if (pages > 1)
            Row(
              children: [
                TextButton(
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _capacityPage = page - 1),
                  child: const Text('上一页'),
                ),
                Text('${page + 1} / $pages'),
                TextButton(
                  onPressed: page + 1 == pages
                      ? null
                      : () => setState(() => _capacityPage = page + 1),
                  child: const Text('下一页'),
                ),
              ],
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final selected = groups.containsKey(_selected)
        ? _selected!
        : groups.keys.first;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('parameter-search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '查找参数…',
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('修改与生效'),
                    content: SizedBox(
                      width: 380,
                      child: SingleChildScrollView(child: _summary()),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                child: const Text('状态与生效'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 160,
                  child: ListView(
                    key: const Key('parameter-group-navigation'),
                    children: [
                      for (final group in groups.entries)
                        ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          selected: group.key == selected && _query.isEmpty,
                          selectedTileColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: .07),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          title: Text(
                            group.value,
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () {
                            setState(() {
                              _selected = group.key;
                              _query = '';
                              _search.clear();
                            });
                          },
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 24),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('parameter-scroll:$selected:$_query'),
                    padding: const EdgeInsets.only(right: 12, bottom: 20),
                    child: _query.isEmpty
                        ? _section(selected)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final id in groups.keys.where(
                                (id) =>
                                    id != 'command' &&
                                    id != 'managed' &&
                                    (id.startsWith('generation-')
                                        ? generationFields(widget.family).any(
                                            (f) => f.group == id && _matches(f),
                                          )
                                        : _definitions.any(
                                            (f) => f.group == id && _matches(f),
                                          )),
                              ))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: _section(id),
                                ),
                            ],
                          ),
                  ),
                ),
                if (constraints.maxWidth > 1050) ...[
                  const VerticalDivider(width: 24),
                  SizedBox(
                    width: 210,
                    child: SingleChildScrollView(child: _summary()),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
