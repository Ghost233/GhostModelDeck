import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_prefill_service.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test(
    'current GMD advertises prefill as unavailable for each callable path',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final runtime = await CouncilRuntime.create(
          modelCount: 1,
          sourceSystemone: true,
        );
        runtime.io.capacityProperties = {
          'total_slots': 1,
          'default_generation_settings': {'n_ctx': 8192},
        };
        final instances = LaunchInstances(
          catalog: runtime.catalog,
          file: File('${runtime.root.path}/instances.json'),
        );
        final instance = await instances.save(
          name: 'Prefill discovery',
          artifactId: runtime.library.state.artifacts.single.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        );
        final council = CouncilController(
          catalog: runtime.catalog,
          launchInstances: instances,
        );
        final routes = PublicModelRoutes(
          library: runtime.library,
          instances: instances,
          runtimes: runtime.catalog.runtimes.toList(),
        );
        var resolutions = 0;
        final gateway = PublicGatewayServer(
          routes: routes,
          jevModels: council.models,
          port: 0,
          prefillServiceFactory: () async => PublicPrefillService(
            ledger: await PrefillOperationLedger.open(
              File('${runtime.root.path}/prefill.json'),
            ),
            resolve: (path, model) async {
              resolutions++;
              throw StateError('disabled');
            },
          ),
        );
        final client = HttpClient();
        try {
          await instances.start(instance.id);
          await gateway.start();
          final request = await client.getUrl(
            gateway.baseUrl!.resolve('/api/v1/models'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          final document =
              jsonDecode(await utf8.decoder.bind(response).join()) as Map;
          final rows = (document['models'] as List)
              .where((row) => row['key'] == instance.publicName)
              .toList();
          expect(
            rows.map((row) => row['type']),
            containsAll(['llm', 'decision']),
          );
          for (final row in rows) {
            expect(row['capabilities']['prefill'], {
              'protocol': 'gmd-prefill/1',
              'supported': false,
              'mode': row['type'] == 'llm'
                  ? 'chat_max_tokens_zero'
                  : 'systemone_state',
              'reason': 'gmd_prefill_unavailable',
            });
          }
          expect(resolutions, 0);
          Future<(int, Map)> post(
            String path,
            Map<String, Object?> body,
          ) async {
            final request = await client.postUrl(
              gateway.baseUrl!.resolve(path),
            );
            request.headers.contentType = ContentType.json;
            request.write(jsonEncode(body));
            final response = await request.close();
            return (
              response.statusCode,
              jsonDecode(await utf8.decoder.bind(response).join()) as Map,
            );
          }

          final chat = {
            'model': instance.publicName,
            'messages': [
              {'role': 'user', 'content': 'Hello'},
            ],
          };
          expect(
            (await post('/v1/chat/completions', {...chat, 'max_tokens': 0})).$1,
            400,
          );
          final result = await post('/v1/chat/completions', {
            ...chat,
            'max_tokens': 8,
          });
          expect(result.$1, 200);
          expect(result.$2['choices'][0]['message']['content'], 'Hello.');
          final decision = await post('/v1/systemone', {
            'model': instance.publicName,
            'state': 'Choose',
            'questions': {
              'pick': {
                'type': 'choice',
                'instructions': 'Choose',
                'criteria': {'a': 'A', 'b': 'B'},
              },
            },
          });
          expect(decision.$1, 200);
          expect(decision.$2['answers'], contains('pick'));
        } finally {
          client.close(force: true);
          await gateway.stop();
          gateway.close();
          routes.close();
          await council.close();
          await instances.close();
          await runtime.close();
        }
      }, _NetworkBoundary());
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
