import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_labels.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/managed_engine_release.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/omlx_engine.dart';
import 'package:ghost_model_deck/launch_instances.dart';

import 'fixtures/engine_archive.dart';

void main() {
  test('retired mainline variant IDs keep the saved instance and parameter snapshot', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final original = LaunchInstance(
      id: 'instance-saved',
      name: 'EmbeddingGemma',
      publicName: 'embedding-kept',
      artifactId: 'saved-artifact',
      engineId: EngineCatalog.embeddingId,
      configuration: EngineLaunchConfiguration(
        formValues: {'--ctx-size': '8192'},
      ),
      revision: 3,
      jevRequestTimeoutSeconds: 91,
      hasAppliedContext: true,
      appliedContextLength: 8192,
    );
    final file = File('${fixture.root.path}/instances.json');
    await file.writeAsString(
      jsonEncode({
        'schema': 1,
        'instances': [original.toJson()],
      }),
    );
    final instances = LaunchInstances(catalog: fixture.catalog, file: file);
    addTearDown(instances.close);
    await instances.load();
    expect(instances.definitions.single.toJson(), {
      ...original.toJson(),
      'engine_id': EngineCatalog.officialId,
    });
    expect(
      jsonDecode(await file.readAsString())['instances'][0]['engine_id'],
      EngineCatalog.officialId,
    );
  });

  testWidgets(
    'managed mainline rows expose download and update without a JEV branch',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        await fixture.catalog.installManaged(
          EngineCatalog.officialId,
          verifiedArchive: fixture.oldArchive,
        );
        fixture.client.release = ManagedEngineRelease(
          family: EngineFamily.llamaCpp,
          tag: fixture.initialRelease.tag,
          artifactTag: fixture.initialRelease.artifactTag,
          commit: fixture.initialRelease.commit,
          url: fixture.initialRelease.url,
          sha256: fixture.initialRelease.sha256,
          sizeBytes: fixture.initialRelease.sizeBytes,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EnginePage(
                catalog: fixture.catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await fixture.catalog.refresh();
      });
      await tester.pumpAndSettle();
      expect(find.text('下载最新'), findsOneWidget);
      expect(find.textContaining('JEV'), findsNothing);
      final update = find.byKey(
        ValueKey('engine-update:${EngineCatalog.officialId}'),
      );
      await tester.ensureVisible(update);
      await tester.runAsync(() async {
        await tester.tap(update);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(fixture.client.calls, 1);
      expect(find.textContaining('当前使用上游最新发行'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'default managed channels have one llama mainline and one oMLX',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      expect(fixture.catalog.state.entries, hasLength(2));
      expect(
        fixture.catalog.state.entries.map(engineDisplayName).join(),
        isNot(contains('JEV')),
      );
      expect(
        fixture.catalog.canUpdateManaged(EngineCatalog.officialId),
        isTrue,
      );
      expect(fixture.catalog.canUpdateManaged(EngineCatalog.omlxId), isTrue);
      expect(mainlineLlamaRelease.buildNumber, greaterThanOrEqualTo(11773));
      expect(mainlineLlamaRelease.supportsSystemone, isTrue);
    },
  );

  test('mainline update preserves identity, old files and selected release after reload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.catalog.installManaged(
      EngineCatalog.officialId,
      verifiedArchive: fixture.oldArchive,
    );
    final oldBinary = fixture.engine.executablePath!;
    await fixture.catalog.updateManaged(
      EngineCatalog.officialId,
      verifiedArchive: fixture.newArchive,
    );
    expect(fixture.engine.release.tag, 'v0.9.0');
    expect(fixture.engine.release.supportsSystemone, isTrue);
    expect(fixture.engine.installationId, EngineCatalog.officialId);
    expect(await File(oldBinary).exists(), isTrue);
    final saved = jsonDecode(await fixture.registry.readAsString()) as Map;
    expect(
      saved['managedReleases'][EngineCatalog.officialId]['artifactTag'],
      'b12110',
    );
    final reopened = fixture.reopen();
    addTearDown(() async {
      await reopened.shutdown();
      reopened.close();
      reopened.officialEngine.close();
    });
    await reopened.refresh();
    expect(reopened.officialEngine.release.tag, 'v0.9.0');
    expect(
      reopened.state.entries.single.status,
      LlamaInstallationStatus.installed,
    );
    expect(fixture.client.calls, 1);
  });

  test('failed update keeps the original installation and registry', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.catalog.installManaged(
      EngineCatalog.officialId,
      verifiedArchive: fixture.oldArchive,
    );
    final before = await fixture.registry.readAsString();
    final original = fixture.engine.release;
    final bytes = await fixture.newArchive.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    final invalid = await File('${fixture.root.path}/invalid.tar.gz')
        .writeAsBytes(bytes);
    await expectLater(
      fixture.catalog.updateManaged(
        EngineCatalog.officialId,
        verifiedArchive: invalid,
      ),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(fixture.engine.release, same(original));
    expect(
      fixture.engine.state.installation,
      LlamaInstallationStatus.installed,
    );
    expect(await fixture.registry.readAsString(), before);
    expect(
      await Directory('${fixture.installation.path}/v0.9.0').exists(),
      isFalse,
    );
  });

  test('duplicate update shares metadata work and shutdown prevents late installation', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.catalog.installManaged(
      EngineCatalog.officialId,
      verifiedArchive: fixture.oldArchive,
    );
    final before = await fixture.registry.readAsString();
    final original = fixture.engine.release;
    fixture.client.lookup = Completer<ManagedEngineRelease>();
    final update = fixture.catalog.updateManaged(
      EngineCatalog.officialId,
      verifiedArchive: fixture.newArchive,
    );
    expect(
      fixture.catalog.updateManaged(EngineCatalog.officialId),
      same(update),
    );
    final rejected = expectLater(update, throwsA(isA<LlamaEngineException>()));
    await fixture.client.lookupStarted.future;
    expect(
      fixture.catalog.managedOperationActive(EngineCatalog.officialId),
      isTrue,
    );
    await fixture.catalog.shutdown();
    fixture.client.lookup!.complete(fixture.client.release);
    await rejected;
    expect(fixture.client.calls, 1);
    expect(
      fixture.catalog.managedOperationActive(EngineCatalog.officialId),
      isFalse,
    );
    expect(fixture.engine.release, same(original));
    expect(await fixture.registry.readAsString(), before);
    expect(
      await Directory('${fixture.installation.path}/v0.9.0').exists(),
      isFalse,
    );
  });
}

