import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/llama_engine.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  test('declared source crosses public HTTP and MCP without synthesizing native results', () async {
    final fixture = await PlaygroundRuntime.create(sourceSystemone: true);
    addTearDown(fixture.close);
    final io = fixture.runtime.io;
    expect(io.requests, isEmpty);
    expect(io.decisionPaths, isEmpty);
    expect(fixture.council.models.availableBindings, hasLength(2));
    for (final instance in fixture.runtime.engine.state.instances) {
      expect(
        instance.decisionSourceIdentity!['capability_origin'],
        'source_declaration',
      );
      expect(instance.typedEvidence, isEmpty);
    }
    final document = jsonEncode(playgroundDocument('native-kev'));
    for (final mode in JevPlaygroundMode.values) {
      final discovered = await fixture.playground.discover(mode);
      expect(jsonEncode(discovered), contains('native-kev'));
      final result = await fixture.playground.run(mode, document);
      expect(result.status, JevPlaygroundStatus.success);
      expect(result.output!['answers'], {
        'route': {
          'type': 'choice',
          'choice': 'b',
          'probabilities': {'a': 0.25, 'b': 0.75},
          'confidence': 0.5,
        },
        'rank': {
          'type': 'score',
          'score': 0.75,
          'confidence': 0.5,
          'legend': {
            '0': 'Low',
            '1': {'label': 'High'},
          },
          'probabilities': {'0': 0.25, '1': 0.75},
        },
        'valid': {'type': 'noul', 'noul': 0.8},
      });
      expect(result.output!['usage'], {'input_tokens': 10, 'output_tokens': 0});
      expect(io.requests, hasLength(mode.index + 1));
    }
    expect(io.decisionPaths, ['/v1/systemone', '/v1/systemone']);
    io.consultationStatus = 501;
    io.respond = (_, _) async => jsonEncode({
      'error': {'message': 'native model unsupported'},
    });
    for (final mode in JevPlaygroundMode.values) {
      final result = await fixture.playground.run(mode, document);
      expect(result.status, JevPlaygroundStatus.businessError);
      expect(result.output!.containsKey('answers'), isFalse);
      expect(jsonEncode(result.output), contains('HTTP 501'));
    }
    expect(io.requests, hasLength(4));
    expect(io.killedChildren, 0);
    expect(
      fixture.runtime.engine.state.instances.map((i) => i.status),
      everyElement(LlamaInstanceStatus.ready),
    );
    expect(
      fixture.runtime.engine.runtimeInstances.map((i) => i.activeRequests),
      everyElement(0),
    );
    final binding = fixture.council.models.definitions
        .singleWhere((d) => d.name == 'native-kev')
        .bindings
        .single;
    final instance = fixture.runtime.engine.state.instances.singleWhere(
      (i) => i.asset.id == binding.artifactId,
    );
    await fixture.runtime.engine.stop(instance.id);
    for (final mode in JevPlaygroundMode.values) {
      final result = await fixture.playground.run(mode, document);
      expect(result.status, JevPlaygroundStatus.businessError);
      expect(jsonEncode(result.output), contains('model_not_ready'));
    }
    expect(io.requests, hasLength(4));
  });

  for (final mode in JevPlaygroundMode.values) {
    test(
      'declared source ${mode.name} cancellation releases admission and preserves its native instance',
      () async {
        final fixture = await PlaygroundRuntime.create(sourceSystemone: true);
        addTearDown(fixture.close);
        final arrived = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        fixture.runtime.io.respond = (_, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
          return raw;
        };
        final token = DecisionCancellation();
        final document = jsonEncode(playgroundDocument('native-kev'));
        final pending = fixture.playground.run(
          mode,
          document,
          cancellation: token,
        );
        await arrived.future.timeout(const Duration(seconds: 3));
        token.cancel();
        expect(
          (await pending.timeout(const Duration(seconds: 3))).status,
          JevPlaygroundStatus.cancelled,
        );
        final watch = Stopwatch()..start();
        while (fixture.runtime.engine.runtimeInstances.any(
          (i) => i.activeRequests != 0,
        )) {
          if (watch.elapsed > const Duration(seconds: 3)) {
            fail('Cancelled native admission did not drain');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(fixture.runtime.io.killedChildren, 0);
        fixture.runtime.io.respond = null;
        release.complete();
        expect(
          (await fixture.playground.run(mode, document)).status,
          JevPlaygroundStatus.success,
        );
        expect(fixture.runtime.io.decisionPaths, [
          '/v1/systemone',
          '/v1/systemone',
        ]);
      },
    );
  }
}
