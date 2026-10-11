import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/jev_models.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('decision discovery reports observed per-slot capacity and revokes stopped routes', () async {
    final runtime = await CouncilRuntime.create();
    addTearDown(runtime.close);
    final council = CouncilController(catalog: runtime.catalog);
    addTearDown(council.close);
    final bindings = council.models.availableBindings;
    await council.models.save(
      JevModelDefinition.native(name: 'native', binding: bindings.first),
    );
    await council.models.save(
      JevModelDefinition.council(
        name: 'council',
        seats: bindings,
        timeout: const Duration(seconds: 10),
      ),
    );
    expect(council.models.capacityModels(), isEmpty);
    for (final instance in runtime.engine.state.instances.toList()) {
      await runtime.engine.stop(instance.id);
    }
    runtime.io.capacityProperties = {
      'default_generation_settings': {'n_ctx': 8192},
      'total_slots': 2,
    };
    for (final binding in bindings) {
      await runtime.engine.start(binding.artifactId);
    }
    final rows = council.models.capacityModels();
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row['source'], 'ghost-model-deck');
      expect(row['type'], 'decision');
      expect(row['loaded_instances'], [
        {
          'id': row['key'],
          'config': {'context_length': 8192, 'max_concurrent_requests': 2},
        },
      ]);
    }
    expect(rows.singleWhere((r) => r['key'] == 'council')['virtual'], isTrue);
    for (final instance in runtime.engine.state.instances.toList()) {
      if (instance.hasLiveProcess) await runtime.engine.stop(instance.id);
    }
    expect(council.models.capacityModels(), isEmpty);
  });
}
