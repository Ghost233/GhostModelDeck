import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/jevman_benchmark.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  for (final failCommit in [false, true]) {
    test(
      failCommit
          ? 'game commit storage failure remains the primary error after owned cleanup'
          : 'game commit waits for durable flush and freezes complete public call evidence',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        final root = await Directory.systemTemp.createTemp(
          'gmd-jevman-commit-',
        );
        addTearDown(() => root.delete(recursive: true));
        final runtime = JevmanRuntime(root);
        addTearDown(runtime.close);
        final original = Directory(
          '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/node-v24.21.0-darwin-arm64',
        );
        if (await File('${original.path}/bin/node').exists()) {
          final installation = Directory(
            '${root.path}/node-v24.21.0-darwin-arm64',
          );
          await Directory('${installation.path}/bin').create(recursive: true);
          await File('${original.path}/bin/node')
              .copy('${installation.path}/bin/node');
          await File('${original.path}/LICENSE')
              .copy('${installation.path}/LICENSE');
          expect(
            (await Process.run('/bin/chmod', [
              '700',
              '${installation.path}/bin/node',
            ])).exitCode,
            0,
          );
        }
        await runtime.prepare(DecisionCancellation());
        final manifest = jsonDecode(
          await File('benchmarks/manifests/jevman.json').readAsString(),
        ) as Map;
        final bridge = JevmanGameBridge(
          runtime: runtime,
          bundle: File('benchmarks/adapters/jevman/bridge.mjs'),
          bundleSha256: manifest['bundleSha256'] as String,
        );
        final cancellation = DecisionCancellation();
        final entered = Completer<Map<String, Object?>>();
        final release = Completer<void>();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          cancellation.cancel();
          await bridge.close();
        });
        fixture.runtime.io.respond = (request, response) async {
          if (!(request['questions'] as Map).containsKey('warmup')) {
            cancellation.cancel();
          }
          return response;
        };
        final primary = StateError('game journal write failed');
        var commits = 0;
        var finished = false;
        final operation = bridge
            .play(
              client: fixture.playground,
              model: 'native-kev',
              cancellation: cancellation,
              isCurrent: () => true,
              onGameCommitted: (Map<String, Object?> game) async {
                commits += 1;
                entered.complete(game);
                await release.future;
                if (failCommit) throw primary;
              },
            )
            .then(
              (value) {
                finished = true;
                return value;
              },
              onError: (Object error, StackTrace stack) {
                finished = true;
                Error.throwWithStackTrace(error, stack);
              },
            );
        final assertion = failCommit
            ? expectLater(operation, throwsA(same(primary)))
            : null;
        final game = await entered.future;
        expect(game['index'], 1);
        expect(game['complete'], isFalse);
        expect(JevmanRecording.parse(game['recording']).frames, isNotEmpty);
        final calls = game['calls'] as List;
        expect(calls, isNotEmpty);
        expect(
          calls.every(
            (call) => (call as Map)['phase'] == 'game' && call['game'] == 1,
          ),
          isTrue,
        );
        expect(
          calls.every(
            (call) =>
                (call as Map).containsKey('result') ||
                call.containsKey('error') ||
                call.containsKey('status'),
          ),
          isTrue,
        );
        expect(() => game['index'] = 99, throwsUnsupportedError);
        expect(() => calls.clear(), throwsUnsupportedError);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(finished, isFalse);
        release.complete();
        if (assertion != null) {
          await assertion;
        } else {
          final result = await operation;
          expect(result['status'], 'cancelled');
          expect(result['complete'], isFalse);
        }
        expect(commits, 1);
        expect(bridge.activeProcessId, isNull);
        expect(fixture.gateway.activeOwnedRequests, 0);
        expect(
          fixture.runtime.engine.runtimeInstances.every(
            (instance) => instance.hasLiveProcess,
          ),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final boundary in [
    (
      name:
          'target invalidation preserves the active game as targetUnavailable',
      kind: 'target',
      channel: JevPlaygroundMode.http,
    ),
    (
      name: 'normal close preserves the active game as interrupted',
      kind: 'close',
      channel: JevPlaygroundMode.http,
    ),
    (
      name: 'public HTTP business error cannot pass original warmup',
      kind: 'error',
      channel: JevPlaygroundMode.http,
    ),
    (
      name: 'public MCP business error cannot pass original warmup',
      kind: 'error',
      channel: JevPlaygroundMode.mcp,
    ),
  ]) {
    test(boundary.name, () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      final root = await Directory.systemTemp.createTemp(
        'gmd-jevman-boundary-',
      );
      addTearDown(() => root.delete(recursive: true));
      final runtime = JevmanRuntime(root);
      addTearDown(runtime.close);
      final original = Directory(
        '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/node-v24.21.0-darwin-arm64',
      );
      if (await File('${original.path}/bin/node').exists()) {
        final installation = Directory(
          '${root.path}/node-v24.21.0-darwin-arm64',
        );
        await Directory('${installation.path}/bin').create(recursive: true);
        await File('${original.path}/bin/node')
            .copy('${installation.path}/bin/node');
        await File('${original.path}/LICENSE')
            .copy('${installation.path}/LICENSE');
        expect(
          (await Process.run('/bin/chmod', [
            '700',
            '${installation.path}/bin/node',
          ])).exitCode,
          0,
        );
      }
      await runtime.prepare(DecisionCancellation());
      final manifest = jsonDecode(
        await File('benchmarks/manifests/jevman.json').readAsString(),
      ) as Map;
      final bridge = JevmanGameBridge(
        runtime: runtime,
        bundle: File('benchmarks/adapters/jevman/bridge.mjs'),
        bundleSha256: manifest['bundleSha256'] as String,
      );
      addTearDown(bridge.close);
      var current = true;
      Future<void>? closing;
      fixture.runtime.io.respond = (request, response) async {
        if (boundary.kind == 'error') {
          // A real public error envelope is returned by the existing production
          // controller after its external native endpoint rejects this input.
          return jsonEncode({
            'error': {'code': 'unavailable', 'message': 'warmup rejected'},
          });
        }
        if (!(request['questions'] as Map).containsKey('warmup')) {
          if (boundary.kind == 'target') current = false;
          if (boundary.kind == 'close') closing ??= bridge.close();
        }
        return response;
      };
      final result = await bridge.play(
        client: fixture.playground,
        model: 'native-kev',
        channel: boundary.channel,
        cancellation: DecisionCancellation(),
        isCurrent: () => current,
      );
      await closing;
      expect(
        result['status'],
        boundary.kind == 'target'
            ? 'targetUnavailable'
            : boundary.kind == 'close'
            ? 'interrupted'
            : 'failed',
      );
      expect(result['complete'], isFalse);
      expect(result['expectedGames'], 100);
      expect(result['summary'], isNull);
      if (boundary.kind == 'error') {
        expect(result['games'], isEmpty);
        expect(result['error'], isA<String>());
        final call = (result['calls'] as List).single as Map;
        expect((call['result'] as Map)['status'], isNot('success'));
        expect((call['request'] as Map)['state'], {'note': 'warm-up'});
      } else {
        final game = (result['games'] as List).single as Map;
        expect(game['complete'], isFalse);
        expect(JevmanRecording.parse(game['recording']).frames, isNotEmpty);
      }
      expect(bridge.activeProcessId, isNull);
      expect(fixture.gateway.activeOwnedRequests, 0);
      expect(
        fixture.runtime.engine.runtimeInstances.every(
          (instance) => instance.hasLiveProcess,
        ),
        isTrue,
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('public game cancellation keeps the active original trace and ends owned resources', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final root = await Directory.systemTemp.createTemp('gmd-jevman-active-');
    addTearDown(() => root.delete(recursive: true));
    final runtime = JevmanRuntime(root);
    addTearDown(runtime.close);
    final original = Directory(
      '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/node-v24.21.0-darwin-arm64',
    );
    if (await File('${original.path}/bin/node').exists()) {
      final installation = Directory('${root.path}/node-v24.21.0-darwin-arm64');
      await Directory('${installation.path}/bin').create(recursive: true);
      await File('${original.path}/bin/node')
          .copy('${installation.path}/bin/node');
      await File('${original.path}/LICENSE')
          .copy('${installation.path}/LICENSE');
      expect(
        (await Process.run('/bin/chmod', [
          '700',
          '${installation.path}/bin/node',
        ])).exitCode,
        0,
      );
    }
    await runtime.prepare(DecisionCancellation());
    final manifest = jsonDecode(
      await File('benchmarks/manifests/jevman.json').readAsString(),
    ) as Map;
    final bridge = JevmanGameBridge(
      runtime: runtime,
      bundle: File('benchmarks/adapters/jevman/bridge.mjs'),
      bundleSha256: manifest['bundleSha256'] as String,
    );
    addTearDown(bridge.close);
    final cancellation = DecisionCancellation();
    fixture.runtime.io.respond = (request, response) async {
      if (!(request['questions'] as Map).containsKey('warmup')) {
        cancellation.cancel();
      }
      return response;
    };
    final result = await bridge.play(
      client: fixture.playground,
      model: 'native-kev',
      cancellation: cancellation,
      isCurrent: () => true,
    );
    expect(result['status'], 'cancelled');
    expect(result['complete'], isFalse);
    expect(result['expectedGames'], 100);
    expect(result['summary'], isNull);
    final game = (result['games'] as List).single as Map;
    expect(game['index'], 1);
    expect(game['complete'], isFalse);
    final recording = JevmanRecording.parse(game['recording']);
    expect(recording.frames, isNotEmpty);
    expect(
      (result['calls'] as List).any((call) => (call as Map)['phase'] == 'game'),
      isTrue,
    );
    expect(bridge.activeProcessId, isNull);
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect(
      fixture.runtime.engine.runtimeInstances.every(
        (instance) => instance.hasLiveProcess,
      ),
      isTrue,
    );
    final originalBytes = jsonEncode(result);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(jsonEncode(result), originalBytes);
    expect(() => (result['games'] as List).clear(), throwsUnsupportedError);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('normal HTTP warmup cancellation seals zero games without stopping the model', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final root = await Directory.systemTemp.createTemp('gmd-jevman-public-');
    addTearDown(() => root.delete(recursive: true));
    final runtime = JevmanRuntime(root);
    addTearDown(runtime.close);
    final original = Directory(
      '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/node-v24.21.0-darwin-arm64',
    );
    if (await File('${original.path}/bin/node').exists()) {
      final installation = Directory('${root.path}/node-v24.21.0-darwin-arm64');
      await Directory('${installation.path}/bin').create(recursive: true);
      await File('${original.path}/bin/node')
          .copy('${installation.path}/bin/node');
      await File('${original.path}/LICENSE')
          .copy('${installation.path}/LICENSE');
      final chmod = await Process.run('/bin/chmod', [
        '700',
        '${installation.path}/bin/node',
      ]);
      expect(chmod.exitCode, 0);
    }
    await runtime.prepare(DecisionCancellation());
    final manifest = jsonDecode(
      await File('benchmarks/manifests/jevman.json').readAsString(),
    ) as Map;
    final bridge = JevmanGameBridge(
      runtime: runtime,
      bundle: File('benchmarks/adapters/jevman/bridge.mjs'),
      bundleSha256: manifest['bundleSha256'] as String,
    );
    addTearDown(bridge.close);
    final cancellation = DecisionCancellation();
    fixture.runtime.io.respond = (request, response) async {
      if ((request['questions'] as Map).containsKey('warmup')) {
        cancellation.cancel();
      }
      return response;
    };
    final result = await bridge.play(
      client: fixture.playground,
      model: 'native-kev',
      cancellation: cancellation,
      isCurrent: () => true,
    );
    expect(result['status'], 'cancelled');
    expect(result['complete'], isFalse);
    expect(result['games'], isEmpty);
    expect(result['summary'], isNull);
    expect(bridge.activeProcessId, isNull);
    final request = fixture.runtime.io.requests.single;
    expect(request['state'], {'note': 'warm-up'});
    expect(request['questions'], {
      'warmup': {
        'type': 'choice',
        'instructions': 'Pick one.',
        'criteria': {'a': 'Option A', 'b': 'Option B'},
      },
    });
    expect(request.containsKey('keys'), isFalse);
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect(
      fixture.runtime.engine.runtimeInstances.every(
        (instance) => instance.hasLiveProcess,
      ),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('original replay verifies the author trace without any model client', () async {
    final root = await Directory.systemTemp.createTemp('gmd-jevman-replay-');
    addTearDown(() => root.delete(recursive: true));
    final installation = Directory('${root.path}/node-v24.21.0-darwin-arm64');
    final original = Directory(
      '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/node-v24.21.0-darwin-arm64',
    );
    if (await File('${original.path}/bin/node').exists()) {
      await Directory('${installation.path}/bin').create(recursive: true);
      await File('${original.path}/bin/node')
          .copy('${installation.path}/bin/node');
      await File('${original.path}/LICENSE')
          .copy('${installation.path}/LICENSE');
      final chmod = await Process.run('/bin/chmod', [
        '700',
        '${installation.path}/bin/node',
      ]);
      expect(chmod.exitCode, 0);
    }
    final runtime = JevmanRuntime(root);
    addTearDown(runtime.close);
    await runtime.prepare(DecisionCancellation());
    final manifest = jsonDecode(
      await File('benchmarks/manifests/jevman.json').readAsString(),
    ) as Map;
    final bridge = JevmanGameBridge(
      runtime: runtime,
      bundle: File('benchmarks/adapters/jevman/bridge.mjs'),
      bundleSha256: manifest['bundleSha256'] as String,
    );
    addTearDown(bridge.close);
    final recording = JevmanRecording.parse(
      jsonDecode(
        await File('benchmarks/sources/jevman/public/demo/kev-4b-demo.json')
            .readAsString(),
      ),
    );
    final verdict = await bridge.replay(recording);
    // Independent literal oracle from upstream src/recordings.ts and its trace.
    expect(verdict['ok'], isTrue);
    expect(verdict['final'], {
      'score': 1480,
      'lives': 0,
      'level': 1,
      'frames': 2693,
    });
    expect((verdict['result'] as Map)['score'], 1480);
    expect(verdict['fingerprint'], isA<String>());
    expect(bridge.activeProcessId, isNull);
    final bad = JevmanRecording.parse({
      ...recording.toJson(),
      'final': Map<String, Object?>.from(recording.toJson()['final'] as Map)
        ..['score'] = 1490,
    });
    final rejected = await bridge.replay(bad);
    expect(rejected['ok'], isFalse);
    expect(rejected['error'], contains('recording claims score 1490'));
    expect(bridge.activeProcessId, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'recording boundary keeps original timing and rejects a bad direction',
    () {
      final document = <String, Object?>{
        'version': 1,
        'recordedAt': '2026-10-09T00:00:00.000Z',
        'model': 'native-kev',
        'frames': [0.0167, 0.0168],
        'decisions': [
          [1, 'pacman@13,23:0', 'left'],
        ],
        'events': <Object?>[],
        'final': {'score': 0, 'lives': 3, 'level': 1, 'frames': 2},
      };
      final recording = JevmanRecording.parse(document);
      expect(recording.frames, [0.0167, 0.0168]);
      expect(recording.finalScore, 0);
      expect(recording.toJson(), document);
      // The boundary must own an immutable copy, rather than retaining mutable
      // incoming IPC/history data and allowing already sealed traces to change.
      (document['frames'] as List<double>)[0] = 0.05;
      expect(recording.frames.first, 0.0167);
      expect(() => recording.frames.add(0.02), throwsUnsupportedError);

      final invalid = <String, Object?>{
        ...recording.toJson(),
        'decisions': [
          [1, 'pacman@13,23:0', 'diagonal'],
        ],
      };
      expect(
        () => JevmanRecording.parse(invalid),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
