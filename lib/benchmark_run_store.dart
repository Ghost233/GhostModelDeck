import 'dart:convert';
import 'dart:io';

import 'decision_protocol.dart';
import 'jev_debug.dart';
import 'jev_models.dart';
import 'jev_playground.dart';

enum BenchmarkRunStatus {
  running,
  completed,
  failed,
  cancelled,
  interrupted,
  targetUnavailable,
}

/// One immutable session or historical snapshot. It never starts inference.
class BenchmarkRun {
  factory BenchmarkRun.fromJson(Map<String, Object?> value) {
    if (value['schema_version'] != 1 ||
        !_validId(value['id']) ||
        value['model'] is! String ||
        (value['model'] as String).isEmpty ||
        !const {'native', 'council'}.contains(value['source']) ||
        value['channel'] != 'http' ||
        !BenchmarkRunStatus.values.any((s) => s.name == value['status']) ||
        value['timeout_us'] is! int ||
        (value['timeout_us'] as int) <= 0 ||
        !_validDate(value['created_at']) ||
        value['finished_at'] != null && !_validDate(value['finished_at']) ||
        value['suite'] is! Map ||
        value['identity'] is! Map ||
        value['summary'] is! Map ||
        value['items'] is! List ||
        value['groups'] is! List) {
      throw const FormatException('评测记录身份、状态或期限无效');
    }
    final summary = value['summary'] as Map;
    final attempted = summary['attempted'];
    if (attempted is! int ||
        attempted < 0 ||
        attempted > 400 ||
        summary['complete'] is! bool ||
        summary['error'] != null && summary['error'] is! String) {
      throw const FormatException('评测摘要进度、完成状态或错误说明无效');
    }
    for (final key in const [
      'expected',
      'expected_pairs',
      'missing',
      'valid',
      'failures',
      'timeouts',
      'client_timeouts',
      'server_timeouts',
      'probability_coverage',
      'unusable',
      'correct',
      'pairs_correct',
    ]) {
      if (summary.containsKey(key) &&
          (summary[key] is! int || (summary[key] as int) < 0)) {
        throw FormatException('评测摘要计数无效：$key');
      }
    }
    for (final key in const [
      'accuracy',
      'pair_accuracy',
      'brier',
      'ece',
      'latency_success_p50_ms',
      'latency_success_p95_ms',
    ]) {
      final metric = summary[key];
      if (metric != null &&
          (metric is! num || !metric.isFinite || metric < 0)) {
        throw FormatException('评测摘要数字无效：$key');
      }
    }
    final ids = <String>{};
    for (final item in value['items'] as List) {
      if (item is! Map ||
          item['id'] is! String ||
          !ids.add(item['id'] as String) ||
          item['pair_id'] is! String ||
          item['gold'] is! String ||
          item['category'] is! String ||
          item['difficulty'] is! String ||
          item['status'] is! String ||
          item['prediction'] != null && item['prediction'] is! String ||
          item['elapsed_us'] is! int ||
          (item['elapsed_us'] as int) < 0 ||
          item['error'] != null && item['error'] is! String) {
        throw const FormatException('评测逐题记录无效');
      }
      final request = item['request'];
      _validateRequest(request, item['request_json'], value['model'] as String);
      final result = item['result'];
      if (result != null) {
        _validateResult(
          result,
          model: value['model'] as String,
          expectedRequest: request,
        );
      }
    }
    for (final group in value['groups'] as List) {
      if (group is! Map ||
          group['pair_id'] is! String ||
          group['members'] is! List ||
          (group['members'] as List).any((id) => id is! String) ||
          group['attempted'] is! int ||
          group['complete'] is! bool ||
          group['correct'] is! bool) {
        throw const FormatException('评测成对记录无效');
      }
    }
    // External records establish known task roles only after schema checks.
    return BenchmarkRun._(
      sealDebugJson(value, projection: JevDebugProjection.benchmarkRun),
    );
  }
  const BenchmarkRun._(this._json);
  final Map<String, Object?> _json;
  String get id => _json['id'] as String;
  String get model => _json['model'] as String;
  String get source => _json['source'] as String;
  BenchmarkRunStatus get status =>
      BenchmarkRunStatus.values.byName(_json['status'] as String);
  Duration get timeout => Duration(microseconds: _json['timeout_us'] as int);
  DateTime get createdAt => DateTime.parse(_json['created_at'] as String);
  Map<String, Object?> get suite => _json['suite'] as Map<String, Object?>;
  Map<String, Object?> get identity =>
      _json['identity'] as Map<String, Object?>;
  Map<String, Object?> get summary => _json['summary'] as Map<String, Object?>;
  List<Map<String, Object?>> get items =>
      (_json['items'] as List).cast<Map<String, Object?>>();
  List<Map<String, Object?>> get groups =>
      (_json['groups'] as List).cast<Map<String, Object?>>();
  Map<String, Object?> toJson() => _json;

  static bool _validDate(Object? value) =>
      value is String && DateTime.tryParse(value) != null;
  static bool _validId(Object? value) =>
      value is String &&
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').hasMatch(value);

