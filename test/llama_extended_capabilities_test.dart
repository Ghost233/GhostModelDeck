import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/embedding_protocol.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/jev_debug.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/startlux_readout.dart';
import 'package:ghost_model_deck/startlux_runtime.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';
import 'fixtures/typed_answers.dart';

void main() {
  test('source declaration routes any text model natively and preserves unsupported errors', () async {
    final harness = await _Harness.create(sourceSystemone: true);
    addTearDown(harness.close);
    final instance = await harness.engine.start(harness.asset.id);
    expect(harness.io.nativeTypedRequests, 0);
    expect(
      instance.capabilities,
      containsAll([
        LlamaCapability.textGeneration,
        LlamaCapability.choiceProbability,
        LlamaCapability.scoreProbability,
        LlamaCapability.noulScalar,
      ]),
    );
    expect(instance.typedEvidence, isEmpty);
    expect(
      instance.decisionSourceIdentity!['capability_origin'],
      'source_declaration',
    );
    expect(
      instance.decisionSourceIdentity!['requested_ref'],
      'feature/systemone',
    );
    expect(instance.maxDecisionConcurrentRequests, 2);
    await expectLater(
      harness.engine.decideBatch(
        instance.id,
        DecisionBatchRequest(
          state: 'state',
          questions: {
            'q': ChoiceQuestion(
              instructions: 'Pick.',
              options: {'a': 'A', 'b': 'B'},
            ),
          },
        ),
      ),
      throwsA(
        isA<LlamaRequestException>().having(
          (e) => e.message,
          'upstream error',
          contains('HTTP 404'),
        ),
      ),
    );
    expect(harness.io.nativeTypedRequests, 1);
    expect(harness.io.nativeTypedPaths, ['/v1/systemone']);
    expect(
      harness.engine.state.instances.single.status,
      LlamaInstanceStatus.ready,
    );
    expect(harness.engine.runtimeInstances.single.activeRequests, 0);
    expect(
      (await harness.engine.generateText(
        instance.id,
        TextRequest(prompt: 'Hi'),
      )).text,
      'Hello.',
    );
  });

  test(
    'source declaration can disable native JEV without changing text readiness',
    () async {
      final harness = await _Harness.create(sourceSystemone: false);
      addTearDown(harness.close);
      final instance = await harness.engine.start(harness.asset.id);
      expect(instance.capabilities, {LlamaCapability.textGeneration});
      expect(harness.io.nativeTypedRequests, 0);
      await expectLater(
        harness.engine.decideBatch(
          instance.id,
          DecisionBatchRequest(
            state: 'state',
            questions: {
              'q': ChoiceQuestion(
                instructions: 'Pick.',
                options: {'a': 'A', 'b': 'B'},
              ),
            },
          ),
        ),
        throwsA(
          isA<LlamaRequestException>().having(
            (e) => e.kind,
            'kind',
            DecisionFailureKind.notReady,
          ),
        ),
      );
      expect(harness.io.nativeTypedRequests, 0);
    },
  );

  test(
    'managed readout earns typed abilities while CPP text remains native',
    () async {
      final harness = await _Harness.create(readout: true);
      addTearDown(harness.close);
      final instance = await harness.engine.start(harness.asset.id);
      expect(
        instance.capabilities,
        containsAll([
          LlamaCapability.textGeneration,
          LlamaCapability.choiceProbability,
          LlamaCapability.scoreProbability,
          LlamaCapability.noulScalar,
        ]),
      );
      expect(harness.io.nativeTypedRequests, 0);
      expect(harness.readoutRequests, 3);
      expect(instance.decisionEndpoint, isNot(instance.endpoint));
      expect(instance.decisionPid, harness.sidecar!.pid);
      expect(
        instance.decisionSourceIdentity!['generation'],
        instance.generation,
      );
      expect(
        instance.decisionSourceIdentity!['native_endpoint'],
        instance.endpoint.toString(),
      );
      expect(instance.maxDecisionConcurrentRequests, 1);
      expect(
        harness.engine.runtimeInstances.single.capacity!.contextPerSlot,
        262144,
      );
      final answer = await harness.engine.decideBatch(
        instance.id,
        DecisionBatchRequest(
          state: 'A change is requested.',
          questions: {
            'choice': ChoiceQuestion(
              instructions: 'Pick.',
              options: {'no': 'No', 'yes': 'Yes'},
            ),
            'score': ScoreQuestion(
              instructions: 'Rate.',
              levels: ['No', 'Yes'],
            ),
            'noul': NoulQuestion(
              instructions: 'Change?',
              falseText: 'No',
              trueText: 'Yes',
            ),
          },
        ),
      );
      expect(answer.answers, hasLength(3));
      final text = await harness.engine.generateText(
        instance.id,
        TextRequest(prompt: 'Hi'),
      );
      expect(text.text, 'Hello.');
      expect(harness.io.nativeTypedRequests, 0);
      await harness.engine.stop(instance.id);
      expect(harness.sidecar!.ended.isCompleted, isTrue);
      expect(harness.io.child!.ended.isCompleted, isTrue);
      expect(harness.engine.runtimeInstances.single.capacity, isNull);
      expect(harness.engine.runtimeInstances.single.capabilities, isEmpty);
    },
  );

  test('readout requires explicit UTF8 Content-Length for startup and Chinese decisions', () async {
    final harness = await _Harness.create(
      readout: true,
      requireContentLength: true,
    );
    addTearDown(harness.close);
    // The wire fixture retains its existing typed answers; this test evaluates
    // framing only, not model probabilities or decision quality.
    final instance = await harness.engine.start(harness.asset.id);
    expect(harness.readoutWire, hasLength(3));
    for (final frame in harness.readoutWire) {
      expect(frame['length'], (frame['bytes'] as List).length);
      expect(frame['transfer'], isNull);
    }
    final trace = DecisionIOTrace();
    final result = await harness.engine.decideBatch(
      instance.id,
      DecisionBatchRequest(
        state: {'请求': '请把蓝色背景改成绿色 😀'},
        questions: {
          '中文判断': ChoiceQuestion(
            instructions: '请选择满足用户请求的操作。',
            options: {'保留': '保持当前状态', '修改': '应用变更 😀'},
          ),
        },
      ),
      ioTrace: trace,
    );
    expect(result.answers, hasLength(1));
    final frame = harness.readoutWire.last;
    final text = frame['text'] as String;
    final bytes = frame['bytes'] as List<int>;
    expect(text, contains('请把蓝色背景改成绿色'));
    expect(bytes.length, greaterThan(text.length));
    expect(frame['length'], bytes.length);
    expect(bytes, utf8.encode(text));
    expect(frame['transfer'], isNull);
    expect(trace.toJson()['request_body'], text);
    expect(trace.toJson()['http_status'], 200);
  });

  test(
    'readout failure revokes typed discovery and stops its native owner',
    () async {
      final harness = await _Harness.create(readout: true);
      addTearDown(harness.close);
      final instance = await harness.engine.start(harness.asset.id);
      final failed = harness.engine.changes.firstWhere(
        (state) => state.instances.any(
          (value) =>
              value.id == instance.id &&
              value.status == LlamaInstanceStatus.failed,
        ),
      );
      await harness.sidecar!.server.close(force: true);
      harness.sidecar!.ended.complete(17);
      await failed.timeout(const Duration(seconds: 5));
      expect(harness.io.child!.ended.isCompleted, isTrue);
      expect(harness.engine.runtimeInstances.single.capabilities, isEmpty);
      expect(harness.engine.runtimeInstances.single.capacity, isNull);
      await expectLater(
        harness.engine.decideBatch(
          instance.id,
          DecisionBatchRequest(
            state: 'state',
            questions: {
              'q': ChoiceQuestion(
                instructions: 'pick',
                options: {'a': 'a', 'b': 'b'},
              ),
            },
          ),
        ),
        throwsA(isA<LlamaRequestException>()),
      );
    },
  );

  test('failed readout startup retains residual owner until explicit stop succeeds', () async {
    final harness = await _Harness.create(
      readout: true,
      badReadiness: true,
      failReadoutKills: 2,
    );
    addTearDown(harness.close);
    Object? startupError;
    await expectLater(
      harness.engine.start(harness.asset.id),
      throwsA(
        predicate((Object error) {
          startupError = error;
          return true;
        }),
      ),
    );
    expect(harness.sidecar!.ended.isCompleted, isFalse);
    expect(harness.engine.hasLiveInstances, isTrue);
    final residual = harness.engine.runtimeInstances.single;
    expect(residual.status, RuntimeInstanceStatus.failed);
    expect(residual.hasLiveProcess, isTrue);
    expect(residual.acceptingRequests, isFalse);
    expect(residual.capabilities, isEmpty);
    expect(residual.capacity, isNull);
    expect(startupError.toString(), contains('readiness identity mismatch'));
    expect(startupError.toString(), contains('sidecar stop denied'));
    await expectLater(
      harness.library.prepareDeletion([harness.asset.id]),
      throwsA(isA<LibraryException>()),
    );
    await harness.engine.stop(residual.id);
    expect(harness.sidecar!.ended.isCompleted, isTrue);
    expect(harness.io.child!.ended.isCompleted, isTrue);
    expect(harness.engine.hasLiveInstances, isFalse);
    expect(
      harness.engine.runtimeInstances.single.status,
      RuntimeInstanceStatus.stopped,
    );
    expect(
      (await harness.library.prepareDeletion([harness.asset.id])).files,
      isNotEmpty,
    );
  });

  for (final failedCleanup in [false, true]) {
    test(
      'native exit readout boundary before starter returns ${failedCleanup ? 'failed' : 'normal'} cleanup',
      () async {
        final readiness = Completer<void>();
        final spawned = Completer<void>();
        final failureObserved = Completer<Object>();
        final delivery = Completer<void>();
        final harness = await _Harness.create(
          readout: true,
          failReadoutKills: failedCleanup ? 2 : 0,
          readoutReadiness: readiness.future,
          readoutSpawned: spawned,
          starterFailureObserved: failureObserved,
          starterFailureDelivery: delivery.future,
        );
        addTearDown(harness.close);
        Object? startupError;
        final start = harness.engine.start(harness.asset.id);
        final rejected = expectLater(
          start,
          throwsA(
            predicate((Object error) {
              startupError = error;
              return true;
            }),
          ),
        );
        try {
          await spawned.future.timeout(const Duration(seconds: 5));
          await harness.io.child!.exitUnexpectedly(17);
          await failureObserved.future.timeout(const Duration(seconds: 5));
          delivery.complete();
          await rejected;
          final instance = harness.engine.runtimeInstances.single;
          expect(instance.status, RuntimeInstanceStatus.failed);
          expect(instance.acceptingRequests, isFalse);
          expect(instance.capabilities, isEmpty);
          expect(instance.capacity, isNull);
          if (failedCleanup) {
            expect(harness.sidecar!.ended.isCompleted, isFalse);
            expect(instance.hasLiveProcess, isTrue);
            expect(harness.engine.hasLiveInstances, isTrue);
            expect(startupError.toString(), contains('sidecar stop denied'));
            await expectLater(
              harness.library.prepareDeletion([harness.asset.id]),
              throwsA(isA<LibraryException>()),
            );
          } else {
            expect(harness.sidecar!.ended.isCompleted, isTrue);
            expect(harness.engine.hasLiveInstances, isFalse);
          }
          await harness.engine.stop(instance.id);
          expect(harness.sidecar!.ended.isCompleted, isTrue);
          expect(harness.engine.hasLiveInstances, isFalse);
          expect(
            (await harness.library.prepareDeletion([harness.asset.id])).files,
            isNotEmpty,
          );
        } finally {
          if (!delivery.isCompleted) delivery.complete();
          if (!readiness.isCompleted) readiness.complete();
          await rejected;
        }
      },
    );

    test(
      'native exit readout boundary after starter returns ${failedCleanup ? 'failed' : 'normal'} cleanup',
      () async {
        final harness = await _Harness.create(readout: true);
        addTearDown(harness.close);
        final instance = await harness.engine.start(harness.asset.id);
        harness.sidecar!.remainingKillFailures = failedCleanup ? 1 : 0;
        final failed = harness.engine.changes.firstWhere(
          (state) => state.instances.any(
            (value) =>
                value.id == instance.id &&
                value.status == LlamaInstanceStatus.failed &&
                (!failedCleanup ||
                    value.error?.contains('sidecar stop denied') == true),
          ),
        );
        await harness.io.child!.exitUnexpectedly(17);
        await failed.timeout(const Duration(seconds: 5));
        expect(harness.engine.runtimeInstances.single.capabilities, isEmpty);
        expect(
          harness.engine.runtimeInstances.single.acceptingRequests,
          isFalse,
        );
        expect(harness.engine.runtimeInstances.single.capacity, isNull);
        if (failedCleanup) {
          expect(harness.sidecar!.ended.isCompleted, isFalse);
          expect(harness.engine.runtimeInstances.single.hasLiveProcess, isTrue);
          expect(harness.engine.hasLiveInstances, isTrue);
          await expectLater(
            harness.library.prepareDeletion([harness.asset.id]),
            throwsA(isA<LibraryException>()),
          );
        } else {
          await harness.sidecar!.ended.future.timeout(
            const Duration(seconds: 5),
          );
        }
        await harness.engine.stop(instance.id);
        expect(harness.sidecar!.ended.isCompleted, isTrue);
        expect(harness.engine.hasLiveInstances, isFalse);
        expect(
          (await harness.library.prepareDeletion([harness.asset.id])).files,
          isNotEmpty,
        );
      },
    );
  }

  test('readout startup needs all three independent typed proofs', () async {
    final harness = await _Harness.create(readout: true, rejectScore: true);
    addTearDown(harness.close);
    await expectLater(
      harness.engine.start(harness.asset.id),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(harness.sidecar!.ended.isCompleted, isTrue);
    expect(harness.io.child!.ended.isCompleted, isTrue);
    expect(harness.engine.runtimeInstances.single.capabilities, isEmpty);
    expect(
      harness.engine.runtimeInstances.single.status,
      RuntimeInstanceStatus.failed,
    );
  });

  test(
    'embedding is proven separately and uses the actual loaded capacity',
    () async {
      final harness = await _Harness.create(embedding: true);
      addTearDown(harness.close);
      final preview = await harness.engine.previewLaunch(harness.asset.id);
      expect(preview.arguments, contains('--embedding'));
      final instance = await harness.engine.start(harness.asset.id);
      expect(harness.io.arguments, contains('--embedding'));
      expect(instance.capabilities, {LlamaCapability.embeddings});
      expect(harness.io.textRequests, 0);
      final observed = harness.engine.runtimeInstances.single;
      expect(observed.capabilities, {RuntimeCapability.embeddings});
      expect(observed.capacity!.contextPerSlot, 262144);
      expect(observed.capacity!.slotCount, 2);
      final result = await harness.engine.generateEmbeddings(
        instance.id,
        EmbeddingRequest.fromJson({
          'model': 'public-embedding',
          'input': ['first', 'second'],
        }),
      );
      expect(result.vectors, [
        [0.6, 0.8],
        [0.6, 0.8],
      ]);
      expect(result.model, instance.id);
      expect(result.usage['prompt_tokens'], 4);
      await expectLater(
        harness.engine.generateText(instance.id, TextRequest(prompt: 'Hi')),
        throwsA(isA<LlamaRequestException>()),
      );
      await harness.engine.stop(instance.id);
      expect(harness.engine.runtimeInstances.single.capacity, isNull);
    },
  );

  test(
    'invalid embedding startup response never advertises embeddings',
    () async {
      final harness = await _Harness.create(
        embedding: true,
        invalidEmbedding: true,
      );
      addTearDown(harness.close);
      await expectLater(
        harness.engine.start(harness.asset.id),
        throwsA(isA<LlamaEngineException>()),
      );
      expect(harness.engine.runtimeInstances.single.capabilities, isEmpty);
      expect(harness.io.child!.ended.isCompleted, isTrue);
    },
  );
}

class _Harness {
  _Harness(this.root, this.library, this.asset, this.io, this.engine);
  final Directory root;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final _NativeIO io;
  final LlamaEngine engine;
  _ReadoutChild? sidecar;
  int readoutRequests = 0;
  final readoutWire = <Map<String, Object?>>[];

  static Future<_Harness> create({
    bool? sourceSystemone,
    bool readout = false,
    bool embedding = false,
    bool rejectScore = false,
    bool requireContentLength = false,
    bool invalidEmbedding = false,
    bool badReadiness = false,
    int failReadoutKills = 0,
    Future<void>? readoutReadiness,
    Completer<void>? readoutSpawned,
    Completer<Object>? starterFailureObserved,
    Future<void>? starterFailureDelivery,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-llama-capabilities-',
    );
    final library = ModelLibrary();
    final models = Directory('${root.path}/models');
    if (embedding) {
      await writeEmbeddingGguf(models);
    } else {
      await writeDecisionKev(models, ordinaryChat: true);
    }
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final bytes = engineArchive(artifactTag: 'b11381');
    final archive = await File('${root.path}/engine.tgz').writeAsBytes(bytes);
    final io = _NativeIO(invalidEmbedding);
    late _Harness harness;
    final engine = LlamaEngine(
      sourceBuild: sourceSystemone == null
          ? null
          : {
              'source': 'https://github.com/example/llama.cpp',
              'requested_ref': 'feature/systemone',
              'commit': 'ffffffffffffffffffffffffffffffffffffffff',
              'supports_systemone': sourceSystemone,
            },
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      release: LlamaRelease(
        tag: 'b11381',
        artifactTag: 'b11381',
        expectedBuild: 11381,
        expectedBinaryVersion: '0.5.0-dev',
        commit: '836d57176',
        url: Uri.parse('https://example.invalid/fixture'),
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
      ),
      startStartluxReadout: readout
          ? (artifact, native, alias, generation, cancellation) async {
              final factory = StartluxReadoutFactory(
                StartluxPreparedRuntime(
                  pythonPath: '/fixture/python',
                  fingerprint: 'fixture-runtime',
                  provenance: {'boundary': 'process fixture'},
                  reused: true,
                ),
                cacheRoot: Directory('${root.path}/readout'),
                assets: (path) => File(path).readAsBytes(),
                spawn: (executable, arguments) async {
                  final server = await HttpServer.bind(
                    InternetAddress.loopbackIPv4,
                    0,
                  );
                  final child = _ReadoutChild(
                    server,
                    alias,
                    generation,
                    badReadiness: badReadiness,
                    remainingKillFailures: failReadoutKills,
                    readiness: readoutReadiness,
                  );
                  harness.sidecar = child;
                  readoutSpawned?.complete();
                  server.listen((request) async {
                    expect(request.uri.path, '/v1/systemone');
                    final bytes = await request.fold<List<int>>(
                      [],
                      (all, chunk) => all..addAll(chunk),
                    );
                    final text = utf8.decode(bytes);
                    final length = request.headers.contentLength;
                    final transfer = request.headers.value(
                      HttpHeaders.transferEncodingHeader,
                    );
                    harness.readoutWire.add({
                      'bytes': List<int>.unmodifiable(bytes),
                      'text': text,
                      'length': length,
                      'transfer': transfer,
                    });
                    if (requireContentLength &&
                        (length != bytes.length || transfer != null)) {
                      request.response.statusCode = HttpStatus.lengthRequired;
                      request.response.write(
                        'readout requires explicit UTF8 Content-Length',
                      );
                      await request.response.close();
                      return;
                    }
                    final body = jsonDecode(text) as Map;
                    expect(body['model'], alias);
                    final questions = body['questions'] as Map;
                    harness.readoutRequests++;
                    request.response.write(
                      jsonEncode({
                        'model': alias,
                        'answers':
                            rejectScore &&
                                questions.values.any(
                                  (q) => q['type'] == 'score',
                                )
                            ? {}
                            : typedAnswers(questions),
                        'usage': {'input_tokens': 4, 'output_tokens': 0},
                      }),
                    );
                    await request.response.close();
                  });
                  return child;
                },
              );
              try {
                return await factory.start(
                  nativeEndpoint: native,
                  alias: alias,
                  generation: generation,
                  cancellation: cancellation,
                );
              } catch (error, stack) {
                starterFailureObserved?.complete(error);
                // Control this external process-start boundary's error delivery;
                // no application controller state or inference is replaced.
                await starterFailureDelivery;
                Error.throwWithStackTrace(error, stack);
              }
            }
          : null,
    );
    harness = _Harness(root, library, asset, io, engine);
    await engine.install(verifiedArchive: archive);
    return harness;
  }

  Future<void> close() async {
    // A failing test may leave the external process fixture unclaimed. Release
    // only this harness-owned peer, then let the production owner drain itself.
    final child = sidecar;
    if (child != null && !child.ended.isCompleted) {
      child.remainingKillFailures = 0;
      child.kill(ProcessSignal.sigterm);
      await child.ended.future.timeout(const Duration(seconds: 5));
    }
    await engine.stopManaged();
    engine.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class _NativeIO implements EngineProcessIO {
  _NativeIO(this.invalidEmbedding);
  final bool invalidEmbedding;
  _NativeChild? child;
  List<String> arguments = [];
  int textRequests = 0;
  int nativeTypedRequests = 0;
  final nativeTypedPaths = <String>[];
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt with AppleClang for Darwin arm64',
        '',
      );
    }
    final result = await Process.run(executable, arguments);
    return EngineCommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    this.arguments = arguments;
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    child = _NativeChild(server);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': arg('--alias'),
            'model_path': arg('--model'),
            'default_generation_settings': {'n_ctx': 262144},
            'total_slots': 2,
          }),
        );
      } else if (request.uri.path == '/v1/chat/completions') {
        textRequests++;
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'Hello.'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 4,
              'completion_tokens': 2,
              'total_tokens': 6,
            },
          }),
        );
      } else if (request.uri.path == '/v1/embeddings') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], arg('--alias'));
        final raw = body['input'];
        final count = raw is List ? raw.length : 1;
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'object': 'list',
            'data': [
              for (var i = 0; i < count; i++)
                {
                  'index': i,
                  'object': 'embedding',
                  'embedding': invalidEmbedding ? [] : [0.6, 0.8],
                },
            ],
            'usage': {'prompt_tokens': 4, 'total_tokens': 4},
          }),
        );
      } else {
        nativeTypedRequests++;
        nativeTypedPaths.add(request.uri.path);
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    return child!;
  }
}

