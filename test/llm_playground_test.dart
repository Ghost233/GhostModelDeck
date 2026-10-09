import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/llm_playground.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  test('挂起真实公开发现支持取消和期限，释放自有连接且后续发现可用', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    final relay = await DiscoveryRelay.create(() => fixture.gateway.baseUrl);
    addTearDown(relay.close);
    final playground = LlmPlayground(baseUrl: () => fixture.gateway.baseUrl);
    final cancellation = DecisionCancellation();
    final cancelled = HttpOverrides.runWithHttpOverrides(
      () => playground.discover(cancellation: cancellation),
      DiscoveryRouting(relay),
    );
    final first = await relay.received(0);
    expect(first.responseText, contains(fixture.publicId));
    cancellation.cancel();
    await expectLater(
      cancelled,
      throwsA(
        isA<HttpException>().having(
          (error) => error.message,
          'cancel reason',
          contains('取消'),
        ),
      ),
    );
    await first.closed.future.timeout(const Duration(seconds: 2));
    final timed = HttpOverrides.runWithHttpOverrides(
      () => playground.discover(timeout: const Duration(seconds: 1)),
      DiscoveryRouting(relay),
    );
    final timeoutCheck = expectLater(timed, throwsA(isA<TimeoutException>()));
    final second = await relay.received(1);
    expect(second.responseText, contains(fixture.publicId));
    await timeoutCheck;
    await second.closed.future.timeout(const Duration(seconds: 2));
    expect(await playground.discover(), [fixture.publicId]);
    expect(fixture.io.bodies, isEmpty);
  });

  test('公开 HTTP 发现 Ready 文本模型并保留真实输入、返回与实际用量', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    final playground = LlmPlayground(baseUrl: () => fixture.gateway.baseUrl);
    expect(await playground.discover(), [fixture.publicId]);
    final document = llmDocument(fixture.publicId);
    final result = await playground.run(jsonEncode(document));
    expect(result.completed, isTrue);
    expect(result.statusCode, 200);
    expect(result.request, document);
    expect(result.text, 'Hello.');
    expect(result.finishReason, 'stop');
    expect(result.usage, {
      'prompt_tokens': 4,
      'completion_tokens': 2,
      'total_tokens': 6,
    });
    expect(jsonDecode(result.rawResponse)['model'], fixture.publicId);
    expect(fixture.io.bodies.last['messages'], document['messages']);
    expect(fixture.io.bodies.last['temperature'], 0.7);
    expect(fixture.io.bodies.last['top_p'], 0.9);
    await fixture.routes.disable(fixture.asset.id);
    expect(await playground.discover(), isEmpty);
  });
  test('真实 SSE 渐进文本保留完整公开帧、usage、finish 与 DONE', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.streamResponse = writeLlmStream;
    final playground = LlmPlayground(baseUrl: () => fixture.gateway.baseUrl);
    final updates = <String>[];
    final result = await playground.run(
      jsonEncode(llmDocument(fixture.publicId, stream: true)),
      onProgress: (progress) => updates.add(progress.text),
    );
    expect(result.completed, isTrue);
    expect(updates, contains('Hel'));
    expect(result.text, 'Hello.');
    expect(result.finishReason, 'stop');
    expect(result.usage, {
      'prompt_tokens': 4,
      'completion_tokens': 2,
      'total_tokens': 6,
    });
    expect(result.rawResponse, contains('data: [DONE]'));
    expect(result.rawResponse, contains(fixture.publicId));
    expect(fixture.io.bodies.single['stream'], isTrue);
    expect(fixture.io.bodies.single['stream_options'], {'include_usage': true});
  });
  test('普通 HTTP 取消及时释放被挂起请求，不影响独立调用或接受晚结果', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.release = Completer<void>();
    fixture.io.held = Completer<void>();
    final document = llmDocument(fixture.publicId);
    (document['messages'] as List).last['content'] = 'Hold';
    final cancellation = DecisionCancellation();
    final playground = LlmPlayground(baseUrl: () => fixture.gateway.baseUrl);
    final pending = playground.run(
      jsonEncode(document),
      cancellation: cancellation,
    );
    await fixture.io.held!.future.timeout(const Duration(seconds: 5));
    expect(fixture.engine.runtimeInstances.single.activeRequests, 1);
    fixture.io.otherRelease = Completer<void>();
    fixture.io.otherHeld = Completer<void>();
    final otherDocument = llmDocument(fixture.publicId);
    (otherDocument['messages'] as List).last['content'] = 'Other';
    final independent = playground.run(jsonEncode(otherDocument));
    await fixture.io.otherHeld!.future.timeout(const Duration(seconds: 5));
    expect(fixture.engine.runtimeInstances.single.activeRequests, 2);
    cancellation.cancel();
    final cancelled = await pending.timeout(const Duration(seconds: 2));
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.completed, isFalse);
    expect(fixture.io.release!.isCompleted, isFalse);
    await waitForLlmPermitRelease(fixture, expected: 1);
    expect(fixture.io.otherRelease!.isCompleted, isFalse);
    fixture.io.otherRelease!.complete();
    expect(
      (await independent.timeout(const Duration(seconds: 2))).completed,
      isTrue,
    );
    fixture.io.release!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(cancelled.completed, isFalse);
    expect(cancelled.text, isEmpty);
  });
  test('客户端期限停止普通HTTP并记录超时，不修改公开请求或服务端预算', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.release = Completer<void>();
    fixture.io.held = Completer<void>();
    final document = llmDocument(fixture.publicId);
    (document['messages'] as List).last['content'] = 'Hold';
    final playground = LlmPlayground(baseUrl: () => fixture.gateway.baseUrl);
    final result = await playground.run(
      jsonEncode(document),
      timeout: const Duration(milliseconds: 250),
    );
    expect(result.timedOut, isTrue);
    expect(result.cancelled, isFalse);
    expect(result.completed, isFalse);
    expect(result.timeout, const Duration(milliseconds: 250));
    expect(result.request, document);
    expect(fixture.io.bodies.single.keys, isNot(contains('timeout')));
    expect(fixture.io.release!.isCompleted, isFalse);
    await waitForLlmPermitRelease(fixture);
    expect(
      (await playground.run(jsonEncode(llmDocument(fixture.publicId))))
          .completed,
      isTrue,
    );
  });
  test('上游未完成SSE明确中断，保留已收到文本且不伪造用量或DONE', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.streamResponse = (response, alias) async {
      response.write(
        'data: ${jsonEncode({
          'model': alias,
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'Hel'},
              'finish_reason': null,
            },
          ],
        })}\n\n',
      );
      await response.flush();
    };
    final result = await LlmPlayground(baseUrl: () => fixture.gateway.baseUrl)
        .run(jsonEncode(llmDocument(fixture.publicId, stream: true)));
    expect(result.interrupted, isTrue);
    expect(result.completed, isFalse);
    expect(result.statusCode, 200);
    expect(result.text, 'Hel');
    expect(result.usage, isNull);
    expect(result.finishReason, isNull);
    expect(result.rawResponse, isNot(contains('[DONE]')));
    expect(result.error, contains('缺少上游 DONE'));
    await waitForLlmPermitRelease(fixture);
  });
  test('公开请求不支持字段和上游失败均明确失败，不删字段或自动重试', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    final playground = LlmPlayground(baseUrl: () => fixture.gateway.baseUrl);
    final unsupported = {
      ...llmDocument(fixture.publicId),
      'tools': <Object?>[],
    };
    final refused = await playground.run(jsonEncode(unsupported));
    expect(refused.statusCode, 400);
    expect(refused.completed, isFalse);
    expect(refused.request, unsupported);
    expect(
      jsonDecode(refused.rawResponse)['error']['message'],
      contains('tools'),
    );
    expect(fixture.io.bodies, isEmpty);
    fixture.io.status = 503;
    final failure = await playground.run(
      jsonEncode(llmDocument(fixture.publicId)),
    );
    expect(failure.statusCode, 502);
    expect(failure.completed, isFalse);
    expect(failure.text, isEmpty);
    expect(jsonDecode(failure.rawResponse)['error']['type'], 'upstream_error');
    expect(fixture.io.bodies, hasLength(1));
  });

  test('公开SSE原文保留任务文本，usage伪装的消息形状仍是脱敏metadata', () async {
    final fixture = await LlmTestRuntime.create();
    addTearDown(fixture.close);
    const task = 'Authorization: allow {"api_key":"ordinary task value"}';
    fixture.io.streamResponse = (response, alias) => writeLlmStream(
      response,
      alias,
      first: task,
      rest: '',
      actualUsage: {
        'prompt_tokens': 4,
        'completion_tokens': 2,
        'total_tokens': 6,
        'api_key': 'metadata-secret',
        'diagnostic': {
          'choices': [
            {
              'delta': {
                'role': 'assistant',
                'content': 'Authorization: Bearer private-trace',
              },
            },
          ],
        },
      },
    );
    final result = await LlmPlayground(baseUrl: () => fixture.gateway.baseUrl)
        .run(jsonEncode(llmDocument(fixture.publicId, stream: true)));
    expect(result.completed, isTrue);
    expect(result.text, task);
    final evidence = result.toJson();
    expect(evidence['text'], task);
    expect((evidence['usage'] as Map)['api_key'], '[redacted]');
    expect(jsonEncode(evidence), isNot(contains('metadata-secret')));
    expect(jsonEncode(evidence), isNot(contains('private-trace')));
    final raw = evidence['raw_response'] as String;
    expect(raw, result.rawResponse);
    expect(raw, contains('data: [DONE]\n\n'));
    final payload = raw
        .split('\n')
        .firstWhere((line) => line.startsWith('data: '));
    expect(
      jsonDecode(payload.substring(6))['choices'][0]['delta']['content'],
      task,
    );
  });
}

