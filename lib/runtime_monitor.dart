import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine_runtime.dart';

enum RequestPhase { queued, prefill, decode, running }

class RequestProgress {
  const RequestProgress({
    required this.id,
    required this.phase,
    this.promptTokens,
    this.processedTokens,
    this.generatedTokens,
    this.maxTokens,
    this.tokensPerSecond,
    this.slotIndex,
  });
  final String id;
  final RequestPhase phase;
  final int? promptTokens;
  final int? processedTokens;
  final int? generatedTokens;
  final int? maxTokens;
  final double? tokensPerSecond;
  final int? slotIndex;
}

/// A read-only engine observation. Null means the engine did not supply it.
class RuntimeTelemetry {
  RuntimeTelemetry({
    this.capacity,
    this.running,
    this.queued,
    this.prefilling,
    this.decoding,
    this.totalRequests,
    this.promptTokens,
    this.generatedTokens,
    this.prefillPerSecond,
    this.decodePerSecond,
    this.prefillSeconds,
    this.decodeSeconds,
    List<RequestProgress> requests = const [],
    this.notice,
  }) : requests = List.unmodifiable(requests);
  final int? capacity;
  final int? running;
  final int? queued;
  final int? prefilling;
  final int? decoding;
  final int? totalRequests;
  final int? promptTokens;
  final int? generatedTokens;
  final double? prefillPerSecond;
  final double? decodePerSecond;
  final double? prefillSeconds;
  final double? decodeSeconds;
  final List<RequestProgress> requests;
  final String? notice;

  factory RuntimeTelemetry.splash(Object? value) {
    final row = _map(value);
    final transport = _map(row['transport']);
    if (transport['status_stale'] == true) {
      throw const FormatException('引擎状态已过期');
    }
    final scheduler = _map(row['scheduler']);
    final metrics = _map(row['metrics']);
    final totals = _map(row['requests']);
    final plan = _map(_map(row['memory_plan'])['budget']);
    if (scheduler.isEmpty &&
        metrics.isEmpty &&
        row['active_requests'] is! int &&
        row['active_requests'] is! List) {
      throw const FormatException('Splash 未提供监控数据');
    }
    final progress = [
      for (final request in _rows(row['active_requests']).where(
        (request) => !const [
          'completed',
          'cancelled',
          'failed',
        ].contains(request['phase']),
      ))
        RequestProgress(
          id: '${request['id']}',
          phase: _phase(request['phase']),
          promptTokens: _int(request['prompt_tokens']),
          processedTokens: _int(request['prompt_processed']),
          generatedTokens: _int(request['generated_tokens']),
          maxTokens: _int(request['max_new_tokens']),
        ),
    ];
    final prefill = _int(scheduler['prefilling']);
    final decode = _int(scheduler['decoding']);
    return RuntimeTelemetry(
      capacity: _int(plan['maximum_batch_width']),
      running: row['active_requests'] is List
          ? progress.where((p) => p.phase != RequestPhase.queued).length
          : _int(row['active_requests']),
      queued: _sum([
        scheduler['queued'],
        scheduler['waiting_resources'],
        scheduler['waiting_prefix'],
        scheduler['waiting_mask'],
        if (_map(row['frontend']).containsKey('waiting'))
          _map(row['frontend'])['waiting'],
      ]),
      prefilling: prefill,
      decoding: decode,
      totalRequests: _int(totals['submitted']),
      promptTokens: _int(metrics['prefill_input_tokens']),
      generatedTokens: _int(metrics['decode_output_tokens']),
      prefillPerSecond: _number(metrics['prefill_tokens_per_second']),
      decodePerSecond: _number(metrics['decode_tokens_per_second']),
      prefillSeconds: _seconds(metrics['prefill_wall_ms']),
      decodeSeconds: _seconds(metrics['decode_wall_ms']),
      requests: progress,
    );
  }

  factory RuntimeTelemetry.llama({
    Object? slots,
    String? metrics,
    int? capacity,
  }) {
    final values = <String, double>{};
    if (metrics != null) {
      for (final line in const LineSplitter().convert(metrics)) {
        final match = RegExp(
          r'^(llamacpp:[a-z_]+)(?:\{[^}]*\})?\s+([\d.eE+-]+)(?:\s.*)?$',
        ).firstMatch(line);
        if (match == null) continue;
        final number = double.tryParse(match.group(2)!);
        if (number != null && number.isFinite && number >= 0) {
          values[match.group(1)!] = number;
        }
      }
    }
    if (slots is! List && values.isEmpty) {
      throw const FormatException('引擎未开放 /slots 或 /metrics');
    }
    final progress = <RequestProgress>[];
    final nativeSlots = _rows(slots).toList();
    for (var index = 0; index < nativeSlots.length; index++) {
      final slot = nativeSlots[index];
      if (slot['is_processing'] != true) continue;
      final next =
          _rows(slot['next_token']).firstOrNull ?? const <String, Object?>{};
      final generated = _int(next['n_decoded']);
      progress.add(
        RequestProgress(
          id: 'slot-${slot['id']}',
          slotIndex: index,
          phase: generated == null
              ? RequestPhase.running
              : generated > 0
              ? RequestPhase.decode
              : _int(slot['n_prompt_tokens_processed']) != null &&
                    _int(slot['n_prompt_tokens']) != null &&
                    _int(slot['n_prompt_tokens_processed'])! <
                        _int(slot['n_prompt_tokens'])!
              ? RequestPhase.prefill
              : RequestPhase.running,
          promptTokens: _int(slot['n_prompt_tokens']),
          processedTokens: _int(slot['n_prompt_tokens_processed']),
          generatedTokens: generated,
          maxTokens: _int(_map(slot['params'])['n_predict']),
        ),
      );
    }
    return RuntimeTelemetry(
      capacity: slots is List ? slots.length : capacity,
      running:
          _int(values['llamacpp:requests_processing']) ??
          (slots is List &&
                  nativeSlots.every((slot) => slot['is_processing'] is bool)
              ? progress.length
              : null),
      queued: _int(values['llamacpp:requests_deferred']),
      prefilling: slots is List
          ? progress.where((p) => p.phase == RequestPhase.prefill).length
          : null,
      decoding: slots is List
          ? progress.where((p) => p.phase == RequestPhase.decode).length
          : null,
      promptTokens: _int(values['llamacpp:prompt_tokens_total']),
      generatedTokens: _int(values['llamacpp:tokens_predicted_total']),
      prefillPerSecond: values['llamacpp:prompt_tokens_seconds'],
      decodePerSecond: values['llamacpp:predicted_tokens_seconds'],
      prefillSeconds: values['llamacpp:prompt_seconds_total'],
      decodeSeconds: values['llamacpp:tokens_predicted_seconds_total'],
      requests: progress,
      notice: values.isEmpty
          ? '引擎未提供 /metrics；启用 --metrics 后可读取累计 token 和平均速度。'
          : slots is! List
          ? '引擎未提供 /slots，无法展示各请求进度。'
          : null,
    );
  }

