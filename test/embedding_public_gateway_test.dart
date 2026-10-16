import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_scenarios.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/embedding_runtime.dart';

void main() {
  test('场景模型名字沿用保存嵌入实例的公开向量协议', () async {
    final fixture = await EmbeddingTestRuntime.create();
    addTearDown(fixture.close);
    final instances = LaunchInstances(
      catalog: fixture.catalog,
      file: File('${fixture.root.path}/instances.json'),
    );
    addTearDown(instances.close);
    final definition = await instances.save(
      name: 'Embedding instance',
      artifactId: fixture.asset.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final scenarios = ModelScenarios(
      names: instances.names,
      instances: instances,
    );
    addTearDown(scenarios.close);
    await scenarios.save(
      0,
      ModelScenario(
        displayName: '文字嵌入',
        modelName: 'embedding-fast',
        instanceId: definition.id,
      ),
    );
    final routes = PublicModelRoutes(
      library: fixture.library,
      runtimes: fixture.catalog.runtimes.toList(),
      instances: instances,
      scenarios: scenarios,
    );
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    await gateway.start();
    addTearDown(() async {
      await gateway.stop();
      gateway.close();
      routes.close();
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, Map)> post() async {
      final request = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/embeddings'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': 'embedding-fast',
          'input': ['first', 'second'],
        }),
      );
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      );
    }

    expect((await post()).$1, 503);
    expect(fixture.io.bodies, isEmpty);
    final run = await instances.start(definition.id);
    final result = await post();
    expect(result.$1, 200);
    expect(result.$2['model'], 'embedding-fast');
    expect((result.$2['data'] as List).map((row) => row['embedding']), [
      [3.0, 0.0],
      [0.0, 4.0],
    ]);
    expect(fixture.io.bodies.single['model'], run.id);
    final request = await client.getUrl(gateway.baseUrl!.resolve('/v1/models'));
    final response = await request.close();
    final listing = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    expect(
      (listing['data'] as List).map((row) => row['id']),
      containsAll([definition.publicName, 'embedding-fast']),
    );
  });
  test('同源公开发现报告实际每槽容量，embedding不宣称文本或typed决策能力', () async {
    final fixture = await EmbeddingTestRuntime.create();
    addTearDown(fixture.close);
    final discovery = await exchange(fixture, 'GET', '/api/v1/models');
    expect(discovery.status, 200);
    expect(discovery.body['source'], 'ghost-model-deck');
    final models = discovery.body['models'] as List;
    expect(models, hasLength(1));
    expect(models.single, {
      'key': fixture.publicId,
      'type': 'embedding',
      'source': 'ghost-model-deck',
      'loaded_instances': [
        {
          'id': fixture.publicId,
          'config': {'context_length': 4096, 'max_concurrent_requests': 1},
        },
      ],
    });
    final compatible = await exchange(fixture, 'GET', '/v1/models');
    expect((compatible.body['data'] as List).single['id'], fixture.publicId);
    expect((compatible.body['data'] as List).single['type'], 'embedding');
    expect((compatible.body['data'] as List).single['source'], 'embedding');
    final embeddings = await exchange(
      fixture,
      'POST',
      '/v1/embeddings',
      body: {
        'model': fixture.publicId,
        'input': ['first', 'second'],
      },
    );
    expect(embeddings.status, 200);
    expect(embeddings.body['model'], fixture.publicId);
    expect(embeddings.body['data'], [
      {
        'object': 'embedding',
        'index': 0,
        'embedding': [3.0, 0.0],
      },
      {
        'object': 'embedding',
        'index': 1,
        'embedding': [0.0, 4.0],
      },
    ]);
    final before = fixture.io.bodies.length;
    final text = await exchange(
      fixture,
      'POST',
      '/v1/chat/completions',
      body: {
        'model': fixture.publicId,
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
      },
    );
    expect(text.status, 503);
    expect(text.body['error']['type'], 'model_not_ready');
    final decision = await exchange(
      fixture,
      'POST',
      '/v1/systemone',
      body: {'model': fixture.publicId, 'state': 's', 'questions': {}},
    );
    expect(decision.status, 404);
    expect(fixture.io.bodies.length, before);
  });

  test('公开嵌入输入、host和体积边界拒绝请求且不访问引擎', () async {
    final fixture = await EmbeddingTestRuntime.create();
    addTearDown(fixture.close);
    for (final input in [
      [],
      [1],
      '',
      ['valid', ''],
    ]) {
      final response = await exchange(
        fixture,
        'POST',
        '/v1/embeddings',
        body: {'model': fixture.publicId, 'input': input},
      );
      expect(response.status, 400);
    }
    for (final fields in [
      {'encoding_format': 'base64'},
      {'dimensions': 0},
      {'unsupported': true},
    ]) {
      final response = await exchange(
        fixture,
        'POST',
        '/v1/embeddings',
        body: {'model': fixture.publicId, 'input': 'text', ...fields},
      );
      expect(response.status, 400);
    }
    final forbidden = await exchange(
      fixture,
      'POST',
      '/v1/embeddings',
      body: {'model': fixture.publicId, 'input': 'text'},
      host: 'untrusted.example',
    );
    expect(forbidden.status, 403);
    final oversized = await exchange(
      fixture,
      'POST',
      '/v1/embeddings',
      body: {'model': fixture.publicId, 'input': 'a' * (1024 * 1024)},
    );
    expect(oversized.status, 413);
    expect(fixture.io.bodies, isEmpty);
  });

  test('停止和禁用即撤下实际容量，重启测量新容量且公开模型身份不变', () async {
    final fixture = await EmbeddingTestRuntime.create();
    addTearDown(fixture.close);
    await fixture.catalog.stopManaged();
    expect(
      (await exchange(fixture, 'GET', '/api/v1/models')).body['models'],
      isEmpty,
    );
    expect(
      (await exchange(
        fixture,
        'POST',
        '/v1/embeddings',
        body: {'model': fixture.publicId, 'input': 'text'},
      )).status,
      503,
    );
    fixture.io.contextPerSlot = 8192;
    fixture.io.slotCount = 2;
    await fixture.engine.start(fixture.asset.id);
    final restarted = await exchange(fixture, 'GET', '/api/v1/models');
    expect((restarted.body['models'] as List).single['loaded_instances'], [
      {
        'id': fixture.publicId,
        'config': {'context_length': 8192, 'max_concurrent_requests': 2},
      },
    ]);
    await fixture.routes.disable(fixture.asset.id);
    expect(
      (await exchange(fixture, 'GET', '/api/v1/models')).body['models'],
      isEmpty,
    );
    expect(
      (await exchange(
        fixture,
        'POST',
        '/v1/embeddings',
        body: {'model': fixture.publicId, 'input': 'text'},
      )).status,
      404,
    );
  });

  test('没有实际加载容量时不以GGUF或启动默认值冒充发现结果', () async {
    final fixture = await EmbeddingTestRuntime.create(
      processIO: EmbeddingTestIO()..contextPerSlot = null,
    );
    addTearDown(fixture.close);
    expect(
      (await exchange(fixture, 'GET', '/api/v1/models')).body['models'],
      isEmpty,
    );
  });

  test('嵌入实例props身份失配返回502并撤销能力容量，拒绝上游嵌入调用', () async {
    final fixture = await EmbeddingTestRuntime.create();
    addTearDown(fixture.close);
    fixture.io.propsAlias = 'foreign-instance';
    final response = await exchange(
      fixture,
      'POST',
      '/v1/embeddings',
      body: {'model': fixture.publicId, 'input': 'text'},
    );
    expect(response.status, 502);
    expect(response.body['error']['type'], 'upstream_error');
    expect(jsonEncode(response.body), isNot(contains('foreign-instance')));
    expect(fixture.io.bodies, isEmpty);
    final instance = fixture.engine.runtimeInstances.single;
    expect(instance.status, RuntimeInstanceStatus.failed);
    expect(instance.capabilities, isEmpty);
    expect(instance.capacity, isNull);
    expect(instance.hasLiveProcess, isFalse);
    expect(instance.activeRequests, 0);
    expect(instance.error, contains('alias 或模型路径不匹配'));
    expect(
      (await exchange(fixture, 'GET', '/api/v1/models')).body['models'],
      isEmpty,
    );
    expect(
      (await exchange(fixture, 'GET', '/v1/models')).body['data'],
      isEmpty,
    );
  });
}

class PublicReply {
  const PublicReply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

Future<PublicReply> exchange(
  EmbeddingTestRuntime fixture,
  String method,
  String path, {
  Object? body,
  String? host,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  Future<PublicReply> receive() async {
    final request = await client.openUrl(
      method,
      fixture.gateway.baseUrl!.resolve(path),
    );
    if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return PublicReply(
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