  static void _validateRequest(Object? request, Object? raw, String model) {
    if (request != null && JevModelRequest.parse(request).model != model) {
      throw const FormatException('请求模型与本批身份不一致');
    }
    if (raw != null) {
      if (raw is! String) throw const FormatException('请求快照需要是字符串');
      final decoded = jsonDecode(raw);
      if (JevModelRequest.parse(decoded).model != model ||
          request != null && !_sameJson(request, decoded)) {
        throw const FormatException('实际请求快照与本批身份或请求内容不一致');
      }
    }
  }

  static bool _sameJson(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) => right.containsKey(key) && _sameJson(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(
            left.length,
            (index) => index,
          ).every((index) => _sameJson(left[index], right[index]));
    }
    return left == right;
  }

  static void _validateResult(
    Object value, {
    required String model,
    Object? expectedRequest,
  }) {
    if (value is! Map ||
        !JevPlaygroundStatus.values.any((s) => s.name == value['status']) ||
        value['channel'] != 'http' ||
        value['message'] is! String ||
        value['timeout_us'] is! int ||
        value['elapsed_us'] is! int ||
        value['request'] != null && value['request'] is! Map ||
        value['request_json'] != null && value['request_json'] is! String ||
        value['output'] != null && value['output'] is! Map ||
        value['debug'] != null && value['debug'] is! Map ||
        value['raw_response'] != null && value['raw_response'] is! String ||
        value['http_status'] != null && value['http_status'] is! int) {
      throw const FormatException('评测公开客户端结果无效');
    }
    _validateRequest(value['request'], value['request_json'], model);
    if (expectedRequest != null &&
        value['request'] != null &&
        !_sameJson(expectedRequest, value['request'])) {
      throw const FormatException('逐题请求与公开客户端请求不一致');
    }
    if (value['status'] == JevPlaygroundStatus.success.name) {
      final request = value['request'];
      final output = value['output'];
      final raw = value['raw_response'];
      if (request == null || output is! Map || raw is! String) {
        throw const FormatException('成功记录缺少实际请求或公开响应');
      }
      final parsed = JevModelRequest.parse(request);
      try {
        final displayed = DecisionBatchResult.parse(
          jsonEncode(output),
          parsed.request,
          expectedModel: parsed.model,
        );
        final received = DecisionBatchResult.parse(
          raw,
          parsed.request,
          expectedModel: parsed.model,
        );
        if (!_sameJson(displayed.toJson(), received.toJson())) {
          throw const FormatException('返回原文与解析 typed 判断不一致');
        }
      } on DecisionProtocolException catch (error) {
        throw FormatException('成功记录不是合法的公开 typed 判断：${error.message}');
      }
    }
  }
}

/// Owns only the directory of evaluation records, never models or datasets.
class BenchmarkRunStore {
  BenchmarkRunStore({required this.directory});
  final Directory directory;

  File _file(String id) {
    if (!BenchmarkRun._validId(id)) throw const FormatException('评测记录 ID 无效');
    return File('${directory.path}/$id.json');
  }

  Future<void> save(BenchmarkRun run) async {
    await directory.create(recursive: true);
    final target = _file(run.id);
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('评测记录不能是符号链接', target.path);
    }
    final temporary = await File('${target.path}.part').create(exclusive: true);
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(run.toJson()),
        flush: true,
      );
      await temporary.rename(target.path);
    } catch (error) {
      try {
        await temporary.delete();
      } catch (cleanupError) {
        throw FileSystemException(
          '保存失败：$error；清理失败：$cleanupError',
          temporary.path,
        );
      }
      rethrow;
    }
  }

  Future<List<BenchmarkRun>> list() async {
    if (!await directory.exists()) return const [];
    final records = <BenchmarkRun>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && entry.path.endsWith('.json')) {
        final filename = entry.uri.pathSegments.last;
        records.add(await load(filename.substring(0, filename.length - 5)));
      }
    }
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(records);
  }

  Future<void> exportTo(String id, File destination) async {
    if (!destination.isAbsolute) throw ArgumentError('导出需要完整绝对路径');
    final record = await load(id);
    final serialized = const JsonEncoder.withIndent('  ')
        .convert(record.toJson());
    await destination.create(exclusive: true);
    try {
      await destination.writeAsString(serialized, flush: true);
    } catch (error) {
      try {
        await destination.delete();
      } catch (cleanupError) {
        throw FileSystemException(
          '导出失败：$error；清理失败：$cleanupError',
          destination.path,
        );
      }
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    final target = _file(id);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('只能删除本批普通记录文件', target.path);
    }
    await target.delete();
  }

  Future<BenchmarkRun> load(String id) async {
    final file = _file(id);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('评测记录不存在或不是普通文件', file.path);
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('评测记录需要是对象');
    }
    final record = BenchmarkRun.fromJson(value.cast<String, Object?>());
    if (record.id != id) throw const FormatException('评测记录身份与文件不符');
    return record;
  }
}