Map<String, Object?> llmDocument(String model, {bool stream = false}) => {
  'model': model,
  'messages': [
    {'role': 'system', 'content': 'Keep whitespace:  '},
    {'role': 'user', 'content': 'Hi'},
    {'role': 'assistant', 'content': 'Previous answer.'},
    {'role': 'user', 'content': 'Continue.'},
  ],
  'stream': stream,
  'max_tokens': 64,
  'temperature': 0.7,
  'top_p': 0.9,
};

/// Full production graph; only the external engine process/HTTP IO is substituted.
class LlmTestRuntime {
  LlmTestRuntime(
    this.root,
    this.library,
    this.asset,
    this.io,
    this.engine,
    this.catalog,
    this.routes,
    this.gateway,
  );
  final Directory root;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final LlmTestIO io;
  final LlamaEngine engine;
  final EngineCatalog catalog;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  String get publicId => 'gmd-${asset.id}';

  static Future<LlmTestRuntime> create({LlmTestIO? processIO}) async {
    final root = await Directory.systemTemp.createTemp('gmd-llm-playground-');
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: true);
    final library = ModelLibrary();
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final bytes = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(bytes);
    final io = processIO ?? LlmTestIO();
    final use = ModelUseRegistry(library);
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      useRegistry: use,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
      ),
      loadTimeout: const Duration(seconds: 3),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
      io: io,
    );
    await catalog.installOfficial(verifiedArchive: archive);
    final routes = PublicModelRoutes(library: library, runtimes: [engine]);
    await routes.enable(asset.id);
    await engine.start(asset.id);
    final gateway = PublicGatewayServer(
      routes: routes,
      port: 0,
      heartbeatInterval: const Duration(milliseconds: 20),
    );
    await gateway.start();
    io.bodies.clear();
    return LlmTestRuntime(
      root,
      library,
      asset,
      io,
      engine,
      catalog,
      routes,
      gateway,
    );
  }

  Future<void> close() async {
    if (io.release != null && !io.release!.isCompleted) io.release!.complete();
    if (io.otherRelease != null && !io.otherRelease!.isCompleted) {
      io.otherRelease!.complete();
    }
    await gateway.stop();
    gateway.close();
    routes.close();
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    for (final child in io.children) {
      await child.server.close(force: true);
    }
    await root.delete(recursive: true);
  }
}