class _NativeChild implements EngineChild {
  _NativeChild(this.server);
  final HttpServer server;
  final ended = Completer<int>();
  @override
  int get pid => 18476;
  @override
  Future<int> get exitCode => ended.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  Future<void> exitUnexpectedly(int code) async {
    await server.close(force: true);
    if (!ended.isCompleted) ended.complete(code);
  }

  @override
  bool kill(ProcessSignal signal) {
    server.close(force: true).then((_) {
      if (!ended.isCompleted) ended.complete(0);
    });
    return true;
  }
}

class _ReadoutChild implements StartluxReadoutProcess {
  _ReadoutChild(
    this.server,
    String alias,
    int generation, {
    bool badReadiness = false,
    this.remainingKillFailures = 0,
    Future<void>? readiness,
  }) : stdout = Stream.fromFuture(
         (readiness ?? Future<void>.value()).then(
           (_) => utf8.encode(
             '${jsonEncode({'status': 'ready', 'model': badReadiness ? 'foreign-alias' : alias, 'generation': generation, 'pin': StartluxReadoutFactory.authorPin, 'port': server.port})}\n',
           ),
         ),
       );
  final HttpServer server;
  int remainingKillFailures;
  final ended = Completer<int>();
  @override
  final Stream<List<int>> stdout;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  int get pid => 18477;
  @override
  Future<int> get exited => ended.future;
  @override
  bool kill(ProcessSignal signal) {
    if (remainingKillFailures > 0) {
      remainingKillFailures--;
      throw StateError('sidecar stop denied');
    }
    server.close(force: true).then((_) {
      if (!ended.isCompleted) ended.complete(0);
    });
    return true;
  }
}