class _ReleaseClient extends ManagedEngineReleaseClient {
  _ReleaseClient(this.release);
  ManagedEngineRelease release;
  int calls = 0;
  Completer<ManagedEngineRelease>? lookup;
  final lookupStarted = Completer<void>();
  @override
  Future<ManagedEngineRelease> latest(EngineFamily family) async {
    calls++;
    if (!lookupStarted.isCompleted) lookupStarted.complete();
    return lookup?.future ?? release;
  }
}

class _IO extends NativeEngineProcessIO {
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable.endsWith('/llama-server')) {
      return const EngineCommandResult(
        0,
        'version: 0.9.0-dev (build 12110, commit cd959bae9)\nbuilt for Darwin arm64',
        '',
      );
    }
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    return super.run(executable, arguments, timeout: timeout);
  }
}

class _Fixture {
  _Fixture(
    this.root,
    this.library,
    this.engine,
    this.catalog,
    this.client,
    this.oldArchive,
    this.newArchive,
    this.initialRelease,
  );
  final Directory root;
  final ModelLibrary library;
  final LlamaEngine engine;
  final EngineCatalog catalog;
  final _ReleaseClient client;
  final File oldArchive, newArchive;
  final LlamaRelease initialRelease;
  Directory get installation => engine.installationDirectory;
  File get registry => File('${root.path}/engines.json');

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('mainline-catalog-');
    final oldBytes = engineArchive(artifactTag: 'b11923');
    final newBytes = engineArchive(artifactTag: 'b12110');
    final oldArchive = await File('${root.path}/old.tar.gz')
        .writeAsBytes(oldBytes);
    final newArchive = await File('${root.path}/new.tar.gz')
        .writeAsBytes(newBytes);
    final initialRelease = LlamaRelease(
      tag: 'v0.8.0',
      artifactTag: 'b11923',
      expectedBuild: 11923,
      commit: 'c' * 40,
      url: Uri.parse(
        'https://github.com/ggml-org/llama.cpp/releases/download/b11923/llama-b11923-bin-macos-arm64.tar.gz',
      ),
      sha256: sha256.convert(oldBytes).toString(),
      sizeBytes: oldBytes.length,
    );
    final client = _ReleaseClient(
      ManagedEngineRelease(
        family: EngineFamily.llamaCpp,
        tag: 'v0.9.0',
        artifactTag: 'b12110',
        commit: 'cd959bae99ff4bed22bef2604f45241c09bbb8c8',
        url: mainlineLlamaRelease.url,
        sha256: sha256.convert(newBytes).toString(),
        sizeBytes: newBytes.length,
      ),
    );
    final library = ModelLibrary();
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/llama'),
      release: initialRelease,
      io: _IO(),
      installationId: EngineCatalog.officialId,
    );
    final registry = File('${root.path}/engines.json');
    await registry.writeAsString('{"schema":1,"linked":[]}');
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      releaseClient: client,
      registryFile: registry,
      omlxEngine: OmlxEngine(
        installationDirectory: Directory('${root.path}/omlx'),
      ),
      useRegistry: ModelUseRegistry(library),
    );
    return _Fixture(
      root,
      library,
      engine,
      catalog,
      client,
      oldArchive,
      newArchive,
      initialRelease,
    );
  }

  EngineCatalog reopen() => EngineCatalog(
    library: library,
    officialEngine: LlamaEngine(
      library: library,
      installationDirectory: installation,
      release: initialRelease,
      io: _IO(),
      installationId: EngineCatalog.officialId,
    ),
    releaseClient: client,
    registryFile: registry,
    useRegistry: ModelUseRegistry(library),
  );

  Future<void> close() async {
    await catalog.shutdown();
    catalog.close();
    catalog.omlxEngine?.close();
    engine.close();
    library.close();
    await root.delete(recursive: true);
  }
}
