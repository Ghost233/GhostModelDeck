import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine_parameter_definitions.dart';
import 'generation_seed.dart';

enum ParameterValueMode { inherit, off, unlimited, nativeDefault, custom }

/// A typed value editor. File selection is UI; inspection stays in runtimes.
class ParameterValueField extends StatefulWidget {
  const ParameterValueField({
    super.key,
    required this.id,
    required this.definition,
    required this.value,
    required this.onChanged,
    this.disabled = false,
    this.overridden = false,
    this.sliderMin,
    this.sliderMax,
    this.sliderStep,
    this.inheritLabel = '继承引擎默认',
    this.inheritedValue,
    this.valueMode,
    this.onModeChanged,
    this.valueModeChoices,
  });
  final String id;
  final String inheritLabel;
  final Object? inheritedValue;
  final ParameterValueMode? valueMode;
  final ValueChanged<ParameterValueMode>? onModeChanged;
  final List<(ParameterValueMode, String)>? valueModeChoices;
  final EngineParameterDefinition definition;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final bool disabled;
  final bool overridden;
  final double? sliderMin, sliderMax, sliderStep;
  @override
  State<ParameterValueField> createState() => _ParameterValueFieldState();
}

class _ParameterValueFieldState extends State<ParameterValueField> {
  late final _text = TextEditingController(text: _display(widget.value));
  final _tag = TextEditingController();
  final _amount = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _customChoice = false;
  bool get _integer =>
      d.kind == ParameterKind.integer ||
      ['--n-gpu-layers', '--spec-draft-ngl'].contains(d.name);
  String _quantityMode = 'inherit', _unit = '';
  static const _json = JsonEncoder.withIndent('  ');
  static String _display(Object? value) => value == null
      ? ''
      : value is Map || value is List
      ? _json.convert(value)
      : '$value';
  EngineParameterDefinition get d => widget.definition;
  @override
  void initState() {
    super.initState();
    _readQuantity();
  }

  void _readQuantity() {
    final raw = widget.value?.toString();
    _quantityMode = raw == null || raw.isEmpty
        ? 'inherit'
        : raw == 'auto'
        ? 'auto'
        : ['off', '0'].contains(raw)
        ? 'off'
        : 'custom';
    if (_quantityMode == 'custom') {
      final match = RegExp(r'^([+]?\d+(?:\.\d+)?)([A-Za-z]*)$')
          .firstMatch(raw!);
      _amount.text = match?[1] ?? raw;
      _unit = match?[2] ?? '';
    }
  }

