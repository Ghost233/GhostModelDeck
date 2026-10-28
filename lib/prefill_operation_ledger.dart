import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'generation_seed.dart';
import 'prefill_operation_id.dart';
import 'splash_operation_client.dart';

enum PrefillOperationKind { prefill, consume }

enum PrefillResultFailure { unavailable, invalid }

enum PrefillOperationState {
  queued,
  running,
  cancelRequested,
  completed,
  cancelled,
  failed,
  rejected,
  unknown,
}

class PrefillOperationForbidden implements Exception {}

class PrefillOperationConflict implements Exception {}

class PrefillCacheBusy implements Exception {}

class PrefillCapacityUnavailable implements Exception {
  const PrefillCapacityUnavailable(this.operation);
  final PrefillOperationView operation;
}

class PrefillAdmissionNotAdmitted implements Exception {
  const PrefillAdmissionNotAdmitted(this.operation);
  final PrefillOperationView operation;
}

/// No rejection record could be saved; there is no safe refusal proof.
class PrefillRejectionCapacityUnavailable implements Exception {}

class PrefillTerminalUnconfirmed implements Exception {}

class PrefillOperationExpired implements Exception {}

class PrefillLegacyCapacityUnavailable implements Exception {}

class PrefillLegacyLease {
  const PrefillLegacyLease._(this._id);
  final String _id;
}

class _LegacyUse {
  const _LegacyUse(this.id, this.owner, this.saltHash);
  final String id, owner, saltHash;
  Map<String, Object> toJson() => {
    'id': id,
    'owner': owner,
    'salt_hash': saltHash,
  };
  static _LegacyUse parse(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['owner'] is! String ||
        value['salt_hash'] is! String ||
        !_idPattern.hasMatch(value['id'] as String) ||
        (value['owner'] as String).isEmpty ||
        (value['owner'] as String).length > 2048 ||
        !_hashPattern.hasMatch(value['salt_hash'] as String)) {
      throw const FormatException('普通请求占用记录无效');
    }
    return _LegacyUse(
      value['id'] as String,
      value['owner'] as String,
      value['salt_hash'] as String,
    );
  }
}

class PrefillOperationView {
  const PrefillOperationView({
    required this.id,
    required this.state,
    this.response,
    this.nativeEvidence,
    this.nativeDispatchNotStarted = false,
    this.identityOnly = false,
    this.cancelRequested = false,
    this.model,
    this.generation,
    this.cacheSaltHash,
    this.resultFailure,
  });
  final String id;
  final PrefillOperationState state;
  final String? response;
  final SplashOperationSnapshot? nativeEvidence;
  final bool nativeDispatchNotStarted;
  final bool identityOnly;
  final bool cancelRequested;
  final String? model, generation, cacheSaltHash;
  final PrefillResultFailure? resultFailure;
  bool get terminal => {
    PrefillOperationState.completed,
    PrefillOperationState.cancelled,
    PrefillOperationState.failed,
    PrefillOperationState.rejected,
  }.contains(state);
  bool get leaseReleased => terminal;
}

class PrefillAdmission {
  const PrefillAdmission({required this.created, required this.operation});
  final bool created;
  final PrefillOperationView operation;
}

