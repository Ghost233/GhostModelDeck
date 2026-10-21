import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/jev_debug.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/splash_help.dart';

void main() {
  test('public preparation protects an existing target deletion plan before external preparation finishes', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    final entered = Completer<void>(), release = Completer<void>();
    fixture.io.beforePreparation = (_) async {
      entered.complete();
      await release.future;
    };
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await engine.shutdown();
      await engine.close();
    });
    final plan = await fixture.library.prepareDeletion([fixture.asset.id]);
    final pending = engine
        .prepareModelBinding(
          fixture.asset.id,
          configuration: EngineLaunchConfiguration(
            family: EngineFamily.splash,
            drafter: const DrafterConfiguration(enabled: false),
          ),
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    await entered.future.timeout(const Duration(seconds: 5));
    Object? outcome;
    try {
      await expectLater(
        fixture.library.delete(plan, confirmed: true),
        throwsA(isA<LibraryException>()),
      );
    } finally {
      release.complete();
      outcome = await pending;
    }
    expect(outcome, isA<SplashModelBinding>());
    expect(
      await fixture.library.prepareDeletion([fixture.asset.id]),
      isA<DeletionPlan>(),
    );
    expect(fixture.io.starts, 0);
  });

  for (final ending in ['success', 'failure', 'cancel']) {
    test(
      'preparation holds target and draft shard deletion plans through $ending',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final assets = await _preparationShardAssets(fixture);
        final engine = fixture.engine();
        final entered = Completer<void>(), release = Completer<void>();
        fixture.io.beforePreparation = (_) async {
          entered.complete();
          await release.future;
        };
        fixture.io.preparationFailure = ending == 'failure';
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await engine.shutdown();
          await engine.close();
        });
        final plans = [
          for (final asset in [assets.target, assets.draft])
            await fixture.library.prepareDeletion([asset.id]),
        ];
        final token = DecisionCancellation();
        final pending = engine
            .prepareModelBinding(
              assets.target.id,
              configuration: EngineLaunchConfiguration(
                family: EngineFamily.splash,
                drafter: DrafterConfiguration(
                  enabled: true,
                  path: assets.directory.path,
                ),
              ),
              cancellation: token,
            )
            .then<Object>((value) => value, onError: (Object error) => error);
        await entered.future.timeout(const Duration(seconds: 5));
        Object? outcome;
        try {
          for (final plan in plans) {
            await expectLater(
              fixture.library.delete(plan, confirmed: true),
              throwsA(isA<LibraryException>()),
            );
          }
          if (ending == 'cancel') {
            token.cancel();
            for (final plan in plans) {
              await expectLater(
                fixture.library.delete(plan, confirmed: true),
                throwsA(isA<LibraryException>()),
              );
            }
          }
        } finally {
          release.complete();
          outcome = await pending;
        }
        expect(
          outcome,
          ending == 'success'
              ? isA<SplashModelBinding>()
              : ending == 'failure'
              ? isA<StateError>()
              : isA<SplashEngineException>(),
        );
        for (final asset in [assets.target, assets.draft]) {
          expect(
            asset.files.where((file) => file.path.endsWith('.safetensors')),
            hasLength(2),
          );
          for (final file in asset.files) {
            expect(await File(file.path).exists(), isTrue);
          }
          expect(
            await fixture.library.prepareDeletion([asset.id]),
            isA<DeletionPlan>(),
          );
        }
        expect(fixture.io.starts, 0);
      },
    );
  }

  test(
    'public Splash start hands preparation shard leases to the accepted owner',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final assets = await _preparationShardAssets(fixture);
      final engine = fixture.engine();
      final entered = Completer<void>(), release = Completer<void>();
      fixture.io.beforePreparation = (_) async {
        entered.complete();
        await release.future;
      };
      fixture.io.releaseStart = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        if (!fixture.io.releaseStart!.isCompleted) {
          fixture.io.releaseStart!.complete();
        }
        await engine.shutdown();
        await engine.close();
      });
      final plans = [
        for (final asset in [assets.target, assets.draft])
          await fixture.library.prepareDeletion([asset.id]),
      ];
      final pending = engine.startWithConfiguration(
        assets.target.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          drafter: DrafterConfiguration(
            enabled: true,
            path: assets.directory.path,
          ),
        ),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      for (final plan in plans) {
        await expectLater(
          fixture.library.delete(plan, confirmed: true),
          throwsA(isA<LibraryException>()),
        );
      }
      release.complete();
      await fixture.io.startEntered.future.timeout(const Duration(seconds: 5));
      for (final plan in plans) {
        await expectLater(
          fixture.library.delete(plan, confirmed: true),
          throwsA(isA<LibraryException>()),
        );
      }
      fixture.io.releaseStart!.complete();
      final run = await pending;
      expect(run.status, RuntimeInstanceStatus.ready);
      for (final plan in plans) {
        await expectLater(
          fixture.library.delete(plan, confirmed: true),
          throwsA(isA<LibraryException>()),
        );
      }
      await engine.stop(run.id);
      for (final asset in [assets.target, assets.draft]) {
        expect(
          await fixture.library.prepareDeletion([asset.id]),
          isA<DeletionPlan>(),
        );
      }
    },
  );

  test('concurrent shared preparations preserve the peer lease and drain late work on shutdown', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final assets = await _preparationShardAssets(fixture);
    final engine = fixture.engine();
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final oldPlan = await fixture.library.prepareDeletion([fixture.asset.id]);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final peer = await engine.startRuntime(fixture.asset.id);
    final aEntered = Completer<void>(), aRelease = Completer<void>();
    final bEntered = Completer<void>(), bRelease = Completer<void>();
    var preparations = 0;
    fixture.io.beforePreparation = (request) async {
      preparations++;
      if ((request['drafter'] as Map)['enabled'] == true) {
        aEntered.complete();
        await aRelease.future;
      } else {
        bEntered.complete();
        await bRelease.future;
      }
    };
    final targetPlan = await fixture.library.prepareDeletion([
      assets.target.id,
    ]);
    final draftPlan = await fixture.library.prepareDeletion([assets.draft.id]);
    final on = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      drafter: DrafterConfiguration(enabled: true, path: assets.directory.path),
    );
    final a = engine.prepareModelBinding(assets.target.id, configuration: on);
    final shared = engine.prepareModelBinding(
      assets.target.id,
      configuration: on,
    );
    final b = engine
        .prepareModelBinding(
          assets.target.id,
          configuration: EngineLaunchConfiguration(
            family: EngineFamily.splash,
            drafter: const DrafterConfiguration(enabled: false),
          ),
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    try {
      await Future.wait([aEntered.future, bEntered.future])
          .timeout(const Duration(seconds: 5));
      for (final plan in [targetPlan, draftPlan, oldPlan]) {
        await expectLater(
          fixture.library.delete(plan, confirmed: true),
          throwsA(isA<LibraryException>()),
        );
      }
      aRelease.complete();
      final bindings = await Future.wait([a, shared]);
      expect(bindings[0].sourceHashes, bindings[1].sourceHashes);
      expect(identical(bindings[0], bindings[1]), isFalse);
      expect(
        preparations,
        2,
        reason: 'Equal preparation inputs share native I/O, while different selections remain independent.',
      );
      expect(
        await fixture.library.prepareDeletion([assets.draft.id]),
        isA<DeletionPlan>(),
      );
      for (final plan in [targetPlan, oldPlan]) {
        await expectLater(
          fixture.library.delete(plan, confirmed: true),
          throwsA(isA<LibraryException>()),
        );
      }
      expect(
        engine.runtimeInstances
            .singleWhere((run) => run.id == peer.id)
            .hasLiveProcess,
        isTrue,
      );
      var closed = false;
      final shutdown = engine.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      await expectLater(
        fixture.library.delete(targetPlan, confirmed: true),
        throwsA(isA<LibraryException>()),
      );
      bRelease.complete();
      expect(await b, isA<SplashEngineException>());
      await shutdown;
      expect(engine.hasLiveInstances, isFalse);
      for (final asset in [fixture.asset, assets.target, assets.draft]) {
        expect(
          await fixture.library.prepareDeletion([asset.id]),
          isA<DeletionPlan>(),
        );
      }
    } finally {
      if (!aRelease.isCompleted) aRelease.complete();
      if (!bRelease.isCompleted) bRelease.complete();
      await Future.wait([a, shared, b]);
    }
  });

  test('compact observation keeps its running source and exposes validated full-head fallback', () async {
    final fixture = await SplashRuntimeFixture.create(compactHelp: true);
    addTearDown(fixture.close);
    fixture.io.optionalFeatures = {
      'compact_draft_head': true,
      'compact_validated': true,
      'compact_capacity': 16384,
      'compact_reason': '',
      'compact_request_fallbacks': 0,
    };
    fixture.io.monitorStatus = {'active_requests': 0};
    var configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      drafter: DrafterConfiguration(
        enabled: true,
        path: '${fixture.assembly.path}/draft',
      ),
      formValues: {
        '--compact-draft-head': 'on',
        '--compact-draft-ranking': '/ranking/form.splash',
        '--compact-draft-capacity': '32768',
      },
      argumentText: '--compact-draft-rank="/ranking/first.splash"',
    );
    final engine = fixture.engine(configurationFor: (_) => configuration);
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final first = await engine.startWithConfiguration(
      fixture.asset.id,
      configuration,
      launchInstanceId: 'compact-first',
    );
    expect(
      engine.actualCompactFor('compact-first'),
      contains('/ranking/first.splash'),
    );
    expect(engine.actualCompactFor('compact-first'), contains('16384'));
    configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      drafter: const DrafterConfiguration(enabled: false),
      formValues: {
        '--compact-draft-head': 'on',
        '--compact-draft-ranking': '/ranking/pending.splash',
        '--compact-draft-capacity': '65536',
      },
    );
    fixture.io.optionalFeatures = {'compact_draft_head': false};
    final second = await engine.startWithConfiguration(
      fixture.asset.id,
      configuration,
      launchInstanceId: 'compact-second',
    );
    expect(
      engine
          .actualCommandFor(second.id)!
          .arguments
          .any((argument) => argument.startsWith('--compact-draft-')),
      isFalse,
    );
    fixture.io.optionalFeaturesByPid[engine.pidFor(first.id)!] = {
      'compact_draft_head': true,
      'compact_validated': true,
      'compact_capacity': 16384,
      'compact_reason': 'rare-token ratio exceeds 1 percent',
      'compact_request_fallbacks': 3,
    };
    await engine.readTelemetry(first.id, cancellation: DecisionCancellation());
    final observed = engine.actualCompactFor('compact-first')!;
    expect(observed, contains('已验证'));
    expect(observed, contains('完整 head 回退'));
    expect(observed, contains('rare-token ratio exceeds 1 percent'));
    expect(observed, contains('请求回退次数 3'));
    expect(observed, contains('/ranking/first.splash'));
    expect(observed, isNot(contains('/ranking/pending.splash')));
    fixture.io.optionalFeaturesByPid[engine.pidFor(first.id)!] = {
      'compact_draft_head': true,
      'compact_validated': false,
      'compact_reason': 'validation unavailable',
    };
    await engine.readTelemetry(first.id, cancellation: DecisionCancellation());
    expect(engine.actualCompactFor('compact-first'), contains('原生未验证'));
    expect(
      engine.actualCompactFor('compact-first'),
      isNot(contains('完整 head 回退')),
    );
    fixture.io.optionalFeaturesByPid[engine.pidFor(first.id)!] = {
      'compact_draft_head': true,
      'compact_validated': true,
      'compact_capacity': 16384,
      'compact_reason': 'lookup supplied proposals; draft head skipped',
      'compact_request_fallbacks': 3,
    };
    await engine.readTelemetry(first.id, cancellation: DecisionCancellation());
    expect(engine.actualCompactFor('compact-first'), contains('跳过草稿 head'));
    expect(
      engine.actualCompactFor('compact-first'),
      isNot(contains('完整 head 回退')),
    );
    fixture.io.optionalFeaturesByPid[engine.pidFor(
          first.id,
        )!]!['compact_reason'] =
        '';
    await engine.readTelemetry(first.id, cancellation: DecisionCancellation());
    expect(engine.actualCompactFor('compact-first'), contains('按原生条件使用'));
    expect(
      engine.actualCompactFor('compact-first'),
      isNot(contains('rare-token ratio')),
    );
    expect(engine.actualCompactFor('compact-second'), '关闭');
    expect(
      engine.actualDrafterFor('compact-first')!.stage,
      DrafterStage.running,
    );
    expect(
      engine.runtimeInstances.every(
        (run) => run.status == RuntimeInstanceStatus.ready,
      ),
      isTrue,
    );
    expect(fixture.io.chatModels, isEmpty);
    expect(fixture.io.decisionBodies, isEmpty);
    await engine.stop(first.id);
    expect(engine.actualCompactFor('compact-first'), isNull);
    expect(
      engine.runtimeInstances
          .singleWhere((run) => run.id == second.id)
          .acceptingRequests,
      isTrue,
    );
  });
  test(
    'Splash startup failures redact current and superseded CLI keys from logs',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      fixture.io.launchStderr =
          'native failed shadow-private-key and owned-private-key';
      fixture.io.wrongPid = true;
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      Object? failure;
      try {
        await engine.startWithConfiguration(
          fixture.asset.id,
          EngineLaunchConfiguration(
            family: EngineFamily.splash,
            argumentText:
                '--api-key shadow-private-key --api-key owned-private-key',
          ),
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<SplashEngineException>());
      for (final key in ['shadow-private-key', 'owned-private-key']) {
        expect(failure.toString(), isNot(contains(key)));
        expect(engine.runtimeInstances.single.error, isNot(contains(key)));
      }
      expect(engine.runtimeInstances.single.hasLiveProcess, isFalse);
    },
  );
  test(
    'Splash failures and default decision traces redact the running API key',
    () async {
      final fixture = await SplashRuntimeFixture.create(
        supportsSystemone: true,
      );
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--api-key': 'private-owned-key'},
        ),
      );
      fixture.io.decisionStatus = 403;
      fixture.io.decisionResponse = (_) => {
        'error': 'native rejected private-owned-key',
      };
      final trace = DecisionIOTrace();
      Object? failure;
      try {
        await engine.decideBatch(
          run.id,
          DecisionBatchRequest(
            state: 'private-owned-key',
            questions: {
              'pick': ChoiceQuestion(
                instructions: 'choose',
                options: {'yes': 'Yes', 'no': 'No'},
              ),
            },
          ),
          ioTrace: trace,
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<SplashRequestException>());
      expect(failure.toString(), isNot(contains('private-owned-key')));
      expect(
        (failure as SplashRequestException).rawResponse,
        isNot(contains('private-owned-key')),
      );
      expect(jsonEncode(trace.toJson()), isNot(contains('private-owned-key')));
      final frozen = trace.toJson();
      trace.sent('{"late":"private-owned-key"}');
      trace.received('late response', 200);
      expect(trace.toJson(), frozen);

      expect(engine.runtimeInstances.single.acceptingRequests, isTrue);
    },
  );
  test(
    'Splash typed trace preserves task roles and final credential correlation',
    () async {
      final fixture = await SplashRuntimeFixture.create(
        supportsSystemone: true,
      );
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--api-key': 'typed-owner-key'},
        ),
      );
      final input = DecisionBatchRequest(
        state: {
          'api_key': 'Authorization: allow',
          'echo': 'typed-owner-key response-private-key',
        },
        questions: {
          'api_key': ChoiceQuestion(
            instructions: {'Authorization': 'allow'},
            options: {'cookie': 'Cookie: allow', 'authorization': 'allow'},
          ),
        },
      );
      fixture.io.decisionResponse = (_) => {
        'model': fixture.io.nativeResponseModel,
        'answers': {
          'api_key': {
            'type': 'choice',
            'choice': 'cookie',
            'probabilities': {'cookie': 1.0, 'authorization': 0.0},
            'confidence': 1.0,
          },
        },
        'usage': {'input_tokens': 1, 'output_tokens': 0},
        'diagnostic': {'API_KEY': 'response-private-key'},
        'echo': 'typed-owner-key response-private-key',
      };
      final trace = DecisionIOTrace();
      final result = await engine.decideBatch(run.id, input, ioTrace: trace);
      expect(fixture.io.decisionBodies.single['state'], input.state);
      final response = result.toJson();
      expect((response['answers'] as Map)['api_key']['choice'], 'cookie');
      final debug = sealDebugJson(
        {
          'input': input.toSystemone(model: 'Authorization: allow'),
          'native': {...trace.toJson(), 'result': response},
          'converted_result': response,
        },
        projection: JevDebugProjection.debug,
        ioTraces: [(trace: trace, typedResponse: true)],
      );
      expect((debug['input'] as Map)['model'], 'Authorization: allow');
      expect(
        (debug['input'] as Map)['questions'],
        input.toSystemone()['questions'],
      );
      expect((debug['input'] as Map)['state'], {
        'api_key': 'Authorization: allow',
        'echo': '[redacted] [redacted]',
      });
      expect(debug['converted_result'], response);
      final raw = jsonDecode(
        (debug['native'] as Map)['raw_response'] as String,
      );
      expect(raw['answers'], response['answers']);
      expect(raw['diagnostic'], {'API_KEY': '[redacted]'});
      expect(jsonEncode(debug), isNot(contains('typed-owner-key')));
      expect(jsonEncode(debug), isNot(contains('response-private-key')));
    },
  );
  test('Splash saved keys affect the next owner without changing live authentication', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    var configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--api-key': 'first-owner-key'},
    );
    final engine = fixture.engine(configurationFor: (_) => configuration);
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final first = await engine.startRuntime(fixture.asset.id);
    configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--api-key': 'second-owner-key'},
    );
    expect(
      (await engine.generateText(first.id, TextRequest(prompt: 'OK'))).text,
      'OK',
    );
    final second = await engine.startRuntime(fixture.asset.id);
    expect(
      (await engine.generateText(second.id, TextRequest(prompt: 'OK'))).text,
      'OK',
    );
    final firstEvents = await engine
        .streamText(first.id, TextRequest(prompt: 'OK'))
        .toList();
    expect(
      firstEvents.where((event) => event.result != null).single.result!.text,
      'OK',
    );
    await engine.stop(first.id);
    expect(
      (await engine.generateText(second.id, TextRequest(prompt: 'OK'))).text,
      'OK',
    );
  });
  for (final operation in ['JSON', 'SSE', 'monitor', 'systemone']) {
    test('Splash API key authenticates owned $operation calls', () async {
      final fixture = await SplashRuntimeFixture.create(
        supportsSystemone: true,
      );
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--api-key': 'owned-call-key'},
        ),
      );
      switch (operation) {
        case 'JSON':
          expect(
            (await engine.generateText(run.id, TextRequest(prompt: 'OK'))).text,
            'OK',
          );
        case 'SSE':
          final events = await engine
              .streamText(run.id, TextRequest(prompt: 'OK'))
              .toList();
          expect(
            events.where((e) => e.result != null).single.result!.text,
            'OK',
          );
        case 'monitor':
          fixture.io.monitorStatus = {'active_requests': 0};
          await engine.readTelemetry(
            run.id,
            cancellation: DecisionCancellation(),
          );
          expect(engine.runtimeInstances.single.acceptingRequests, isTrue);
        case 'systemone':
          final result = await engine.decide(
            run.id,
            DecisionRequest(
              state: 'test',
              instructions: 'choose',
              options: {'yes': 'Yes', 'no': 'No'},
            ),
          );
          expect(result.choice, 'yes');
      }
    });
  }
  test(
    'Splash API key permits owned startup and rejects unauthenticated access',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--api-key': 'form-key'},
          argumentText: '--api-key=first-key --api-k text-key',
        ),
      );
      expect(run.status, RuntimeInstanceStatus.ready);
      final endpoint = engine.endpointFor(run.id)!;
      final client = HttpClient();
      try {
        for (final key in [null, 'wrong-key', 'text-key']) {
          final request = await client.getUrl(endpoint.resolve('/status'));
          if (key != null) request.headers.set('Authorization', 'Bearer $key');
          final response = await request.close();
          expect(response.statusCode, key == 'text-key' ? 200 : 401);
          await response.drain<void>();
        }
      } finally {
        client.close(force: true);
      }
    },
  );
  for (final stream in [false, true]) {
    test(
      '${stream ? 'SSE' : 'JSON'} transient Splash unready keeps the same text instance callable',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final engine = fixture.engine();
        addTearDown(() async {
          await engine.shutdown();
          await engine.close();
        });
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        final run = await engine.startRuntime(fixture.asset.id);
        Future<Object> request() async => stream
            ? await engine
                  .streamText(run.id, TextRequest(prompt: 'OK'))
                  .toList()
            : await engine.generateText(run.id, TextRequest(prompt: 'OK'));
        fixture.io.readyStatus = 503;
        await expectLater(
          request(),
          throwsA(
            isA<SplashRequestException>().having(
              (e) => e.kind,
              'kind',
              DecisionFailureKind.notReady,
            ),
          ),
        );
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
        expect(engine.runtimeInstances.single.activeRequests, 0);
        expect(engine.runtimeInstances.single.acceptingRequests, isTrue);
        expect(fixture.io.chatModels, isEmpty);
        fixture.io.readyStatus = 200;
        await request();
        expect(fixture.io.chatModels, hasLength(1));
        expect(fixture.io.starts, 1);
        expect(fixture.io.groupSignals, isEmpty);
      },
    );
  }
  test('Splash starts two instances concurrently and cancels only the selected startup', () async {
    final fixture = await SplashRuntimeFixture.create();
    final engine = fixture.engine();
    fixture.io.expectedStarts = 2;
    fixture.io.startsEntered = Completer<void>();
    fixture.io.releaseStart = Completer<void>();
    Future<Object?>? first;
    Future<RuntimeInstance>? second;
    try {
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final cancel = DecisionCancellation();
      first = engine
          .startWithConfiguration(
            fixture.asset.id,
            EngineLaunchConfiguration(family: EngineFamily.splash),
            cancellation: cancel,
            launchInstanceId: 'first',
          )
          .then<Object?>((value) => value, onError: (Object error) => error);
      second = engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(family: EngineFamily.splash),
        launchInstanceId: 'second',
      );
      await fixture.io.startsEntered!.future.timeout(
        const Duration(seconds: 2),
      );
      expect(
        engine.runtimeInstances.where(
          (run) => run.status == RuntimeInstanceStatus.starting,
        ),
        hasLength(2),
      );
      cancel.cancel();
      fixture.io.releaseStart!.complete();
      expect(await first, isA<SplashEngineException>());
      final ready = await second;
      expect(ready.status, RuntimeInstanceStatus.ready);
      expect(ready.launchInstanceId, 'second');
      expect(ready.hasLiveProcess, isTrue);
      expect(
        fixture.io.children.where((child) => !child.closing),
        hasLength(1),
      );
      await engine.stop(ready.id);
      expect(engine.hasLiveInstances, isFalse);
    } finally {
      if (!fixture.io.releaseStart!.isCompleted) {
        fixture.io.releaseStart!.complete();
      }
      if (first != null) await first;
      if (second != null) {
        await second.then<void>((_) {}, onError: (Object _) {});
      }
      await engine.shutdown();
      await engine.close();
      await fixture.close();
    }
  });
  test('decision GGUF binding uses the same assembly and native validation as chat', () async {
    final fixture = await SplashRuntimeFixture.create(ordinaryChat: false);
    addTearDown(fixture.close);
    expect(fixture.asset.kind, AssetKind.decision);
    final engine = fixture.engine();
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final binding = await engine.bindModel(fixture.asset.id, fixture.assembly);
    expect(
      binding.sourceHashes[fixture.asset.files.single.path],
      fixture.asset.files.single.sha256,
    );
    final run = await engine.startRuntime(fixture.asset.id);
    expect(run.status, RuntimeInstanceStatus.ready);
    expect(
      (await engine.generateText(
        run.id,
        TextRequest(prompt: 'Reply OK.'),
      )).text,
      isNotEmpty,
    );
    await engine.stop(run.id);
    expect(engine.hasLiveInstances, isFalse);
  });
  test(
    'source loss keeps the loaded Splash run callable until explicit stop',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(engine.close);
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      try {
        await fixture.installation.nativeBinary.delete();
        await engine.refreshInstallation();
        expect(engine.state.installation, LlamaInstallationStatus.failed);
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
        expect(
          (await engine.generateText(
            run.id,
            TextRequest(prompt: 'Hello'),
          )).text,
          isNotEmpty,
        );
      } finally {
        await engine.stop(run.id);
      }
      await expectLater(
        engine.startRuntime(fixture.asset.id),
        throwsA(isA<SplashEngineException>()),
      );
    },
  );

  test('normal Splash startup loads and binds identity without any inference request', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    try {
      final run = await engine.startRuntime(fixture.asset.id);
      expect(run.status, RuntimeInstanceStatus.ready);
      expect(run.hasLiveProcess, isTrue);
      expect(run.capabilities, {RuntimeCapability.textGeneration});
      expect(fixture.io.httpPaths, contains('/ready'));
      expect(fixture.io.httpPaths, contains('/status'));
      expect(fixture.io.chatModels, isEmpty);
      expect(fixture.io.sizedPosts, 0);
      await engine.stop(run.id);
      expect(engine.runtimeInstances.single.hasLiveProcess, isFalse);
    } finally {
      await engine.shutdown();
    }
  });
  test('Splash sends sized JSON for explicit text and streaming without startup inference', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.rejectTransferEncoding = true;
    final engine = fixture.engine();
    addTearDown(engine.close);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    try {
      final run = await engine.startRuntime(fixture.asset.id);
      final reply = await engine.generateText(
        run.id,
        TextRequest(prompt: 'Reply OK.'),
        timeout: const Duration(seconds: 2),
      );
      expect(reply.text, 'OK');
      final events = await engine
          .streamText(
            run.id,
            TextRequest(prompt: 'Reply OK.'),
            timeout: const Duration(seconds: 2),
          )
          .toList();
      expect(events.any((event) => event.result != null), isTrue);
      expect(fixture.io.sizedPosts, 2);
    } finally {
      await engine.shutdown();
    }
  });
  test('cold readiness timeout stays within the startup deadline without an automatic text probe', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.identityDelay = const Duration(seconds: 6);
    final engine = fixture.engine();
    addTearDown(engine.close);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    try {
      final run = await engine.startRuntime(fixture.asset.id);
      expect(run.status, RuntimeInstanceStatus.ready);
      expect(fixture.io.starts, 1);
      expect(
        fixture.io.httpPaths.where((path) => path == '/ready').length,
        greaterThan(1),
      );
      expect(fixture.io.httpPaths, isNot(contains('/v1/chat/completions')));
      final reply = await engine.generateText(
        run.id,
        TextRequest(prompt: 'Reply OK.'),
      );
      expect(reply.text, 'OK');
      expect(fixture.io.httpPaths, contains('/v1/chat/completions'));
    } finally {
      await engine.shutdown();
    }
  });
  test('Splash only supplies its private cache directory with an explicit persistent-cache option', () async {
    final fixture = await SplashRuntimeFixture.create(compactHelp: true);
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    for (final text in ['', '--future-option "--persistent-cache"']) {
      final command = engine.composeLaunch(
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          argumentText: text,
        ),
      );
      expect(command.arguments, isNot(contains('--cache-dir')));
    }
    final persistent = engine.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--persistent-cache --cache-dir /external',
      ),
    );
    expect(persistent.arguments, contains('--persistent-cache'));
    expect(
      persistent.arguments,
      containsAllInOrder([
        '--cache-dir',
        '${engine.runtimeDirectory.path}/cache',
      ]),
    );
    expect(persistent.arguments, isNot(contains('/external')));
    final prefixed = engine.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--persistent-c --cache-dir /external',
      ),
    );
    expect(
      prefixed.arguments,
      containsAllInOrder([
        '--cache-dir',
        '${engine.runtimeDirectory.path}/cache',
      ]),
    );
    expect(prefixed.arguments, isNot(contains('/external')));
    expect(prefixed.arguments, contains('--persistent-c'));
    final ambiguous = engine.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--p',
      ),
    );
    expect(ambiguous.arguments, contains('--p'));
    expect(ambiguous.arguments, isNot(contains('--cache-dir')));
    final unread = fixture.engine(
      installation: await SplashEngine.inspectInstallation(
        fixture.source,
        io: fixture.io,
      ),
    );
    addTearDown(unread.close);
    final notObserved = unread.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--persistent-c',
      ),
    );
    expect(notObserved.arguments, contains('--persistent-c'));
    expect(notObserved.arguments, isNot(contains('--cache-dir')));
  });
  test(
    'linked Splash discovers paths without executing help or hashing content',
    () async {
      final root = await Directory.systemTemp.createTemp('splash-observe-');
      addTearDown(() => root.delete(recursive: true));
      for (final path in [
        '.venv/bin/python',
        'build/splash',
        'server/server.py',
        'install/launcher.py',
        'install/gguf.py',
      ]) {
        final file = File('${root.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString('original $path');
      }
      final io = SplashTestProcessIO(root);
      final observed = await SplashEngine.inspectInstallation(root, io: io);
      expect(observed.python.path, '${root.path}/.venv/bin/python');
      expect(io.calls, isEmpty);
      expect(io.starts, 0);
      expect(io.calls.any((args) => args.contains('make')), isFalse);
    },
  );
  test('source registration does not execute Python prefix probes', () async {
    final root = await Directory.systemTemp.createTemp('splash-prefix-');
    addTearDown(() => root.delete(recursive: true));
    for (final path in [
      '.venv/bin/python',
      'build/splash',
      'server/server.py',
      'install/launcher.py',
      'install/gguf.py',
    ]) {
      final file = File('${root.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString('original $path');
    }
    final io = SplashTestProcessIO(root, mutate: false, wrongPrefix: true);
    final observed = await SplashEngine.inspectInstallation(root, io: io);
    expect(observed.python.path, '${root.path}/.venv/bin/python');
    expect(io.calls, isEmpty);
    expect(io.starts, 0);
  });
  test('binding rejects a different canonical target even with complete recorded SHA', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final other = await writeDecisionKev(
      Directory('${fixture.root.path}/other'),
      ordinaryChat: true,
    );
    await fixture.writeAssembly(other);
    var saved = 0;
    final engine = SplashEngine(
      installation: fixture.installation,
      library: fixture.library,
      useRegistry: ModelUseRegistry(fixture.library),
      runtimeDirectory: Directory('${fixture.root.path}/runtime'),
      io: fixture.io,
      configurationFor: (_) =>
          EngineLaunchConfiguration(family: EngineFamily.splash),
      saveBinding: (_) async {
        saved++;
      },
    );
    await expectLater(
      engine.bindModel(fixture.asset.id, fixture.assembly),
      throwsA(isA<SplashEngineException>()),
    );
    expect(saved, 0);
    expect(engine.bindingFor(fixture.asset.id), isNull);
    expect(fixture.io.starts, 0);
  });
  test(
    'binding saves a selected model without a native compatibility probe',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      fixture.io.modelCheckFailure = true;
      var saved = 0;
      final engine = SplashEngine(
        installation: fixture.installation,
        library: fixture.library,
        useRegistry: ModelUseRegistry(fixture.library),
        runtimeDirectory: Directory('${fixture.root.path}/runtime'),
        io: fixture.io,
        configurationFor: (_) =>
            EngineLaunchConfiguration(family: EngineFamily.splash),
        saveBinding: (_) async {
          saved++;
        },
      );
      final binding = await engine.bindModel(
        fixture.asset.id,
        fixture.assembly,
      );
      expect(saved, 1);
      expect(engine.bindingFor(fixture.asset.id), same(binding));
      expect(
        fixture.io.calls.where((args) => args.first == 'model-check'),
        isEmpty,
      );
      await engine.shutdown();
      await engine.close();
      expect(fixture.io.starts, 0);
    },
  );
  test('public start earns text Ready from owned status and native response identity', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = SplashEngine(
      installation: fixture.installation,
      library: fixture.library,
      useRegistry: ModelUseRegistry(fixture.library),
      runtimeDirectory: Directory('${fixture.root.path}/runtime'),
      io: fixture.io,
      configurationFor: (_) =>
          EngineLaunchConfiguration(family: EngineFamily.splash),
      saveBinding: (_) async {},
    );
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final started = await engine.startRuntime(fixture.asset.id);
    expect(started.status, RuntimeInstanceStatus.ready);
    expect(started.capabilities, {RuntimeCapability.textGeneration});
    expect(fixture.io.nativeResponseModel, 'fixture/target:Q8');
    expect(
      engine.actualCommandFor(started.id)!.arguments,
      isNot(contains('--default-reasoning-effort')),
    );
    final result = await engine.generateText(
      started.id,
      TextRequest(prompt: 'Say OK'),
    );
    expect(result.text, 'OK');
    final events = await engine
        .streamText(started.id, TextRequest(prompt: 'Say OK'))
        .toList();
    expect(
      events.where((event) => event.result != null).single.result!.text,
      'OK',
    );
    await engine.stop(started.id);
    expect(
      engine.runtimeInstances.single.status,
      RuntimeInstanceStatus.stopped,
    );
    expect(engine.hasLiveInstances, isFalse);
    expect(await fixture.io.groupAlive(engine.pidFor(started.id)!), isFalse);
  });
  test(
    'request cancellation drains its permit and leaves peer owner callable',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final first = await engine.startRuntime(fixture.asset.id);
      final peer = await engine.startRuntime(fixture.asset.id);
      final cancellation = DecisionCancellation();
      final pending = engine.generateText(
        first.id,
        TextRequest(prompt: 'hold'),
        cancellation: cancellation,
      );
      final failed = expectLater(
        pending,
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.cancelled,
          ),
        ),
      );
      await fixture.io.holdReached.future;
      expect(engine.runtimeInstances.first.activeRequests, 1);
      cancellation.cancel();
      await failed;
      expect(engine.runtimeInstances.first.activeRequests, 0);
      expect(
        (await engine.generateText(peer.id, TextRequest(prompt: 'OK'))).text,
        'OK',
      );
      await engine.stopManaged();
      expect(engine.hasLiveInstances, isFalse);
      final next = await engine.startRuntime(fixture.asset.id);
      expect(next.generation, greaterThan(peer.generation));
      await engine.shutdown();
      await engine.shutdown();
      await expectLater(
        engine.startRuntime(fixture.asset.id),
        throwsA(isA<SplashEngineException>()),
      );
      expect(engine.hasLiveInstances, isFalse);
      await engine.close();
    },
  );
  test(
    'stop drains a paused SSE consumer without a fabricated completion',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      final delta = Completer<void>();
      final results = <TextResult>[];
      late StreamSubscription<TextStreamEvent> subscription;
      subscription = engine
          .streamText(run.id, TextRequest(prompt: 'streamhold'))
          .listen((event) {
            if (event.result != null) results.add(event.result!);
            if (!delta.isCompleted) {
              subscription.pause();
              delta.complete();
            }
          }, onError: (Object _) {});
      try {
        await delta.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('SSE first delta not delivered'),
        );
        await engine
            .stop(run.id)
            .timeout(
              const Duration(seconds: 1),
              onTimeout: () =>
                  throw StateError('owned stop did not drain SSE permit'),
            );
        expect(engine.runtimeInstances.single.activeRequests, 0);
        expect(engine.hasLiveInstances, isFalse);
        expect(results, isEmpty);
      } finally {
        if (!fixture.io.releaseHeld.isCompleted) {
          fixture.io.releaseHeld.complete();
        }
        await subscription.cancel();
        await engine.shutdown();
        await engine.close();
      }
    },
  );
  test(
    'restored installation checks required paths without rehashing content',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final recorded = SplashInstallation.fromJson(
        fixture.installation.toJson(),
      );
      final engine = fixture.engine(installation: recorded);
      expect(
        engine.state.installation,
        isNot(LlamaInstallationStatus.installed),
      );
      await engine.refreshInstallation();
      expect(engine.state.installation, LlamaInstallationStatus.installed);
      await File('${fixture.source.path}/build/splash')
          .writeAsString('updated binary');
      await engine.refreshInstallation();
      expect(engine.state.installation, LlamaInstallationStatus.installed);
      expect(engine.installation.fingerprints, recorded.fingerprints);
      await fixture.installation.nativeBinary.delete();
      await engine.refreshInstallation();
      expect(engine.state.installation, LlamaInstallationStatus.failed);
      await expectLater(
        engine.previewLaunch(fixture.asset.id),
        throwsA(isA<SplashEngineException>()),
      );
      expect(fixture.io.starts, 0);
      await engine.close();
    },
  );
  test('actual help failure retains linked identity and built-in raw launch support', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    fixture.io.helpFailure = true;
    final installation = await SplashEngine.inspectInstallation(
      fixture.source,
      io: fixture.io,
      readParameters: true,
    );
    final engine = fixture.engine(installation: installation);
    final command = engine.composeLaunch(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        argumentText: '--future-option value --host external --max-context 1K',
      ),
    );
    expect(command.arguments, contains('--future-option'));
    expect(command.arguments, isNot(contains('external')));
    expect(installation.recognition.notices, isNotEmpty);
    expect(installation.toJson(), contains('help_error'));
    await engine.close();
  });
  test(
    'a restored binding rechecks the canonical assembly target before spawning',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      final binding = await engine.bindModel(
        fixture.asset.id,
        fixture.assembly,
      );
      final restored = SplashModelBinding.fromJson(binding.toJson());
      final other = await writeDecisionKev(
        Directory('${fixture.root.path}/other'),
        ordinaryChat: true,
      );
      await Link('${fixture.assembly.path}/target/model.gguf').delete();
      await Link('${fixture.assembly.path}/target/model.gguf')
          .create(other.path);
      final owner = SplashEngine(
        installation: fixture.installation,
        library: fixture.library,
        useRegistry: ModelUseRegistry(fixture.library),
        runtimeDirectory: Directory('${fixture.root.path}/restored-runtime'),
        io: fixture.io,
        configurationFor: (_) =>
            EngineLaunchConfiguration(family: EngineFamily.splash),
        saveBinding: (_) async {},
        bindings: [restored],
      );
      try {
        await expectLater(
          owner.startRuntime(fixture.asset.id),
          throwsA(isA<SplashEngineException>()),
        );
        expect(fixture.io.starts, 0);
      } finally {
        await owner.shutdown();
        await owner.close();
        await engine.close();
      }
    },
  );
  test('detach drains accepted starts and refuses live removal without implicit stop', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    fixture.io.releaseStart = Completer<void>();
    final accepted = engine.startRuntime(fixture.asset.id);
    await fixture.io.startEntered.future;
    final release = engine.holdStartAdmission();
    var removed = 0;
    final detaching = expectLater(
      engine.detachLinked(
        persistRemoval: () async {
          removed++;
        },
      ),
      throwsA(isA<SplashEngineException>()),
    );
    await expectLater(
      engine.startRuntime(fixture.asset.id),
      throwsA(isA<SplashEngineException>()),
    );
    fixture.io.releaseStart!.complete();
    final run = await accepted;
    await detaching;
    expect(removed, 0);
    expect(engine.runtimeInstances.single.status, RuntimeInstanceStatus.ready);
    await engine.stop(run.id);
    await engine.detachLinked(
      persistRemoval: () async {
        removed++;
      },
    );
    expect(removed, 1);
    release();
    await expectLater(
      engine.startRuntime(fixture.asset.id),
      throwsA(isA<SplashEngineException>()),
    );
    await engine.shutdown();
    await engine.close();
  });
  test('accepted spawn protects all model files and shutdown cleans the late child', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final deletion = await fixture.library.prepareDeletion([fixture.asset.id]);
    fixture.io.releaseStart = Completer<void>();
    final pending = engine.startRuntime(fixture.asset.id);
    final rejected = expectLater(
      pending,
      throwsA(isA<SplashEngineException>()),
    );
    await fixture.io.startEntered.future;
    try {
      await expectLater(
        fixture.library.delete(deletion, confirmed: true),
        throwsA(isA<LibraryException>()),
      );
    } finally {
      engine.beginShutdown();
      fixture.io.releaseStart!.complete();
      await rejected;
      await engine.shutdown();
      await engine.close();
    }
    expect(fixture.io.starts, 1);
    expect(engine.hasLiveInstances, isFalse);
    expect(await File(fixture.asset.files.single.path).exists(), isTrue);
    expect(
      await fixture.library.prepareDeletion([fixture.asset.id]),
      isA<DeletionPlan>(),
    );
  });
  test('source replacement retains loaded Splash runs and refreshes only future launches', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final first = await engine.startRuntime(fixture.asset.id);
    await engine.startRuntime(fixture.asset.id);
    await File('${fixture.source.path}/build/splash')
        .writeAsString('replacement');
    final oldVersion = engine.actualVersionFor(first.id);
    await engine.refreshInstallation();
    expect(engine.state.installation, LlamaInstallationStatus.installed);
    expect(
      (await engine.generateText(first.id, TextRequest(prompt: 'OK'))).text,
      isNotEmpty,
    );
    expect(
      engine.runtimeInstances.every(
        (run) =>
            run.status == RuntimeInstanceStatus.ready && run.hasLiveProcess,
      ),
      isTrue,
    );
    expect(engine.actualVersionFor(first.id), oldVersion);
    expect(engine.installation.fingerprints, fixture.installation.fingerprints);
    expect(fixture.io.starts, 2);
    await engine.shutdown();
    await engine.close();
  });
  test(
    'timeout and truncated SSE are failures, never terminal text successes',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      await expectLater(
        engine.generateText(
          run.id,
          TextRequest(prompt: 'hold'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.timedOut,
          ),
        ),
      );
      fixture.io.omitDone = true;
      final terminal = <TextResult>[];
      await expectLater(
        engine.streamText(run.id, TextRequest(prompt: 'OK')).forEach((event) {
          if (event.result != null) terminal.add(event.result!);
        }),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.invalidResponse,
          ),
        ),
      );
      expect(terminal, isEmpty);
      expect(engine.runtimeInstances.single.activeRequests, 0);
      expect(fixture.io.starts, 1);
      await engine.shutdown();
      await engine.close();
    },
  );
  for (final wrongPid in [true, false]) {
    test(
      wrongPid
          ? 'startup refuses unowned PID as Ready'
          : 'explicit generation refuses reasoning-only empty content',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        fixture.io.wrongPid = wrongPid;
        fixture.io.emptyText = !wrongPid;
        final engine = fixture.engine();
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        if (wrongPid) {
          await expectLater(
            engine.startRuntime(fixture.asset.id),
            throwsA(isA<SplashEngineException>()),
          );
        } else {
          final run = await engine.startRuntime(fixture.asset.id);
          expect(fixture.io.chatModels, isEmpty);
          expect(run.status, RuntimeInstanceStatus.ready);
          await expectLater(
            engine.generateText(run.id, TextRequest(prompt: 'Reply OK.')),
            throwsA(
              isA<SplashRequestException>().having(
                (error) => error.kind,
                'kind',
                DecisionFailureKind.invalidResponse,
              ),
            ),
          );
          await engine.stop(run.id);
        }
        expect(engine.runtimeInstances.single.capabilities, isEmpty);
        expect(engine.hasLiveInstances, isFalse);
        expect(fixture.io.starts, 1);
        await engine.shutdown();
        await engine.close();
      },
    );
  }
  test('configuration saves affect next start while captured live command and PID remain fixed', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    var configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--max-context': '1K'},
    );
    final engine = fixture.engine(configurationFor: (_) => configuration);
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final first = await engine.startRuntime(fixture.asset.id);
    final command = engine.actualCommandFor(first.id)!;
    final pid = engine.pidFor(first.id);
    configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {'--max-context': '2K'},
    );
    expect(
      (await engine.previewLaunch(fixture.asset.id)).arguments,
      contains('2K'),
    );
    expect(engine.actualCommandFor(first.id), same(command));
    expect(engine.pidFor(first.id), pid);
    expect(command.arguments, contains('1K'));
    final next = await engine.startRuntime(fixture.asset.id);
    expect(engine.actualCommandFor(next.id)!.arguments, contains('2K'));
    expect(fixture.io.starts, 2);
    await engine.shutdown();
    await engine.close();
  });
  test('unknown group cleanup remains failed and in use until confirmed explicit recovery', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final engine = fixture.engine();
    await engine.bindModel(fixture.asset.id, fixture.assembly);
    final run = await engine.startRuntime(fixture.asset.id);
    fixture.io.unknownGroup = true;
    await expectLater(
      engine.stop(run.id),
      throwsA(isA<SplashEngineException>()),
    );
    expect(engine.runtimeInstances.single.status, RuntimeInstanceStatus.failed);
    expect(engine.hasLiveInstances, isTrue);
    await expectLater(
      fixture.library.prepareDeletion([fixture.asset.id]),
      throwsA(isA<LibraryException>()),
    );
    fixture.io.unknownGroup = false;
    await engine.stop(run.id);
    expect(engine.hasLiveInstances, isFalse);
    await engine.shutdown();
    await engine.close();
  });
  test(
    'unexpected Python exit reclaims only its remaining owned child group',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      final cleaned = engine.changes.firstWhere(
        (state) =>
            state.instances.single.status == RuntimeInstanceStatus.failed &&
            !state.instances.single.hasLiveProcess,
      );
      fixture.io.children.single.crash();
      try {
        await cleaned.timeout(const Duration(seconds: 1));
        expect(fixture.io.groupSignals, contains(engine.pidFor(run.id)));
        expect(engine.runtimeInstances.single.error, contains('70'));
      } catch (error, stack) {
        try {
          await engine.shutdown();
        } catch (cleanup) {
          stderr.writeln('Secondary owned cleanup failure: $cleanup');
        }
        await engine.close();
        Error.throwWithStackTrace(error, stack);
      }
      await engine.shutdown();
      await engine.close();
    },
  );
  test('installation JSON cannot redirect bootstrap outside the recorded linked source', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final row = fixture.installation.toJson();
    expect(
      () => SplashInstallation.fromJson({
        ...row,
        'module_root': '${fixture.root.path}/other',
      }),
      throwsFormatException,
    );
    final restored = SplashInstallation.fromJson({
      ...row,
      'fingerprints': <String, Object?>{},
    });
    expect(restored.python.path, fixture.installation.python.path);
    expect(
      () => SplashInstallation.fromJson({...row, 'python': '/outside/python'}),
      throwsFormatException,
    );
    expect(
      () => SplashInstallation.fromJson({
        ...row,
        'native_binary': '/outside/engine',
      }),
      throwsFormatException,
    );
    expect(fixture.io.starts, 0);
  });
  test('binding canonicalizes logical snapshot identity and rejects its redirected source', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final role = File('${fixture.assembly.path}/draft/config.json');
    final bytes = await role.readAsBytes();
    final blob = File('${fixture.root.path}/hf/blobs/config');
    await blob.parent.create(recursive: true);
    await blob.writeAsBytes(bytes);
    final snapshot = Link('${fixture.root.path}/hf/snapshots/rev/config.json');
    await snapshot.parent.create(recursive: true);
    await snapshot.create(blob.path);
    await role.delete();
    await Link(role.path).create(blob.path);
    final manifest = File('${fixture.assembly.path}/model.json');
    final row = jsonDecode(await manifest.readAsString()) as Map;
    (row['files'] as Map)['draft/config.json']['path'] = snapshot.path;
    await manifest.writeAsString(jsonEncode(row));
    var saved = 0;
    final engine = fixture.engine(
      saveBinding: (_) async {
        saved++;
      },
    );
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final binding = await engine.bindModel(fixture.asset.id, fixture.assembly);
    expect(
      binding.roles['draft/config.json'],
      await blob.resolveSymbolicLinks(),
    );
    expect(binding.sourceHashes[blob.path], sha256.convert(bytes).toString());
    expect(
      await FileSystemEntity.type(snapshot.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await blob.readAsBytes(), bytes);
    expect(saved, 1);
    final redirected = File('${fixture.root.path}/hf/blobs/other');
    await redirected.writeAsBytes(bytes);
    await snapshot.delete();
    await snapshot.create(redirected.path);
    await expectLater(
      engine.bindModel(fixture.asset.id, fixture.assembly),
      throwsA(isA<SplashEngineException>()),
    );
    expect(saved, 1);
    expect(engine.bindingFor(fixture.asset.id), same(binding));
    expect(fixture.io.starts, 0);
  });
  test('binding records author blob declarations without reading whole model files', () async {
    final fixture = await SplashRuntimeFixture.create();
    addTearDown(fixture.close);
    final role = File('${fixture.assembly.path}/draft/config.json');
    await role.writeAsString('{"name":"草稿配置"}');
    final bytes = await role.readAsBytes();
    final blobHash = sha1.convert([
      ...utf8.encode('blob ${bytes.length} '),
      ...bytes,
    ]).toString();
    final manifest = File('${fixture.assembly.path}/model.json');
    final row = jsonDecode(await manifest.readAsString()) as Map;
    final entry = (row['files'] as Map)['draft/config.json'] as Map;
    entry['bytes'] = bytes.length;
    entry['digest'] = blobHash;
    await manifest.writeAsString(jsonEncode(row));
    var saved = 0;
    final engine = fixture.engine(
      saveBinding: (_) async {
        saved++;
      },
    );
    addTearDown(() async {
      await engine.shutdown();
      await engine.close();
    });
    final binding = await engine.bindModel(fixture.asset.id, fixture.assembly);
    expect(binding.sourceHashes[await role.resolveSymbolicLinks()], blobHash);
    expect(
      binding.sourceHashes.values.every(
        (value) => RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(value),
      ),
      isTrue,
    );
    expect(
      binding.sourceHashes[fixture.asset.files.single.path],
      fixture.asset.files.single.sha256,
    );
    expect(saved, 1);
    for (final wrong in [
      sha1.convert(bytes).toString(),
      List.filled(40, '0').join(),
      List.filled(64, '0').join(),
      'unsupported',
    ]) {
      entry['digest'] = wrong;
      await manifest.writeAsString(jsonEncode(row));
      if (wrong == 'unsupported') {
        await expectLater(
          engine.bindModel(fixture.asset.id, fixture.assembly),
          throwsA(isA<SplashEngineException>()),
        );
      } else {
        final changed = await engine.bindModel(
          fixture.asset.id,
          fixture.assembly,
        );
        expect(changed.sourceHashes[await role.resolveSymbolicLinks()], wrong);
      }
    }
    expect(saved, 4);

    expect(fixture.io.starts, 0);
  });
  for (final failSave in [false, true]) {
    test(
      'binding persistence protects file use and releases after ${failSave ? 'failure' : 'success'}',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final entered = Completer<void>();
        final release = Completer<void>();
        var saved = 0;
        final engine = fixture.engine(
          saveBinding: (_) async {
            entered.complete();
            await release.future;
            if (failSave) {
              throw const FileSystemException('binding write failed');
            }
            saved++;
          },
        );
        addTearDown(() async {
          await engine.shutdown();
          await engine.close();
        });
        final plan = await fixture.library.prepareDeletion([fixture.asset.id]);
        final pending = engine.bindModel(fixture.asset.id, fixture.assembly);
        final completed = failSave
            ? expectLater(pending, throwsA(isA<FileSystemException>()))
            : pending.then<void>((_) {});
        await entered.future;
        try {
          await expectLater(
            fixture.library.delete(plan, confirmed: true),
            throwsA(isA<LibraryException>()),
          );
        } finally {
          release.complete();
          await completed;
        }
        expect(await File(fixture.asset.files.single.path).exists(), isTrue);
        expect(saved, failSave ? 0 : 1);
        expect(
          await fixture.library.prepareDeletion([fixture.asset.id]),
          isA<DeletionPlan>(),
        );
        expect(fixture.io.starts, 0);
      },
    );
  }
  for (final mutateManifest in [false, true]) {
    test(
      'binding persistence captures selected ${mutateManifest ? 'manifest' : 'source paths'} while file content is left to loading',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final entered = Completer<void>();
        final release = Completer<void>();
        var saved = 0;
        final engine = fixture.engine(
          saveBinding: (_) async {
            saved++;
            if (saved == 2) {
              entered.complete();
              await release.future;
            }
          },
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await engine.shutdown();
          await engine.close();
        });
        final old = await engine.bindModel(fixture.asset.id, fixture.assembly);
        final pending = engine.bindModel(fixture.asset.id, fixture.assembly);
        await entered.future;
        if (mutateManifest) {
          final file = File('${fixture.assembly.path}/model.json');
          final row = jsonDecode(await file.readAsString()) as Map;
          row['model'] = 'changed/model';
          await file.writeAsString(jsonEncode(row));
        } else {
          await File('${fixture.assembly.path}/draft/config.json')
              .writeAsString('{"fixture":"changed after save began"}');
        }
        release.complete();
        final captured = await pending;
        expect(captured.nativeModel, old.nativeModel);
        expect(captured.roles, old.roles);
        expect(saved, 2);
        expect(engine.bindingFor(fixture.asset.id), same(captured));
        expect(
          await fixture.library.prepareDeletion([fixture.asset.id]),
          isA<DeletionPlan>(),
        );
        expect(fixture.io.starts, 0);
        if (mutateManifest) {
          await expectLater(
            engine.startRuntime(fixture.asset.id),
            throwsA(isA<SplashEngineException>()),
          );
        } else {
          expect(
            (await engine.startRuntime(fixture.asset.id)).status,
            RuntimeInstanceStatus.ready,
          );
        }
      },
    );
  }
  test(
    'JSON request deadline starts before delayed identity and preserves Ready',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      fixture.io.identityDelay = const Duration(milliseconds: 200);
      await expectLater(
        engine.generateText(
          run.id,
          TextRequest(prompt: 'OK'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.timedOut,
          ),
        ),
      );
      expect(engine.runtimeInstances.single.activeRequests, 0);
      expect(
        engine.runtimeInstances.single.status,
        RuntimeInstanceStatus.ready,
      );
      fixture.io.identityDelay = Duration.zero;
      expect(
        (await engine.generateText(run.id, TextRequest(prompt: 'OK'))).text,
        'OK',
      );
      expect(fixture.io.starts, 1);
    },
  );
  test(
    'SSE deadline closes pending identity and drains without a terminal result',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(() async {
        await engine.shutdown();
        await engine.close();
      });
      await engine.bindModel(fixture.asset.id, fixture.assembly);
      final run = await engine.startRuntime(fixture.asset.id);
      fixture.io.identityEntered = Completer<void>();
      fixture.io.identityClosed = Completer<void>();
      final gate = Completer<void>();
      fixture.io.identityRelease = gate;
      final results = <TextResult>[];
      final pending = engine
          .streamText(
            run.id,
            TextRequest(prompt: 'OK'),
            timeout: const Duration(milliseconds: 50),
          )
          .forEach((event) {
            if (event.result != null) results.add(event.result!);
          });
      final failed = expectLater(
        pending,
        throwsA(
          isA<SplashRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.timedOut,
          ),
        ),
      );
      try {
        await fixture.io.identityEntered!.future;
        await failed.timeout(
          const Duration(milliseconds: 150),
          onTimeout: () =>
              throw StateError('identity deadline did not drain SSE'),
        );
        await fixture.io.identityClosed!.future.timeout(
          const Duration(milliseconds: 150),
        );
        expect(engine.runtimeInstances.single.activeRequests, 0);
        expect(
          engine.runtimeInstances.single.status,
          RuntimeInstanceStatus.ready,
        );
        expect(results, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        fixture.io.identityRelease = null;
        await failed;
      }
    },
  );
  for (final stream in [false, true]) {
    test(
      '${stream ? 'SSE' : 'JSON'} cancellation closes only pending identity and preserves peer Ready',
      () async {
        final fixture = await SplashRuntimeFixture.create();
        addTearDown(fixture.close);
        final engine = fixture.engine();
        addTearDown(() async {
          await engine.shutdown();
          await engine.close();
        });
        await engine.bindModel(fixture.asset.id, fixture.assembly);
        final first = await engine.startWithConfiguration(
          fixture.asset.id,
          EngineLaunchConfiguration(
            family: EngineFamily.splash,
            formValues: {'--api-key': 'cancelled-owner-key'},
          ),
        );
        final peer = await engine.startWithConfiguration(
          fixture.asset.id,
          EngineLaunchConfiguration(
            family: EngineFamily.splash,
            formValues: {'--api-key': 'peer-owner-key'},
          ),
        );
        fixture.io.identityEntered = Completer<void>();
        fixture.io.identityClosed = Completer<void>();
        final gate = Completer<void>();
        fixture.io.identityRelease = gate;
        final cancellation = DecisionCancellation();
        final Future<Object?> pending = stream
            ? engine
                  .streamText(
                    first.id,
                    TextRequest(prompt: 'OK'),
                    cancellation: cancellation,
                  )
                  .toList()
            : engine.generateText(
                first.id,
                TextRequest(prompt: 'OK'),
                cancellation: cancellation,
              );
        final failed = expectLater(
          pending,
          throwsA(
            isA<SplashRequestException>().having(
              (e) => e.kind,
              'kind',
              DecisionFailureKind.cancelled,
            ),
          ),
        );
        try {
          await fixture.io.identityEntered!.future;
          cancellation.cancel();
          await failed.timeout(
            const Duration(milliseconds: 150),
            onTimeout: () =>
                throw StateError('identity cancellation did not drain request'),
          );
          await fixture.io.identityClosed!.future.timeout(
            const Duration(milliseconds: 150),
          );
          expect(
            engine.runtimeInstances.every(
              (run) =>
                  run.status == RuntimeInstanceStatus.ready &&
                  run.activeRequests == 0,
            ),
            isTrue,
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          fixture.io.identityRelease = null;
          await failed;
        }
        expect(
          (await engine.generateText(peer.id, TextRequest(prompt: 'OK'))).text,
          'OK',
        );
        expect(
          (await engine.generateText(first.id, TextRequest(prompt: 'OK'))).text,
          'OK',
        );
        expect(fixture.io.starts, 2);
      },
    );
  }
}