class LlmTestIO implements EngineProcessIO {
  final bodies = <Map<String, Object?>>[];
  final children = <LlmTestChild>[];
  int status = 200;
  String responseText = 'Hello.';
  Map<String, Object?> responseUsage = {
    'prompt_tokens': 4,
    'completion_tokens': 2,
    'total_tokens': 6,
  };
  Completer<void>? release;
  Completer<void>? held;
  Completer<void>? otherRelease;
  Completer<void>? otherHeld;
  Future<void> Function(HttpResponse response, String alias)? streamResponse;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    final child = LlmTestChild(server);
    children.add(child);
    server.listen((request) async {
      try {
        if (request.uri.path == '/health') {
          request.response.write('{"status":"ok"}');
        } else if (request.uri.path == '/props') {
          request.response.write(
            jsonEncode({
              'model_alias': arg('--alias'),
              'model_path': arg('--model'),
            }),
          );
        } else if (request.uri.path == '/v1/chat/completions') {
          final body = Map<String, Object?>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          bodies.add(body);
          if (body['stream'] == true) {
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.bufferOutput = false;
            await streamResponse!(request.response, arg('--alias'));
          } else {
            if (release != null &&
                (body['messages'] as List).last['content'] == 'Hold') {
              if (held != null && !held!.isCompleted) held!.complete();
              await release!.future;
            }
            if (otherRelease != null &&
                (body['messages'] as List).last['content'] == 'Other') {
              if (otherHeld != null && !otherHeld!.isCompleted) {
                otherHeld!.complete();
              }
              await otherRelease!.future;
            }
            request.response.statusCode = status;
            request.response.write(
              status == 200
                  ? jsonEncode({
                      'model': arg('--alias'),
                      'choices': [
                        {
                          'index': 0,
                          'message': {
                            'role': 'assistant',
                            'content': responseText,
                          },
                          'finish_reason': 'stop',
                        },
                      ],
                      'usage': responseUsage,
                    })
                  : 'upstream refused',
            );
          }
        }
        await request.response.close();
      } on HttpException {
        /* Disconnected normal public client. */
      }
    });
    return child;
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
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
}

