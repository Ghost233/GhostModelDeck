import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/embedding_runtime.dart';

void main() {
  for (final embedding in [true, false]) {
    test('公开${embedding ? '嵌入' : '文本'}随新增引擎、停止、路由冲突和解除关联实时变化', () async {
      final io = _DynamicEngineIO();
      final fixture = await EmbeddingTestRuntime.create(processIO: io);
      addTearDown(fixture.close);
      await fixture.gateway.stop();
      await fixture.catalog.stopManaged();
      var asset = fixture.asset;
      if (!embedding) {
        final models = Directory(fixture.library.state.rootPath!);
        await writeDecisionKev(models, ordinaryChat: true);
        asset = (await fixture.library.scan(
          models,
          verifyFiles: true,
        )).singleWhere((entry) => entry.kind == AssetKind.chat);
      }
      final id = 'gmd-${asset.id}';
      final routes = PublicModelRoutes(
        library: fixture.library,
        runtimes: const [],
        runtimeSources: () => [
          for (final entry in fixture.catalog.state.entries)
            fixture.catalog.runtimeFor(entry.id),
        ],
      );
      await routes.enable(asset.id);
      final gateway = PublicGatewayServer(routes: routes, port: 0);
      await gateway.start();
      addTearDown(() async {
        await gateway.stop();
        gateway.close();
        routes.close();
      });
      final path = embedding ? '/v1/embeddings' : '/v1/chat/completions';
      final body = embedding
          ? {'model': id, 'input': 'test input'}
          : {
              'model': id,
              'messages': [
                {'role': 'user', 'content': 'Say hello.'},
              ],
            };
      expect((await _http(gateway, 'POST', path, body: body)).status, 503);
      expect(
        (await _http(gateway, 'GET', '/api/v1/models')).body['models'],
        isEmpty,
      );

      // The registration is created after the already-serving public routes.
      final external = await Directory(
        '${fixture.root.path}/newly-built-engine',
      ).create();
      final binary = await File(fixture.engine.executablePath!)
          .copy('${external.path}/llama-server');
      expect(
        (await Process.run('/bin/chmod', ['755', binary.path])).exitCode,
        0,
      );
      final registration = await fixture.catalog.link(binary.path);
      final provider = fixture.catalog.providerFor(registration.id);
      final instance = await provider.start(asset.id);
      io.bodies.clear();
      final reply = await _http(gateway, 'POST', path, body: body);
      expect(reply.status, 200);
      expect(reply.body['model'], id);
      if (embedding) {
        expect((reply.body['data'] as List).single['embedding'], [3.0, 0.0]);
      } else {
        expect(
          (reply.body['choices'] as List).single['message']['content'],
          'Hello.',
        );
      }
      expect(io.bodies, hasLength(1));
      expect(io.bodies.single['model'], instance.id);
      final discovered =
          (await _http(gateway, 'GET', '/v1/models')).body['data'] as List;
      expect(discovered.single['id'], id);
      final capacity =
          (await _http(gateway, 'GET', '/api/v1/models')).body['models']
              as List;
      expect(capacity.single['key'], id);
      expect(capacity.single['type'], embedding ? 'embedding' : 'llm');
      expect(capacity.single['loaded_instances'], [
        {
          'id': id,
          'config': {'context_length': 4096, 'max_concurrent_requests': 1},
        },
      ]);

      await provider.stop(instance.id);
      expect((await _http(gateway, 'POST', path, body: body)).status, 503);
      expect((await _http(gateway, 'GET', '/v1/models')).body['data'], isEmpty);
      expect(
        (await _http(gateway, 'GET', '/api/v1/models')).body['models'],
        isEmpty,
      );
      await provider.start(asset.id);
      await fixture.engine.start(asset.id);
      final before = io.bodies.length;
      expect((await _http(gateway, 'POST', path, body: body)).status, 409);
      expect(io.bodies.length, before);
      expect(
        (await _http(gateway, 'GET', '/api/v1/models')).body['models'],
        isEmpty,
      );
      await fixture.engine.stopManaged();
      expect((await _http(gateway, 'POST', path, body: body)).status, 200);
      await provider.stopManaged();
      final removal = await fixture.catalog.prepareRemoval(registration.id);
      await fixture.catalog.remove(removal, confirmed: true);
      expect(await binary.exists(), isTrue);
      expect((await _http(gateway, 'POST', path, body: body)).status, 503);
      expect((await _http(gateway, 'GET', '/v1/models')).body['data'], isEmpty);
      expect(
        (await _http(gateway, 'GET', '/api/v1/models')).body['models'],
        isEmpty,
      );
    });
  }
}

class _DynamicEngineIO extends EmbeddingTestIO {
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.singleOrNull == '--help') {
      return const EngineCommandResult(
        0,
        '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device --embedding',
        '',
      );
    }
    return super.run(executable, arguments, timeout: timeout);
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    final child = EmbeddingTestChild(server);
    children.add(child);
    server.listen((request) async {
      try {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/health') {
          request.response.write('{"status":"ok"}');
        } else if (request.uri.path == '/props') {
          request.response.write(
            jsonEncode({
              'model_alias': arg('--alias'),
              'model_path': arg('--model'),
              'total_slots': 1,
              'default_generation_settings': {'n_ctx': 4096},
            }),
          );
        } else {
          final body = Map<String, Object?>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          bodies.add(body);
          if (request.uri.path == '/v1/embeddings') {
            final input = body['input'];
            request.response.write(
              jsonEncode({
                'object': 'list',
                'model': arg('--alias'),
                'data': [
                  for (
                    var index = 0;
                    index < (input is List ? input.length : 1);
                    index++
                  )
                    {
                      'object': 'embedding',
                      'index': index,
                      'embedding': [3, 0],
                    },
                ],
                'usage': {'prompt_tokens': 4, 'total_tokens': 4},
              }),
            );
          } else if (request.uri.path == '/v1/chat/completions') {
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
          } else {
            request.response.statusCode = 404;
          }
        }
        await request.response.close();
      } on HttpException {
        /* Ordinary clients may close their own connection. */
      }
    });
    return child;
  }
}

class _Reply {
  const _Reply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

Future<_Reply> _http(
  PublicGatewayServer gateway,
  String method,
  String path, {
  Object? body,
}) async {
  const timeout = Duration(seconds: 3);
  final client = HttpClient()..connectionTimeout = timeout;
  Future<_Reply> receive() async {
    final request = await client.openUrl(
      method,
      gateway.baseUrl!.resolve(path),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return _Reply(
      response.statusCode,
      Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      ),
    );
  }

  try {
    return await receive().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
