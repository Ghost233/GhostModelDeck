import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/jev_debug.dart';
import 'package:ghost_model_deck/llama_engine.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test(
    'native debug contains the actual IO and conversion only for this call',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      await council.models.save(
        JevModelDefinition.native(
          name: 'native',
          binding: council.models.availableBindings.single,
        ),
      );
      final plain = await council.models.decide('native', request('plain'));
      expect(plain.keys, ['model', 'answers', 'usage']);
      final traced = await council.models.decide(
        'native',
        request('traced'),
        debug: true,
      );
      final debug = traced['debug'] as Map;
      expect(debug['model'], 'native');
      expect(debug['source'], 'native');
      expect(debug['input']['state'], 'traced');
      expect(debug.containsKey('council'), false);
      expect(debug.containsKey('seats'), false);
      final native = debug['native'] as Map;
      expect(native['status'], 'ok');
      expect(native['dispatched'], true);
      expect(native['http_status'], 200);
      expect(native['request']['state'], 'traced');
      expect(native['request'], runtime.io.requests.last);
      expect(
        jsonDecode(native['request_body'] as String),
        runtime.io.requests.last,
      );
      final raw = jsonDecode(native['raw_response'] as String) as Map;
      expect(raw['model'], native['instance_id']);
      expect(raw['usage'], {'input_tokens': 10, 'output_tokens': 0});
      expect(native['elapsed_us'], isNonNegative);
      expect(debug['converted_result'], {
        'model': 'native',
        'answers': traced['answers'],
        'usage': traced['usage'],
      });
      expect(debug['elapsed_us'], isNonNegative);
      final next = await council.models.decide('native', request('next'));
      expect(next.keys, ['model', 'answers', 'usage']);
      expect(runtime.engine.state.instances.single.activeRequests, 0);
      expect(runtime.io.killedChildren, 0);
    },
  );
  test(
    'council debug accounts for successful invalid and unavailable bindings',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 3);
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      final bindings = council.models.availableBindings;
      await council.models.save(
        JevModelDefinition.council(
          name: 'hard',
          seats: bindings,
          timeout: const Duration(seconds: 2),
        ),
      );
      final invalid = runtime.engine.state.instances[1].id;
      await runtime.engine.stop(runtime.engine.state.instances.last.id);
      runtime.io.respond = (body, raw) async =>
          body['model'] == invalid ? '{"broken":' : raw;
      final result = await council.models.decide(
        'hard',
        request('partial'),
        debug: true,
      );
      expect(result['usage'], {'input_tokens': 10, 'output_tokens': 0});
      final debug = result['debug'] as Map;
      expect(debug['model'], 'hard');
      expect(debug['input']['state'], 'partial');
      final seats = debug['seats'] as List;
      expect(seats, hasLength(3));
      expect(seats.map((s) => s['status']).toSet(), {
        'ok',
        'invalid_response',
        'not_ready',
      });
      final failed =
          seats.singleWhere((s) => s['status'] == 'invalid_response') as Map;
      expect(
        failed['request'],
        runtime.io.requests.singleWhere((r) => r['model'] == invalid),
      );
      expect(failed['raw_response'], '{"broken":');
      expect(failed['http_status'], 200);
      expect(failed['error'], isNotEmpty);
      final offline =
          seats.singleWhere((s) => s['status'] == 'not_ready') as Map;
      expect(offline['dispatched'], false);
      expect(offline['request'], isNull);
      expect(offline['raw_response'], isNull);
      expect(debug['valid_seats'], hasLength(1));
      expect(debug['council']['status'], 'partial');
      expect(debug['council']['seats'], hasLength(2));
      expect(debug['converted_result'], {
        'model': 'hard',
        'answers': result['answers'],
        'usage': result['usage'],
      });
      expect(
        runtime.engine.state.instances.every((i) => i.activeRequests == 0),
        true,
      );
    },
  );
  test(
    'native errors preserve complete raw IO without successful answers',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      await council.models.save(
        JevModelDefinition.native(
          name: 'native',
          binding: council.models.availableBindings.single,
        ),
      );
      for (final sample in [
        (200, '{"invalid-json":', 'invalid_response'),
        (
          200,
          '{"answers":{},"diagnostic":"invalid-business"}',
          'invalid_response',
        ),
        (503, 'upstream unavailable: raw marker', 'engine_error'),
      ]) {
        runtime.io.consultationStatus = sample.$1;
        runtime.io.respond = (_, _) async => sample.$2;
        final error = await failed(
          council.models.decide('native', request(sample.$3), debug: true),
        );
        expect((error['error'] as Map)['code'], sample.$3);
        expect(error.containsKey('answers'), false);
        final debug = error['debug'] as Map;
        expect(debug.containsKey('council'), false);
        expect(debug['native']['status'], sample.$3);
        expect(debug['native']['raw_response'], sample.$2);
        expect(debug['native']['http_status'], sample.$1);
        expect(debug['native']['request']['state'], sample.$3);
        expect(debug['converted_result'], {'error': error['error']});
        expect(runtime.engine.state.instances.single.activeRequests, 0);
      }
    },
  );
  test('council cancellation keeps received evidence and deadline keeps valid success', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 1),
      ),
    );
    final fast = runtime.engine.state.instances.first.id;
    for (final cancel in [true, false]) {
      final arrived = Completer<void>(),
          fastRelease = Completer<void>(),
          slowRelease = Completer<void>();
      var calls = 0;
      addTearDown(() {
        if (!fastRelease.isCompleted) fastRelease.complete();
        if (!slowRelease.isCompleted) slowRelease.complete();
      });
      runtime.io.respond = (body, raw) async {
        if (body['state'] != 'next') {
          if (++calls == 2) arrived.complete();
          await (body['model'] == fast
              ? fastRelease.future
              : slowRelease.future);
        }
        return raw;
      };
      final token = DecisionCancellation();
      final pending = council.models.decide(
        'quick',
        request(cancel ? 'cancel' : 'deadline'),
        cancellation: token,
        debug: true,
      );
      final outcome = cancel ? failed(pending) : pending;
      await arrived.future.timeout(const Duration(seconds: 2));
      final fastIdle = runtime.engine.changes.firstWhere(
        (s) => s.instances.any((i) => i.id == fast && i.activeRequests == 0),
      );
      fastRelease.complete();
      await fastIdle.timeout(const Duration(seconds: 2));
      await Future<void>.value();
      if (cancel) token.cancel();
      final result = await outcome.timeout(const Duration(seconds: 2));
      if (cancel) {
        expect((result['error'] as Map)['code'], 'cancelled');
        expect(result.containsKey('answers'), false);
      } else {
        expect(result['usage'], {'input_tokens': 10, 'output_tokens': 0});
      }
      final debug = result['debug'] as Map;
      final seats = debug['seats'] as List;
      expect(
        seats.singleWhere((s) => s['instance_id'] == fast)['status'],
        'ok',
      );
      expect(
        seats.singleWhere((s) => s['instance_id'] == fast)['raw_response'],
        isNotNull,
      );
      final slow = seats.singleWhere((s) => s['instance_id'] != fast) as Map;
      expect(slow['status'], cancel ? 'cancelled' : 'timed_out');
      expect(slow['dispatched'], true);
      expect(slow['raw_response'], isNull);
      expect(debug['valid_seats'], hasLength(1));
      expect(debug['converted_result'], {
        for (final e in result.entries)
          if (e.key != 'debug') e.key: e.value,
      });
      final frozen = jsonEncode(result);
      final next = await council.models.decide(
        'quick',
        request('next'),
        debug: true,
      );
      expect((next['debug'] as Map)['input']['state'], 'next');
      slowRelease.complete();
      token.cancel();
      await Future<void>.value();
      expect(jsonEncode(result), frozen);
      expect(
        runtime.engine.state.instances.every((i) => i.activeRequests == 0),
        true,
      );
      expect(runtime.io.killedChildren, 0);
    }
  });
  test('a council deadline with no complete seat reports timed_out and seals empty responses', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 1),
      ),
    );
    runtime.io.holdConsultation();
    final pending = failed(
      council.models.decide('hard', request('zero-success'), debug: true),
    );
    await runtime.io.bothArrived!.future.timeout(const Duration(seconds: 2));
    final result = await pending.timeout(const Duration(seconds: 2));
    expect((result['error'] as Map)['code'], 'timed_out');
    expect(result.containsKey('answers'), false);
    final debug = result['debug'] as Map;
    expect(debug['valid_seats'], isEmpty);
    expect(debug['council']['status'], 'failed');
    for (final seat in debug['seats'] as List) {
      expect(seat['status'], 'timed_out');
      expect(seat['dispatched'], true);
      expect(seat['raw_response'], isNull);
    }
    final frozen = jsonEncode(result);
    runtime.io.release!.complete();
    expect(
      (await council.models.decide('hard', request('after-deadline')))['model'],
      'hard',
    );
    expect(jsonEncode(result), frozen);
    expect(
      runtime.engine.state.instances.every((i) => i.activeRequests == 0),
      true,
    );
    expect(runtime.io.killedChildren, 0);
  });
  test('debug redacts credential fields and echoes without changing engine input or standard answers', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final binding = council.models.availableBindings.single;
    await council.models.save(
      JevModelDefinition.native(name: 'native', binding: binding),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [binding],
        timeout: const Duration(seconds: 2),
      ),
    );
    runtime.io.respond = (_, raw) async => jsonEncode({
      ...jsonDecode(raw) as Map,
      'diagnostic': {
        'AuThOrIzAtIoN': 'Bearer test-auth-secret',
        'nested': {
          'Cookie': 'sid=test-cookie-secret',
          'API-Key': 'test-api-secret',
        },
      },
      'echo': 'test-api-secret test-auth-secret',
    });
    for (final name in ['native', 'quick']) {
      final result = await council.models.decide(
        name,
        request('business-test-api-secret'),
        debug: true,
      );
      expect(runtime.io.requests.last['state'], 'business-test-api-secret');
      expect((result['answers'] as Map)['pick']['choice'], 'b');
      final serialized = jsonEncode(result);
      for (final secret in [
        'test-auth-secret',
        'test-cookie-secret',
        'test-api-secret',
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
      expect(serialized, contains('[redacted]'));
      final debug = result['debug'] as Map;
      expect(
        () => (debug['configuration'] as Map)['name'] = 'mutated',
        throwsUnsupportedError,
      );
      expect(
        () => (debug['input'] as Map)['state'] = 'mutated',
        throwsUnsupportedError,
      );
    }
    for (final sample in [
      (200, '{"api_key":"test-malformed-secret","broken":'),
      (
        503,
        'Authorization: Bearer test-error-secret\nCookie: sid=test-error-cookie',
      ),
    ]) {
      runtime.io.consultationStatus = sample.$1;
      runtime.io.respond = (_, _) async => sample.$2;
      final error = await failed(
        council.models.decide('native', request('error'), debug: true),
      );
      expect(jsonEncode(error), isNot(contains('test-malformed-secret')));
      expect(jsonEncode(error), isNot(contains('test-error-secret')));
      expect(jsonEncode(error), isNot(contains('test-error-cookie')));
      expect(
        (error['debug'] as Map)['native']['raw_response'],
        contains('[redacted]'),
      );
      expect((error['debug'] as Map)['converted_result'], {
        'error': error['error'],
      });
    }
  });
  test('active cancellation during real native fault cleanup still ends as cancelled', () async {
    final io = CouncilRuntimeIO();
    final runtime = await CouncilRuntime.create(modelCount: 1, processIO: io);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.native(
        name: 'native',
        binding: council.models.availableBindings.single,
      ),
    );
    final alias = runtime.engine.state.instances.single.id;
    io.identityAliases[alias] = 'wrong-identity';
    io.heldExitAliases.add(alias);
    io.childKilled = Completer<void>();
    io.exitRelease = Completer<void>();
    final token = DecisionCancellation();
    var completed = false;
    final pending = failed(
      council.models.decide(
        'native',
        request('fault-cleanup'),
        cancellation: token,
        debug: true,
      ),
    ).whenComplete(() => completed = true);
    await io.childKilled!.future.timeout(const Duration(seconds: 2));
    expect(runtime.engine.state.instances.single.activeRequests, 0);
    expect(completed, false);
    token.cancel();
    io.exitRelease!.complete();
    final error = await pending.timeout(const Duration(seconds: 2));
    expect((error['error'] as Map)['code'], 'cancelled');
    final native = (error['debug'] as Map)['native'] as Map;
    expect(native['status'], 'cancelled');
    expect(native['dispatched'], false);
    expect(native['raw_response'], isNull);
    expect(error.containsKey('answers'), false);
    expect(io.killedAliases, [alias]);
  });
  test('native cancellation and its actual ten-second budget preserve only submitted IO', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.native(
        name: 'native',
        binding: council.models.availableBindings.single,
      ),
    );
    final pid = runtime.engine.state.instances.single.pid;
    for (final cancel in [true, false]) {
      final arrived = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      runtime.io.respond = (body, raw) async {
        if (body['state'] != 'next') {
          arrived.complete();
          await release.future;
        }
        return raw;
      };
      final token = DecisionCancellation();
      final pending = failed(
        council.models.decide(
          'native',
          request(cancel ? 'cancel' : 'timeout'),
          cancellation: token,
          debug: true,
        ),
      );
      await arrived.future.timeout(const Duration(seconds: 2));
      if (cancel) token.cancel();
      final result = await pending.timeout(const Duration(seconds: 12));
      expect(
        (result['error'] as Map)['code'],
        cancel ? 'cancelled' : 'timed_out',
      );
      final debug = result['debug'] as Map;
      expect(debug['native']['status'], cancel ? 'cancelled' : 'timed_out');
      expect(debug['native']['dispatched'], true);
      expect(debug['native']['raw_response'], isNull);
      expect(debug['native']['http_status'], isNull);
      expect(debug.containsKey('council'), false);
      expect(debug.containsKey('valid_seats'), false);
      if (!cancel) expect(debug['elapsed_us'], greaterThanOrEqualTo(9900000));
      final frozen = jsonEncode(result);
      expect(
        (await council.models.decide('native', request('next')))['model'],
        'native',
      );
      release.complete();
      token.cancel();
      await Future<void>.value();
      expect(jsonEncode(result), frozen);
      expect(runtime.engine.state.instances.single.activeRequests, 0);
      expect(runtime.engine.state.instances.single.pid, pid);
      expect(runtime.io.killedChildren, 0);
    }
  });
  test('the public managed decideBatch trace seals failures and returns deep snapshots', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final alias = runtime.engine.state.instances.first.id;
    final peer = runtime.engine.state.instances.last.id;
    runtime.io.consultationStatus = 503;
    runtime.io.respond = (_, _) async => 'managed error raw';
    final io = DecisionIOTrace();
    await expectLater(
      runtime.engine.decideBatch(alias, request('direct-managed'), ioTrace: io),
      throwsA(isA<LlamaRequestException>()),
    );
    final evidence = io.toJson();
    expect(evidence['raw_response'], 'managed error raw');
    expect(evidence['http_status'], 503);
    expect((evidence['request'] as Map)['state'], 'direct-managed');
    expect(
      () => (evidence['request'] as Map)['state'] = 'mutated',
      throwsUnsupportedError,
    );
    runtime.io.consultationStatus = 200;
    runtime.io.respond = null;
    await runtime.engine.stop(alias);
    final unavailable = DecisionIOTrace();
    await expectLater(
      runtime.engine.decideBatch(
        alias,
        request('not-ready'),
        ioTrace: unavailable,
      ),
      throwsA(isA<LlamaRequestException>()),
    );
    final unavailableSnapshot = jsonEncode(unavailable.toJson());
    await runtime.engine.decideBatch(peer, request('healthy-peer'));
    expect(jsonEncode(io.toJson()), jsonEncode(evidence));
    expect(jsonEncode(unavailable.toJson()), unavailableSnapshot);
    expect(unavailable.toJson()['request'], isNull);
    expect(unavailable.toJson()['raw_response'], isNull);
    expect(
      runtime.engine.state.instances.every((i) => i.activeRequests == 0),
      true,
    );
  });
  test('council cutoff seals IO before cleanup and a later active cancel withdraws its success', () async {
    for (final mode in [
      'cancel-before-cutoff',
      'cancel-after-cutoff',
      'deadline-control',
    ]) {
      final io = CouncilRuntimeIO();
      final runtime = await CouncilRuntime.create(processIO: io);
      addTearDown(runtime.close);
      final council = CouncilController(catalog: runtime.catalog);
      addTearDown(council.close);
      final fast = runtime.engine.state.instances.first;
      final bad = runtime.engine.state.instances.last;
      final bindings = council.models.availableBindings;
      await council.models.save(
        JevModelDefinition.council(
          name: 'hard',
          seats: bindings,
          timeout: const Duration(seconds: 1),
        ),
      );
      await council.models.save(
        JevModelDefinition.native(
          name: 'peer',
          binding: bindings.singleWhere((b) => b.artifactId == fast.asset.id),
        ),
      );
      io.identityAliases[bad.id] = 'wrong-identity';
      io.heldExitAliases.add(bad.id);
      io.exitRelease = Completer<void>();
      io.childKilled = Completer<void>();
      final fastArrived = Completer<void>(), fastRelease = Completer<void>();
      addTearDown(() {
        if (!fastRelease.isCompleted) fastRelease.complete();
      });
      io.respond = (body, raw) async {
        if (body['state'] == mode) {
          fastArrived.complete();
          await fastRelease.future;
        }
        return raw;
      };
      final token = DecisionCancellation();
      var completed = false;
      final pending = council.models.decide(
        'hard',
        request(mode),
        cancellation: token,
        debug: true,
      );
      final outcome = (mode == 'deadline-control' ? pending : failed(pending))
          .whenComplete(() => completed = true);
      await Future.wait([io.childKilled!.future, fastArrived.future])
          .timeout(const Duration(seconds: 2));
      final idle = runtime.engine.changes.firstWhere(
        (s) => s.instances.any((i) => i.id == fast.id && i.activeRequests == 0),
      );
      fastRelease.complete();
      await idle.timeout(const Duration(seconds: 2));
      await Future<void>.value();
      if (mode != 'cancel-before-cutoff') {
        // Both IO gates are established first. This timer is later than the saved round deadline.
        final afterDeadline = Completer<void>();
        Timer(const Duration(milliseconds: 1100), afterDeadline.complete);
        await afterDeadline.future;
      }
      expect(
        completed,
        false,
        reason: 'the external child exit is still blocked',
      );
      if (mode != 'deadline-control') token.cancel();
      expect(
        (await council.models.decide(
          'peer',
          request('concurrent-peer'),
        ))['model'],
        'peer',
      );
      expect(
        runtime.engine.state.instances.singleWhere((i) => i.id == fast.id).pid,
        fast.pid,
      );
      io.exitRelease!.complete();
      final result = await outcome.timeout(const Duration(seconds: 2));
      if (mode == 'deadline-control') {
        expect(result['usage'], {'input_tokens': 10, 'output_tokens': 0});
      } else {
        expect((result['error'] as Map)['code'], 'cancelled');
        expect(result.containsKey('answers'), false);
      }
      final debug = result['debug'] as Map;
      expect(debug['valid_seats'], hasLength(1));
      final seats = debug['seats'] as List;
      expect(
        seats.singleWhere((s) => s['instance_id'] == fast.id)['status'],
        'ok',
      );
      final fault = seats.singleWhere((s) => s['instance_id'] == bad.id) as Map;
      expect(
        fault['status'],
        mode == 'cancel-before-cutoff' ? 'cancelled' : 'timed_out',
      );
      expect(fault['dispatched'], false);
      expect(fault['raw_response'], isNull);
      expect(io.killedAliases, [bad.id]);
      expect(
        runtime.engine.state.instances.every((i) => i.activeRequests == 0),
        true,
      );
    }
  });

  test('overlapping profiles and native calls keep their own reverse-order IO and debug choice', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final registry = File('${runtime.root.path}/private/jev.json');
    final council = CouncilController(
      catalog: runtime.catalog,
      modelRegistryFile: registry,
    );
    addTearDown(council.close);
    final binding = council.models.availableBindings.single;
    for (final name in ['quick', 'hard']) {
      await council.models.save(
        JevModelDefinition.council(
          name: name,
          seats: [binding],
          timeout: Duration(seconds: name == 'quick' ? 3 : 4),
        ),
      );
    }
    await council.models.save(
      JevModelDefinition.native(name: 'native', binding: binding),
    );
    final before = await registry.readAsString();
    final arrivals = Completer<void>(),
        releaseA = Completer<void>(),
        releaseB = Completer<void>();
    addTearDown(() {
      if (!releaseA.isCompleted) releaseA.complete();
      if (!releaseB.isCompleted) releaseB.complete();
    });
    var count = 0;
    runtime.io.respond = (body, raw) async {
      if (body['state'] == 'A' || body['state'] == 'B') {
        if (++count == 2) arrivals.complete();
        await (body['state'] == 'A' ? releaseA.future : releaseB.future);
      }
      return jsonEncode({
        ...jsonDecode(raw) as Map,
        'marker': body['state'],
        'usage': {
          'input_tokens': body['state'] == 'A' ? 11 : 22,
          'output_tokens': 0,
        },
      });
    };
    final a = council.models.decide('quick', request('A'), debug: true);
    final b = council.models.decide('hard', request('B'), debug: true);
    await arrivals.future.timeout(const Duration(seconds: 2));
    final concurrent = await council.models.decide(
      'native',
      request('plain-peer'),
    );
    expect(concurrent.keys, ['model', 'answers', 'usage']);
    releaseB.complete();
    final resultB = await b;
    await council.models.save(
      JevModelDefinition.council(
        name: 'renamed',
        seats: [binding],
        timeout: const Duration(seconds: 2),
      ),
      replacing: 'quick',
    );
    releaseA.complete();
    final resultA = await a;
    for (final result in [resultA, resultB]) {
      final marker = result['model'] == 'quick' ? 'A' : 'B';
      final debug = result['debug'] as Map;
      expect(debug['configuration']['name'], result['model']);
      expect(
        debug['configuration']['timeout_us'],
        marker == 'A' ? 3000000 : 4000000,
      );
      expect(debug['input']['state'], marker);
      final io = (debug['seats'] as List).single as Map;
      expect(io['request']['state'], marker);
      expect(jsonDecode(io['raw_response'] as String)['marker'], marker);
      expect(result['usage'], {
        'input_tokens': marker == 'A' ? 11 : 22,
        'output_tokens': 0,
      });
    }
    expect(
      (await council.models.decide('renamed', request('next')))['model'],
      'renamed',
    );
    await expectLater(
      council.models.decide('quick', request('old-name')),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'model_not_found',
        ),
      ),
    );
    final saved = await registry.readAsString();
    expect(before, isNot(contains('debug')));
    expect(saved, isNot(contains('debug')));
    expect(saved, isNot(contains('history')));
    expect(runtime.engine.state.instances.single.activeRequests, 0);
    expect(runtime.io.killedChildren, 0);
  });
  test('deep JSON input and renamed bindings share the frozen request and its actual IO trace', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    for (final source in ['native', 'council']) {
      final oldName = '$source-old', newName = '$source-new';
      await council.models.save(
        source == 'native'
            ? JevModelDefinition.native(name: oldName, binding: bindings.first)
            : JevModelDefinition.council(
                name: oldName,
                seats: bindings,
                timeout: const Duration(seconds: 3),
              ),
      );
      final state = <String, Object?>{
        'conversation': [
          {'content': 'original'},
        ],
        'ids': [1, 2],
      };
      final instructions = <String, Object?>{
        'policy': [
          'keep',
          {'flag': true},
        ],
      };
      final descriptions = <String, Object?>{
        'a': {
          'label': ['A', true],
        },
        'b': ['B', 2],
      };
      final levels = <Object?>[
        {
          'tier': 'low',
          'detail': [1],
        },
        ['high', 2],
      ];
      final extensions = <String, Object?>{'images': null};
      final submitted = DecisionBatchRequest(
        state: state,
        extensions: extensions,
        questions: {
          'pick': ChoiceQuestion(
            instructions: instructions,
            options: descriptions,
          ),
          'rank': ScoreQuestion(
            instructions: [
              'rank',
              {'ordered': true},
            ],
            levels: levels,
          ),
        },
      );
      runtime.io.requests.clear();
      runtime.io.holdIdentity(expected: source == 'native' ? 1 : 2);
      runtime.io.respond = (body, raw) async => jsonEncode({
        ...jsonDecode(raw) as Map,
        'input_marker': body['state'],
      });
      final pending = council.models.decide(oldName, submitted, debug: true);
      await runtime.io.identityArrived!.future.timeout(
        const Duration(seconds: 2),
      );
      ((state['conversation'] as List).single as Map)['content'] = 'mutated';
      (state['ids'] as List).add(3);
      (instructions['policy'] as List).clear();
      (descriptions['b'] as List).clear();
      (levels.first as Map)['tier'] = 'mutated';
      extensions['images'] = <Object?>[];
      await council.models.save(
        source == 'native'
            ? JevModelDefinition.native(name: newName, binding: bindings.last)
            : JevModelDefinition.council(
                name: newName,
                seats: [bindings.last],
                timeout: const Duration(seconds: 1),
              ),
        replacing: oldName,
      );
      runtime.io.identityRelease!.complete();
      final result = await pending.timeout(const Duration(seconds: 3));
      expect(result['model'], oldName);
      final debug = result['debug'] as Map;
      expect(debug['configuration']['name'], oldName);
      expect(
        debug['configuration']['bindings'],
        hasLength(source == 'native' ? 1 : 2),
      );
      expect(
        debug['configuration']['timeout_us'],
        source == 'native' ? 10000000 : 3000000,
      );
      final expectedState = {
        'conversation': [
          {'content': 'original'},
        ],
        'ids': [1, 2],
      };
      expect(debug['input']['state'], expectedState);
      expect(debug['input']['questions']['pick']['instructions'], {
        'policy': [
          'keep',
          {'flag': true},
        ],
      });
      expect(debug['input']['questions']['pick']['criteria']['b'], ['B', 2]);
      expect(debug['input']['questions']['rank']['criteria'], [
        {
          'tier': 'low',
          'detail': [1],
        },
        ['high', 2],
      ]);
      expect((debug['input'] as Map).containsKey('images'), true);
      expect(debug['input']['images'], isNull);
      final captured = source == 'native'
          ? [debug['native']]
          : debug['seats'] as List;
      expect(runtime.io.requests, hasLength(captured.length));
      for (final io in captured) {
        final actual = runtime.io.requests.singleWhere(
          (body) => body['model'] == io['instance_id'],
        );
        expect(io['request'], actual);
        expect(jsonDecode(io['request_body'] as String), actual);
        expect(actual['state'], expectedState);
        expect(actual.containsKey('images'), true);
        expect(actual['images'], isNull);
        expect(
          jsonDecode(io['raw_response'] as String)['input_marker'],
          expectedState,
        );
        expect(
          () => (io['request']['state']['ids'] as List).add(9),
          throwsUnsupportedError,
        );
      }
      expect((result['answers'] as Map)['rank']['legend']['0'], {
        'tier': 'low',
        'detail': [1],
      });
      await expectLater(
        council.models.decide(oldName, request('old-route')),
        throwsA(
          isA<JevRequestException>().having(
            (e) => e.code,
            'code',
            'model_not_found',
          ),
        ),
      );
      final next = await council.models.decide(
        newName,
        request('new-route'),
        debug: true,
      );
      final newDebug = next['debug'] as Map;
      expect(newDebug['configuration']['bindings'], [bindings.last.toJson()]);
      expect(
        newDebug['configuration']['timeout_us'],
        source == 'native' ? 10000000 : 1000000,
      );
    }
    expect(
      runtime.engine.state.instances.every((i) => i.activeRequests == 0),
      true,
    );
    expect(runtime.io.killedChildren, 0);
  });
  test('contextual projection preserves legal typed data but redacts credential extras and known echoes', () {
    final wire =
        '{\n  "model": "native", "answers": {"api_key": {"type": "choice", "choice": "cookie", "confidence": 0.5, "probabilities": {"authorization": 0.25, "cookie": 0.75}, "diagnostic": {"API_KEY": "extra-secret"}}}, "usage": {"input_tokens": 10, "output_tokens": 0}, "server_log": "Authorization: Bearer raw-header-secret"\n}';
    final response = jsonDecode(wire) as Map<String, Object?>;
    final projected = sealDebugJson({
      'configuration': {
        'API_KEY': 'config-secret',
        'Authorization': 'Bearer config-auth-secret',
      },
      'input': {
        'model': 'native',
        'state': {
          'authorization': 'allow',
          'api_key': 'nonsecret payload',
          'echo': 'config-secret',
        },
        'questions': {
          'api_key': {
            'type': 'score',
            'instructions': 'Authorization: allow',
            'criteria': [
              'Authorization: allow',
              {'cookie': true},
            ],
          },
        },
      },
      'native': {'status': 'ok', 'result': response, 'raw_response': wire},
      'echo': 'extra-secret raw-header-secret config-secret config-auth-secret',
      'error': {'message': 'Cookie: sid=error-cookie-secret'},
    }, projection: JevDebugProjection.debug);
    final answer =
        (((projected['native'] as Map)['result'] as Map)['answers']
                as Map)['api_key']
            as Map;
    expect(answer['probabilities'], {'authorization': 0.25, 'cookie': 0.75});
    expect(answer['diagnostic'], {'API_KEY': '[redacted]'});
    expect((projected['input'] as Map)['state'], {
      'authorization': 'allow',
      'api_key': 'nonsecret payload',
      'echo': '[redacted]',
    });
    expect(
      ((projected['input'] as Map)['questions'] as Map)['api_key']['criteria'],
      [
        'Authorization: allow',
        {'cookie': true},
      ],
    );
    expect(
      (projected['native'] as Map)['raw_response'],
      wire
          .replaceAll('extra-secret', '[redacted]')
          .replaceAll('Bearer raw-header-secret', '[redacted]'),
    );
    for (final secret in [
      'extra-secret',
      'raw-header-secret',
      'config-secret',
      'config-auth-secret',
      'error-cookie-secret',
    ]) {
      expect(jsonEncode(projected), isNot(contains(secret)));
    }
    expect(wire, contains('extra-secret'));
    expect(
      () => (answer['probabilities'] as Map)['cookie'] = 1,
      throwsUnsupportedError,
    );
  });
}

DecisionBatchRequest request(String state) => DecisionBatchRequest(
  state: state,
  questions: {
    'pick': ChoiceQuestion(
      instructions: 'Choose',
      options: {'a': 'A', 'b': 'B'},
    ),
  },
);

Future<Map<String, Object>> failed(Future<Map<String, Object?>> pending) async {
  try {
    await pending;
    fail('Expected this call to fail');
  } on JevRequestException catch (error) {
    return error.toJson();
  }
}