  @override
  void didUpdateWidget(ParameterValueField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && (!_focus.hasFocus || widget.disabled)) {
      _text.text = _display(widget.value);
      _readQuantity();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _tag.dispose();
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _number(String text) {
    final parsed = d.name == 'seed'
        ? parseGenerationSeed(text)
        : _integer
        ? int.tryParse(text)
        : double.tryParse(text);
    final value =
        parsed is ExactGenerationSeed || parsed is num && parsed.isFinite
        ? parsed
        : null;
    setState(
      () => _error = value == null ? '请输入${_integer ? '整数' : '数值'}' : null,
    );
    widget.onChanged(value ?? text);
  }

  Future<void> _pick() async {
    try {
      final method = d.kind == ParameterKind.directory
          ? 'pickLibraryDirectory'
          : 'pickParameterFile';
      final path =
          await const MethodChannel('com.ghost233.ghostmodeldeck/native')
              .invokeMethod<String>(
                method,
                d.name == 'drafter-path' && d.kind == ParameterKind.file
                    ? {
                        'extensions': ['gguf'],
                      }
                    : null,
              );
      if (!mounted || path == null) return;
      _text.text = path;
      widget.onChanged(path);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Widget _choice(
    List<(String, String)> choices,
    String selected,
    ValueChanged<String> onChanged,
  ) {
    final rows = [...choices];
    if (!rows.any((row) => row.$1 == selected)) {
      rows.add((selected, '未识别：$selected（保留）'));
    }
    return InputDecorator(
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: Key('parameter-choice:${widget.id}'),
          isExpanded: true,
          value: selected,
          items: [
            for (final row in rows)
              DropdownMenuItem(
                value: row.$1,
                child: Text(
                  row.$2,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: widget.disabled
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
        ),
      ),
    );
  }

  bool get _numberEnabled =>
      !widget.disabled &&
      (widget.valueMode == null ||
          widget.valueMode == ParameterValueMode.custom);

  List<(ParameterValueMode, String)> get _modes =>
      widget.valueModeChoices ??
      [
        (ParameterValueMode.inherit, widget.inheritLabel),
        (ParameterValueMode.off, '关闭'),
        (ParameterValueMode.custom, '指定数值'),
      ];

  String? get _modeLabel => widget.valueMode == null
      ? null
      : _modes.where((row) => row.$1 == widget.valueMode).firstOrNull?.$2;

  Widget _withMode(Widget child) => widget.valueMode == null
      ? child
      : SizedBox(
          width: 245,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _choice(
                [for (final row in _modes) (row.$1.name, row.$2)],
                widget.valueMode!.name,
                (value) {
                  setState(() => _error = null);
                  widget.onModeChanged?.call(
                    ParameterValueMode.values.byName(value),
                  );
                },
              ),
              const SizedBox(height: 8),
              child,
            ],
          ),
        );

  Widget _numeric() {
    final number = TextField(
      key: Key('parameter-number:${widget.id}'),
      controller: _text,
      focusNode: _focus,
      enabled: _numberEnabled,
      textAlign: TextAlign.right,
      keyboardType: TextInputType.numberWithOptions(
        decimal: !_integer,
        signed: true,
      ),
      onChanged: _number,
      decoration: InputDecoration(
        hintText:
            widget.valueMode != null &&
                widget.valueMode != ParameterValueMode.custom &&
                widget.valueMode != ParameterValueMode.inherit
            ? _modeLabel
            : widget.inheritedValue?.toString() ?? '未指定',
        errorText: _error,
        errorMaxLines: 2,
      ),
    );
    return SizedBox(
      width: 156,
      child: Row(
        children: [
          IconButton(
            tooltip: '减少',
            visualDensity: VisualDensity.compact,
            onPressed: _numberEnabled ? () => _step(-1) : null,
            icon: const Icon(Icons.remove, size: 14),
          ),
          Expanded(child: number),
          IconButton(
            tooltip: '增加',
            visualDensity: VisualDensity.compact,
            onPressed: _numberEnabled ? () => _step(1) : null,
            icon: const Icon(Icons.add, size: 14),
          ),
        ],
      ),
    );
  }

  void _step(int direction) {
    if (d.name == 'seed') {
      final current =
          generationSeedInteger(parseGenerationSeed(_text.text)) ?? BigInt.zero;
      _text.text = (current + BigInt.from(direction)).toString();
      _number(_text.text);
      return;
    }
    final current = num.tryParse(_text.text) ?? num.tryParse(d.initial) ?? 0;
    final next =
        current + direction * (widget.sliderStep ?? (_integer ? 1 : .1));
    _text.text = _integer
        ? '${next.toInt()}'
        : next
              .toStringAsFixed(3)
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceFirst(RegExp(r'\.$'), '');
    _number(_text.text);
  }

  List<String> _tags() {
    final value = widget.value;
    if (value is List) return value.whereType<String>().toList();
    if (value is String && value.isNotEmpty) {
      if (d.name == 'stop') return [value];
      try {
        final parsed = jsonDecode(value);
        if (parsed is List) return parsed.whereType<String>().toList();
      } on FormatException {
        return [value];
      }
      return [value];
    }
    return [];
  }

  void _addTag() {
    if (_tag.text.isEmpty) return;
    widget.onChanged([..._tags(), _tag.text]);
    _tag.clear();
  }

  Widget _tagEditor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final (index, value) in _tags().indexed)
            InputChip(
              label: Text(value),
              onDeleted: widget.disabled
                  ? null
                  : () {
                      final list = _tags()..removeAt(index);
                      widget.onChanged(list);
                    },
            ),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: Key('parameter-list:${widget.id}'),
              controller: _tag,
              enabled: !widget.disabled,
              decoration: const InputDecoration(hintText: '输入后按 Enter 添加'),
              onSubmitted: (_) => _addTag(),
            ),
          ),
          IconButton(
            tooltip: '添加',
            onPressed: widget.disabled ? null : _addTag,
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
    ],
  );
  void _quantityChanged() {
    widget.onChanged(switch (_quantityMode) {
      'inherit' => null,
      'auto' => 'auto',
      'off' => d.kind == ParameterKind.duration ? 'off' : '0',
      _ => _amount.text.isEmpty ? null : '${_amount.text}$_unit',
    });
  }

  Widget _quantity() {
    final duration = d.kind == ParameterKind.duration;
    final context = d.name == '--max-context';
    final units = duration
        ? ['s', 'm', 'h']
        : context
        ? ['', 'K']
        : ['', 'K', 'KB', 'KiB', 'M', 'MB', 'MiB', 'G', 'GB', 'GiB'];
    final unit = units.firstWhere(
      (value) => value.toLowerCase() == _unit.toLowerCase(),
      orElse: () => _unit,
    );
    final modes = <(String, String)>[
      ('inherit', widget.inheritLabel),
      if (d.initial == 'auto' ||
          d.name == '--max-context' ||
          d.name == '--max-memory')
        ('auto', '自动'),
      if ([
        '--idle-release',
        '--max-cache-disk',
        '--max-cache-disk-writes',
      ].contains(d.name))
        ('off', d.name == '--max-cache-disk-writes' ? '不限' : '关闭'),
      ('custom', '指定数值'),
    ];
    return Column(
      children: [
        _choice(modes, _quantityMode, (v) {
          setState(() => _quantityMode = v);
          _quantityChanged();
        }),
        if (_quantityMode == 'custom')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('parameter-quantity:${widget.id}'),
                    controller: _amount,
                    focusNode: _focus,
                    enabled: !widget.disabled,
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: duration,
                    ),
                    decoration: const InputDecoration(hintText: '数值'),
                    onChanged: (_) => _quantityChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  child: _choice(
                    [
                      for (final u in units)
                        (u, u.isEmpty ? (context ? 'token' : '字节') : u),
                    ],
                    unit,
                    (v) {
                      setState(() => _unit = v);
                      _quantityChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final kind = d.kind;
    final value = widget.value;
    final scheme = Theme.of(context).colorScheme;
    Widget control;
    if (kind == ParameterKind.flag) {
      final raw = value == null
          ? 'inherit'
          : value == true || value == 'true'
          ? 'true'
          : value == false || value == 'false'
          ? 'false'
          : '$value';
      control = SizedBox(
        width: 170,
        child: _choice(
          [('inherit', widget.inheritLabel), ('true', '开启'), ('false', '关闭')],
          raw,
          (v) => widget.onChanged(v == 'inherit' ? null : v == 'true'),
        ),
      );
    } else if (kind == ParameterKind.toggle || kind == ParameterKind.choice) {
      control = SizedBox(
        width: 220,
        child: _choice(
          [
            ('', widget.inheritLabel),
            for (final choice in d.choices)
              (
                choice,
                switch (choice) {
                  'on' => '开启',
                  'off' => '关闭',
                  'auto' => '自动',
                  'none' => '关闭 / 无',
                  _ => choice,
                },
              ),
          ],
          value?.toString() ?? '',
          (v) => widget.onChanged(v.isEmpty ? null : v),
        ),
      );
    } else if (kind == ParameterKind.integer || kind == ParameterKind.decimal) {
      control = _withMode(_numeric());
    } else if (kind == ParameterKind.text && d.choices.isNotEmpty) {
      final raw = value?.toString() ?? '';
      final custom =
          _customChoice || raw.isNotEmpty && !d.choices.contains(raw);
      control = SizedBox(
        width: 220,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _choice(
              [
                ('', widget.inheritLabel),
                for (final option in d.choices)
                  (
                    option,
                    switch (option) {
                      'auto' => '自动',
                      'all' => '全部',
                      'off' => '关闭',
                      _ => option,
                    },
                  ),
                ('__custom', '指定数值'),
              ],
              custom ? '__custom' : raw,
              (v) {
                setState(() => _customChoice = v == '__custom');
                if (v == '__custom') {
                  _text.clear();
                  widget.onChanged(null);
                } else {
                  widget.onChanged(v.isEmpty ? null : v);
                }
              },
            ),
            if (custom)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _numeric(),
              ),
          ],
        ),
      );
    } else if (kind == ParameterKind.quantity ||
        kind == ParameterKind.duration) {
      control = SizedBox(width: 245, child: _quantity());
    } else if (kind == ParameterKind.file || kind == ParameterKind.directory) {
      control = Row(
        children: [
          Expanded(
            child: TextField(
              key: Key('parameter-path:${widget.id}'),
              controller: _text,
              focusNode: _focus,
              enabled: !widget.disabled,
              decoration: InputDecoration(
                hintText: kind == ParameterKind.file ? '选择本地文件' : '选择本地目录',
                errorText: _error,
              ),
              onChanged: (v) => widget.onChanged(v.isEmpty ? null : v),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: widget.disabled ? null : _pick,
            icon: const Icon(Icons.folder_open, size: 17),
            label: const Text('选择…'),
          ),
        ],
      );
    } else {
      control = _withMode(
        TextField(
          key: Key('parameter-text:${widget.id}'),
          controller: _text,
          focusNode: _focus,
          enabled: _numberEnabled,
          obscureText: kind == ParameterKind.secret,
          decoration: InputDecoration(
            hintText: _modeLabel ?? widget.inheritLabel,
            errorText: _error,
          ),
          onChanged: (v) => widget.onChanged(
            v.isEmpty && widget.valueMode == null ? null : v,
          ),
        ),
      );
    }
    final fullWidth =
        kind == ParameterKind.file ||
        kind == ParameterKind.directory ||
        kind == ParameterKind.list;
    final slider = widget.sliderMin != null && widget.sliderMax != null;
    final parsed = num.tryParse(
      (value ?? widget.inheritedValue)?.toString() ?? '',
    )?.toDouble();
    final number = parsed != null && parsed.isFinite
        ? parsed
        : widget.sliderMin ?? 0;
    final minimum = slider ? math.min(widget.sliderMin!, number) : 0.0;
    final maximum = slider ? math.max(widget.sliderMax!, number) : 0.0;
    return Padding(
      key: Key('parameter-field:${widget.id}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.label,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    if (d.help.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          d.help,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                widget.overridden
                    ? '文本优先'
                    : widget.valueMode != null &&
                          widget.valueModeChoices != null
                    ? _modeLabel!
                    : widget.valueMode == ParameterValueMode.off
                    ? '已关闭'
                    : widget.valueMode == ParameterValueMode.inherit ||
                          value == null
                    ? widget.inheritLabel
                    : '自定义',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: widget.overridden
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                tooltip: '恢复默认',
                onPressed:
                    widget.disabled ||
                        (widget.valueMode == null
                            ? value == null
                            : widget.valueMode == ParameterValueMode.inherit)
                    ? null
                    : () {
                        setState(() {
                          _customChoice = false;
                          _quantityMode = 'inherit';
                          _text.clear();
                          _error = null;
                        });
                        if (widget.valueMode != null) {
                          widget.onModeChanged?.call(
                            ParameterValueMode.inherit,
                          );
                        } else {
                          widget.onChanged(null);
                        }
                      },
                icon: const Icon(Icons.undo, size: 16),
              ),
              if (!fullWidth)
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 245),
                    child: control,
                  ),
                ),
            ],
          ),
          if (fullWidth)
            Padding(
              padding: const EdgeInsets.only(top: 9),
              child: kind == ParameterKind.list ? _tagEditor() : control,
            ),
          if (slider && (value != null || widget.inheritedValue is num))
            // Enabled state changes Slider's semantics subtree in the fixed SDK.
            // Retire that subtree before rebuilding its accessible actions.
            KeyedSubtree(
              key: ValueKey('slider-state:${widget.id}:$_numberEnabled'),
              // Keep the value-indicator portal inside this slider's subtree.
              // The fixed SDK otherwise emits orphan nodes on pushed routes:
              // https://github.com/flutter/flutter/issues/190357
              child: Overlay.wrap(
                alwaysSizeToContent: true,
                clipBehavior: Clip.none,
                child: Slider(
                  key: Key('parameter-slider:${widget.id}'),
                  value: number.clamp(minimum, maximum).toDouble(),
                  min: minimum,
                  max: maximum,
                  divisions: widget.sliderStep == null
                      ? null
                      : ((maximum - minimum) / widget.sliderStep!)
                            .round()
                            .clamp(1, 10000)
                            .toInt(),
                  onChanged: !_numberEnabled
                      ? null
                      : (v) {
                          final n = kind == ParameterKind.integer
                              ? v.round()
                              : v == minimum || v == maximum
                              ? v
                              : double.parse(v.toStringAsFixed(3));
                          _text.text = '$n';
                          setState(() => _error = null);
                          widget.onChanged(n);
                        },
                ),
              ),
            ),
          const SizedBox(height: 8),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

