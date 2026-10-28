import 'dart:convert';

import 'package:crypto/crypto.dart';

class PrefillOperationId {
  const PrefillOperationId._(this.generationHash, this.issuedAtMs, this.nonce);
  final String generationHash;
  final int issuedAtMs;
  final String nonce;

  static final _format = RegExp(
    r'^gmd1\.([0-9a-f]{64})\.(0|[1-9][0-9]{0,15})\.([0-9a-f]{32})$',
  );
  static const acceptanceWindowMs = 10 * 60 * 1000;
  static const futureToleranceMs = 60 * 1000;
  static final _token = RegExp(r'^[0-9a-f]{64}$');

  /// Every operation must have an independently generated 256-bit token.
  static String nonceForToken(String token) {
    if (!_token.hasMatch(token)) throw const FormatException('操作凭证格式无效');
    final bytes = <int>[
      ...utf8.encode('gmd-prefill/1:operation-token'),
      0,
      for (var offset = 0; offset < token.length; offset += 2)
        int.parse(token.substring(offset, offset + 2), radix: 16),
    ];
    return sha256.convert(bytes).toString().substring(0, 32);
  }

  bool hasToken(String token) {
    if (!_token.hasMatch(token)) return false;
    final actual = nonceForToken(token);
    var difference = 0;
    for (var i = 0; i < nonce.length; i++) {
      difference |= nonce.codeUnitAt(i) ^ actual.codeUnitAt(i);
    }
    return difference == 0;
  }

  static PrefillOperationId parse(String value) {
    final match = _format.firstMatch(value);
    if (match == null) throw const FormatException('操作 ID 格式无效');
    final issuedAt = int.tryParse(match[2]!);
    if (issuedAt == null) throw const FormatException('操作 ID 时间无效');
    return PrefillOperationId._(match[1]!, issuedAt, match[3]!);
  }

  /// Only apply to first admission. An existing operation is authenticated and
  /// matched to its original binding before its age is considered.
  bool accepts({required String generation, required int nowMs}) =>
      generationHash == sha256.convert(utf8.encode(generation)).toString() &&
      issuedAtMs >= nowMs - acceptanceWindowMs &&
      issuedAtMs <= nowMs + futureToleranceMs;

  int get admissionExpiresAtMs => issuedAtMs + acceptanceWindowMs;
}

/// A forward-only time basis for one GMD boot. A new boot uses a new public
/// generation, so old IDs must not be admitted against the new generation.
class PrefillOperationClock {
  PrefillOperationClock(this._wallClock);
  final int Function() _wallClock;
  int _watermark = 0;

  void advancePast(int value) {
    if (value < 0) throw StateError('操作时间基准无效');
    if (value >= _watermark) _watermark = value + 1;
  }

  int get nowMs {
    final value = _wallClock();
    if (value < 0) throw StateError('操作时间基准无效');
    if (value > _watermark) _watermark = value;
    return _watermark;
  }
}
