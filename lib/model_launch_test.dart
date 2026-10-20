import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'decision_protocol.dart';
import 'engine_catalog.dart';
import 'engine_launch_configuration.dart';
import 'llama_engine.dart';
import 'model_library.dart';
import 'public_gateway.dart';
import 'splash_engine.dart';
import 'omlx_engine.dart';

/// Owns only the temporary instance and its ephemeral public HTTP listener.
/// Saved configuration, public registrations and existing instances are untouched.
Future<String> testModelLaunch({
  required EngineCatalog catalog,
  required String engineId,
  required LibraryArtifact artifact,
  required EngineLaunchConfiguration configuration,
  required DecisionCancellation cancellation,
  Directory? splashAssembly,
}) async {
  catalog.requireRuntimeEnabled();
  configuration.validateArgumentText();
  final runtime = catalog.runtimeFor(engineId);
  String? instanceId;
  PublicModelRoutes? routes;
  PublicGatewayServer? gateway;
  final client = HttpClient();
  final detach = cancellation.listen(() => client.close(force: true));
  Object? failure;
  try {
    if (cancellation.isCancelled) throw StateError('测试已取消');
    String model;
    final Uri endpoint;
    Map<String, Object?> body;
    DecisionRequest? decision;
    if (runtime is LlamaEngine) {
      final instance = await runtime.start(
        artifact.id,
        configuration: configuration,
        cancellation: cancellation,
        temporaryTest: true,
      );
      instanceId = instance.id;
      if (artifact.kind == AssetKind.decision) {
        model = instance.id;
        endpoint = (instance.decisionEndpoint ?? instance.endpoint).resolve(
          '/v1/systemone',
        );
        decision = DecisionRequest(
          state: 'A short connection test.',
          instructions: 'Choose one option.',
          options: {'keep': 'Keep', 'change': 'Change'},
        );
        body = decision.toSystemone(model: model);
      } else {
        body = {};
        model = '';
        endpoint = Uri();
      }
    } else if (runtime is SplashEngine) {
      final instance = await runtime.startWithConfiguration(
        artifact.id,
        configuration,
        cancellation: cancellation,
        temporaryTest: true,
        assembly: splashAssembly,
      );
      instanceId = instance.id;
      model = '';
      endpoint = Uri();
      body = {};
    } else if (runtime is OmlxEngine) {
      final entry = catalog.state.entries.singleWhere(
        (entry) => entry.id == engineId,
      );
      final instance = await runtime.startWithConfiguration(
        artifact.id,
        configuration,
        launchInstanceId:
            'temporary-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
        launchRevision: 0,
        sourceBundle: Directory(entry.path!),
        sourceReceipt: entry.omlxReceipt,
        cancellation: cancellation,
        temporaryTest: true,
      );
      instanceId = instance.id;
      model = '';
      endpoint = Uri();
      body = {};
    } else {
      throw StateError('此引擎尚未接通模型运行');
    }
    if (cancellation.isCancelled) throw StateError('测试已取消');
    Uri requestUrl = endpoint;
    if (decision == null) {
      routes = PublicModelRoutes(
        library: catalog.library,
        runtimes: [runtime],
        instanceIds: {instanceId},
      );
      await routes.enable(artifact.id);
      model = routes.publicIdFor(artifact.id);
      gateway = PublicGatewayServer(routes: routes, port: 0);
      await gateway.start();
      requestUrl = gateway.baseUrl!.resolve(
        artifact.kind == AssetKind.embedding
            ? '/v1/embeddings'
            : '/v1/chat/completions',
      );
      body = artifact.kind == AssetKind.embedding
          ? {'model': model, 'input': 'Connection test'}
          : {
              'model': model,
              'messages': [
                {'role': 'user', 'content': 'Reply only OK.'},
              ],
              'max_tokens': 32,
              'stream': false,
            };
    }
    if (decision == null && artifact.kind != AssetKind.embedding) {
      body = {...configuration.generation.values, ...body};
    }
    final request = await client
        .postUrl(requestUrl)
        .timeout(const Duration(seconds: 30));
    final bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final raw = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 30));
    if (cancellation.isCancelled) throw StateError('测试已取消');
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}：$raw');
    }
    if (decision != null) {
      DecisionResult.parse(raw, decision, expectedModel: model);
    } else {
      final value = jsonDecode(raw);
      if (artifact.kind == AssetKind.embedding) {
        final data = value is Map ? value['data'] : null;
        if (data is! List ||
            data.length != 1 ||
            data.single is! Map ||
            data.single['embedding'] is! List ||
            (data.single['embedding'] as List).isEmpty ||
            (data.single['embedding'] as List).any(
              (v) => v is! num || !v.isFinite,
            )) {
          throw StateError('HTTP 返回的嵌入向量无效');
        }
      } else {
        final choices = value is Map ? value['choices'] : null;
        final message =
            choices is List && choices.length == 1 && choices.single is Map
            ? choices.single['message']
            : null;
        final content = message is Map ? message['content'] : null;
        if (content is! String ||
            content.trim().isEmpty ||
            choices.single['finish_reason'] != 'stop') {
          throw StateError('HTTP 响应不是已完成的非空文本');
        }
      }
    }
    return '测试通过 · HTTP 200 · 测试实例已停止';
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    detach();
    client.close(force: true);
    final cleanupErrors = <Object>[];
    try {
      await gateway?.stop();
    } catch (error) {
      cleanupErrors.add(error);
    }
    gateway?.close();
    routes?.close();
    if (instanceId != null) {
      try {
        await runtime.stop(instanceId);
      } catch (error) {
        cleanupErrors.add(error);
      }
    }
    if (cleanupErrors.isNotEmpty) {
      throw StateError(
        '${failure == null ? '' : '$failure；'}测试收尾失败：${cleanupErrors.join('；')}',
      );
    }
  }
}