class _Record {
  const _Record({
    required this.id,
    required this.tokenHash,
    required this.model,
    required this.owner,
    required this.generation,
    required this.saltHash,
    required this.requestHash,
    required this.kind,
    required this.state,
    this.nativeServiceInstance,
    this.nativeRuntimeGeneration,
    this.response,
    this.finishedAtMs,
    this.finishedAtElapsedMs,
    this.nativeEvidence,
    this.cancelRequested = false,
    this.resultFailure,
  });
  final String id, tokenHash, model, owner, generation, saltHash, requestHash;
  final PrefillOperationKind kind;
  final PrefillOperationState state;
  final String? nativeServiceInstance;
  final int? nativeRuntimeGeneration;
  final int? finishedAtMs;
  final int? finishedAtElapsedMs;
  // Results remain in memory; after restart their availability is unknown.
  final String? response;
  final SplashOperationSnapshot? nativeEvidence;
  final bool cancelRequested;
  final PrefillResultFailure? resultFailure;
  PrefillOperationView get view => PrefillOperationView(
    id: id,
    state: state,
    response: response,
    nativeEvidence: nativeEvidence,
    cancelRequested: cancelRequested,
    model: model,
    generation: generation,
    cacheSaltHash: saltHash,
    resultFailure: resultFailure,
    nativeDispatchNotStarted:
        state == PrefillOperationState.rejected ||
        state == PrefillOperationState.cancelled &&
            nativeServiceInstance == null,
  );
  _Record afterRestart(int elapsed) => _Record(
    id: id,
    tokenHash: tokenHash,
    model: model,
    owner: owner,
    generation: generation,
    saltHash: saltHash,
    requestHash: requestHash,
    kind: kind,
    state: state == PrefillOperationState.rejected
        ? PrefillOperationState.rejected
        : PrefillOperationState.unknown,
    nativeServiceInstance: nativeServiceInstance,
    nativeRuntimeGeneration: nativeRuntimeGeneration,
    finishedAtMs: state == PrefillOperationState.rejected ? finishedAtMs : null,
    finishedAtElapsedMs: state == PrefillOperationState.rejected
        ? elapsed
        : null,
    cancelRequested: cancelRequested,
  );
  _Record update({
    PrefillOperationState? state,
    String? nativeServiceInstance,
    int? nativeRuntimeGeneration,
    String? response,
    int? finishedAtMs,
    int? finishedAtElapsedMs,
    SplashOperationSnapshot? nativeEvidence,
    bool? cancelRequested,
    PrefillResultFailure? resultFailure,
  }) => _Record(
    id: id,
    tokenHash: tokenHash,
    model: model,
    owner: owner,
    generation: generation,
    saltHash: saltHash,
    requestHash: requestHash,
    kind: kind,
    state: state ?? this.state,
    nativeServiceInstance: nativeServiceInstance ?? this.nativeServiceInstance,
    nativeRuntimeGeneration:
        nativeRuntimeGeneration ?? this.nativeRuntimeGeneration,
    response: response ?? this.response,
    finishedAtMs: finishedAtMs ?? this.finishedAtMs,
    finishedAtElapsedMs: finishedAtElapsedMs ?? this.finishedAtElapsedMs,
    nativeEvidence: nativeEvidence ?? this.nativeEvidence,
    cancelRequested: cancelRequested ?? this.cancelRequested,
    resultFailure: resultFailure ?? this.resultFailure,
  );
  Map<String, Object> toJson() => {
    'id': id,
    'token_hash': tokenHash,
    'model': model,
    'owner': owner,
    'generation': generation,
    'salt_hash': saltHash,
    'request_hash': requestHash,
    'kind': kind.name,
    'state': state.name,
    'native_service_instance': ?nativeServiceInstance,
    'native_runtime_generation': ?nativeRuntimeGeneration,
    'finished_at_ms': ?finishedAtMs,
    'cancel_requested': cancelRequested,
  };
  static _Record parse(Object? value) {
    if (value is! Map) throw const FormatException('操作登记格式无效');
    String text(String key) {
      final item = value[key];
      if (item is! String || item.isEmpty || item.length > 2048) {
        throw const FormatException('操作登记字段无效');
      }
      return item;
    }

    final id = text('id');
    final tokenHash = text('token_hash');
    final saltHash = text('salt_hash');
    final requestHash = text('request_hash');
    final kind = PrefillOperationKind.values
        .where((item) => item.name == value['kind'])
        .singleOrNull;
    final state = PrefillOperationState.values
        .where((item) => item.name == value['state'])
        .singleOrNull;
    if (!_idPattern.hasMatch(id) ||
        ![tokenHash, saltHash, requestHash].every(_hashPattern.hasMatch) ||
        kind == null ||
        state == null) {
      throw const FormatException('操作登记字段无效');
    }
    final generation = text('generation');
    if (PrefillOperationId.parse(id).generationHash != _hash(generation)) {
      throw const FormatException('操作登记代次不匹配');
    }
    final nativeService = value['native_service_instance'];
    final nativeGeneration = value['native_runtime_generation'];
    final finishedAt = value['finished_at_ms'];
    final cancellation =
        value['cancel_requested'] ??
        (state == PrefillOperationState.cancelRequested);
    if ((nativeService == null) != (nativeGeneration == null) ||
        nativeService != null &&
            (nativeService is! String || !_idPattern.hasMatch(nativeService)) ||
        nativeGeneration != null &&
            (nativeGeneration is! int || nativeGeneration < 1) ||
        finishedAt != null && (finishedAt is! int || finishedAt < 0) ||
        cancellation is! bool ||
        state == PrefillOperationState.rejected &&
            (nativeService != null || finishedAt == null)) {
      throw const FormatException('原生操作绑定无效');
    }
    return _Record(
      id: id,
      tokenHash: tokenHash,
      model: text('model'),
      owner: text('owner'),
      generation: generation,
      saltHash: saltHash,
      requestHash: requestHash,
      kind: kind,
      state: state,
      nativeServiceInstance: nativeService as String?,
      nativeRuntimeGeneration: nativeGeneration as int?,
      finishedAtMs: finishedAt as int?,
      cancelRequested: cancellation,
    );
  }
}