  factory RuntimeTelemetry.omlx(
    Object? value,
    String model, {
    int? capacity,
    bool modelScoped = false,
  }) {
    final row = _map(value);
    final models = _rows(_map(row['active_models'])['models']);
    final status = models.where((m) => m['id'] == model).singleOrNull;
    if (status == null) throw const FormatException('oMLX 未提供所选模型状态');
    final progress = <RequestProgress>[];
    for (final waiting in _rows(status['waiting'])) {
      progress.add(
        RequestProgress(
          id: '${waiting['request_id']}',
          phase: RequestPhase.queued,
          promptTokens: _int(waiting['prompt_tokens']),
        ),
      );
    }
    for (final prefill in _rows(status['prefilling'])) {
      progress.add(
        RequestProgress(
          id: '${prefill['request_id']}',
          phase: RequestPhase.prefill,
          promptTokens: _int(prefill['total']),
          processedTokens: _int(prefill['processed']),
          tokensPerSecond: _number(prefill['speed']),
        ),
      );
    }
    for (final decode in _rows(status['generating'])) {
      progress.add(
        RequestProgress(
          id: '${decode['request_id']}',
          phase: RequestPhase.decode,
          promptTokens: _int(decode['prompt_tokens']),
          generatedTokens: _int(decode['generated_tokens']),
          maxTokens: _int(decode['max_tokens']),
          tokensPerSecond: _number(decode['tokens_per_second']),
        ),
      );
    }
    for (final activity in _rows(status['activities'])) {
      final id = '${activity['request_id']}';
      if (progress.any((p) => p.id == id)) continue;
      progress.add(
        RequestProgress(
          id: id,
          phase: _phase(activity['phase']),
          promptTokens: _int(activity['prompt_tokens']),
          generatedTokens: _int(activity['generated_tokens']),
        ),
      );
    }
    return RuntimeTelemetry(
      capacity: capacity,
      running: _int(status['active_requests']),
      queued: _int(status['waiting_requests']),
      prefilling: status['prefilling'] is List
          ? (status['prefilling'] as List).length
          : null,
      decoding: status['generating'] is List
          ? (status['generating'] as List).length
          : null,
      // The admin endpoint can filter its root snapshot by model. Unscoped
      // callers must not copy a global aggregate into each instance.
      totalRequests: modelScoped ? _int(row['total_requests']) : null,
      promptTokens: modelScoped ? _int(row['total_prompt_tokens']) : null,
      generatedTokens: modelScoped
          ? _int(row['total_completion_tokens'])
          : null,
      requests: progress,
    );
  }
}

abstract interface class RuntimeMonitorSource {
  Future<RuntimeTelemetry> readTelemetry(
    String instanceId, {
    required DecisionCancellation cancellation,
  });
}

/// Bounded GET for monitoring only; it never admits an inference request.
Future<String> readMonitorHttp(
  Uri uri, {
  required DecisionCancellation cancellation,
  Map<String, String> headers = const {},
}) async {
  if (cancellation.isCancelled) throw const HttpException('监控已取消');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  final remove = cancellation.listen(() => client.close(force: true));
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('监控接口 HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('监控响应超出大小上限');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    })().timeout(const Duration(seconds: 3));
  } finally {
    remove();
    client.close(force: true);
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map && value.keys.every((k) => k is String)
    ? Map<String, Object?>.from(value)
    : const {};
Iterable<Map<String, Object?>> _rows(Object? value) =>
    value is List ? value.whereType<Map>().map(_map) : const [];
int? _int(Object? value) =>
    value is num &&
        value.isFinite &&
        value >= 0 &&
        value == value.roundToDouble()
    ? value.toInt()
    : null;
double? _number(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;
double? _seconds(Object? milliseconds) {
  final value = _number(milliseconds);
  return value == null ? null : value / 1000;
}

int? _sum(List<Object?> values) => values.any((v) => _int(v) == null)
    ? null
    : values.fold<int>(0, (sum, v) => sum + _int(v)!);
RequestPhase _phase(Object? phase) => switch (phase) {
  'queued' ||
  'waiting_resources' ||
  'waiting_prefix' ||
  'waiting_mask' => RequestPhase.queued,
  'prefill' => RequestPhase.prefill,
  'decode' || 'generating' => RequestPhase.decode,
  _ => RequestPhase.running,
};