Future<({LibraryArtifact target, LibraryArtifact draft, Directory directory})>
_preparationShardAssets(SplashRuntimeFixture fixture) async {
  for (final name in ['lease-target', 'lease-draft']) {
    final directory = Directory('${fixture.root.path}/models/$name');
    await directory.create(recursive: true);
    await File('${directory.path}/config.json').writeAsString(
      jsonEncode({
        'model_type': 'qwen3_5',
        'architectures': ['Qwen3_5ForConditionalGeneration'],
      }),
    );
    final weights = <String, String>{};
    for (var i = 1; i <= 2; i++) {
      final file = 'model-0000$i-of-00002.safetensors';
      final tensor = 'weight_$i';
      weights[tensor] = file;
      final header = utf8.encode(
        jsonEncode({
          tensor: {
            'dtype': 'BF16',
            'shape': [1],
            'data_offsets': [0, 2],
          },
        }),
      );
      final size = ByteData(8)..setUint64(0, header.length, Endian.little);
      await File('${directory.path}/$file')
          .writeAsBytes([...size.buffer.asUint8List(), ...header, 0, 0]);
    }
    await File('${directory.path}/model.safetensors.index.json').writeAsString(
      jsonEncode({
        'metadata': {'total_size': 4},
        'weight_map': weights,
      }),
    );
  }
  final scanned = await fixture.library.scan(
    Directory('${fixture.root.path}/models'),
    verifyFiles: true,
  );
  return (
    target: scanned.singleWhere(
      (asset) =>
          asset.files.any((file) => file.path.contains('/lease-target/')),
    ),
    draft: scanned.singleWhere(
      (asset) => asset.files.any((file) => file.path.contains('/lease-draft/')),
    ),
    directory: Directory('${fixture.root.path}/models/lease-draft'),
  );
}

