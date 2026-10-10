import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'benchmark_game_record.dart';
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
    if (value['schema_version'] == 2 ||
        value['schema_version'] == 4 ||
        value['schema_version'] == 6) {
      return _batchFromJson(value);
    }
    if (value['schema_version'] == 3) return _questionFromJson(value);
    if (value['schema_version'] == 5) return _gameFromJson(value);
    if (value['schema_version'] != 1 ||
        !_validId(value['id']) ||
        value['model'] is! String ||
        (value['model'] as String).isEmpty ||
        !const {'native', 'council'}.contains(value['source']) ||
        !const {'http', 'mcp'}.contains(value['channel']) ||
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
          channel: value['channel'] as String,
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
  factory BenchmarkRun.batch({
    required String id,
    required DateTime createdAt,
    required BenchmarkRunStatus status,
    required List<BenchmarkRun> evaluations,
  }) {
    if (evaluations.isEmpty || evaluations.any((run) => run.isBatch)) {
      throw const FormatException('对照批次需要独立对象/通道结果');
    }
    final journalSchema = evaluations.first.toJson()['schema_version'];
    final questionBatch = journalSchema == 3 || journalSchema == 5;
    if (evaluations.any(
      (run) => run.toJson()['schema_version'] != journalSchema,
    )) {
      throw const FormatException('同批不能混用不同题集记录格式');
    }
    if (questionBatch) {
      for (var index = 0; index < evaluations.length; index++) {
        if (evaluations[index].id != '$id-$index') {
          throw const FormatException('原题独立日志只能属于当前批次对象/通道');
        }
      }
    }
    final expected = questionBatch
        ? evaluations.fold<int>(
            0,
            (sum, run) => sum + (run.summary['expected'] as int),
          )
        : evaluations.length * 400;
    final names = evaluations.map((run) => run.model).toSet();
    final attempted = evaluations.fold<int>(
      0,
      (sum, run) => sum + (run.summary['attempted'] as int),
    );
    final document = {
      'schema_version': questionBatch ? (journalSchema as int) + 1 : 2,
      'id': id,
      'created_at': createdAt.toIso8601String(),
      'finished_at': status == BenchmarkRunStatus.running
          ? null
          : DateTime.now().toUtc().toIso8601String(),
      'status': status.name,
      'model': names.join(', '),
      'source': 'comparison',
      'channel': 'separate',
      'timeout_us': evaluations.first.timeout.inMicroseconds,
      'suite': evaluations.first.suite,
      'identity': {},
      'items': [],
      'groups': [],
      'summary': {
        'expected': expected,
        'attempted': attempted,
        'missing': expected - attempted,
        'complete':
            status == BenchmarkRunStatus.completed &&
            evaluations.every((run) => run.summary['complete'] == true),
        'evaluations': evaluations.length,
      },
      'evaluations': List<Map<String, Object?>>.unmodifiable([
        for (final run in evaluations) run.toJson(),
      ]),
    };
    if (!questionBatch) {
      return BenchmarkRun._(freezeDebugJson(document) as Map<String, Object?>);
    }
    final header = freezeDebugJson({
      ...document,
      'evaluations': <Object?>[],
    }) as Map<String, Object?>;
    return BenchmarkRun._(
      Map<String, Object?>.unmodifiable({
        ...header,
        'evaluations': document['evaluations'],
      }),
    );
  }

  static BenchmarkRun _batchFromJson(Map<String, Object?> value) {
    final entries = value['evaluations'];
    if (!_validId(value['id']) ||
        !_validDate(value['created_at']) ||
        value['finished_at'] != null && !_validDate(value['finished_at']) ||
        !BenchmarkRunStatus.values.any(
          (status) => status.name == value['status'],
        ) ||
        entries is! List ||
        entries.isEmpty ||
        entries.any(
          (entry) =>
              entry is! Map ||
              entry['schema_version'] !=
                  (value['schema_version'] == 2
                      ? 1
                      : (value['schema_version'] as int) - 1),
        )) {
      throw const FormatException('对照批次身份、状态或独立结果无效');
    }
    final evaluations = [
      for (final entry in entries)
        BenchmarkRun.fromJson(Map<String, Object?>.from(entry as Map)),
    ];
    final pairs = <String>{};
    final identities = <String, Map<String, Object?>>{};
    for (final run in evaluations) {
      final identity = identities.putIfAbsent(run.model, () => run.identity);
      if (!_sameJson(identity, run.identity) ||
          !pairs.add(jsonEncode([run.model, run.channel])) ||
          run.timeout != evaluations.first.timeout ||
          !_sameJson(run.suite, evaluations.first.suite)) {
        throw const FormatException('对照批次对象/通道重复或题库/期限/运行身份不一致');
      }
    }
    final rebuilt = BenchmarkRun.batch(
      id: value['id'] as String,
      createdAt: DateTime.parse(value['created_at'] as String),
      status: BenchmarkRunStatus.values.byName(value['status'] as String),
      evaluations: evaluations,
    );
    if (!_sameJson(value['summary'], rebuilt.summary) ||
        value['model'] != rebuilt.model ||
        value['timeout_us'] != rebuilt.timeout.inMicroseconds ||
        !_sameJson(value['suite'], rebuilt.suite)) {
      throw const FormatException('对照批次摘要与独立结果不一致');
    }
    return BenchmarkRun._(
      freezeDebugJson({
        ...rebuilt.toJson(),
        'finished_at': value['finished_at'],
      }) as Map<String, Object?>,
    );
  }

  /// Trusted application snapshots reuse already sealed rows. Their immutable
  /// prefix length prevents later replies from changing earlier notifications.
  factory BenchmarkRun.questionSnapshot({
    required Map<String, Object?> header,
    required List<Map<String, Object?>> items,
  }) {
    _validateQuestionHeader(header);
    final sealed = sealDebugJson({
      ...header,
      'items': <Object?>[],
    }, projection: JevDebugProjection.benchmarkQuestionRun);
    return BenchmarkRun._(
      Map<String, Object?>.unmodifiable({
        ...sealed,
        'items': _RowPrefix(items, items.length),
      }),
    );
  }

  static Map<String, Object?> questionItem(
    Map<String, Object?> row, {
    required String model,
    required String channel,
    required Map<String, Object?> identity,
  }) {
    _validateQuestionItem(row, model: model, channel: channel);
    final sealed = sealDebugJson({
      'items': [row],
      'identity': identity,
    }, projection: JevDebugProjection.benchmarkQuestionRun);
    return (sealed['items'] as List).single as Map<String, Object?>;
  }

  factory BenchmarkRun.gameSnapshot({
    required Map<String, Object?> header,
    required List<Map<String, Object?>> items,
  }) {
    _validateGameHeader(header);
    final sealed = sealDebugJson({
      ...header,
      'items': <Object?>[],
    }, projection: JevDebugProjection.benchmarkGameRun);
    return BenchmarkRun._(
      Map<String, Object?>.unmodifiable({
        ...sealed,
        'items': _RowPrefix(items, items.length),
      }),
    );
  }

  static Map<String, Object?> gameItem(
    Map<String, Object?> row, {
    required String model,
    required String channel,
    required Map<String, Object?> identity,
  }) {
    _validateGameItem(row, model: model, channel: channel);
    final sealed = sealDebugJson({
      'items': [row],
      'identity': identity,
    }, projection: JevDebugProjection.benchmarkGameRun);
    return (sealed['items'] as List).single as Map<String, Object?>;
  }

  static void _validateGameItem(
    Map<String, Object?> row, {
    required String model,
    required String channel,
  }) {
    BenchmarkGameRecord.parse(
      row,
      model: model,
      channel: JevPlaygroundMode.values.byName(channel),
    );
    if (row['id'] != 'game-${row['index']}') {
      throw const FormatException('游戏日志局号与记录ID不一致');
    }
    for (final value in row['calls'] as List) {
      final call = value as Map;
      _validateRequest(call['request'], null, model, allowUnsupported: true);
      if (call['result'] != null) {
        _validateResult(
          call['result'],
          model: model,
          channel: channel,
          expectedRequest: call['request'],
          allowUnsupported: true,
        );
      }
    }
  }

  static BenchmarkRun _gameFromJson(Map<String, Object?> value) {
    _validateGameHeader(value);
    final items = value['items'];
    if (items is! List ||
        items.length != (value['summary'] as Map)['attempted']) {
      throw const FormatException('游戏历史局数与进度不一致');
    }
    var completed = 0;
    for (var index = 0; index < items.length; index++) {
      final row = items[index];
      if (row is! Map<String, Object?> || row['index'] != index + 1) {
        throw const FormatException('游戏原局号必须唯一连续');
      }
      _validateGameItem(
        row,
        model: value['model'] as String,
        channel: value['channel'] as String,
      );
      if (row['complete'] == true) completed++;
    }
    final summary = value['summary'] as Map;
    final source = value['source_summary'] as Map;
    if (summary['valid'] != completed ||
        summary['failures'] != items.length - completed ||
        summary['complete'] == true &&
            (items.length != 100 ||
                completed != 100 ||
                source['complete'] != true) ||
        summary['complete'] != true &&
            (source['summary'] != null || source['originalSummary'] != null)) {
      throw const FormatException('游戏覆盖或完整100局原成绩不一致');
    }
    return BenchmarkRun._(
      sealDebugJson(value, projection: JevDebugProjection.benchmarkGameRun),
    );
  }

  static void _validateQuestionHeader(Map<String, Object?> value) =>
      _validateJournalHeader(value, game: false);
  static void _validateGameHeader(Map<String, Object?> value) {
    _validateJournalHeader(value, game: true);
    final warmup = value['warmup_calls'];
    if (warmup is! List ||
        value['client_summary'] is! Map ||
        !_finiteJson(value['client_summary'])) {
      throw const FormatException('游戏预热或客户端证据无效');
    }
    final ids = <int>{};
    for (final call in warmup) {
      if (call is! Map ||
          call['phase'] != 'warmup' ||
          call['channel'] != value['channel'] ||
          call['id'] is! int ||
          !ids.add(call['id'] as int)) {
        throw const FormatException('原预热调用身份或通道无效');
      }
      _validateRequest(
        call['request'],
        null,
        value['model'] as String,
        allowUnsupported: true,
      );
      if (call['result'] != null) {
        _validateResult(
          call['result'],
          model: value['model'] as String,
          channel: value['channel'] as String,
          expectedRequest: call['request'],
          allowUnsupported: true,
        );
      }
    }
  }

  static void _validateJournalHeader(
    Map<String, Object?> value, {
    required bool game,
  }) {
    final summary = value['summary'];
    final suite = value['suite'];
    if (value['schema_version'] != (game ? 5 : 3) ||
        !_validId(value['id']) ||
        value['model'] is! String ||
        (value['model'] as String).isEmpty ||
        !const {'native', 'council'}.contains(value['source']) ||
        !const {'http', 'mcp'}.contains(value['channel']) ||
        !BenchmarkRunStatus.values.any(
          (status) => status.name == value['status'],
        ) ||
        value['timeout_us'] is! int ||
        (value['timeout_us'] as int) <= 0 ||
        !_validDate(value['created_at']) ||
        value['finished_at'] != null && !_validDate(value['finished_at']) ||
        suite is! Map ||
        !(game
            ? suite['id'] == 'jevman'
            : const {
                'jeval',
                'coherence',
                'adversarial',
              }.contains(suite['id'])) ||
        suite['pin'] is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(suite['pin'] as String) ||
        value['identity'] is! Map ||
        value['source_summary'] is! Map ||
        value['groups'] is! List ||
        summary is! Map ||
        summary['expected'] is! int ||
        (summary['expected'] as int) <= 0 ||
        summary['attempted'] is! int ||
        (summary['attempted'] as int) < 0 ||
        (summary['attempted'] as int) > (summary['expected'] as int) ||
        summary['missing'] !=
            (summary['expected'] as int) - (summary['attempted'] as int) ||
        summary['complete'] is! bool ||
        summary['error'] != null && summary['error'] is! String) {
      throw const FormatException('原题评测身份、原版本或进度无效');
    }
    // Historical versions retain their own published full denominator; current
    // runtime task counts must not rewrite or shrink that fixed suite identity.
    final publishedCount = switch (suite['id']) {
      'jeval' => suite['questionCount'],
      'coherence' => suite['requests'],
      'adversarial' => suite['requestCount'],
      'jevman' => suite['games'],
      _ => null,
    };
    if (game &&
        (suite['games'] != 100 ||
            suite['pin'] != '1c8b77ac61bafa10956c601b1c9b339dcd277836' ||
            value['timeout_us'] != 2000000)) {
      throw const FormatException('游戏必须使用原100局及固定2秒决策期限');
    }
    if (publishedCount is! int ||
        publishedCount <= 0 ||
        summary['expected'] != publishedCount) {
      throw const FormatException('原题完整分母与固定来源声明不一致');
    }
    for (final key in const [
      'valid',
      'failures',
      'client_timeouts',
      'server_timeouts',
      'timeouts',
    ]) {
      if (summary[key] is! int || (summary[key] as int) < 0) {
        throw FormatException('原题客户端计数无效：$key');
      }
    }
    if ((summary['valid'] as int) + (summary['failures'] as int) !=
            summary['attempted'] ||
        summary['timeouts'] !=
            (summary['client_timeouts'] as int) +
                (summary['server_timeouts'] as int) ||
        summary['complete'] == true &&
            (value['status'] != 'completed' || summary['missing'] != 0) ||
        !_finiteJson(value['source_summary']) ||
        !_finiteJson(value['groups']) ||
        !_finiteJson(value['suite']) ||
        !_finiteJson(value['identity'])) {
      throw const FormatException('原题客户端覆盖与原评分不一致或包含非法数值');
    }
    for (final key in const [
      'latency_success_p50_ms',
      'latency_success_p95_ms',
    ]) {
      final metric = summary[key];
      if (metric != null &&
          (metric is! num || !metric.isFinite || metric < 0)) {
        throw FormatException('原题延迟指标无效：$key');
      }
    }
    if ((value['groups'] as List).any((group) => group is! Map)) {
      throw const FormatException('原题分组记录无效');
    }
  }

  static bool _finiteJson(Object? value) => switch (value) {
    null || String() || bool() => true,
    num() => value.isFinite,
    List() => value.every(_finiteJson),
    Map() =>
      value.keys.every((key) => key is String) &&
          value.values.every(_finiteJson),
    _ => false,
  };

  static void _validateQuestionItem(
    Map row, {
    required String model,
    required String channel,
  }) {
    if (row['id'] is! String ||
        (row['id'] as String).isEmpty ||
        row['metadata'] is! Map ||
        row['source_result'] is! Map ||
        !JevPlaygroundStatus.values.any(
          (status) => status.name == row['status'],
        ) ||
        row['elapsed_us'] is! int ||
        (row['elapsed_us'] as int) < 0 ||
        row['error'] != null && row['error'] is! String ||
        row['dispatched'] != null && row['dispatched'] is! bool ||
        row['request'] is! Map ||
        row['request_json'] is! String ||
        row['original_request_json'] is! String ||
        row['request_representation'] !=
            (channel == 'http' ? 'original-json' : 'mcp-object') ||
        row['result'] is! Map ||
        !_finiteJson(row['metadata']) ||
        !_finiteJson(row['source_result'])) {
      throw const FormatException('原题逐请求证据无效');
    }
    _validateRequest(
      row['request'],
      row['request_json'],
      model,
      allowUnsupported: true,
    );
    _validateRequest(
      row['request'],
      row['original_request_json'],
      model,
      allowUnsupported: true,
    );
    _validateResult(
      row['result'],
      model: model,
      channel: channel,
      expectedRequest: row['request'],
      allowUnsupported: true,
    );
    final result = row['result'] as Map;
    if (row['status'] != result['status'] ||
        row['elapsed_us'] != result['elapsed_us']) {
      throw const FormatException('原题客户端状态或耗时不一致');
    }
  }

  static BenchmarkRun _questionFromJson(Map<String, Object?> value) {
    _validateQuestionHeader(value);
    final items = value['items'];
    if (items is! List ||
        items.length != (value['summary'] as Map)['attempted']) {
      throw const FormatException('原题历史逐请求数量不一致');
    }
    final ids = <String>{};
    var valid = 0, clientTimeouts = 0, serverTimeouts = 0;
    for (final row in items) {
      if (row is! Map ||
          row['id'] is! String ||
          !ids.add(row['id'] as String)) {
        throw const FormatException('原题请求 ID 无效或重复');
      }
      _validateQuestionItem(
        row,
        model: value['model'] as String,
        channel: value['channel'] as String,
      );
      if (row['status'] == JevPlaygroundStatus.success.name) valid++;
      if (row['status'] == JevPlaygroundStatus.timedOut.name) clientTimeouts++;
      final output = (row['result'] as Map)['output'];
      if (row['status'] == JevPlaygroundStatus.businessError.name &&
          output is Map &&
          output['error'] is Map &&
          (output['error'] as Map)['code'] == 'timed_out') {
        serverTimeouts++;
      }
    }
    final summary = value['summary'] as Map;
    if (summary['valid'] != valid ||
        summary['failures'] != items.length - valid ||
        summary['client_timeouts'] != clientTimeouts ||
        summary['server_timeouts'] != serverTimeouts ||
        summary['timeouts'] != clientTimeouts + serverTimeouts) {
      throw const FormatException('原题客户端覆盖与逐请求实际结果不一致');
    }
    return BenchmarkRun._(
      sealDebugJson(value, projection: JevDebugProjection.benchmarkQuestionRun),
    );
  }

  const BenchmarkRun._(this._json);
  final Map<String, Object?> _json;
  bool get isBatch =>
      _json['schema_version'] == 2 ||
      _json['schema_version'] == 4 ||
      _json['schema_version'] == 6;
  bool get isQuestionRun =>
      _json['schema_version'] == 3 || _json['schema_version'] == 4;
  bool get isGameRun =>
      _json['schema_version'] == 5 || _json['schema_version'] == 6;
  bool get usesJournal => isQuestionRun || isGameRun;
  bool get hasItemDetails => isBatch
      ? evaluations.every((run) => run.hasItemDetails)
      : items.length == summary['attempted'];
  String get channel => _json['channel'] as String;
  List<BenchmarkRun> get evaluations => isBatch
      ? List.unmodifiable(
          (_json['evaluations'] as List).map(
            (entry) => BenchmarkRun._(entry as Map<String, Object?>),
          ),
        )
      : [this];

  /// Gains and costs compare only same-batch complete results in one channel.
  /// Seat-level success is unknown without public debug from that exact call.
  List<Map<String, Object?>> get comparisons {
    if (!isBatch) return const [];
    final rows = <Map<String, Object?>>[];
    for (final council in evaluations.where((run) => run.source == 'council')) {
      for (final native in evaluations.where(
        (run) => run.source == 'native' && run.channel == council.channel,
      )) {
        double? difference(String key) {
          final left = council.summary[key], right = native.summary[key];
          return council.summary['complete'] == true &&
                  native.summary['complete'] == true &&
                  left is num &&
                  right is num
              ? (left - right).toDouble()
              : null;
        }

        rows.add({
          'council': council.model,
          'native': native.model,
          'channel': council.channel,
          'comparable':
              council.summary['complete'] == true &&
              native.summary['complete'] == true,
          'accuracy_delta': difference('accuracy'),
          'pair_accuracy_delta': difference('pair_accuracy'),
          'latency_success_p50_ms_delta': difference('latency_success_p50_ms'),
          'latency_success_p95_ms_delta': difference('latency_success_p95_ms'),
          'failures_delta': difference('failures'),
          'probability_coverage_delta': difference('probability_coverage'),
          'successful_seat_coverage': null,
        });
      }
    }
    return List.unmodifiable(rows);
  }

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

  static void _validateRequest(
    Object? request,
    Object? raw,
    String model, {
    bool allowUnsupported = false,
  }) {
    if (request != null &&
        (allowUnsupported
            ? request is! Map || request['model'] != model
            : JevModelRequest.parse(request).model != model)) {
      throw const FormatException('请求模型与本批身份不一致');
    }
    if (raw != null) {
      if (raw is! String) throw const FormatException('请求快照需要是字符串');
      final decoded = jsonDecode(raw);
      if ((allowUnsupported
              ? decoded is! Map || decoded['model'] != model
              : JevModelRequest.parse(decoded).model != model) ||
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
    required String channel,
    Object? expectedRequest,
    bool allowUnsupported = false,
  }) {
    if (value is! Map ||
        !JevPlaygroundStatus.values.any((s) => s.name == value['status']) ||
        value['channel'] != channel ||
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
    _validateRequest(
      value['request'],
      value['request_json'],
      model,
      allowUnsupported: allowUnsupported,
    );
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
  final _journals = <String, _QuestionJournal>{};

  File _file(String id) {
    if (!BenchmarkRun._validId(id)) throw const FormatException('评测记录 ID 无效');
    return File('${directory.path}/$id.json');
  }

  Future<void> save(BenchmarkRun run) async {
    if (run.usesJournal) {
      await _saveQuestions(run);
      return;
    }
    await _saveDocument(run.id, run.toJson());
  }

  Future<void> _saveDocument(String id, Map<String, Object?> document) async {
    await directory.create(recursive: true);
    final target = _file(id);
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('评测记录不能是符号链接', target.path);
    }
    final temporary = await File('${target.path}.part').create(exclusive: true);
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(document),
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
        records.add(
          await _load(
            filename.substring(0, filename.length - 5),
            details: false,
          ),
        );
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
    final document = await _readDocument(id);
    if (const {3, 4, 5, 6}.contains(document['schema_version'])) {
      // Validate every owner-bound journal before any deletion starts.
      await _load(id, details: true);
      final entries = _questionEntries(document);
      for (var index = 0; index < entries.length; index++) {
        await _journalFile(id, index).delete();
        _journals.remove('$id/$index');
      }
    }
    await target.delete();
  }

  Future<BenchmarkRun> load(String id) => _load(id, details: true);

  Future<Map<String, Object?>> _readDocument(String id) async {
    final file = _file(id);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('评测记录不存在或不是普通文件', file.path);
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('评测记录需要是对象');
    }
    if (value['id'] != id) throw const FormatException('评测记录身份与文件不符');
    return value.cast<String, Object?>();
  }

  File _journalFile(String owner, int index) =>
      File('${directory.path}/$owner-$index.items.jsonl');

  List<Map<String, Object?>> _questionEntries(Map<String, Object?> document) {
    if (document['schema_version'] == 3 || document['schema_version'] == 5) {
      return [document];
    }
    final entries = document['evaluations'];
    if (!const {4, 6}.contains(document['schema_version']) ||
        entries is! List ||
        entries.isEmpty ||
        entries.any(
          (entry) =>
              entry is! Map ||
              entry['schema_version'] !=
                  (document['schema_version'] as int) - 1,
        )) {
      throw const FormatException('原题批次独立记录无效');
    }
    return [
      for (final entry in entries) Map<String, Object?>.from(entry as Map),
    ];
  }

  Future<void> _saveQuestions(BenchmarkRun run) async {
    if (!run.hasItemDetails) throw StateError('元数据历史不能作为新推理结果保存');
    await directory.create(recursive: true);
    final stored = <Map<String, Object?>>[];
    final evaluations = run.evaluations;
    for (var index = 0; index < evaluations.length; index++) {
      final evaluation = evaluations[index];
      final key = '${run.id}/$index';
      final file = _journalFile(run.id, index);
      var journal = _journals[key];
      if (journal == null) {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.notFound ||
            await FileSystemEntity.type(
                  _file(run.id).path,
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound) {
          throw FileSystemException('既有原题历史不能覆盖或续跑', file.path);
        }
        await file.create(exclusive: true);
        journal = _QuestionJournal(evaluation);
        _journals[key] = journal;
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != journal.bytes ||
          !journal.matches(evaluation) ||
          evaluation.items.length < journal.count) {
        throw FileSystemException('原题日志或评测身份已变化', file.path);
      }
      if (evaluation.items.length > journal.count) {
        final output = await file.open(mode: FileMode.append);
        try {
          while (journal.count < evaluation.items.length) {
            final row = evaluation.items[journal.count];
            if (evaluation.isGameRun) {
              BenchmarkRun._validateGameItem(
                row,
                model: evaluation.model,
                channel: evaluation.channel,
              );
            } else {
              BenchmarkRun._validateQuestionItem(
                row,
                model: evaluation.model,
                channel: evaluation.channel,
              );
            }
            if (!journal.ids.add(row['id'] as String)) {
              throw const FormatException('原题追加请求 ID 重复');
            }
            final payload = utf8.encode(jsonEncode(row));
            final digest = sha256.convert([
              ...utf8.encode(journal.head),
              ...payload,
            ]).toString();
            final line = utf8.encode(
              '${jsonEncode({'previous': journal.head, 'sha256': digest, 'item': row})}\n',
            );
            await output.writeFrom(line);
            await output.flush();
            journal.bytes += line.length;
            journal.count++;
            journal.head = digest;
          }
        } finally {
          await output.close();
        }
      }
      stored.add({
        ...evaluation.toJson(),
        'items': <Object?>[],
        'journal': {
          'format': 'gmd-frozen-request-journal-v1',
          'file': file.uri.pathSegments.last,
          'count': journal.count,
          'bytes': journal.bytes,
          'sha256': journal.head,
        },
      });
    }
    final document = run.isBatch
        ? {...run.toJson(), 'evaluations': stored}
        : stored.single;
    await _saveDocument(run.id, document);
  }

  Future<BenchmarkRun> _load(String id, {required bool details}) async {
    final document = await _readDocument(id);
    if (!const {3, 4, 5, 6}.contains(document['schema_version'])) {
      return BenchmarkRun.fromJson(document);
    }
    final entries = _questionEntries(document);
    final evaluations = <BenchmarkRun>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry['schema_version'] == 5) {
        BenchmarkRun._validateGameHeader(entry);
      } else {
        BenchmarkRun._validateQuestionHeader(entry);
      }
      if (entry['id'] !=
              (const {3, 5}.contains(document['schema_version'])
                  ? id
                  : '$id-$index') ||
          entry['items'] is! List ||
          (entry['items'] as List).isNotEmpty) {
        throw const FormatException('原题日志所属批次或文件结构不一致');
      }
      final file = _journalFile(id, index);
      final descriptor = entry['journal'];
      if (descriptor is! Map ||
          descriptor['format'] != 'gmd-frozen-request-journal-v1' ||
          descriptor['file'] != file.uri.pathSegments.last ||
          descriptor['count'] != (entry['summary'] as Map)['attempted'] ||
          descriptor['bytes'] is! int ||
          (descriptor['bytes'] as int) < 0 ||
          descriptor['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(descriptor['sha256'] as String) ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != descriptor['bytes']) {
        throw FileSystemException('原题日志摘要、数量或普通文件身份无效', file.path);
      }
      final header = {...entry}..remove('journal');
      if (!details) {
        evaluations.add(
          entry['schema_version'] == 5
              ? BenchmarkRun.gameSnapshot(header: header, items: [])
              : BenchmarkRun.questionSnapshot(header: header, items: []),
        );
        continue;
      }
      final rows = <Map<String, Object?>>[];
      var head = _QuestionJournal.emptyHead;
      final ids = <String>{};
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final envelope = jsonDecode(line);
        if (envelope is! Map ||
            envelope['previous'] != head ||
            envelope['item'] is! Map) {
          throw const FormatException('原题逐行日志损坏或顺序不一致');
        }
        final row = Map<String, Object?>.from(envelope['item'] as Map);
        final digest = sha256.convert([
          ...utf8.encode(head),
          ...utf8.encode(jsonEncode(row)),
        ]).toString();
        if (envelope['sha256'] != digest ||
            row['id'] is! String ||
            !ids.add(row['id'] as String)) {
          throw const FormatException('原题逐行内容摘要或请求 ID 无效');
        }
        if (entry['schema_version'] == 5) {
          BenchmarkRun._validateGameItem(
            row,
            model: entry['model'] as String,
            channel: entry['channel'] as String,
          );
        } else {
          BenchmarkRun._validateQuestionItem(
            row,
            model: entry['model'] as String,
            channel: entry['channel'] as String,
          );
        }
        rows.add(row);
        head = digest;
      }
      if (rows.length != descriptor['count'] || head != descriptor['sha256']) {
        throw const FormatException('原题日志未完整封存或含额外请求');
      }
      evaluations.add(BenchmarkRun.fromJson({...header, 'items': rows}));
    }
    if (document['schema_version'] == 3 || document['schema_version'] == 5) {
      return evaluations.single;
    }
    if (!BenchmarkRun._validDate(document['created_at']) ||
        !BenchmarkRunStatus.values.any(
          (status) => status.name == document['status'],
        )) {
      throw const FormatException('原题对照批次状态无效');
    }
    final pairs = <String>{};
    final identities = <String, Map<String, Object?>>{};
    for (final evaluation in evaluations) {
      final identity = identities.putIfAbsent(
        evaluation.model,
        () => evaluation.identity,
      );
      if (!pairs.add(jsonEncode([evaluation.model, evaluation.channel])) ||
          !BenchmarkRun._sameJson(identity, evaluation.identity) ||
          !BenchmarkRun._sameJson(evaluation.suite, evaluations.first.suite) ||
          evaluation.timeout != evaluations.first.timeout) {
        throw const FormatException('原题对照对象、题集、身份或期限不一致');
      }
    }
    final rebuilt = BenchmarkRun.batch(
      id: id,
      createdAt: DateTime.parse(document['created_at'] as String),
      status: BenchmarkRunStatus.values.byName(document['status'] as String),
      evaluations: evaluations,
    );
    if (!BenchmarkRun._sameJson(document['summary'], rebuilt.summary) ||
        document['model'] != rebuilt.model ||
        document['source'] != 'comparison' ||
        document['channel'] != 'separate' ||
        document['timeout_us'] != rebuilt.timeout.inMicroseconds ||
        !BenchmarkRun._sameJson(document['suite'], rebuilt.suite) ||
        document['finished_at'] != null &&
            !BenchmarkRun._validDate(document['finished_at'])) {
      throw const FormatException('原题对照总记录与各独立结果不一致');
    }
    return BenchmarkRun._(
      Map<String, Object?>.unmodifiable({
        ...rebuilt.toJson(),
        'finished_at': document['finished_at'],
      }),
    );
  }
}