final _idPattern = RegExp(r'^[A-Za-z0-9._~-]{1,128}$');
final _tokenPattern = RegExp(r'^[0-9a-fA-F]{64}$');
final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
String _hash(String input) => sha256.convert(utf8.encode(input)).toString();
String _requestDigest(Map<String, Object?> request) =>
    _hash(encodeGenerationRequest(_canonical(request) as Map<String, Object?>));
String _newBootIdentity() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Persistent admission ledger. No source material or operation token is stored.
/// This component does not itself claim that an engine has finished or released.
class PrefillOperationLedger {
  PrefillOperationLedger._(
    this.file,
    this._lock,
    this._lockPath,
    this.maxOperations,
    this.maxPrefills,
    this.maxRejections,
    this._clock,
    this._monotonicClock,
  );
  static final _openPaths = <String>{};
  final String _bootIdentity = _newBootIdentity();
  final File file;
  final RandomAccessFile _lock;
  final String _lockPath;
  final int maxOperations, maxPrefills, maxRejections;
  final PrefillOperationClock _clock;
  int _rejectionWatermarkMs = -1;

  /// [nativeBinding] must come from the resolved runtime, never a client header.
  String publicGeneration(String nativeBinding) {
    if (nativeBinding.isEmpty) throw ArgumentError('运行绑定无效');
    return 'gmd1b-$_bootIdentity-${_hash(nativeBinding)}';
  }

  bool _ownsGeneration(String generation) =>
      generation.startsWith('gmd1b-$_bootIdentity-') &&
      RegExp(r'^gmd1b-[0-9a-f]{32}-[0-9a-f]{64}$').hasMatch(generation);
  final int Function() _monotonicClock;
  int _elapsedWatermark = 0;
  int get _elapsedNow {
    final value = _monotonicClock();
    if (value < 0) throw StateError('单调时间基准无效');
    if (value > _elapsedWatermark) _elapsedWatermark = value;
    return _elapsedWatermark;
  }

  int get timeBasisMs => _clock.nowMs;
  Map<String, _Record> _records = {};
  Map<String, _LegacyUse> _legacy = {};
  Future<void> _operations = Future.value();
  bool _closed = false;
  Future<void>? _closing;