class LlmTestChild implements EngineChild {
  LlmTestChild(this.server) : pid = server.port;
  final HttpServer server;
  final exited = Completer<int>();
  @override
  final int pid;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    unawaited(
      server.close(force: true).then((_) {
        if (!exited.isCompleted) exited.complete(0);
      }),
    );
    return true;
  }
}

Future<void> writeLlmStream(
  HttpResponse response,
  String alias, {
  String first = 'Hel',
  String rest = 'lo.',
  Map<String, Object?>? actualUsage,
}) async {
  void frame(Map<String, Object?> choice, {Map<String, Object?>? usage}) {
    response.write(
      'data: ${jsonEncode({
        'model': alias,
        'choices': [choice],
        'usage': ?usage,
      })}\n\n',
    );
  }

  frame({
    'index': 0,
    'delta': {'role': 'assistant', 'content': first},
    'finish_reason': null,
  });
  await response.flush();
  frame({
    'index': 0,
    'delta': {'content': rest},
    'finish_reason': null,
  });
  frame(
    {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
    usage:
        actualUsage ??
        {'prompt_tokens': 4, 'completion_tokens': 2, 'total_tokens': 6},
  );
  response.write('data: [DONE]\n\n');
}

Future<void> waitForLlmPermitRelease(
  LlmTestRuntime fixture, {
  int expected = 0,
}) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (fixture.engine.runtimeInstances.single.activeRequests != expected) {
    if (DateTime.now().isAfter(until)) {
      fail(
        'ordinary HTTP cancellation did not release the held inference permit',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// External network delay: forwards real GETs to the production gateway and
/// buffers its exact response bytes. It never fabricates model data or status.
class DiscoveryRelay {
  DiscoveryRelay._(this.server, this.target);
  final ServerSocket server;
  final Uri? Function() target;
  final connections = <DiscoveryConnection>[];
  final _attachments = <Future<void>>[];
  bool _closing = false;
  int get port => server.port;

  static Future<DiscoveryRelay> create(Uri? Function() target) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = DiscoveryRelay._(server, target);
    server.listen((peer) {
      final connection = DiscoveryConnection(peer);
      relay.connections.add(connection);
      final attachment = relay._attach(connection).catchError((Object error) {
        connection.networkError = error;
        connection.destroy();
      });
      relay._attachments.add(attachment);
      unawaited(attachment);
    });
    return relay;
  }

  Future<void> _attach(DiscoveryConnection connection) async {
    final target = this.target();
    if (target == null) throw StateError('Production gateway is not running');
    final upstream = await Socket.connect(target.host, target.port);
    connection.upstream = upstream;
    if (_closing) {
      connection.destroy();
      return;
    }
    final request = StringBuffer();
    var forwarded = false;
    connection.peerSubscription = connection.peer.listen(
      (data) {
        if (forwarded) {
          upstream.add(data);
          return;
        }
        request.write(utf8.decode(data));
        if (!request.toString().contains('\r\n\r\n')) return;
        forwarded = true;
        // Normal reverse-proxy authority routing; method/path/body remain intact.
        upstream.write(
          request.toString().replaceFirst(
            RegExp(r'^host:[^\r\n]*', caseSensitive: false, multiLine: true),
            'Host: ${target.host}:${target.port}',
          ),
        );
        unawaited(
          upstream.flush().catchError((Object error) {
            connection.networkError = error;
            connection.destroy();
          }),
        );
      },
      onDone: connection.destroy,
      onError: (Object _) => connection.destroy(),
    );
    connection.upstreamSubscription = upstream.listen(
      (data) {
        connection.response.add(data);
        if (connection.released && !connection.closed.isCompleted) {
          connection.peer.add(data);
        }
        final raw = connection.responseText;
        final boundary = raw.indexOf('\r\n\r\n');
        if (boundary < 0) return;
        final length = RegExp(
          r'content-length:\s*(\d+)',
          caseSensitive: false,
        ).firstMatch(raw.substring(0, boundary));
        final complete = length != null
            ? connection.response.length >=
                  boundary + 4 + int.parse(length.group(1)!)
            : raw.endsWith('0\r\n\r\n');
        if (complete && !connection.ready.isCompleted) {
          connection.ready.complete();
        }
      },
      onDone: () {
        if (!connection.ready.isCompleted) connection.ready.complete();
      },
      onError: (Object error) {
        connection.networkError = error;
        connection.destroy();
      },
    );
  }

  Future<DiscoveryConnection> received(int index) async {
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (connections.length <= index) {
      if (DateTime.now().isAfter(until)) {
        fail('discovery network connection was not accepted');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final connection = connections[index];
    await connection.ready.future.timeout(const Duration(seconds: 5));
    expect(connection.networkError, isNull);
    expect(connection.responseText, startsWith('HTTP/1.1 200'));
    return connection;
  }

  Future<void> close() async {
    _closing = true;
    await server.close();
    for (final connection in connections) {
      connection.destroy();
    }
    await Future.wait(_attachments);
    for (final connection in connections) {
      await connection.peerSubscription?.cancel();
      await connection.upstreamSubscription?.cancel();
    }
  }
}

class DiscoveryConnection {
  DiscoveryConnection(this.peer);
  final Socket peer;
  Socket? upstream;
  StreamSubscription<List<int>>? peerSubscription;
  StreamSubscription<List<int>>? upstreamSubscription;
  final response = BytesBuilder();
  final ready = Completer<void>();
  final closed = Completer<void>();
  Object? networkError;
  bool released = false;
  String get responseText =>
      utf8.decode(response.toBytes(), allowMalformed: true);
  void destroy() {
    if (!closed.isCompleted) closed.complete();
    peer.destroy();
    upstream?.destroy();
  }

  Future<void> release() async {
    if (closed.isCompleted) return;
    released = true;
    peer.add(response.toBytes());
    await peer.flush();
  }
}

class DiscoveryRouting extends HttpOverrides {
  DiscoveryRouting(this.relay);
  final DiscoveryRelay relay;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => 'PROXY 127.0.0.1:${relay.port}';
    return client;
  }
}
