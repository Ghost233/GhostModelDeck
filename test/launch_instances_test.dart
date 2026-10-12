import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/engine_runtime.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test(
    'saved copies keep independent parameter snapshots across reopen',
    () async {
      final fixture = await SplashRuntimeFixture.create();
      addTearDown(fixture.close);
      final cpp = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/cpp'),
      );
      final catalog = EngineCatalog(
        library: fixture.library,
        officialEngine: cpp,
        useRegistry: ModelUseRegistry(fixture.library),
        registryFile: File('${fixture.root.path}/engines.json'),
        splashIO: fixture.io,
      );
      addTearDown(() async {
        await catalog.shutdown();
        catalog.close();
        cpp.close();
      });
      final engine = await catalog.link(fixture.source.path);
      final file = File('${fixture.root.path}/launch-instances.json');
      final instances = LaunchInstances(catalog: catalog, file: file);
      addTearDown(instances.close);
      final configuration = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--max-context': '65536'},
        argumentText: '--disable-ane',
      );
      final original = await instances.save(
        name: 'Fast',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: configuration,
      );
      final copy = await instances.copy(original.id);
      expect(copy.id, isNot(original.id));
      expect(original.publicName, 'kev-q8-0');
      expect(copy.publicName, 'kev-q8-0-2');
      await catalog.saveLaunchDefaults(
        engine.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--max-context': '1024'},
        ),
      );
      await instances.save(
        id: original.id,
        name: 'Fast renamed',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--max-context': '2048'},
        ),
      );
      final reopened = LaunchInstances(catalog: catalog, file: file);
      addTearDown(reopened.close);
      await reopened.load();
      expect(reopened.find(original.id)!.publicName, 'kev-q8-0');
      expect(reopened.find(copy.id)!.publicName, 'kev-q8-0-2');
      expect(
        reopened.find(original.id)!.configuration.formValues['--max-context'],
        '2048',
      );
      expect(
        reopened.find(copy.id)!.configuration.formValues['--max-context'],
        '65536',
      );
      expect(
        reopened.find(copy.id)!.configuration.argumentText,
        '--disable-ane',
      );
      expect(
        catalog.runtimes.expand((runtime) => runtime.runtimeInstances),
        isEmpty,
      );
      final validConfiguration = instances.find(original.id)!.configuration;
      final invalidDraft = await instances.save(
        id: original.id,
        name: 'Fast renamed',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          argumentText: "--note 'unterminated",
        ),
      );
      expect(invalidDraft.configuration.argumentText, "--note 'unterminated");
      final restoredDraft = LaunchInstances(catalog: catalog, file: file);
      await restoredDraft.load();
      expect(
        restoredDraft.find(original.id)!.configuration.argumentText,
        "--note 'unterminated",
      );
      await restoredDraft.close();
      await expectLater(
        instances.start(original.id),
        throwsA(isA<LaunchArgumentTextException>()),
      );
      expect(fixture.io.starts, 0);
      await instances.save(
        id: original.id,
        name: 'Fast renamed',
        artifactId: fixture.asset.id,
        engineId: engine.id,
        configuration: validConfiguration,
      );
      final savedBytes = await file.readAsBytes();
      expect(instances.find(original.id)!.name, 'Fast renamed');
      await expectLater(
        instances.save(
          id: original.id,
          name: 'Wrong engine parameters',
          artifactId: fixture.asset.id,
          engineId: engine.id,
          configuration: EngineLaunchConfiguration(),
        ),
        throwsArgumentError,
      );
      expect(await file.readAsBytes(), savedBytes);
      await instances.renamePublicName(original.id, 'FAST Test');
      expect(instances.find(original.id)!.publicName, 'fast-test');
      expect(instances.find(original.id)!.name, 'Fast renamed');
      final renamedBytes = await file.readAsBytes();
      await expectLater(
        instances.renamePublicName(copy.id, 'fast-test'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'suggestion',
            contains('fast-test-2'),
          ),
        ),
      );
      expect(await file.readAsBytes(), renamedBytes);
      expect(instances.find(copy.id)!.publicName, 'kev-q8-0-2');
    },
  );

  test(
    'new instance registry does not import model launch overrides',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-fresh-instances-',
      );
      addTearDown(() => root.delete(recursive: true));
      final library = ModelLibrary();
      addTearDown(library.close);
      final usage = ModelUseRegistry(library);
      final engine = LlamaEngine(
        library: library,
        useRegistry: usage,
        installationDirectory: Directory('${root.path}/engine'),
      );
      final registry = File('${root.path}/engines.json');
      await registry.writeAsString(
        jsonEncode({
          'schema': 4,
          'linked': [],
          'launchDefaults': {},
          'modelLaunchOverrides': {
            EngineCatalog.officialId: {
              'old-model': {
                'enabled': true,
                'configuration': EngineLaunchConfiguration(
                  argumentText: '--reasoning off',
                ).toJson(),
              },
            },
          },
        }),
      );
      final catalog = EngineCatalog(
        library: library,
        officialEngine: engine,
        useRegistry: usage,
        registryFile: registry,
      );
      addTearDown(catalog.close);
      await catalog.refresh();
      final file = File('${root.path}/launch-instances.json');
      final instances = LaunchInstances(catalog: catalog, file: file);
      addTearDown(instances.close);
      await instances.load();
      expect(instances.definitions, isEmpty);
      final reopened = LaunchInstances(catalog: catalog, file: file);
      addTearDown(reopened.close);
      await reopened.load();
      expect(reopened.definitions, isEmpty);
      expect(jsonDecode(await file.readAsString()), {
        'schema': 1,
        'instances': [],
      });
    },
  );
}