  static Future<PrefillOperationLedger> open(
    File file, {
    int maxOperations = 4096,
    int maxPrefills = 3584,
    int maxRejections = 4096,
    int Function()? wallClock,
    int Function()? monotonicClock,
  }) async {
    if (maxOperations < 1 ||
        maxPrefills < 0 ||
        maxPrefills >= maxOperations ||
        maxRejections < 1) {
      throw ArgumentError('操作容量配置无效');
    }
    await file.parent.create(recursive: true);
    final lockPath =
        '${await file.parent.resolveSymbolicLinks()}/${file.uri.pathSegments.last}.lock';
    if (!_openPaths.add(lockPath)) throw StateError('操作登记已被占用');
    RandomAccessFile? lock;
    try {
      lock = await File(lockPath).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final stopwatch = Stopwatch()..start();
      final ledger = PrefillOperationLedger._(
        file,
        lock,
        lockPath,
        maxOperations,
        maxPrefills,
        maxRejections,
        PrefillOperationClock(
          wallClock ?? () => DateTime.now().millisecondsSinceEpoch,
        ),
        monotonicClock ?? () => stopwatch.elapsedMilliseconds,
      );
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map ||
            decoded['version'] != 1 ||
            decoded['operations'] is! List) {
          throw const FormatException('操作登记文件无效');
        }
        final records = <String, _Record>{};
        for (final item in decoded['operations'] as List) {
          final record = _Record.parse(item).afterRestart(ledger._elapsedNow);
          if (records.containsKey(record.id)) {
            throw const FormatException('操作登记包含重复 ID');
          }
          records[record.id] = record;
        }
        ledger._records = records;
        final legacy = decoded['legacy_uses'] ?? const [];
        if (legacy is! List) throw const FormatException('普通请求占用记录无效');
        for (final item in legacy) {
          final use = _LegacyUse.parse(item);
          if (ledger._legacy.containsKey(use.id)) {
            throw const FormatException('普通请求占用记录重复');
          }
          ledger._legacy[use.id] = use;
        }
      }
      return ledger;
    } catch (_) {
      await lock?.close();
      _openPaths.remove(lockPath);
      rethrow;
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operations.then((_) {
      if (_closed) throw StateError('操作登记已关闭');
      return action();
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> _persist(
    Map<String, _Record> records, {
    int? watermark,
    Map<String, _LegacyUse>? legacy,
  }) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'admission_fence_ms': watermark ?? _rejectionWatermarkMs,
        'operations': [for (final record in records.values) record.toJson()],
        'legacy_uses': [
          for (final use in (legacy ?? _legacy).values) use.toJson(),
        ],
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  bool _matches(String expected, String token) {
    if (!_tokenPattern.hasMatch(token)) return false;
    final actual = _hash(token.toLowerCase());
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<PrefillAdmission> admit({
    required String operationId,
    required String token,
    required String model,
    required String owner,
    required String generation,
    required String cacheSalt,
    required Map<String, Object?> request,
    required PrefillOperationKind kind,
  }) => _serial(() async {
    if (!_idPattern.hasMatch(operationId) ||
        !_tokenPattern.hasMatch(token) ||
        [
          model,
          owner,
          generation,
          cacheSalt,
        ].any((value) => value.isEmpty || value.length > 2048)) {
      throw const FormatException('操作身份、绑定或凭证无效');
    }
    final tokenHash = _hash(token.toLowerCase());
    final saltHash = _hash(cacheSalt);
    final requestHash = _requestDigest(request);
    final existing = _records[operationId];
    if (existing != null) {
      if (!_matches(existing.tokenHash, token)) {
        throw PrefillOperationForbidden();
      }
      if (existing.model != model ||
          existing.owner != owner ||
          existing.generation != generation ||
          existing.saltHash != saltHash ||
          existing.requestHash != requestHash ||
          existing.kind != kind) {
        throw PrefillOperationConflict();
      }
      return PrefillAdmission(created: false, operation: existing.view);
    }
    final parsed = PrefillOperationId.parse(operationId);
    if (parsed.generationHash != _hash(generation)) {
      throw PrefillOperationConflict();
    }
    if (generation.startsWith('gmd1b-') &&
        (!_ownsGeneration(generation) || !parsed.hasToken(token))) {
      throw PrefillOperationForbidden();
    }
    final now = _clock.nowMs;
    final elapsed = _elapsedNow;
    if (!parsed.accepts(generation: generation, nowMs: now)) {
      throw PrefillOperationExpired();
    }
    if (parsed.issuedAtMs <= _rejectionWatermarkMs) {
      if (!_ownsGeneration(generation) || !parsed.hasToken(token)) {
        throw PrefillOperationForbidden();
      }
      throw PrefillAdmissionNotAdmitted(_identityOnly(operationId, generation));
    }
    final retained = <String, _Record>{};
    for (final entry in _records.entries) {
      final record = entry.value;
      final finished = record.finishedAtElapsedMs;
      final expires = PrefillOperationId.parse(record.id).admissionExpiresAtMs;
      if (!record.view.terminal ||
          finished == null ||
          now <= expires ||
          elapsed < finished + PrefillOperationId.acceptanceWindowMs) {
        retained[entry.key] = record;
      }
    }
    final activeRecords = retained.values.where(
      (record) => record.state != PrefillOperationState.rejected,
    );
    if (activeRecords.length >= maxOperations ||
        kind == PrefillOperationKind.prefill &&
            activeRecords.where((record) => record.kind == kind).length >=
                maxPrefills) {
      if (retained.values
              .where((record) => record.state == PrefillOperationState.rejected)
              .length >=
          maxRejections) {
        if (_ownsGeneration(generation) && parsed.hasToken(token)) {
          await _setFence(parsed.issuedAtMs);
          throw PrefillCapacityUnavailable(
            _identityOnly(operationId, generation),
          );
        }
        throw PrefillRejectionCapacityUnavailable();
      }
      final rejected = _Record(
        id: operationId,
        tokenHash: tokenHash,
        model: model,
        owner: owner,
        generation: generation,
        saltHash: saltHash,
        requestHash: requestHash,
        kind: kind,
        state: PrefillOperationState.rejected,
        finishedAtMs: now,
        finishedAtElapsedMs: elapsed,
      );
      final next = {...retained, operationId: rejected};
      await _persist(next);
      _records = next;
      throw PrefillCapacityUnavailable(rejected.view);
    }
    if (_legacy.values.any(
          (use) => use.owner == owner && use.saltHash == saltHash,
        ) ||
        retained.values.any(
          (record) =>
              record.owner == owner &&
              record.saltHash == saltHash &&
              !record.view.terminal,
        )) {
      throw PrefillCacheBusy();
    }
    final record = _Record(
      id: operationId,
      tokenHash: tokenHash,
      model: model,
      owner: owner,
      generation: generation,
      saltHash: saltHash,
      requestHash: requestHash,
      kind: kind,
      state: PrefillOperationState.queued,
    );
    final next = {...retained, operationId: record};
    await _persist(next);
    _records = next;
    return PrefillAdmission(created: true, operation: record.view);
  });

  /// The owner must be derived from the resolved instance, never client input.
  Future<PrefillLegacyLease> reserveLegacy({
    required String owner,
    required String cacheSalt,
  }) => _serial(() async {
    if (owner.isEmpty ||
        owner.length > 2048 ||
        cacheSalt.isEmpty ||
        cacheSalt.length > 2048) {
      throw const FormatException('普通请求缓存绑定无效');
    }
    final saltHash = _hash(cacheSalt);
    if (_records.values.any(
      (record) =>
          record.owner == owner &&
          record.saltHash == saltHash &&
          !record.view.terminal,
    )) {
      throw PrefillCacheBusy();
    }
    if (_legacy.length >= maxOperations) {
      throw PrefillLegacyCapacityUnavailable();
    }
    var id = _newBootIdentity();
    while (_legacy.containsKey(id)) {
      id = _newBootIdentity();
    }
    final next = {..._legacy, id: _LegacyUse(id, owner, saltHash)};
    await _persist(_records, legacy: next);
    _legacy = next;
    return PrefillLegacyLease._(id);
  });

  /// Release only with evidence that this request's native work has ended.
  Future<void> finishLegacy(
    PrefillLegacyLease lease, {
    required bool released,
  }) => _serial(() async {
    if (!_legacy.containsKey(lease._id) || !released) return;
    final next = {..._legacy}..remove(lease._id);
    await _persist(_records, legacy: next);
    _legacy = next;
  });

  Future<PrefillOperationView> query(String id, String token) =>
      _serial(() async {
        final record = _records[id];
        if (record == null || !_matches(record.tokenHash, token)) {
          throw PrefillOperationForbidden();
        }
        return record.view;
      });

  /// Used only after the current instance is proven not to support tracking.
  Future<void> assertNoTracked({
    required String owner,
    required String cacheSalt,
  }) => _serial(() async {
    if (owner.isEmpty || cacheSalt.isEmpty) {
      throw const FormatException('缓存绑定无效');
    }
    final saltHash = _hash(cacheSalt);
    if (_records.values.any(
      (record) =>
          record.owner == owner &&
          record.saltHash == saltHash &&
          !record.view.terminal,
    )) {
      throw PrefillCacheBusy();
    }
  });

  /// Existing operations may replay even after their runtime is unavailable.
  Future<PrefillOperationView?> replay({
    required String operationId,
    required String token,
    required String model,
    required String generation,
    required String cacheSalt,
    required Map<String, Object?> request,
    required PrefillOperationKind kind,
  }) => _serial(() async {
    final record = _records[operationId];
    if (record == null) return null;
    if (!_matches(record.tokenHash, token)) throw PrefillOperationForbidden();
    if (record.model != model ||
        record.generation != generation ||
        record.saltHash != _hash(cacheSalt) ||
        record.requestHash != _requestDigest(request) ||
        record.kind != kind) {
      throw PrefillOperationConflict();
    }
    return record.view;
  });

  PrefillOperationView _identityOnly(String id, String generation) =>
      PrefillOperationView(
        id: id,
        state: PrefillOperationState.rejected,
        nativeDispatchNotStarted: true,
        identityOnly: true,
        generation: generation,
      );

  PrefillOperationId _proofIdentity(
    String id,
    String token,
    String generation,
  ) {
    final parsed = PrefillOperationId.parse(id);
    if (!_ownsGeneration(generation) ||
        !parsed.hasToken(token) ||
        !parsed.accepts(generation: generation, nowMs: _clock.nowMs)) {
      throw PrefillOperationForbidden();
    }
    return parsed;
  }

  Future<void> _setFence(int issuedAtMs) async {
    if (issuedAtMs <= _rejectionWatermarkMs) return;
    await _persist(_records, watermark: issuedAtMs);
    _rejectionWatermarkMs = issuedAtMs;
    _clock.advancePast(issuedAtMs);
  }

  /// [generation] must be resolved from the current trusted runtime binding.
  /// Existing operations return their actual state and are not auto-cancelled.
  Future<PrefillOperationView> fenceUnadmitted(
    String id,
    String token,
    String generation,
  ) => _serial(() async {
    final existing = _records[id];
    if (existing != null) {
      if (!_matches(existing.tokenHash, token) ||
          existing.generation != generation) {
        throw PrefillOperationForbidden();
      }
      return existing.view;
    }
    final parsed = _proofIdentity(id, token, generation);
    await _setFence(parsed.issuedAtMs);
    return _identityOnly(id, generation);
  });

  /// A fence cannot recover a result or prove facts about a previous boot.
  Future<PrefillOperationView> queryUnadmitted(
    String id,
    String token,
    String generation,
  ) => _serial(() async {
    final existing = _records[id];
    if (existing != null) {
      if (!_matches(existing.tokenHash, token) ||
          existing.generation != generation) {
        throw PrefillOperationForbidden();
      }
      return existing.view;
    }
    final parsed = _proofIdentity(id, token, generation);
    if (parsed.issuedAtMs > _rejectionWatermarkMs) {
      throw PrefillOperationForbidden();
    }
    return _identityOnly(id, generation);
  });

  _Record _authorized(String id, String token) {
    final record = _records[id];
    if (record == null || !_matches(record.tokenHash, token)) {
      throw PrefillOperationForbidden();
    }
    return record;
  }

  Future<PrefillOperationView> bindNative(
    String id,
    String token,
    SplashOperationIdentity identity,
  ) => _serial(() async {
    final record = _authorized(id, token);
    if (record.state != PrefillOperationState.queued ||
        !_idPattern.hasMatch(identity.serviceInstance) ||
        identity.runtimeGeneration < 1) {
      throw PrefillOperationConflict();
    }
    final nextRecord = record.update(
      state: PrefillOperationState.running,
      nativeServiceInstance: identity.serviceInstance,
      nativeRuntimeGeneration: identity.runtimeGeneration,
    );
    final next = {..._records, id: nextRecord};
    await _persist(next);
    _records = next;
    return nextRecord.view;
  });

  Future<PrefillOperationView> requestCancel(String id, String token) =>
      _serial(() async {
        final record = _authorized(id, token);
        if (record.view.terminal || record.cancelRequested) {
          return record.view;
        }
        final nextRecord = record.update(
          // bindNative must complete before dispatch, so queued is not sent.
          state: record.state == PrefillOperationState.queued
              ? PrefillOperationState.cancelled
              : record.state == PrefillOperationState.unknown
              ? PrefillOperationState.unknown
              : PrefillOperationState.cancelRequested,
          cancelRequested: true,
          finishedAtMs: record.state == PrefillOperationState.queued
              ? _clock.nowMs
              : null,
          finishedAtElapsedMs: record.state == PrefillOperationState.queued
              ? _elapsedNow
              : null,
        );
        final next = {..._records, id: nextRecord};
        await _persist(next);
        _records = next;
        return nextRecord.view;
      });

  /// A lost transport is not evidence of native completion or release.
  Future<PrefillOperationView> markUnknown(String id, String token) =>
      _serial(() async {
        final record = _authorized(id, token);
        if (record.view.terminal ||
            record.state == PrefillOperationState.unknown ||
            record.state == PrefillOperationState.cancelRequested) {
          return record.view;
        }
        final nextRecord = record.update(state: PrefillOperationState.unknown);
        final next = {..._records, id: nextRecord};
        await _persist(next);
        _records = next;
        return nextRecord.view;
      });

  /// Caller validates the business response before supplying it. Results stay
  /// in memory; this method alone does not permit acknowledging native deletion.
  Future<PrefillOperationView> recordTerminal(
    String id,
    String token,
    SplashOperationSnapshot evidence, {
    String? response,
  }) => _serial(() async {
    final record = _authorized(id, token);
    if (record.view.terminal) throw PrefillOperationConflict();
    if (evidence.operationId != id ||
        !evidence.terminal ||
        !evidence.leaseReleased ||
        record.nativeServiceInstance == null ||
        record.nativeRuntimeGeneration == null ||
        evidence.serviceInstance != record.nativeServiceInstance ||
        evidence.expectedRuntimeGeneration != record.nativeRuntimeGeneration) {
      throw PrefillTerminalUnconfirmed();
    }
    final cancelledByOwner =
        record.cancelRequested ||
        record.state == PrefillOperationState.cancelRequested;
    if (evidence.state == 'completed' &&
        !cancelledByOwner &&
        record.kind == PrefillOperationKind.prefill) {
      evidence.requirePrefillEvidence();
    }
    if (evidence.state == 'completed' &&
        !cancelledByOwner &&
        (response == null ||
            response.isEmpty ||
            utf8.encode(response).length > 1024 * 1024)) {
      throw PrefillTerminalUnconfirmed();
    }
    final state = cancelledByOwner
        ? PrefillOperationState.cancelled
        : switch (evidence.state) {
            'completed' => PrefillOperationState.completed,
            'cancelled' => PrefillOperationState.cancelled,
            'failed' => PrefillOperationState.failed,
            _ => throw PrefillTerminalUnconfirmed(),
          };
    final nextRecord = record.update(
      state: state,
      response: cancelledByOwner ? null : response,
      nativeEvidence: evidence,
      finishedAtMs: _clock.nowMs,
      finishedAtElapsedMs: _elapsedNow,
    );
    final next = {..._records, id: nextRecord};
    await _persist(next);
    _records = next;
    return nextRecord.view;
  });

  /// Native work completed and released, but its business result is unusable.
  Future<PrefillOperationView> recordResultFailure(
    String id,
    String token,
    SplashOperationSnapshot evidence,
    PrefillResultFailure failure,
  ) => _serial(() async {
    final record = _authorized(id, token);
    if (record.view.terminal) throw PrefillOperationConflict();
    if (evidence.operationId != id ||
        evidence.state != 'completed' ||
        !evidence.terminal ||
        !evidence.leaseReleased ||
        record.nativeServiceInstance == null ||
        record.nativeRuntimeGeneration == null ||
        evidence.serviceInstance != record.nativeServiceInstance ||
        evidence.expectedRuntimeGeneration != record.nativeRuntimeGeneration) {
      throw PrefillTerminalUnconfirmed();
    }
    final cancelled =
        record.cancelRequested ||
        record.state == PrefillOperationState.cancelRequested;
    final nextRecord = record.update(
      state: cancelled
          ? PrefillOperationState.cancelled
          : PrefillOperationState.failed,
      resultFailure: cancelled ? null : failure,
      nativeEvidence: evidence,
      finishedAtMs: _clock.nowMs,
      finishedAtElapsedMs: _elapsedNow,
    );
    final next = {..._records, id: nextRecord};
    await _persist(next);
    _records = next;
    return nextRecord.view;
  });

  Future<void> close() => _closing ??= (() async {
    _closed = true;
    await _operations;
    try {
      await _lock.unlock();
    } finally {
      await _lock.close();
      _openPaths.remove(_lockPath);
    }
  })();
}

Object? _canonical(Object? value) {
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('请求字段无效');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  if (value == null ||
      value is ExactGenerationSeed ||
      value is String ||
      value is bool ||
      value is int ||
      value is double && value.isFinite) {
    return value;
  }
  throw const FormatException('请求内容无效');
}
