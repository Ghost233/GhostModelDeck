import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

import '../fixtures/council_runtime.dart';

const _enabled = bool.fromEnvironment('GMD_PREFILL_FIXTURE');

void main() {
  test(
    'isolated synthetic GMD gateway fixture',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixture = await CouncilRuntime.create(
          modelCount: 1,
          sourceSystemone: true,
        );
        fixture.io.capacityProperties = {
          'total_slots': 1,
          'default_generation_settings': {'n_ctx': 8192},
        };
        final instances = LaunchInstances(
          catalog: fixture.catalog,
          file: File('${fixture.root.path}/instances.json'),
        );
        final instance = await instances.save(
          name: 'Synthetic fixture',
          artifactId: fixture.library.state.artifacts.single.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        );
        final council = CouncilController(
          catalog: fixture.catalog,
          launchInstances: instances,
        );
        final routes = PublicModelRoutes(
          library: fixture.library,
          instances: instances,
          runtimes: fixture.catalog.runtimes.toList(),
        );
        final ledger = await PrefillOperationLedger.open(
          File('${fixture.root.path}/prefill.json'),
        );
        final native = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final shutdown = Completer<void>();
        final jobs = <String, _Job>{};
        var nativeId = 0;
        native.listen((request) async {
          try {
            request.response.headers.contentType = ContentType.json;
            if (request.method == 'POST' &&
                request.uri.path == '/__fixture_shutdown') {
              request.response.write('{"ok":true}');
              if (!shutdown.isCompleted) shutdown.complete();
            } else if (request.uri.path == '/v1/splash/runtime') {
              request.response.write(
                jsonEncode({
                  'service_instance': 'fixture-service',
                  'runtime_generation': 1,
                }),
              );
            } else if (request.method == 'POST' &&
                (request.uri.path == '/v1/chat/completions' ||
                    request.uri.path == '/v1/systemone')) {
              final id = request.headers.value('x-splash-operation-id')!;
              final token = request.headers.value('x-splash-operation-token')!;
              final body =
                  jsonDecode(await utf8.decoder.bind(request).join()) as Map;
              final decision = request.uri.path == '/v1/systemone';
              final prefill = decision
                  ? body['prefill_only'] == true
                  : body['max_tokens'] == 0;
              final questions = !decision || prefill
                  ? <String>[]
                  : (body['questions'] as Map).keys.cast<String>().toList();
              final children = <Map<String, Object?>>[];
              for (final question
                  in questions.isEmpty ? <String?>[null] : questions) {
                children.add({
                  'question_id': question,
                  'native_request_id': ++nativeId,
                  'runtime_generation': 1,
                  'state': prefill ? 'length' : 'stop',
                  'lease_released': true,
                  'prompt_tokens': 24,
                  'completion_tokens': prefill || decision ? 0 : 8,
                  'matched_prompt_tokens': 8,
                  'deduplicated_tokens': 0,
                });
              }
              jobs[id] = _Job(token, children);
              if (decision) {
                final answers = <String, Object?>{};
                for (final question in questions) {
                  final spec = (body['questions'] as Map)[question] as Map;
                  final criteria = spec['criteria'] as Map;
                  final choice = criteria.containsKey('unknown')
                      ? 'unknown'
                      : criteria.keys.first as String;
                  answers[question] = {
                    'type': 'choice',
                    'choice': choice,
                    'confidence': 1.0,
                    'probabilities': {
                      for (final key in criteria.keys)
                        key: key == choice ? 1.0 : 0.0,
                    },
                  };
                }
                request.response.write(
                  jsonEncode({
                    'model': 'fixture-native-response',
                    'answers': answers,
                    'usage': {
                      'input_tokens': 24 * (prefill ? 1 : questions.length),
                      'output_tokens': 0,
                    },
                    if (prefill) 'prefill_only': true,
                  }),
                );
              } else {
                String? text;
                if (!prefill) {
                  final messages = body['messages'] as List;
                  final payload = jsonDecode(
                    (messages[1] as Map)['content'] as String,
                  ) as Map;
                  final groups = (payload['evidence'] as List).cast<Map>();
                  final group =
                      groups
                          .where(
                            (g) =>
                                g['isCurrentInput'] != true &&
                                (g['options'] as List).isNotEmpty,
                          )
                          .firstOrNull ??
                      groups.firstWhere(
                        (g) => (g['options'] as List).isNotEmpty,
                      );
                  final option =
                      ((group['options'] as List).first as Map)['optionId'];
                  text = jsonEncode({
                    'selectedOptionIds': [],
                    'gaps': [],
                    'summary': {
                      'text': '已观察到本轮执行材料，具体检查仍以本轮判断为准。',
                      'evidenceOptionIds': [option],
                    },
                  });
                }
                request.response.write(
                  jsonEncode({
                    'object': 'chat.completion',
                    'model': 'fixture-native-response',
                    'choices': [
                      {
                        'index': 0,
                        'finish_reason': prefill ? 'length' : 'stop',
                        'message': {'role': 'assistant', 'content': text},
                      },
                    ],
                    'usage': {
                      'prompt_tokens': 24,
                      'completion_tokens': prefill ? 0 : 8,
                      'total_tokens': prefill ? 24 : 32,
                    },
                  }),
                );
              }
            } else if (request.uri.path.startsWith('/v1/splash/operations/')) {
              final parts = request.uri.pathSegments;
              final id = parts.length >= 4 ? parts[3] : '';
              final job = jobs[id];
              if (job == null ||
                  request.headers.value('x-splash-operation-token') !=
                      job.token) {
                request.response.statusCode = 404;
                request.response.write('{}');
              } else {
                request.response.write(
                  jsonEncode({
                    'operation_id': id,
                    'service_instance': 'fixture-service',
                    'state': 'completed',
                    'terminal': true,
                    'lease_released': true,
                    'children': job.children,
                  }),
                );
              }
            } else {
              request.response.statusCode = 404;
              request.response.write('{}');
            }
          } catch (_) {
            request.response.statusCode = 500;
            request.response.write('{}');
          }
          await request.response.close();
        });
        final runtime = _SyntheticRuntime(
          ledger.publicGeneration('synthetic-fixture'),
          SplashOperationClient(
            endpoint: Uri.parse('http://127.0.0.1:${native.port}'),
          ),
        );
        final service = PublicPrefillService(
          enabled: true,
          ledger: ledger,
          resolve: (path, model) async {
            if (model != instance.publicName) {
              throw StateError('unknown synthetic model');
            }
            return runtime;
          },
        );
        final gateway = PublicGatewayServer(
          routes: routes,
          jevModels: council.models,
          port: 0,
          prefillService: service,
        );
        try {
          await instances.start(instance.id);
          await gateway.start();
          // Machine-readable handoff; every endpoint is loopback and simulated.
          stdout.writeln(
            'GMD_PREFILL_FIXTURE_READY ${jsonEncode({'base_url': gateway.baseUrl.toString(), 'model': instance.publicName, 'shutdown_url': 'http://127.0.0.1:${native.port}/__fixture_shutdown', 'synthetic': true})}',
          );
          await shutdown.future.timeout(const Duration(minutes: 5));
        } finally {
          await gateway.stop();
          await service.close();
          gateway.close();
          routes.close();
          await council.close();
          await instances.close();
          await ledger.close();
          await native.close(force: true);
          await fixture.close();
        }
      }, _NetworkBoundary());
    },
    skip: _enabled ? false : '仅显式启动的隔离联调服务',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

class _Job {
  const _Job(this.token, this.children);
  final String token;
  final List<Map<String, Object?>> children;
}

class _SyntheticRuntime implements PublicPrefillRuntime {
  _SyntheticRuntime(this.generation, this.client);
  @override
  final String generation;
  final SplashOperationClient client;
  @override
  String get owner => 'synthetic-fixture';
  @override
  String get nativeModel => 'fixture-native-request';
  @override
  GenerationConfiguration get defaults => const GenerationConfiguration.empty();
  @override
  bool supportsPrefill(SplashOperationPath path) => true;
  @override
  Future<bool> isCurrent() async => true;
  @override
  Future<T> withClient<T>(
    Future<T> Function(
      SplashOperationClient client,
      String nativeModel,
      String responseModel,
      DecisionCancellation cancellation,
    )
    work, {
    DecisionCancellation? cancellation,
  }) => work(
    client,
    'fixture-native-request',
    'fixture-native-response',
    cancellation ?? DecisionCancellation(),
  );
}

class _NetworkBoundary extends HttpOverrides {}
