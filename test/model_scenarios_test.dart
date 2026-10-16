import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_scenarios.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/decision_gguf.dart';

Future<(CouncilRuntime, LaunchInstances, LaunchInstance)> fixture() async {
  final runtime = await CouncilRuntime.create(
    modelCount: 0,
    sourceSystemone: true,
  );
  final directory = Directory('${runtime.root.path}/models');
  await writeDecisionKev(directory, ordinaryChat: true);
  await runtime.library.scan(directory);
  final instances = LaunchInstances(
    catalog: runtime.catalog,
    file: File('${runtime.root.path}/instances.json'),
  );
  final instance = await instances.save(
    name: 'Saved model',
    artifactId: runtime.library.state.artifacts.single.id,
    engineId: EngineCatalog.officialId,
    configuration: EngineLaunchConfiguration(),
  );
  addTearDown(() async {
    await instances.close();
    await runtime.close();
  });
  return (runtime, instances, instance);
}

void main() {
  test('reopening preserves four slots, Chinese descriptions, names and saved instance identities', () async {
    final (runtime, instances, instance) = await fixture();
    final file = File('${runtime.root.path}/scenarios.json');
    final first = ModelScenarios(
      file: file,
      names: instances.names,
      instances: instances,
    );
    await first.load();
    expect(first.entries.map((entry) => entry.displayName), [
      '短上下文',
      '长上下文',
      '短上下文＋视觉',
      '长上下文＋视觉',
    ]);
    await first.save(
      0,
      ModelScenario(
        displayName: '4k上线+视觉',
        modelName: 'fast-v',
        instanceId: instance.id,
        enabled: false,
      ),
    );
    await first.close();
    final reopened = ModelScenarios(
      file: file,
      names: instances.names,
      instances: instances,
    );
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.entries, hasLength(4));
    final saved = reopened.entries.first;
    expect(saved.displayName, '4k上线+视觉');
    expect(saved.modelName, 'fast-v');
    expect(saved.instanceId, instance.id);
    expect(saved.enabled, isFalse);
    expect(reopened.entries.skip(1).every((entry) => entry.enabled), isTrue);
    expect(runtime.engine.state.instances, isEmpty);
  });

  test('failed persistence keeps the old selection and releases only the newly proposed name', () async {
    final (runtime, instances, instance) = await fixture();
    final file = File('${runtime.root.path}/scenarios.json');
    final scenarios = ModelScenarios(
      file: file,
      names: instances.names,
      instances: instances,
    );
    addTearDown(scenarios.close);
    await scenarios.save(
      0,
      ModelScenario(
        displayName: 'Original',
        modelName: 'fast-v',
        instanceId: instance.id,
      ),
    );
    final obstruction = Directory('${file.path}.tmp');
    await obstruction.create();
    await expectLater(
      scenarios.save(
        0,
        ModelScenario(
          displayName: 'Changed',
          modelName: 'new-fast',
          instanceId: instance.id,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(scenarios.entries.first.displayName, 'Original');
    expect(scenarios.entries.first.modelName, 'fast-v');
    await expectLater(
      instances.renamePublicName(instance.id, 'fast-v'),
      throwsStateError,
    );
    await instances.renamePublicName(instance.id, 'new-fast');
    expect(instances.find(instance.id)!.publicName, 'new-fast');
    await obstruction.delete();
    await scenarios.close();
    final reopened = ModelScenarios(
      file: file,
      names: instances.names,
      instances: instances,
    );
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.entries.first.modelName, 'fast-v');
    expect(reopened.entries.first.displayName, 'Original');
    expect(runtime.engine.state.instances, isEmpty);
  });

  test(
    'a scene cannot take an actual model name or another slot name',
    () async {
      final (runtime, instances, instance) = await fixture();
      final scenarios = ModelScenarios(
        names: instances.names,
        instances: instances,
      );
      addTearDown(scenarios.close);
      await expectLater(
        scenarios.save(
          0,
          ModelScenario(
            displayName: 'Conflict',
            modelName: instance.publicName,
            instanceId: instance.id,
          ),
        ),
        throwsStateError,
      );
      await scenarios.save(
        0,
        ModelScenario(
          displayName: 'Saved',
          modelName: 'fast-v',
          instanceId: instance.id,
        ),
      );
      await expectLater(
        scenarios.save(
          1,
          ModelScenario(
            displayName: 'Another',
            modelName: 'fast-v',
            instanceId: instance.id,
          ),
        ),
        throwsFormatException,
      );
      expect(scenarios.entries.first.modelName, 'fast-v');
      expect(scenarios.entries[1].modelName, isEmpty);
      expect(runtime.engine.state.instances, isEmpty);
    },
  );
}
