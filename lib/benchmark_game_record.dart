import 'dart:convert';

import 'jev_playground.dart';
import 'jevman_benchmark.dart';

/// A journal entry preserves the original game and its ordinary public calls.
/// Parsing a trace does not replace the upstream independent replay verifier.
class BenchmarkGameRecord {
  BenchmarkGameRecord._(this._value);

  factory BenchmarkGameRecord.parse(
    Map<String, Object?> game, {
    required String model,
    required JevPlaygroundMode channel,
  }) {
    final index = game['index'];
    final result = game['result'];
    final calls = game['calls'];
    if (model.isEmpty ||
        index is! int ||
        index < 1 ||
        index > 100 ||
        game['complete'] is! bool ||
        game['costKnown'] is! bool ||
        result is! Map<String, Object?> ||
        calls is! List) {
      throw const FormatException('游戏日志的局号、完成状态或原结果无效');
    }
    final trace = JevmanRecording.parse(game['recording']);
    final terminal = trace.toJson()['final'] as Map;
    if (trace.toJson()['model'] != model ||
        result['score'] != trace.finalScore ||
        result['level'] != terminal['level']) {
      throw const FormatException('游戏日志与原录像身份或终局结果不一致');
    }
    for (final key in const [
      'score',
      'pellets',
      'deaths',
      'level',
      'calls',
      'decisions',
      'fallbacks',
      'fruitSpawned',
      'fruitEaten',
      'ghostsEaten',
    ]) {
      if (result[key] is! int || (result[key] as int) < 0) {
        throw FormatException('原游戏计数无效：$key');
      }
    }
    for (final key in const ['survived', 'latencyMsSum', 'cost']) {
      final number = result[key];
      if (number is! num || !number.isFinite || number < 0) {
        throw FormatException('原游戏数值无效：$key');
      }
    }
    final deathsBy = result['deathsBy'];
    if (deathsBy is! Map<String, Object?> ||
        deathsBy.values.any((count) => count is! int || count < 0)) {
      throw const FormatException('原游戏死亡分组无效');
    }
    if (game['complete'] == true &&
        terminal['lives'] != 0 &&
        (result['survived'] as num) < 300) {
      throw const FormatException('未到原终局或局时限的录像不能声明完整');
    }
    final ids = <int>{};
    for (final call in calls) {
      if (call is! Map<String, Object?> ||
          call['id'] is! int ||
          (call['id'] as int) < 1 ||
          !ids.add(call['id'] as int) ||
          call['phase'] != 'game' ||
          call['game'] != index ||
          call['channel'] != channel.name ||
          call['request'] is! Map<String, Object?>) {
        throw const FormatException('公开调用不属于该局或通道');
      }
      final request = call['request'] as Map<String, Object?>;
      if (request['model'] != model || request['questions'] is! Map) {
        throw const FormatException('游戏公开请求身份无效');
      }
      final elapsed = call['elapsed_us'];
      if (elapsed != null && (elapsed is! int || elapsed < 0)) {
        throw const FormatException('游戏公开调用耗时无效');
      }
      final response = call['result'];
      if (response != null &&
          (response is! Map<String, Object?> ||
              response['channel'] != channel.name ||
              !JevPlaygroundStatus.values.any(
                (status) => status.name == response['status'],
              ))) {
        throw const FormatException('游戏公开响应状态或通道无效');
      }
    }
    // Copy once at the external boundary, then seal nested extension fields.
    // Store performs the existing public request/response and redaction checks.
    try {
      final copy = jsonDecode(jsonEncode(game));
      return BenchmarkGameRecord._(_seal(copy) as Map<String, Object?>);
    } on JsonUnsupportedObjectError {
      throw const FormatException('游戏日志包含非 JSON 证据');
    }
  }

  final Map<String, Object?> _value;
  int get index => _value['index'] as int;
  bool get complete => _value['complete'] as bool;
  Map<String, Object?> toJson() => _value;

  static Object? _seal(Object? value) {
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries) entry.key: _seal(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_seal));
    }
    return value;
  }
}
