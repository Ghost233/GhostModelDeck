import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'council.dart';

class CouncilPage extends StatefulWidget {
  const CouncilPage({
    super.key,
    required this.controller,
    required this.onOpenLibrary,
  });
  final CouncilController controller;
  final VoidCallback onOpenLibrary;
  @override
  State<CouncilPage> createState() => _CouncilPageState();
}

class _CouncilPageState extends State<CouncilPage> {
  final _context = TextEditingController();
  final _options = [_OptionFields(1), _OptionFields(2)];
  int _nextOption = 3;
  String? _error;
  DecisionCancellation? _activeCancellation;

  @override
  void dispose() {
    _activeCancellation?.cancel();
    _context.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  bool get _validOptions =>
      _options.length >= 2 &&
      _options.every(
        (option) =>
            option.id.text.trim().isNotEmpty &&
            option.text.text.trim().isNotEmpty,
      ) &&
      _options.map((option) => option.id.text.trim()).toSet().length ==
          _options.length;

  Future<void> _consult() async {
    final cancellation = DecisionCancellation();
    setState(() {
      _error = null;
      _activeCancellation = cancellation;
    });
    try {
      await widget.controller.consult(
        state: _context.text,
        options: {
          for (final option in _options)
            option.id.text.trim(): option.text.text.trim(),
        },
        cancellation: cancellation,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _activeCancellation = null);
    }
  }

  void _select(CouncilSeat seat, bool selected) {
    final ids = [...widget.controller.selectedSeatIds];
    selected ? ids.add(seat.id) : ids.remove(seat.id);
    try {
      widget.controller.selectSeats(ids);
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<CouncilState>(
    stream: widget.controller.changes,
    initialData: widget.controller.state,
    builder: (context, snapshot) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        JevPageHeader(
          title: '委员会',
          action: TextButton.icon(
            onPressed: widget.onOpenLibrary,
            icon: const Icon(Icons.folder_outlined, size: 16),
            label: const Text('模型库'),
          ),
        ),
        if (widget.controller.availableSeats.isEmpty &&
            widget.controller.selectedSeats.isEmpty &&
            snapshot.data!.lastResult == null)
          Expanded(
            child: Center(
              child: JevSurface(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.hub_outlined,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '暂无运行中模型',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: widget.onOpenLibrary,
                      child: const Text('打开模型库'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final state = snapshot.data!;
                final result = state.lastResult;
                final input = _input(context, state);
                return SingleChildScrollView(
                  child: result != null && constraints.maxWidth >= 880
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 5, child: input),
                            const SizedBox(width: 20),
                            Expanded(flex: 6, child: _result(context, result)),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            input,
                            if (result != null) ...[
                              const SizedBox(height: 20),
                              _result(context, result),
                            ],
                          ],
                        ),
                );
              },
            ),
          ),
      ],
    ),
  );

  Widget _input(BuildContext context, CouncilState state) {
    final theme = Theme.of(context);
    final selected = widget.controller.selectedSeatIds;
    final available = widget.controller.availableSeats;
    final readyIds = available.map((seat) => seat.id).toSet();
    final seats = [
      ...available,
      ...widget.controller.selectedSeats.where(
        (seat) => !readyIds.contains(seat.id),
      ),
    ];
    return JevSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('席位', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text('${selected.length} 已选', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final seat in seats)
                Tooltip(
                  message: '${seat.engine.name} · ${seat.instance.id}',
                  child: FilterChip(
                    label: Text(
                      '${_seatLabel(seat)}${readyIds.contains(seat.id) ? '' : ' · 未就绪'}',
                    ),
                    selected: selected.contains(seat.id),
                    onSelected: state.busy
                        ? null
                        : (chosen) => _select(seat, chosen),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text('上下文', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            key: const Key('council-context'),
            controller: _context,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(hintText: '输入本次判断的上下文'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('候选项', style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: state.busy || _options.length >= 255
                    ? null
                    : () => setState(
                        () => _options.add(_OptionFields(_nextOption++)),
                      ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final option in _options)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: TextField(
                      key: Key('council-id-${option.number}'),
                      controller: option.id,
                      enabled: !state.busy,
                      decoration: const InputDecoration(hintText: 'ID'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: Key('council-option-${option.number}'),
                      controller: option.text,
                      enabled: !state.busy,
                      decoration: const InputDecoration(hintText: '候选内容'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '删除候选项',
                    onPressed: state.busy || _options.length <= 2
                        ? null
                        : () {
                            setState(() => _options.remove(option));
                            option.dispose();
                          },
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (state.busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Spacer(),
              if (_activeCancellation != null) ...[
                TextButton(
                  onPressed: _activeCancellation!.cancel,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton(
                onPressed: state.busy || selected.isEmpty || !_validOptions
                    ? null
                    : _consult,
                child: Text(state.busy ? '咨询中' : '咨询'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _result(BuildContext context, CouncilConsultation result) {
    final theme = Theme.of(context);
    final ensemble = result.scope == CouncilScope.ensemble;
    return JevSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ensemble
                      ? '综合评分'
                      : result.scope == CouncilScope.singleModel
                      ? '单模型结果'
                      : '咨询失败',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              JevStatusChip(
                label: switch (result.status) {
                  CouncilStatus.ok => '已完成',
                  CouncilStatus.partial => '部分返回',
                  CouncilStatus.failed => '失败',
                },
                tone: result.status == CouncilStatus.failed
                    ? JevStatusTone.error
                    : result.status == CouncilStatus.partial
                    ? JevStatusTone.warning
                    : JevStatusTone.success,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${result.seats.where((seat) => seat.result != null).length}/${result.seats.length} 席 · ${result.elapsed.inMilliseconds} ms${ensemble ? ' · 分歧 ${(result.disagreement! * 100).toStringAsFixed(1)}%' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          if (ensemble) ...[
            const SizedBox(height: 20),
            for (final option in result.request.options.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            option.value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(result.aggregateScores![option.key]! * 100).toStringAsFixed(1)}%',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: result.aggregateScores![option.key],
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '${option.key} · ${result.votes![option.key]} 票',
                          style: theme.textTheme.bodySmall,
                        ),
                        const Spacer(),
                        if (result.topChoices!.contains(option.key))
                          JevStatusChip(
                            label: result.topChoices!.length > 1
                                ? '并列最高'
                                : '最高评分',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Text('各席意见', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final opinion in result.seats)
            ExpansionTile(
              key: PageStorageKey('${result.requestId}/${opinion.seat.id}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      _seatLabel(opinion.seat),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  JevStatusChip(
                    label: switch (opinion.status) {
                      CouncilSeatStatus.ok => '已完成',
                      CouncilSeatStatus.notReady => '未就绪',
                      CouncilSeatStatus.timedOut => '超时',
                      CouncilSeatStatus.cancelled => '已取消',
                      CouncilSeatStatus.invalidResponse => '响应无效',
                      CouncilSeatStatus.failed => '失败',
                    },
                    tone: opinion.status == CouncilSeatStatus.ok
                        ? JevStatusTone.success
                        : opinion.status == CouncilSeatStatus.cancelled
                        ? JevStatusTone.neutral
                        : opinion.status == CouncilSeatStatus.notReady ||
                              opinion.status == CouncilSeatStatus.timedOut
                        ? JevStatusTone.warning
                        : JevStatusTone.error,
                  ),
                ],
              ),
              subtitle: Text(
                opinion.result == null
                    ? opinion.error ?? '失败'
                    : '${result.request.options[opinion.result!.choice]} · ${opinion.elapsed.inMilliseconds} ms',
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                if (opinion.result != null) ...[
                  for (final option in result.request.options.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              option.value,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          Text(
                            '${(opinion.result!.probabilities[option.key]! * 100).toStringAsFixed(1)}%',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('原始响应', style: theme.textTheme.titleSmall),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(opinion.toJson()),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _OptionFields {
  _OptionFields(this.number)
    : id = TextEditingController(text: 'option_$number');
  final int number;
  final TextEditingController id;
  final text = TextEditingController();
  void dispose() {
    id.dispose();
    text.dispose();
  }
}

String _seatLabel(CouncilSeat seat) {
  final file = seat.instance.asset.files.first.path.split('/').last;
  final name =
      seat.instance.asset.repoId
          ?.split('/')
          .last
          .replaceFirst(RegExp(r'-GGUF$', caseSensitive: false), '') ??
      seat.instance.asset.files.first.path.split('/').reversed.skip(1).first;
  final variant = RegExp(
    r'(?:^|[-.])(Q\d(?:_[A-Z0-9]+)*|BF16|F16|F32)(?=[-.]|$)',
    caseSensitive: false,
  ).firstMatch(file)?.group(1);
  return variant == null ? name : '$name · $variant';
}