class _QuestionJournal {
  _QuestionJournal(BenchmarkRun evaluation)
    : model = evaluation.model,
      channel = evaluation.channel,
      source = evaluation.source,
      timeout = evaluation.timeout,
      suite = evaluation.suite,
      createdAt = evaluation.createdAt,
      id = evaluation.id;
  static const emptyHead =
      '0000000000000000000000000000000000000000000000000000000000000000';
  final String model, channel, source, id;
  final Duration timeout;
  final Map<String, Object?> suite;
  final DateTime createdAt;
  final ids = <String>{};
  int count = 0, bytes = 0;
  String head = emptyHead;
  bool matches(BenchmarkRun evaluation) =>
      evaluation.id == id &&
      evaluation.model == model &&
      evaluation.channel == channel &&
      evaluation.source == source &&
      evaluation.timeout == timeout &&
      evaluation.createdAt == createdAt &&
      BenchmarkRun._sameJson(evaluation.suite, suite);
}

class _RowPrefix extends ListBase<Map<String, Object?>> {
  _RowPrefix(this._rows, this._length);
  final List<Map<String, Object?>> _rows;
  final int _length;
  @override
  int get length => _length;
  @override
  set length(int value) => throw UnsupportedError('immutable benchmark rows');
  @override
  Map<String, Object?> operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _rows[index];
  }

  @override
  void operator []=(int index, Map<String, Object?> value) =>
      throw UnsupportedError('immutable benchmark rows');
}
