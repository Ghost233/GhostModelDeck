import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/decision_protocol.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test(
    'offline named models persist independently without loading instances',
    () async {
      final runtime = await CouncilRuntime.create();
      addTearDown(runtime.close);
      final instances = runtime.engine.state.instances.toList();
      for (final instance in instances) {
        await runtime.engine.stop(instance.id);
      }
      final file = File('${runtime.root.path}/named-models.json');
      final council = CouncilController(
        catalog: runtime.catalog,
        modelRegistryFile: file,
      );
      addTearDown(council.close);
      final bindings = council.models.availableBindings;
      expect(bindings, hasLength(2));
      await council.models.save(
        JevModelDefinition.council(
          name: 'quick',
          seats: [bindings.first],
          timeout: const Duration(seconds: 2),
        ),
      );
      await council.models.save(
        JevModelDefinition.council(
          name: 'hard',
          seats: bindings,
          timeout: const Duration(seconds: 9),
        ),
      );
      await council.models.save(
        JevModelDefinition.native(name: 'native-kev', binding: bindings.last),
      );
      expect(
        council.models.configuredModels.map((m) => m.available),
        everyElement(false),
      );
      expect(
        council.models.configuredModels.map((m) => m.reason),
        everyElement(isNotEmpty),
      );
      expect(
        runtime.engine.state.instances.where((i) => i.hasLiveProcess),
        isEmpty,
      );
      final restored = CouncilController(
        catalog: runtime.catalog,
        modelRegistryFile: file,
      );
      addTearDown(restored.close);
      await restored.models.load();
      expect(restored.models.definitions.map((m) => m.name), [
        'quick',
        'hard',
        'native-kev',
      ]);
      expect(
        restored.models.definitions[1].timeout,
        const Duration(seconds: 9),
      );
      expect(
        restored.models.definitions[1].bindings.map((b) => b.artifactId),
        bindings.map((b) => b.artifactId),
      );
      await restored.models.save(
        JevModelDefinition.council(
          name: 'renamed',
          seats: [bindings.last],
          timeout: const Duration(seconds: 3),
        ),
        replacing: 'quick',
      );
      await restored.models.delete('hard');
      expect(restored.models.definitions.map((m) => m.name), [
        'native-kev',
        'renamed',
      ]);
    },
  );
  test('native named model retains actual engine decisions confidence and token usage', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.native(
        name: 'native-kev',
        binding: council.models.availableBindings.first,
      ),
    );
    runtime.io.requests.clear();
    runtime.io.respond = (request, response) async => jsonEncode({
      'model': request['model'],
      'answers': {
        'route': {
          'type': 'choice',
          'choice': 'z',
          'probabilities': {'z': 0.5, 'a': 0.5},
          'confidence': 0.17,
        },
        'rank': {
          'type': 'score',
          'score': 1.000001,
          'legend': {'0': 'Low', '1': 'Medium', '2': 'High'},
          'probabilities': {'0': 0.5, '1': 0.0, '2': 0.5},
          'confidence': 0.23,
        },
        'valid': {'type': 'noul', 'noul': 0.8},
      },
      'usage': {'input_tokens': 27, 'output_tokens': 0},
    });
    final result = await council.models.decide('native-kev', _mixed());
    expect(result, {
      'model': 'native-kev',
      'answers': {
        'route': {
          'type': 'choice',
          'choice': 'z',
          'probabilities': {'z': 0.5, 'a': 0.5},
          'confidence': 0.17,
        },
        'rank': {
          'type': 'score',
          'score': 1.000001,
          'legend': {'0': 'Low', '1': 'Medium', '2': 'High'},
          'probabilities': {'0': 0.5, '1': 0.0, '2': 0.5},
          'confidence': 0.23,
        },
        'valid': {'type': 'noul', 'noul': 0.8},
      },
      'usage': {'input_tokens': 27, 'output_tokens': 0},
    });
    expect(runtime.io.requests, hasLength(1));
    expect(
      runtime.engine.state.instances.where((i) => i.activeRequests != 0),
      isEmpty,
    );
  });
  test('council computes standard mixed answers from final distribution and actual successful usage', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final first = runtime.engine.state.instances.first.id;
    runtime.io.respond = (request, response) async {
      final left = request['model'] == first;
      return jsonEncode({
        'model': request['model'],
        'answers': {
          'route': {
            'type': 'choice',
            'choice': left ? 'z' : 'a',
            'probabilities': {'z': left ? 0.9 : 0.1, 'a': left ? 0.1 : 0.9},
            'confidence': 0.8,
          },
          'rank': {
            'type': 'score',
            'score': left ? 1.0 : 0.3,
            'legend': {'0': 'Low', '1': 'Medium', '2': 'High'},
            'probabilities': {
              '0': left ? 0.1 : 0.8,
              '1': left ? 0.8 : 0.1,
              '2': 0.1,
            },
            'confidence': left ? 0.7 : 0.55,
          },
          'valid': {'type': 'noul', 'noul': left ? 0.2 : 0.8},
        },
        'usage': {'input_tokens': left ? 7 : 13, 'output_tokens': 0},
      });
    };
    final result = await council.models.decide('hard', _mixed());
    expect(result.keys, ['model', 'answers', 'usage']);
    final answers = result['answers'] as Map;
    expect(answers['route'], {
      'type': 'choice',
      'choice': 'a',
      'probabilities': {'z': 0.5, 'a': 0.5},
      'confidence': 0.0,
    });
    expect(answers['rank']['score'], closeTo(0.65, 1e-14));
    expect(answers['rank']['confidence'], closeTo(0.025, 1e-14));
    expect(answers['rank']['legend'], {'0': 'Low', '1': 'Medium', '2': 'High'});
    expect(answers['valid'], {'type': 'noul', 'noul': 0.5});
    expect(result['usage'], {'input_tokens': 20, 'output_tokens': 0});
  });
  test('partly available council shows offline reason and recovers stable bindings after restart', () async {
    final runtime = await CouncilRuntime.create();
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
    await council.models.save(
      JevModelDefinition.native(name: 'native-kev', binding: bindings.first),
    );
    final instance = runtime.engine.state.instances.singleWhere(
      (i) => i.asset.id == bindings.first.artifactId,
    );
    await runtime.engine.stop(instance.id);
    final partial = council.models.configuredModels.first;
    expect(partial.available, true);
    expect(partial.reason, contains('没有就绪'));
    expect(council.models.callableModels.map((m) => m.definition.name), [
      'hard',
    ]);
    final result = await council.models.decide('hard', _mixed());
    expect(result['usage'], {'input_tokens': 10, 'output_tokens': 0});
    await expectLater(
      council.models.decide('native-kev', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'model_not_ready',
        ),
      ),
    );
    await runtime.engine.start(bindings.first.artifactId);
    expect(council.models.callableModels.map((m) => m.definition.name), [
      'hard',
      'native-kev',
    ]);
    expect(council.models.configuredModels.first.reason, isNull);
    expect(
      runtime.engine.state.instances
          .where(
            (i) => i.hasLiveProcess && i.asset.id == bindings.first.artifactId,
          )
          .single
          .id,
      isNot(instance.id),
    );
    expect(
      (await council.models.decide('native-kev', _mixed()))['model'],
      'native-kev',
    );
  });
  test('global names and invalid configurations never overwrite a valid profile or create a default', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    await expectLater(
      council.models.decide('gmd-council', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'model_not_found',
        ),
      ),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [bindings.first],
        timeout: const Duration(seconds: 2),
      ),
    );
    await expectLater(
      council.models.save(
        JevModelDefinition.native(name: 'quick', binding: bindings.last),
      ),
      throwsA(isA<DecisionProtocolException>()),
    );
    for (final name in ['', ' ']) {
      expect(
        () => JevModelDefinition.council(
          name: name,
          seats: bindings,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<DecisionProtocolException>()),
      );
    }
    for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => JevModelDefinition.council(
          name: 'quick',
          seats: bindings,
          timeout: timeout,
        ),
        throwsA(isA<DecisionProtocolException>()),
      );
    }
    expect(
      () => JevModelDefinition.council(
        name: 'quick',
        seats: [bindings.first, bindings.first],
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<DecisionProtocolException>()),
    );
    await expectLater(
      council.models.save(
        JevModelDefinition.council(
          name: 'quick',
          seats: [
            const JevModelBinding(artifactId: 'unknown', engineId: 'unknown'),
          ],
          timeout: const Duration(seconds: 1),
        ),
        replacing: 'quick',
      ),
      throwsA(isA<DecisionProtocolException>()),
    );
    expect(
      council.models.definitions.single.bindings.single.id,
      bindings.first.id,
    );
    expect(
      council.models.definitions.single.timeout,
      const Duration(seconds: 2),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'gmd-council',
        seats: [bindings.last],
        timeout: const Duration(seconds: 2),
      ),
    );
    expect(
      (await council.models.decide('gmd-council', _mixed()))['model'],
      'gmd-council',
    );
  });

  test('incomplete or illegal mixed replies remove the whole seat and never repair probabilities or usage', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final invalid = runtime.engine.state.instances.last.id;
    for (final mutation in <void Function(Map)>[
      (body) => (body['answers'] as Map).remove('rank'),
      (body) =>
          body['answers']['route']['probabilities'] = {'z': 0.2, 'a': 0.2},
      (body) => (body['answers']['route'] as Map).remove('confidence'),
      (body) => body['answers']['valid']['confidence'] = 1,
    ]) {
      runtime.io.respond = (request, response) async {
        final body = jsonDecode(response) as Map;
        if (request['model'] == invalid) mutation(body);
        return jsonEncode(body);
      };
      final result = await council.models.decide('hard', _mixed());
      expect(result['usage'], {'input_tokens': 10, 'output_tokens': 0});
      expect((result['answers'] as Map)['route']['probabilities'], {
        'z': 0.25,
        'a': 0.75,
      });
      expect((result['answers'] as Map)['rank']['score'], 0.75);
      expect((result['answers'] as Map)['valid'], {
        'type': 'noul',
        'noul': 0.8,
      });
    }
    runtime.io.respond = (request, response) async {
      final body = jsonDecode(response) as Map;
      body['answers'] = {};
      return jsonEncode(body);
    };
    await expectLater(
      council.models.decide('hard', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'no_successful_seats',
        ),
      ),
    );
  });

  test('ambiguous binding is excluded from discovery and one council seat fails without choosing an instance', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.native(name: 'native-kev', binding: bindings.first),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: bindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    await runtime.engine.start(bindings.first.artifactId);
    runtime.io.requests.clear();
    expect(council.models.callableModels.map((m) => m.definition.name), [
      'hard',
    ]);
    expect(council.models.configuredModels.first.reason, contains('歧义'));
    await expectLater(
      council.models.decide('native-kev', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'route_conflict',
        ),
      ),
    );
    expect(runtime.io.requests, isEmpty);
    final result = await council.models.decide('hard', _mixed());
    expect(result['usage'], {'input_tokens': 10, 'output_tokens': 0});
    final unique = runtime.engine.state.instances.singleWhere(
      (i) => i.asset.id == bindings.last.artifactId,
    );
    expect(runtime.io.requests.map((r) => r['model']), [unique.id]);
  });

  test('only exact committee Choice ties use candidate ID order including one-seat results', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final request = DecisionBatchRequest(
      state: 'exact',
      questions: {
        'pick': ChoiceQuestion(
          instructions: 'Choose',
          options: {'z': 'Z', 'a': 'A'},
        ),
      },
    );
    runtime.io.respond = (request, response) async => jsonEncode({
      'model': request['model'],
      'answers': {
        'pick': {
          'type': 'choice',
          'choice': 'z',
          'probabilities': {'z': 0.5, 'a': 0.5},
          'confidence': 0.0,
        },
      },
      'usage': {'input_tokens': 11, 'output_tokens': 0},
    });
    expect((await council.models.decide('quick', request))['answers'], {
      'pick': {
        'type': 'choice',
        'choice': 'a',
        'probabilities': {'z': 0.5, 'a': 0.5},
        'confidence': 0.0,
      },
    });
    runtime.io.respond = (request, response) async => jsonEncode({
      'model': request['model'],
      'answers': {
        'pick': {
          'type': 'choice',
          'choice': 'z',
          'probabilities': {'a': 0.4999999999997726, 'z': 0.5000000000002274},
          'confidence': 0.0000000000004547473508864641,
        },
      },
      'usage': {'input_tokens': 11, 'output_tokens': 0},
    });
    final near =
        (await council.models.decide('quick', request))['answers'] as Map;
    expect(near['pick']['choice'], 'z');
    expect(
      near['pick']['confidence'],
      closeTo(0.0000000000004547473508864641, 1e-26),
    );
  });

  test('Score confidence matches independent native vectors and the first ordinal mode', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 2),
      ),
    );
    final vectors =
        <({List<double> probabilities, double score, double confidence})>[
          (probabilities: [0.5, 0.5], score: 0.5, confidence: 0.0),
          (probabilities: [0.75, 0.25], score: 0.25, confidence: 0.5),
          (probabilities: [0.6, 0.3, 0.1], score: 0.5, confidence: 0.25),
          (probabilities: [0.2, 0.6, 0.2], score: 1.0, confidence: 0.4),
          (probabilities: [0.5, 0.0, 0.5], score: 1.0, confidence: 0.0),
          (probabilities: [0.4, 0.4, 0.1, 0.1], score: 0.9, confidence: 0.1),
          (probabilities: [0.1, 0.2, 0.6, 0.1], score: 1.7, confidence: 0.5),
          (probabilities: [0.45, 0.45, 0.1], score: 0.65, confidence: 0.025),
        ];
    final request = DecisionBatchRequest(
      state: 'oracle',
      questions: {
        for (var i = 0; i < vectors.length; i++)
          'rank$i': ScoreQuestion(
            instructions: 'Rank',
            levels: [
              for (var j = 0; j < vectors[i].probabilities.length; j++)
                'Level $j',
            ],
          ),
      },
    );
    runtime.io.respond = (request, response) async => jsonEncode({
      'model': request['model'],
      'answers': {
        for (var i = 0; i < vectors.length; i++)
          'rank$i': {
            'type': 'score',
            'score': vectors[i].score,
            'legend': {
              for (var j = 0; j < vectors[i].probabilities.length; j++)
                '$j': 'Level $j',
            },
            'probabilities': {
              for (var j = 0; j < vectors[i].probabilities.length; j++)
                '$j': vectors[i].probabilities[j],
            },
            'confidence': 0.321,
          },
      },
      'usage': {'input_tokens': 27, 'output_tokens': 0},
    });
    final result = await council.models.decide('quick', request);
    final answers = result['answers'] as Map;
    for (var i = 0; i < vectors.length; i++) {
      expect(answers['rank$i']['score'], closeTo(vectors[i].score, 1e-14));
      expect(
        answers['rank$i']['confidence'],
        closeTo(vectors[i].confidence, 1e-14),
      );
    }
    expect(result['usage'], {'input_tokens': 27, 'output_tokens': 0});
  });

  test('rename edit and deletion affect new requests while admitted name members and timeout stay fixed', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: bindings,
        timeout: const Duration(seconds: 3),
      ),
    );
    runtime.io.holdConsultation();
    final pending = council.models.decide(
      'hard',
      _mixed(state: 'before-edit'),
      debug: true,
    );
    await runtime.io.bothArrived!.future.timeout(const Duration(seconds: 2));
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: [bindings.first],
        timeout: const Duration(seconds: 1),
      ),
      replacing: 'hard',
    );
    await expectLater(
      council.models.decide('hard', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'model_not_found',
        ),
      ),
    );
    runtime.io.release!.complete();
    final old = await pending;
    expect(old['model'], 'hard');
    expect(old['usage'], {'input_tokens': 20, 'output_tokens': 0});
    final snapshot = (old['debug'] as Map)['configuration'];
    expect(snapshot['name'], 'hard');
    expect(snapshot['timeout_us'], 3000000);
    expect(snapshot['bindings'], hasLength(2));
    final current = await council.models.decide('quick', _mixed(), debug: true);
    expect(current['model'], 'quick');
    expect(current['usage'], {'input_tokens': 10, 'output_tokens': 0});
    expect((current['debug'] as Map)['configuration']['timeout_us'], 1000000);
    final arrived = Completer<void>(), release = Completer<void>();
    runtime.io.respond = (request, response) async {
      if (request['state'] == 'before-delete') {
        arrived.complete();
        await release.future;
      }
      return response;
    };
    final deleting = council.models.decide(
      'quick',
      _mixed(state: 'before-delete'),
    );
    await arrived.future.timeout(const Duration(seconds: 2));
    await council.models.delete('quick');
    await expectLater(
      council.models.decide('quick', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'model_not_found',
        ),
      ),
    );
    release.complete();
    expect((await deleting)['model'], 'quick');
  });

  test('timeout uses a completed seat but active cancellation withdraws success and isolates the next call', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.council(
        name: 'quick',
        seats: bindings,
        timeout: const Duration(milliseconds: 300),
      ),
    );
    final first = runtime.engine.state.instances.first.id;
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    runtime.io.respond = (request, response) async {
      if (request['model'] != first) await release.future;
      return response;
    };
    final completed = runtime.engine.changes.firstWhere(
      (s) => s.instances.any((i) => i.id == first && i.lastBatchResult != null),
    );
    final timed = council.models.decide('quick', _mixed());
    await completed.timeout(const Duration(seconds: 2));
    final timedResult = await timed.timeout(const Duration(seconds: 2));
    expect(timedResult['usage'], {'input_tokens': 10, 'output_tokens': 0});
    release.complete();
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    runtime.io.respond = (request, response) async {
      if (request['model'] != first) await held.future;
      return response;
    };
    final arrived = runtime.engine.changes.firstWhere(
      (s) => s.instances.any(
        (i) =>
            i.id == first && i.lastBatchResult != null && i.activeRequests == 0,
      ),
    );
    final token = DecisionCancellation();
    final cancelled = council.models.decide(
      'quick',
      _mixed(),
      cancellation: token,
    );
    final rejected = expectLater(
      cancelled,
      throwsA(
        isA<JevRequestException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    await arrived.timeout(const Duration(seconds: 2));
    token.cancel();
    await rejected;
    held.complete();
    runtime.io.respond = null;
    expect((await council.models.decide('quick', _mixed()))['usage'], {
      'input_tokens': 20,
      'output_tokens': 0,
    });
    expect(
      runtime.engine.state.instances.where((i) => i.activeRequests != 0),
      isEmpty,
    );
    expect(runtime.io.killedChildren, 0);
  });
  test('application shutdown withdraws an admitted council success before normal output', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.council(
        name: 'hard',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 3),
      ),
    );
    final first = runtime.engine.state.instances.first.id;
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    runtime.io.respond = (request, response) async {
      if (request['model'] != first) await held.future;
      return response;
    };
    final complete = runtime.engine.changes.firstWhere(
      (s) => s.instances.any(
        (i) =>
            i.id == first && i.lastBatchResult != null && i.activeRequests == 0,
      ),
    );
    final pending = council.models.decide('hard', _mixed());
    final rejected = expectLater(
      pending,
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'service_stopping',
        ),
      ),
    );
    await complete.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    council.beginShutdown();
    await rejected;
    await council.shutdown();
    held.complete();
    expect(
      runtime.engine.state.instances.where((i) => i.activeRequests != 0),
      isEmpty,
    );
    expect(runtime.io.killedChildren, 0);
  });
  test('application shutdown withdraws an admitted native result before normal output', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    await council.models.save(
      JevModelDefinition.native(
        name: 'native-kev',
        binding: council.models.availableBindings.single,
      ),
    );
    runtime.io.respond = (request, response) async {
      council.beginShutdown();
      return response;
    };
    await expectLater(
      council.models.decide('native-kev', _mixed()),
      throwsA(
        isA<JevRequestException>().having(
          (e) => e.code,
          'code',
          'service_stopping',
        ),
      ),
    );
    expect(runtime.engine.state.instances.single.activeRequests, 0);
    expect(runtime.io.killedChildren, 0);
  });
}

DecisionBatchRequest _mixed({String state = 'mixed'}) => DecisionBatchRequest(
  state: state,
  questions: {
    'route': ChoiceQuestion(
      instructions: 'Choose',
      options: {'z': 'Z', 'a': 'A'},
    ),
    'rank': ScoreQuestion(
      instructions: 'Rank',
      levels: ['Low', 'Medium', 'High'],
    ),
    'valid': NoulQuestion(
      instructions: 'Valid',
      falseText: 'False',
      trueText: 'True',
    ),
  },
);