class SplashRuntimeFixture {
  SplashRuntimeFixture(
    this.root,
    this.source,
    this.library,
    this.asset,
    this.assembly,
    this.installation,
    this.io,
  );
  final Directory root;
  final Directory source;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final Directory assembly;
  final SplashInstallation installation;
  final SplashTestProcessIO io;

  static Future<SplashRuntimeFixture> create({
    bool ordinaryChat = true,
    bool supportsSystemone = false,
    bool compactHelp = false,
    String? helpOutput,
  }) async {
    final root = await Directory.systemTemp.createTemp('splash-runtime-');
    final source = Directory('${root.path}/source');
    for (final path in [
      '.venv/bin/python',
      'build/splash',
      'server/server.py',
      'install/launcher.py',
      'install/gguf.py',
    ]) {
      final file = File('${source.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString('original $path');
    }
    final io = SplashTestProcessIO(source, mutate: false);
    if (compactHelp) io.helpOutput = splashCurrentHelp;
    if (helpOutput != null) io.helpOutput = helpOutput;
    if (supportsSystemone) {
      await File('${source.path}/server/server.py').writeAsString(
        '"/v1/systemone": PostRoute("_post_systemone", SYSTEMONE_ERRORS)',
      );
    }
    final installation = await SplashEngine.inspectInstallation(
      source,
      io: io,
      readParameters: true,
    );
    final library = ModelLibrary();
    final model = await writeDecisionKev(
      Directory('${root.path}/models'),
      ordinaryChat: ordinaryChat,
    );
    final asset = (await library.scan(model.parent, verifyFiles: true)).single;
    final result = SplashRuntimeFixture(
      root,
      source,
      library,
      asset,
      Directory('${root.path}/assembly'),
      installation,
      io,
    );
    await result.writeAssembly(model);
    return result;
  }

  SplashEngine engine({
    SplashInstallation? installation,
    EngineLaunchConfiguration Function(String)? configurationFor,
    Future<void> Function(SplashModelBinding)? saveBinding,
  }) => SplashEngine(
    installation: installation ?? this.installation,
    library: library,
    useRegistry: ModelUseRegistry(library),
    runtimeDirectory: Directory('${root.path}/runtime'),
    io: io,
    configurationFor:
        configurationFor ??
        (_) => EngineLaunchConfiguration(family: EngineFamily.splash),
    saveBinding: saveBinding ?? (_) async {},
  );

  Future<void> writeAssembly(File target) async {
    if (await assembly.exists()) await assembly.delete(recursive: true);
    await assembly.create(recursive: true);
    final paths = <String, File>{};
    for (final role in [
      'config.json',
      'draft/config.json',
      'draft/model.safetensors',
      'tokenizer/tokenizer.json',
      'tokenizer/tokenizer_config.json',
    ]) {
      final file = File('${assembly.path}/$role');
      await file.parent.create(recursive: true);
      await file.writeAsString('{"fixture":"$role"}');
      paths[role] = file;
    }
    await Directory('${assembly.path}/target').create();
    await Link('${assembly.path}/target/model.gguf').create(target.path);
    paths['target/model.gguf'] = target;
    final records = <String, Object?>{};
    for (final entry in paths.entries) {
      records[entry.key] = {
        'path': await entry.value.resolveSymbolicLinks(),
        'bytes': await entry.value.length(),
        'digest': (await sha256.bind(entry.value.openRead()).first).toString(),
      };
    }
    await File('${assembly.path}/model.json').writeAsString(
      jsonEncode({
        'version': 1,
        'model': 'fixture/target:Q8',
        'family': 'Qwen3.8-27B',
        'target_format': 'gguf',
        'vision_format': 'none',
        'files': records,
      }),
    );
  }

  Future<void> close() async {
    await io.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class SplashTestProcessIO implements SplashProcessIO {
  SplashTestProcessIO(
    this.root, {
    this.mutate = true,
    this.wrongPrefix = false,
  });
  final Directory root;
  final bool mutate;
  final bool wrongPrefix;
  final calls = <List<String>>[];
  final httpPaths = <String>[];
  final chatModels = <String>[];
  final chatBodies = <Map>[];
  final rawChatBodies = <String>[];
  final decisionBodies = <Map>[];
  Completer<void>? decisionEntered;
  Completer<void>? decisionRelease;
  int decisionStatus = 200;
  String? launchStderr;
  Map<String, Object?> Function(Map body)? decisionResponse;
  Map<String, Object?>? monitorStatus;
  Map<String, Object?>? optionalFeatures;
  Map<String, Object?>? startupFeatures;
  final startupFeaturesByPid = <int, Map<String, Object?>>{};
  int? launchExitCode;
  final optionalFeaturesByPid = <int, Map<String, Object?>>{};
  void Function()? afterDecision;
  bool rejectTransferEncoding = false;
  int sizedPosts = 0;
  int starts = 0;
  final launchArguments = <List<String>>[];
  int? expectedStarts;
  Completer<void>? startsEntered;
  Duration identityDelay = Duration.zero;
  Completer<void>? identityEntered;
  Completer<void>? identityClosed;
  Completer<void>? identityRelease;
  final detachedIdentitySockets = <Socket>{};
  String? nativeDrafter;
  bool modelCheckFailure = false;
  bool helpFailure = false;
  String helpOutput = '--max-context TOKENS  Maximum context';
  bool omitDone = false;
  bool wrongPid = false;
  int readyStatus = 200;
  bool statusReady = true;
  bool holdChatResponses = false;
  String? statusModel;
  String? statusServerId;
  int transportRestarts = 0;
  bool emptyText = false;
  bool unknownGroup = false;
  final groupSignals = <int>[];
  Completer<void>? modelCheckEntered;
  Completer<void>? releaseCheck;
  Future<void> Function(Map<String, dynamic>)? beforePreparation;
  bool preparationFailure = false;
  final children = <SplashTestChild>[];
  String? nativeResponseModel;
  final startEntered = Completer<void>();
  Completer<void>? releaseStart;
  final holdReached = Completer<void>();
  final releaseHeld = Completer<void>();
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    calls.add(arguments);
    if (arguments.any(
      (value) => value.contains('# Ghost Model Deck Splash preparation'),
    )) {
      final request = jsonDecode(arguments.last) as Map;
      await beforePreparation?.call(Map<String, dynamic>.from(request));
      if (preparationFailure) {
        return const EngineCommandResult(70, '', 'native preparation failed');
      }
      final source = Directory('${root.parent.path}/assembly');
      final selection = request['drafter'] as Map?;
      final selectedDirectory = selection?['path'] as String?;
      final selectionKey = sha256
          .convert(utf8.encode(jsonEncode(selection)))
          .toString();
      final directory = Directory(
        '${request['root']}/fixture-prepared-$selectionKey',
      );
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        final record = jsonDecode(
          await File('${source.path}/model.json').readAsString(),
        ) as Map;
        (record['files'] as Map).removeWhere(
          (key, _) => (key as String).startsWith('target/'),
        );
        for (final path in (request['files'] as List).cast<String>()) {
          final file = File(path);
          (record['files'] as Map)['target/${file.uri.pathSegments.last}'] = {
            'path': await file.resolveSymbolicLinks(),
            'bytes': await file.length(),
            'digest': (await sha256.bind(file.openRead()).first).toString(),
          };
        }
        if (selection?['enabled'] != true) {
          (record['files'] as Map).removeWhere(
            (key, _) => (key as String).startsWith('draft/'),
          );
        } else if (selectedDirectory != null) {
          final selected = Directory(selectedDirectory);
          final config = File('${selected.path}/config.json');
          final index = File('${selected.path}/model.safetensors.index.json');
          final shards = await index.exists()
              ? ((jsonDecode(await index.readAsString()) as Map)['weight_map']
                        as Map)
                    .values
                    .cast<String>()
                    .toSet()
              : {'model.safetensors'};
          for (final entry in {
            'draft/config.json': config,
            if (await index.exists())
              'draft/model.safetensors.index.json': index,
            for (final shard in shards)
              'draft/$shard': File('${selected.path}/$shard'),
          }.entries) {
            if (!await entry.value.exists()) {
              return EngineCommandResult(
                1,
                '',
                'Missing drafter ${entry.value.path}',
              );
            }
            (record['files'] as Map)[entry.key] = {
              'path': await entry.value.resolveSymbolicLinks(),
              'bytes': await entry.value.length(),
              'digest': (await sha256.bind(entry.value.openRead()).first)
                  .toString(),
            };
          }
        }
        for (final entry in (record['files'] as Map).entries) {
          final link = Link('${directory.path}/${entry.key}');
          await link.parent.create(recursive: true);
          await link.create((entry.value as Map)['path'] as String);
        }
        await File('${directory.path}/model.json')
            .writeAsString(jsonEncode(record));
      }
      return EngineCommandResult(
        0,
        jsonEncode({'directory': directory.path}),
        '',
      );
    }
    if (arguments.first == 'model-check') {
      if (modelCheckEntered?.isCompleted == false) {
        modelCheckEntered!.complete();
      }
      await releaseCheck?.future;
      return modelCheckFailure
          ? const EngineCommandResult(70, '', 'invalid target/draft pairing')
          : const EngineCommandResult(0, '{"family":"Qwen3.8-27B"}', '');
    }
    if (arguments.any((value) => value.contains('scalar_metadata'))) {
      return const EngineCommandResult(
        0,
        '{"unsigned":{},"float":{},"string":{}}',
        '',
      );
    }
    if (arguments.any((value) => value.contains('sys.prefix'))) {
      return EngineCommandResult(
        0,
        '{"prefix":"${root.path}/${wrongPrefix ? 'system' : '.venv'}"}',
        '',
      );
    }
    if (arguments.contains('--help')) {
      if (mutate) {
        await File('${root.path}/build/splash')
            .writeAsString('concurrent binary replacement');
      }
      return helpFailure
          ? const EngineCommandResult(70, '', 'fixture help failed')
          : EngineCommandResult(0, helpOutput, '');
    }
    return EngineCommandResult(
      0,
      arguments.contains('-c') ? 'Splash (source checkout)' : 'Python 3.14.7',
      '',
    );
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    launchArguments.add(List.unmodifiable(arguments));
    starts++;
    if (starts == expectedStarts && startsEntered?.isCompleted == false) {
      startsEntered!.complete();
    }
    if (!startEntered.isCompleted) startEntered.complete();
    await releaseStart?.future;
    String value(String option) => arguments[arguments.lastIndexOf(option) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(value('--port')),
    );
    final child = SplashTestChild(
      server,
      30000 + children.length,
      diagnostic: launchStderr,
    );
    children.add(child);
    if (launchExitCode != null) child.done.complete(launchExitCode);
    if (startupFeatures != null) {
      startupFeaturesByPid[child.pid] = Map.from(startupFeatures!);
    }
    if (optionalFeatures != null) {
      optionalFeaturesByPid[child.pid] = Map.from(optionalFeatures!);
    }
    final preparation = calls.lastWhere(
      (args) => args.any(
        (value) => value.contains('# Ghost Model Deck Splash preparation'),
      ),
    );
    final requestedDraft =
        (jsonDecode(preparation.last) as Map)['drafter'] as Map?;
    final reportedDrafter =
        nativeDrafter ??
        (requestedDraft?['enabled'] == true ? 'dflash' : 'none');
    String? apiKey;
    for (var index = 0; index < arguments.length; index++) {
      if (arguments[index].startsWith('--') &&
          arguments[index].length > 2 &&
          '--api-key'.startsWith(arguments[index])) {
        apiKey = arguments[++index];
      }
      if (arguments[index].startsWith('--api-key=')) {
        apiKey = arguments[index].substring('--api-key='.length);
      }
    }
    final model = value('--model');
    final alias = value('--served-model-name');
    nativeResponseModel = model;
    server.listen((request) async {
      try {
        request.response.headers.contentType = ContentType.json;
        Object response;
        httpPaths.add(request.uri.path);
        if (apiKey != null &&
            !{'/health', '/ready'}.contains(request.uri.path) &&
            request.headers.value('Authorization') != 'Bearer $apiKey') {
          request.response.statusCode = 401;
          request.response.write('{"error":"invalid or missing API key"}');
          await request.response.close();
          return;
        }
        switch (request.uri.path) {
          case '/ready':
            if (readyStatus != 200) {
              request.response.statusCode = readyStatus;
              request.response.write('{"status":"unavailable"}');
              await request.response.close();
              return;
            }
            if (identityDelay > Duration.zero || identityRelease != null) {
              final delay = identityDelay;
              identityDelay = Duration.zero;
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              detachedIdentitySockets.add(socket);
              void closed() {
                detachedIdentitySockets.remove(socket);
                if (identityClosed?.isCompleted == false) {
                  identityClosed!.complete();
                }
              }

              socket.listen(
                (_) {},
                onDone: closed,
                onError: (Object _) {
                  closed();
                },
              );
              unawaited(socket.done.catchError((Object _) {}));
              final body = utf8.encode('{"status":"ready"}');
              socket.write(
                'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
              );
              socket.write('{"status":');
              await socket.flush();
              if (identityEntered?.isCompleted == false) {
                identityEntered!.complete();
              }
              if (identityRelease != null) {
                await identityRelease!.future;
              } else {
                await Future<void>.delayed(delay);
              }
              try {
                socket.write('"ready"}');
                await socket.flush();
                await socket.close();
              } on IOException {
                socket.destroy();
              }
              return;
            }
            response = {'status': 'ready'};
          case '/status':
            response = {
              ...?monitorStatus,
              'ready': statusReady,
              'startup_features': {
                ...?startupFeaturesByPid[child.pid],
                'drafter': reportedDrafter,
                if (optionalFeaturesByPid[child.pid] != null)
                  'optional': optionalFeaturesByPid[child.pid],
              },
              'instance': {
                'id': statusServerId ?? 'source-${child.pid}',
                'pid': child.pid + (wrongPid ? 1 : 0),
                'model': statusModel ?? model,
                'host': '127.0.0.1',
                'port': server.port,
              },
              'transport': {
                'ready': true,
                'recovering': false,
                'stopped': false,
                'restarts': transportRestarts,
              },
            };
          case '/v1/models':
            response = {
              'object': 'list',
              'data': [
                {'id': model},
                {'id': alias},
              ],
            };
          case '/v1/systemone':
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            decisionBodies.add(body);
            if (decisionEntered?.isCompleted == false) {
              decisionEntered!.complete();
            }
            if (decisionRelease != null) await decisionRelease!.future;
            request.response.statusCode = decisionStatus;
            response =
                decisionResponse?.call(body) ??
                {
                  'model': nativeResponseModel ?? model,
                  'answers': {
                    for (final entry in (body['questions'] as Map).entries)
                      '${entry.key}': {
                        'type': 'choice',
                        'choice': ((entry.value as Map)['criteria'] as Map)
                            .keys
                            .first,
                        'probabilities': {
                          for (final key
                              in ((entry.value as Map)['criteria'] as Map).keys)
                            '$key':
                                key ==
                                    ((entry.value as Map)['criteria'] as Map)
                                        .keys
                                        .first
                                ? 1.0
                                : 0.0,
                        },
                        'confidence': 1.0,
                      },
                  },
                  'usage': {'input_tokens': 10, 'output_tokens': 0},
                };
            afterDecision?.call();
          case '/v1/chat/completions':
            if (rejectTransferEncoding &&
                (request.headers.value(HttpHeaders.transferEncodingHeader) !=
                        null ||
                    request.contentLength < 0)) {
              request.response.statusCode = 400;
              request.response.write(
                '{"error":{"message":"transfer encoding is not supported"}}',
              );
              await request.response.close();
              return;
            }
            if (request.contentLength >= 0) sizedPosts++;
            final rawBody = await request
                .cast<List<int>>()
                .transform(utf8.decoder)
                .join();
            rawChatBodies.add(rawBody);
            final body = jsonDecode(rawBody) as Map;
            chatModels.add(body['model'] as String);
            chatBodies.add(body);
            if (holdChatResponses ||
                (body['messages'] as List).last['content'] == 'hold') {
              if (!holdReached.isCompleted) holdReached.complete();
              await releaseHeld.future;
            }
            if (body['stream'] == true) {
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
              );
              request.response.bufferOutput = false;
              for (final frame in [
                {
                  'model': model,
                  'choices': [
                    {
                      'index': 0,
                      'delta': {'role': 'assistant', 'content': 'OK'},
                      'finish_reason': null,
                    },
                  ],
                },
                {
                  'model': model,
                  'choices': [
                    {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
                  ],
                },
                {
                  'model': model,
                  'choices': [],
                  'usage': {
                    'prompt_tokens': 2,
                    'completion_tokens': 1,
                    'total_tokens': 3,
                  },
                },
              ]) {
                request.response.write('data: ${jsonEncode(frame)}\n\n');
              }
              if ((body['messages'] as List).last['content'] == 'streamhold') {
                await request.response.flush();
                await releaseHeld.future;
              }
              if (!omitDone) request.response.write('data: [DONE]\n\n');
              await request.response.close();
              return;
            }
            response = {
              'model': model,
              'choices': [
                {
                  'index': 0,
                  'message': {
                    'role': 'assistant',
                    'content': emptyText ? '' : 'OK',
                    'reasoning_content': emptyText ? 'thought' : null,
                  },
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 2,
                'completion_tokens': 1,
                'total_tokens': 3,
              },
            };
          default:
            response = {'error': 'unknown'};
        }
        request.response.write(jsonEncode(response));
        await request.response.close();
      } on HttpException {
        /* client cancellation */
      } on SocketException {
        /* client cancellation */
      }
    });
    return child;
  }

  @override
  Future<bool> groupAlive(int ownedParentPid) async {
    if (unknownGroup) throw const SplashEngineException('group state unknown');
    return children.any(
      (child) =>
          child.pid == ownedParentPid &&
          (child.orphanLive || !child.done.isCompleted),
    );
  }

  @override
  Future<void> signalOwnedGroup(
    int ownedParentPid,
    ProcessSignal signal,
  ) async {
    groupSignals.add(ownedParentPid);
    children.singleWhere((child) => child.pid == ownedParentPid).kill(signal);
  }

  Future<void> close() async {
    if (!releaseHeld.isCompleted) releaseHeld.complete();
    if (identityRelease?.isCompleted == false) identityRelease!.complete();
    for (final socket in detachedIdentitySockets.toList()) {
      socket.destroy();
    }
    for (final child in children) {
      child.kill(ProcessSignal.sigterm);
      await child.exitCode;
    }
  }
}

class SplashTestChild implements EngineChild {
  SplashTestChild(this.server, this.pid, {this.diagnostic});
  final String? diagnostic;
  final HttpServer server;
  @override
  final int pid;
  final done = Completer<int>();
  bool orphanLive = false;
  bool closing = false;
  void crash() {
    orphanLive = true;
    done.complete(70);
  }

  @override
  Future<int> get exitCode => done.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => diagnostic == null
      ? const Stream.empty()
      : Stream.value(utf8.encode(diagnostic!));
  @override
  bool kill(ProcessSignal signal) {
    if (!closing) {
      closing = true;
      orphanLive = false;
      server.close(force: true).then((_) {
        if (!done.isCompleted) done.complete(0);
      });
    }
    return true;
  }
}
