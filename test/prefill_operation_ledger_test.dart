import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/prefill_operation_id.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

String operationId(String name, String generation, [int issuedAt = 1000000]) {
  final digest = sha256.convert(utf8.encode(generation));
  final nonce = sha256.convert(utf8.encode(name)).toString().substring(0, 32);
  return 'gmd1.$digest.$issuedAt.$nonce';
}

void main() {
  test(
    'legacy and tracked requests atomically share the actual instance and salt',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-prefill-legacy-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/operations.json');
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final ledger = await PrefillOperationLedger.open(
        file,
        wallClock: () => 1000000,
      );
      Future<PrefillAdmission> admit(
        PrefillOperationLedger target,
        String name,
        String salt,
      ) => target.admit(
        operationId: operationId(name, 'generation'),
        token: token,
        model: 'alias',
        owner: 'actual-instance',
        generation: 'generation',
        cacheSalt: salt,
        request: {'text': name},
        kind: PrefillOperationKind.prefill,
      );
      final lease = await ledger.reserveLegacy(
        owner: 'actual-instance',
        cacheSalt: 'same',
      );
      await expectLater(
        admit(ledger, 'blocked', 'same'),
        throwsA(isA<PrefillCacheBusy>()),
      );
      expect((await admit(ledger, 'other', 'different')).created, isTrue);
      await ledger.finishLegacy(lease, released: true);
      expect((await admit(ledger, 'after', 'same')).created, isTrue);
      await expectLater(
        ledger.reserveLegacy(owner: 'actual-instance', cacheSalt: 'same'),
        throwsA(isA<PrefillCacheBusy>()),
      );
      final unknown = await ledger.reserveLegacy(
        owner: 'other-instance',
        cacheSalt: 'other',
      );
      await ledger.finishLegacy(unknown, released: false);
      await ledger.close();
      final reopened = await PrefillOperationLedger.open(
        file,
        wallClock: () => 1000000,
      );
      try {
        await expectLater(
          reopened.admit(
            operationId: operationId('restart', 'generation'),
            token: token,
            model: 'alias',
            owner: 'other-instance',
            generation: 'generation',
            cacheSalt: 'other',
            request: {'text': 'restart'},
            kind: PrefillOperationKind.consume,
          ),
          throwsA(isA<PrefillCacheBusy>()),
        );
      } finally {
        await reopened.close();
      }
    },
  );

  test('lost native connection keeps the cache occupied as unknown', () async {
    final root = await Directory.systemTemp.createTemp('gmd-prefill-lost-');
    addTearDown(() => root.delete(recursive: true));
    final ledger = await PrefillOperationLedger.open(
      File('${root.path}/operations.json'),
      wallClock: () => 1000000,
    );
    addTearDown(ledger.close);
    const token =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final id = operationId('lost', 'generation');
    await ledger.admit(
      operationId: id,
      token: token,
      model: 'm',
      owner: 'instance',
      generation: 'generation',
      cacheSalt: 'same',
      request: {'text': 'A'},
      kind: PrefillOperationKind.prefill,
    );
    await ledger.bindNative(
      id,
      token,
      const SplashOperationIdentity('service', 1),
    );
    final lost = await ledger.markUnknown(id, token);
    expect(lost.state, PrefillOperationState.unknown);
    expect(lost.leaseReleased, isFalse);
    await expectLater(
      ledger.admit(
        operationId: operationId('next', 'generation'),
        token: token,
        model: 'm',
        owner: 'instance',
        generation: 'generation',
        cacheSalt: 'same',
        request: {'text': 'A+B'},
        kind: PrefillOperationKind.consume,
      ),
      throwsA(isA<PrefillCacheBusy>()),
    );
    expect((await ledger.requestCancel(id, token)).cancelRequested, isTrue);
    await ledger.close();
    final reopened = await PrefillOperationLedger.open(
      File('${root.path}/operations.json'),
      wallClock: () => 1000000,
    );
    try {
      final restored = await reopened.query(id, token);
      expect(restored.state, PrefillOperationState.unknown);
      expect(restored.cancelRequested, isTrue);
      expect(restored.leaseReleased, isFalse);
    } finally {
      await reopened.close();
    }
  });

  test('future fence advances time and expired identity has no proof', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-prefill-future-fence-',
    );
    addTearDown(() => root.delete(recursive: true));
    var wall = 1000000;
    final ledger = await PrefillOperationLedger.open(
      File('${root.path}/operations.json'),
      wallClock: () => wall,
    );
    addTearDown(ledger.close);
    const token =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final generation = ledger.publicGeneration('engine');
    final id =
        'gmd1.${sha256.convert(utf8.encode(generation))}.1060000.${PrefillOperationId.nonceForToken(token)}';
    final proof = await ledger.fenceUnadmitted(id, token, generation);
    expect(proof.identityOnly, isTrue);
    expect(ledger.timeBasisMs, 1060001);
    expect(
      (await ledger.queryUnadmitted(id, token, generation)).identityOnly,
      isTrue,
    );
    wall = 1660001;
    await expectLater(
      ledger.queryUnadmitted(id, token, generation),
      throwsA(isA<PrefillOperationForbidden>()),
    );
    wall = 1000000;
    await expectLater(
      ledger.queryUnadmitted(id, token, generation),
      throwsA(isA<PrefillOperationForbidden>()),
    );
  });

  test('fence serializes admission and never proves on persistence failure', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-prefill-fence-race-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/operations.json');
    final ledger = await PrefillOperationLedger.open(
      file,
      wallClock: () => 1000000,
    );
    addTearDown(ledger.close);
    const first =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const second =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final generation = ledger.publicGeneration('engine');
    String id(String token) =>
        'gmd1.${sha256.convert(utf8.encode(generation))}.1000000.${PrefillOperationId.nonceForToken(token)}';
    Future<PrefillAdmission> admit(String token) => ledger.admit(
      operationId: id(token),
      token: token,
      model: 'm',
      owner: 'o',
      generation: generation,
      cacheSalt: token,
      request: {'text': token},
      kind: PrefillOperationKind.prefill,
    );
    final obstruction = await Directory('${file.path}.tmp').create();
    await expectLater(
      ledger.fenceUnadmitted(id(first), first, generation),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      ledger.queryUnadmitted(id(first), first, generation),
      throwsA(isA<PrefillOperationForbidden>()),
    );
    await obstruction.delete();
    final admittedFirst = admit(first);
    final tooLateToFence = ledger.fenceUnadmitted(id(first), first, generation);
    expect((await admittedFirst).created, isTrue);
    expect((await tooLateToFence).state, PrefillOperationState.queued);
    final fenceFirst = ledger.fenceUnadmitted(id(second), second, generation);
    final tooLateToAdmit = expectLater(
      admit(second),
      throwsA(isA<PrefillAdmissionNotAdmitted>()),
    );
    expect((await fenceFirst).identityOnly, isTrue);
    await tooLateToAdmit;
  });

  test('full refusal storage uses the fence and leaves consume capacity', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-prefill-fence-quota-',
    );
    addTearDown(() => root.delete(recursive: true));
    final ledger = await PrefillOperationLedger.open(
      File('${root.path}/operations.json'),
      maxOperations: 2,
      maxPrefills: 1,
      maxRejections: 1,
      wallClock: () => 1000000,
    );
    addTearDown(ledger.close);
    const a =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const b =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const c =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const d =
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
    final generation = ledger.publicGeneration('engine');
    String id(String token, int ms) =>
        'gmd1.${sha256.convert(utf8.encode(generation))}.$ms.${PrefillOperationId.nonceForToken(token)}';
    Future<PrefillAdmission> admit(
      String token,
      int ms,
      PrefillOperationKind kind,
    ) => ledger.admit(
      operationId: id(token, ms),
      token: token,
      model: 'm',
      owner: 'o',
      generation: generation,
      cacheSalt: token,
      request: {'text': token},
      kind: kind,
    );
    await admit(a, 1000000, PrefillOperationKind.prefill);
    await expectLater(
      admit(b, 1000000, PrefillOperationKind.prefill),
      throwsA(isA<PrefillCapacityUnavailable>()),
    );
    await expectLater(
      admit(c, 1000000, PrefillOperationKind.prefill),
      throwsA(
        isA<PrefillCapacityUnavailable>().having(
          (e) => e.operation.identityOnly,
          'identity only',
          true,
        ),
      ),
    );
    expect(
      (await ledger.queryUnadmitted(
        id(c, 1000000),
        c,
        generation,
      )).identityOnly,
      isTrue,
    );
    expect(
      (await admit(
        d,
        ledger.timeBasisMs,
        PrefillOperationKind.consume,
      )).created,
      isTrue,
    );
  });

  test('identity-only fence prevents late admission without unbounded records', () async {
    final root = await Directory.systemTemp.createTemp('gmd-prefill-fence-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/operations.json');
    const first =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const second =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const third =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final ledger = await PrefillOperationLedger.open(
      file,
      wallClock: () => 1000000,
    );
    final generation = ledger.publicGeneration('engine-a');
    String boundId(String token, int issued) =>
        'gmd1.${sha256.convert(utf8.encode(generation))}.$issued.${PrefillOperationId.nonceForToken(token)}';
    Future<PrefillAdmission> admit(
      PrefillOperationLedger target,
      String id,
      String token,
      PrefillOperationKind kind,
      String salt,
    ) => target.admit(
      operationId: id,
      token: token,
      model: 'model',
      owner: 'owner',
      generation: generation,
      cacheSalt: salt,
      request: {'text': salt},
      kind: kind,
    );
    final original = boundId(first, 1000000);
    final late = boundId(second, 1000000);
    try {
      await admit(
        ledger,
        original,
        first,
        PrefillOperationKind.prefill,
        'active',
      );
      await expectLater(
        ledger.fenceUnadmitted(late, first, generation),
        throwsA(isA<PrefillOperationForbidden>()),
      );
      final proof = await ledger.fenceUnadmitted(late, second, generation);
      expect(proof.nativeDispatchNotStarted, isTrue);
      expect(proof.identityOnly, isTrue);
      expect(ledger.timeBasisMs, greaterThan(1000000));
      expect(
        (await ledger.queryUnadmitted(late, second, generation)).identityOnly,
        isTrue,
      );
      await expectLater(
        admit(ledger, late, second, PrefillOperationKind.prefill, 'late'),
        throwsA(isA<PrefillAdmissionNotAdmitted>()),
      );
      expect(
        (await admit(
          ledger,
          original,
          first,
          PrefillOperationKind.prefill,
          'active',
        )).created,
        isFalse,
      );
      expect(
        (await admit(
          ledger,
          boundId(third, ledger.timeBasisMs),
          third,
          PrefillOperationKind.consume,
          'other',
        )).created,
        isTrue,
      );
    } finally {
      await ledger.close();
    }
    final reopened = await PrefillOperationLedger.open(
      file,
      wallClock: () => 1000000,
    );
    try {
      await expectLater(
        reopened.queryUnadmitted(late, second, generation),
        throwsA(isA<PrefillOperationForbidden>()),
      );
      expect(
        (await reopened.query(original, first)).state,
        PrefillOperationState.unknown,
      );
    } finally {
      await reopened.close();
    }
  });

  test(
    'logical time jumps cannot shorten the terminal replay window',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-prefill-monotonic-',
      );
      addTearDown(() => root.delete(recursive: true));
      var wall = 1000000;
      var elapsed = 0;
      final ledger = await PrefillOperationLedger.open(
        File('${root.path}/operations.json'),
        maxOperations: 2,
        maxPrefills: 1,
        wallClock: () => wall,
        monotonicClock: () => elapsed,
      );
      addTearDown(ledger.close);
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Future<PrefillAdmission> admit(String id, String salt) => ledger.admit(
        operationId: id,
        token: token,
        model: 'model',
        owner: 'owner',
        generation: 'generation',
        cacheSalt: salt,
        request: {'text': salt},
        kind: PrefillOperationKind.prefill,
      );
      final old = operationId('old', 'generation', wall);
      await admit(old, 'old');
      await ledger.requestCancel(old, token);
      wall += 700000;
      elapsed = 1000;
      await expectLater(
        admit(operationId('early', 'generation', wall), 'new'),
        throwsA(isA<PrefillCapacityUnavailable>()),
      );
      expect((await admit(old, 'old')).created, isFalse);
      elapsed = 600000;
      expect(
        (await admit(operationId('new', 'generation', wall), 'new')).created,
        isTrue,
      );
      await expectLater(
        admit(old, 'old'),
        throwsA(isA<PrefillOperationExpired>()),
      );
    },
  );

  test(
    'refusal persistence failure and exhausted refusal storage give no proof',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-prefill-refusal-limits-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/operations.json');
      final ledger = await PrefillOperationLedger.open(
        file,
        maxOperations: 2,
        maxPrefills: 1,
        maxRejections: 1,
        wallClock: () => 1000000,
      );
      addTearDown(ledger.close);
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Future<PrefillAdmission> admit(String name) => ledger.admit(
        operationId: operationId(name, 'generation'),
        token: token,
        model: 'model',
        owner: 'owner',
        generation: 'generation',
        cacheSalt: name,
        request: {'text': name},
        kind: PrefillOperationKind.prefill,
      );
      await admit('active');
      final obstruction = await Directory('${file.path}.tmp').create();
      await expectLater(
        admit('write-failed'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        ledger.query(operationId('write-failed', 'generation'), token),
        throwsA(isA<PrefillOperationForbidden>()),
      );
      await obstruction.delete();
      await expectLater(
        admit('first-refusal'),
        throwsA(isA<PrefillCapacityUnavailable>()),
      );
      await expectLater(
        admit('refusal-store-full'),
        throwsA(isA<PrefillRejectionCapacityUnavailable>()),
      );
      await expectLater(
        ledger.query(operationId('refusal-store-full', 'generation'), token),
        throwsA(isA<PrefillOperationForbidden>()),
      );
    },
  );

  test('quota rejection is durable and cannot later dispatch', () async {
    final root = await Directory.systemTemp.createTemp('gmd-prefill-refused-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/operations.json');
    const token =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const other =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final active = operationId('active', 'generation');
    final rejected = operationId('rejected', 'generation');
    final finalId = operationId('final', 'generation');
    final ledger = await PrefillOperationLedger.open(
      file,
      maxOperations: 2,
      maxPrefills: 1,
      maxRejections: 2,
      wallClock: () => 1000000,
    );
    Future<PrefillAdmission> admit(
      PrefillOperationLedger target,
      String id,
      PrefillOperationKind kind,
      String salt, {
      String key = token,
    }) => target.admit(
      operationId: id,
      token: key,
      model: 'model',
      owner: 'owner',
      generation: 'generation',
      cacheSalt: salt,
      request: {'text': salt},
      kind: kind,
    );
    try {
      await admit(ledger, active, PrefillOperationKind.prefill, 'active');
      await expectLater(
        admit(ledger, rejected, PrefillOperationKind.prefill, 'requested'),
        throwsA(
          isA<PrefillCapacityUnavailable>().having(
            (e) => e.operation.nativeDispatchNotStarted,
            'not dispatched',
            isTrue,
          ),
        ),
      );
      final proof = await ledger.query(rejected, token);
      expect(proof.state, PrefillOperationState.rejected);
      expect(proof.terminal, isTrue);
      expect(proof.leaseReleased, isTrue);
      expect(proof.nativeDispatchNotStarted, isTrue);
      await expectLater(
        ledger.query(rejected, other),
        throwsA(isA<PrefillOperationForbidden>()),
      );
      await expectLater(
        admit(ledger, rejected, PrefillOperationKind.prefill, 'changed'),
        throwsA(isA<PrefillOperationConflict>()),
      );
      expect(
        (await admit(
          ledger,
          finalId,
          PrefillOperationKind.consume,
          'requested',
        )).created,
        isTrue,
      );
      await ledger.requestCancel(active, token);
      final replay = await admit(
        ledger,
        rejected,
        PrefillOperationKind.prefill,
        'requested',
      );
      expect(replay.created, isFalse);
      expect(replay.operation.state, PrefillOperationState.rejected);
      await expectLater(
        ledger.bindNative(
          rejected,
          token,
          const SplashOperationIdentity('service', 1),
        ),
        throwsA(isA<PrefillOperationConflict>()),
      );
    } finally {
      await ledger.close();
    }
    final reopened = await PrefillOperationLedger.open(
      file,
      maxOperations: 2,
      maxPrefills: 1,
      maxRejections: 2,
      wallClock: () => 1000000,
    );
    try {
      final proof = await reopened.query(rejected, token);
      expect(proof.state, PrefillOperationState.rejected);
      expect(proof.nativeDispatchNotStarted, isTrue);
      expect(
        (await admit(
          reopened,
          rejected,
          PrefillOperationKind.prefill,
          'requested',
        )).created,
        isFalse,
      );
    } finally {
      await reopened.close();
    }
  });

  test(
    'failed persistence does not admit and corrupted records fail closed',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-prefill-persist-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/operations.json');
      final ledger = await PrefillOperationLedger.open(
        file,
        wallClock: () => 1000000,
      );
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Future<PrefillAdmission> admit() => ledger.admit(
        operationId: operationId('op', 'generation'),
        token: token,
        model: 'model',
        owner: 'run',
        generation: 'generation',
        cacheSalt: 'salt',
        request: {'prompt': 'private'},
        kind: PrefillOperationKind.prefill,
      );
      try {
        await expectLater(
          PrefillOperationLedger.open(file, wallClock: () => 1000000),
          throwsA(isA<StateError>()),
        );
        final obstruction = await Directory('${file.path}.tmp').create();
        await expectLater(admit(), throwsA(isA<FileSystemException>()));
        await expectLater(
          ledger.query(operationId('op', 'generation'), token),
          throwsA(isA<PrefillOperationForbidden>()),
        );
        await obstruction.delete();
        expect((await admit()).created, isTrue);
      } finally {
        await ledger.close();
      }
      await file.writeAsString('{broken');
      await expectLater(
        PrefillOperationLedger.open(file, wallClock: () => 1000000),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'native release evidence gates completion, replay and cache reuse',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-prefill-terminal-',
        );
        addTearDown(() => root.delete(recursive: true));
        final file = File('${root.path}/operations.json');
        final ledger = await PrefillOperationLedger.open(
          file,
          wallClock: () => 1000000,
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        const token =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        var completed = false;
        server.listen((request) async {
          final id = request.uri.pathSegments.last;
          request.response.write(
            jsonEncode({
              'operation_id': id,
              'service_instance': 'service-a',
              'state': completed ? 'completed' : 'cancel_requested',
              'terminal': completed,
              'lease_released': completed,
              'children': [
                {
                  'question_id': null,
                  'native_request_id': 42,
                  'runtime_generation': 1,
                  'state': completed ? 'length' : 'running',
                  'lease_released': completed,
                  if (completed) ...{
                    'prompt_tokens': 10,
                    'completion_tokens': 0,
                    'matched_prompt_tokens': 3,
                  },
                },
              ],
            }),
          );
          await request.response.close();
        });
        final native = SplashOperationClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        const identity = SplashOperationIdentity('service-a', 1);
        Future<PrefillAdmission> admit(String id) => ledger.admit(
          operationId: id,
          token: token,
          model: 'model',
          owner: 'run',
          generation: 'public-generation',
          cacheSalt: 'salt',
          request: {'body': 'private'},
          kind: PrefillOperationKind.prefill,
        );
        try {
          await admit(operationId('op-1', 'public-generation'));
          await ledger.bindNative(
            operationId('op-1', 'public-generation'),
            token,
            identity,
          );
          await ledger.markUnknown(
            operationId('op-1', 'public-generation'),
            token,
          );
          final unknownCancel = await ledger.requestCancel(
            operationId('op-1', 'public-generation'),
            token,
          );
          expect(unknownCancel.state, PrefillOperationState.unknown);
          expect(unknownCancel.cancelRequested, isTrue);
          final pending = await native.query(
            operationId: operationId('op-1', 'public-generation'),
            token: token,
            expected: identity,
          );
          await expectLater(
            ledger.recordTerminal(
              operationId('op-1', 'public-generation'),
              token,
              pending,
              response: 'late',
            ),
            throwsA(isA<PrefillTerminalUnconfirmed>()),
          );
          await expectLater(
            admit(operationId('op-2', 'public-generation')),
            throwsA(isA<PrefillCacheBusy>()),
          );
          completed = true;
          final finished = await native.query(
            operationId: operationId('op-1', 'public-generation'),
            token: token,
            expected: identity,
          );
          final cancelled = await ledger.recordTerminal(
            operationId('op-1', 'public-generation'),
            token,
            finished,
            response: 'late',
          );
          expect(cancelled.state, PrefillOperationState.cancelled);
          expect(cancelled.response, isNull);
          expect(cancelled.leaseReleased, isTrue);
          expect(
            (await admit(operationId('op-2', 'public-generation'))).created,
            isTrue,
          );
          await ledger.bindNative(
            operationId('op-2', 'public-generation'),
            token,
            identity,
          );
          final second = await native.query(
            operationId: operationId('op-2', 'public-generation'),
            token: token,
            expected: identity,
          );
          await expectLater(
            ledger.recordTerminal(
              operationId('op-2', 'public-generation'),
              token,
              finished,
              response: 'wrong operation',
            ),
            throwsA(isA<PrefillTerminalUnconfirmed>()),
          );
          final obstruction = await Directory('${file.path}.tmp').create();
          await expectLater(
            ledger.recordTerminal(
              operationId('op-2', 'public-generation'),
              token,
              second,
              response: 'private output',
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(
            (await ledger.query(
              operationId('op-2', 'public-generation'),
              token,
            )).state,
            PrefillOperationState.running,
          );
          await expectLater(
            admit(operationId('op-3', 'public-generation')),
            throwsA(isA<PrefillCacheBusy>()),
          );
          await obstruction.delete();
          final result = await ledger.recordTerminal(
            operationId('op-2', 'public-generation'),
            token,
            second,
            response: '{"result":"private output"}',
          );
          expect(result.state, PrefillOperationState.completed);
          expect(result.nativeEvidence, same(second));
          expect(
            (await admit(operationId('op-2', 'public-generation')))
                .operation
                .response,
            result.response,
          );
          expect(await file.readAsString(), isNot(contains('private output')));
        } finally {
          await ledger.close();
        }
        final reopened = await PrefillOperationLedger.open(
          file,
          wallClock: () => 1000000,
        );
        try {
          final restored = await reopened.query(
            operationId('op-2', 'public-generation'),
            token,
          );
          expect(restored.state, PrefillOperationState.unknown);
          expect(restored.response, isNull);
          expect(restored.nativeEvidence, isNull);
          expect(restored.leaseReleased, isFalse);
        } finally {
          await reopened.close();
        }
      }, _NetworkBoundary());
    },
  );

  test(
    'same operation is idempotent, isolated and remains held after restart',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-prefill-ledger-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/operations.json');
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const other =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final ledger = await PrefillOperationLedger.open(
        file,
        wallClock: () => 1000000,
      );
      Future<PrefillAdmission> admit(
        String id, {
        String key = token,
        String prompt = 'first',
        String owner = 'instance-a',
      }) => ledger.admit(
        operationId: id,
        token: key,
        model: 'model',
        owner: owner,
        generation: 'service-a:1',
        cacheSalt: 'private-salt',
        request: {
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        },
        kind: PrefillOperationKind.prefill,
      );
      try {
        final first = await admit(operationId('op-1', 'service-a:1'));
        expect(first.created, isTrue);
        expect(first.operation.state, PrefillOperationState.queued);
        final retry = await admit(operationId('op-1', 'service-a:1'));
        expect(retry.created, isFalse);
        final concurrent = await Future.wait([
          admit(operationId('op-1', 'service-a:1')),
          admit(operationId('op-1', 'service-a:1')),
        ]);
        expect(concurrent.every((entry) => !entry.created), isTrue);
        await expectLater(
          admit(operationId('op-1', 'service-a:1'), prompt: 'changed'),
          throwsA(isA<PrefillOperationConflict>()),
        );
        await expectLater(
          admit(operationId('op-1', 'service-a:1'), key: other),
          throwsA(isA<PrefillOperationForbidden>()),
        );
        await expectLater(
          admit(operationId('op-2', 'service-a:1')),
          throwsA(isA<PrefillCacheBusy>()),
        );
        expect(
          (await admit(
            operationId('op-2', 'service-a:1'),
            owner: 'instance-b',
          )).created,
          isTrue,
        );
        final text = await file.readAsString();
        expect(text, isNot(contains(token)));
        expect(text, isNot(contains('private-salt')));
        expect(text, isNot(contains('first')));
      } finally {
        await ledger.close();
      }
      final reopened = await PrefillOperationLedger.open(
        file,
        wallClock: () => 1000000,
      );
      try {
        final old = await reopened.query(
          operationId('op-1', 'service-a:1'),
          token,
        );
        expect(old.state, PrefillOperationState.unknown);
        expect(old.terminal, isFalse);
        expect(old.leaseReleased, isFalse);
        await expectLater(
          reopened.admit(
            operationId: operationId('op-3', 'service-b:1'),
            token: token,
            model: 'model',
            owner: 'instance-a',
            generation: 'service-b:1',
            cacheSalt: 'private-salt',
            request: {'messages': []},
            kind: PrefillOperationKind.prefill,
          ),
          throwsA(isA<PrefillCacheBusy>()),
        );
        await expectLater(
          reopened.query(operationId('op-1', 'service-a:1'), other),
          throwsA(isA<PrefillOperationForbidden>()),
        );
      } finally {
        await reopened.close();
      }
    },
  );

  test('prefill quota reserves capacity for final operations', () async {
    final root = await Directory.systemTemp.createTemp('gmd-prefill-limit-');
    addTearDown(() => root.delete(recursive: true));
    final ledger = await PrefillOperationLedger.open(
      File('${root.path}/operations.json'),
      wallClock: () => 1000000,
      maxOperations: 2,
      maxPrefills: 1,
    );
    addTearDown(ledger.close);
    const token =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    Future<PrefillAdmission> admit(String id, PrefillOperationKind kind) =>
        ledger.admit(
          operationId: id,
          token: token,
          model: 'model',
          owner: 'instance-a',
          generation: 'service-a:1',
          cacheSalt: id,
          request: {'text': id},
          kind: kind,
        );
    expect(
      (await admit(
        operationId('prefill', 'service-a:1'),
        PrefillOperationKind.prefill,
      )).created,
      isTrue,
    );
    await expectLater(
      admit(
        operationId('prefill-2', 'service-a:1'),
        PrefillOperationKind.prefill,
      ),
      throwsA(isA<PrefillCapacityUnavailable>()),
    );
    expect(
      (await admit(
        operationId('consume', 'service-a:1'),
        PrefillOperationKind.consume,
      )).created,
      isTrue,
    );
    await expectLater(
      admit(
        operationId('consume-2', 'service-a:1'),
        PrefillOperationKind.consume,
      ),
      throwsA(isA<PrefillCapacityUnavailable>()),
    );
  });

  test(
    'cancellation before native binding closes admission without dispatch',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-prefill-not-sent-',
      );
      addTearDown(() => root.delete(recursive: true));
      final ledger = await PrefillOperationLedger.open(
        File('${root.path}/operations.json'),
        wallClock: () => 1000000,
      );
      addTearDown(ledger.close);
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Future<PrefillAdmission> admit(String id) => ledger.admit(
        operationId: id,
        token: token,
        model: 'model',
        owner: 'instance',
        generation: 'generation',
        cacheSalt: 'salt',
        request: {'text': 'private'},
        kind: PrefillOperationKind.prefill,
      );
      await admit(operationId('first', 'generation'));
      final cancelled = await ledger.requestCancel(
        operationId('first', 'generation'),
        token,
      );
      expect(cancelled.state, PrefillOperationState.cancelled);
      expect(cancelled.leaseReleased, isTrue);
      await expectLater(
        ledger.bindNative(
          operationId('first', 'generation'),
          token,
          const SplashOperationIdentity('service', 1),
        ),
        throwsA(isA<PrefillOperationConflict>()),
      );
      expect(
        (await admit(operationId('second', 'generation'))).created,
        isTrue,
      );
    },
  );

  test(
    'expired terminal records are reclaimed without readmitting old IDs',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-prefill-retain-');
      addTearDown(() => root.delete(recursive: true));
      var now = 1000000;
      final ledger = await PrefillOperationLedger.open(
        File('${root.path}/operations.json'),
        maxOperations: 2,
        maxPrefills: 1,
        wallClock: () => now,
        monotonicClock: () => now,
      );
      addTearDown(ledger.close);
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Future<PrefillAdmission> admit(String id, String salt) => ledger.admit(
        operationId: id,
        token: token,
        model: 'model',
        owner: 'owner',
        generation: 'generation',
        cacheSalt: salt,
        request: {'text': salt},
        kind: PrefillOperationKind.prefill,
      );
      final old = operationId('old', 'generation', now);
      await admit(old, 'old');
      await ledger.requestCancel(old, token);
      now += 10 * 60 * 1000;
      await expectLater(
        admit(operationId('early', 'generation', now), 'new'),
        throwsA(isA<PrefillCapacityUnavailable>()),
      );
      now++;
      expect(
        (await admit(operationId('new', 'generation', now), 'new')).created,
        isTrue,
      );
      await expectLater(
        admit(old, 'old'),
        throwsA(isA<PrefillOperationExpired>()),
      );
      now = 1000001;
      await expectLater(
        admit(old, 'old'),
        throwsA(isA<PrefillOperationExpired>()),
      );
    },
  );

  test(
    'terminal replay window starts at completion rather than admission',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-prefill-replay-');
      addTearDown(() => root.delete(recursive: true));
      var now = 1000000;
      final ledger = await PrefillOperationLedger.open(
        File('${root.path}/operations.json'),
        maxOperations: 2,
        maxPrefills: 1,
        wallClock: () => now,
        monotonicClock: () => now,
      );
      addTearDown(ledger.close);
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Future<PrefillAdmission> admit(String id, String salt) => ledger.admit(
        operationId: id,
        token: token,
        model: 'model',
        owner: 'owner',
        generation: 'generation',
        cacheSalt: salt,
        request: {'text': salt},
        kind: PrefillOperationKind.prefill,
      );
      final old = operationId('old', 'generation', now);
      await admit(old, 'old');
      now += 9 * 60 * 1000;
      await ledger.requestCancel(old, token);
      now += 2 * 60 * 1000;
      expect((await admit(old, 'old')).created, isFalse);
      await expectLater(
        admit(operationId('new', 'generation', now), 'new'),
        throwsA(isA<PrefillCapacityUnavailable>()),
      );
      now += 8 * 60 * 1000 + 1;
      expect(
        (await admit(operationId('new', 'generation', now), 'new')).created,
        isTrue,
      );
      await expectLater(
        admit(old, 'old'),
        throwsA(isA<PrefillOperationExpired>()),
      );
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
