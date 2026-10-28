import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/prefill_operation_id.dart';

void main() {
  test('operation token is bound to the ID using the shared byte contract', () {
    const token =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const other =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    expect(
      PrefillOperationId.nonceForToken(token),
      'faa591af733fea97bd8c09da5bdd24b5',
    );
    expect(
      PrefillOperationId.nonceForToken(other),
      '4146148b74e124330f8b80e7a7fd192c',
    );
    final generation = sha256.convert(utf8.encode('generation'));
    final parsed = PrefillOperationId.parse(
      'gmd1.$generation.1000000.${PrefillOperationId.nonceForToken(token)}',
    );
    expect(parsed.hasToken(token), isTrue);
    expect(parsed.hasToken(other), isFalse);
    expect(parsed.hasToken('invalid'), isFalse);
    expect(
      () => PrefillOperationId.nonceForToken('AA' * 32),
      throwsFormatException,
    );
  });

  test('new IDs bind generation and remain within the acceptance window', () {
    const generation = 'boot-a:service-a:1';
    final digest = sha256.convert(utf8.encode(generation));
    final id = PrefillOperationId.parse('gmd1.$digest.1000000.${'a' * 32}');
    expect(id.accepts(generation: generation, nowMs: 1000000), isTrue);
    expect(id.accepts(generation: generation, nowMs: 1600000), isTrue);
    expect(id.accepts(generation: generation, nowMs: 1600001), isFalse);
    expect(id.accepts(generation: generation, nowMs: 940000), isTrue);
    expect(id.accepts(generation: generation, nowMs: 939999), isFalse);
    expect(
      id.accepts(generation: 'boot-b:service-a:1', nowMs: 1000000),
      isFalse,
    );
    expect(id.admissionExpiresAtMs, 1600000);
    expect(
      () => PrefillOperationId.parse('gmd1.$digest.01000000.${'a' * 32}'),
      throwsFormatException,
    );
    expect(
      () => PrefillOperationId.parse('gmd1.$digest.1000000.${'a' * 31}'),
      throwsFormatException,
    );
  });

  test('wall clock rollback cannot reopen an expired admission window', () {
    var wall = 1000000;
    final clock = PrefillOperationClock(() => wall);
    expect(clock.nowMs, 1000000);
    wall = 1700000;
    expect(clock.nowMs, 1700000);
    wall = 1100000;
    expect(clock.nowMs, 1700000);
  });
}