/// JSON is a value, not a CLI escape hatch; its syntax is checked while editing.
class ParameterObjectField extends StatefulWidget {
  const ParameterObjectField({
    super.key,
    required this.id,
    required this.label,
    required this.value,
    required this.onChanged,
    this.disabled = false,
  });
  final String id, label;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final bool disabled;
  @override
  State<ParameterObjectField> createState() => _ParameterObjectFieldState();
}

class _ParameterObjectFieldState extends State<ParameterObjectField> {
  late final _controller = TextEditingController(
    text: widget.value == null
        ? ''
        : widget.value is String
        ? widget.value as String
        : const JsonEncoder.withIndent('  ').convert(widget.value),
  );
  String? _error;
  final _focus = FocusNode();
  @override
  void didUpdateWidget(ParameterObjectField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _controller.text = widget.value == null
          ? ''
          : widget.value is String
          ? widget.value as String
          : const JsonEncoder.withIndent('  ').convert(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: TextField(
      key: Key('parameter-object:${widget.id}'),
      controller: _controller,
      focusNode: _focus,
      enabled: !widget.disabled,
      minLines: 5,
      maxLines: 10,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(fontFamily: 'monospace'),
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: 'JSON 对象；留空继承默认。',
        errorText: _error,
        errorMaxLines: 3,
      ),
      onChanged: (text) {
        if (text.trim().isEmpty) {
          setState(() => _error = null);
          widget.onChanged(null);
          return;
        }
        try {
          final value = jsonDecode(text);
          if (value is! Map) throw const FormatException('需要 JSON 对象');
          setState(() => _error = null);
          widget.onChanged(value);
        } on FormatException catch (e) {
          setState(() => _error = e.message);
          widget.onChanged(text);
        }
      },
    ),
  );
}
