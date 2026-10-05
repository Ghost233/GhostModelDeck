import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/engine_archive.dart';

void main() {
  for (final standard in [false, true]) {
    test(
      '${standard ? 'standard' : 'JEV'} managed marker and complete inventory survive reopen but reject false version and corruption',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-managed-integrity-',
        );
        addTearDown(() => root.delete(recursive: true));
        final library = ModelLibrary();
        addTearDown(library.close);
        final data = engineArchive(artifactTag: standard ? 'b11146' : 'b11381');
        final archive = await File('${root.path}/archive.tar.gz')
            .writeAsBytes(data);
        final release = LlamaRelease(
          tag: standard ? 'v0.5.0' : 'b11381',
          artifactTag: standard ? 'b11146' : 'b11381',
          expectedBuild: standard ? 11146 : 11381,
          expectedBinaryVersion: '0.5.0-dev',
          supportsSystemone: !standard,
          commit: standard
              ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
              : '836d57176',
          url: Uri.parse('https://github.com/fixture'),
          sha256: sha256.convert(data).toString(),
          sizeBytes: data.length,
        );
        final io = standard ? _StandardIO() : _ManagedIO();
        final directory = Directory('${root.path}/owned');
        final original = LlamaEngine(
          library: library,
          installationDirectory: directory,
          release: release,
          io: io,
        );
        addTearDown(original.close);
        await original.install(verifiedArchive: archive);
        final reopened = LlamaEngine(
          library: library,
          installationDirectory: directory,
          release: release,
          io: io,
        );
        addTearDown(reopened.close);
        await reopened.refreshInstallation();
        expect(reopened.state.installation, LlamaInstallationStatus.installed);
        final marker = File(
          '${directory.path}/${release.tag}/installation.json',
        );
        final text = await marker.readAsString();
        final value = jsonDecode(text) as Map<String, dynamic>;
        expect(value['artifactRoot'], release.archiveRoot);
        expect(value['expectedBuild'], release.buildNumber);
        expect(value['files'], contains('llama-server'));
        value['version'] =
            '${value['version']}\nMetal initialization diagnostic';
        await marker.writeAsString(jsonEncode(value));
        await reopened.refreshInstallation();
        expect(reopened.state.installation, LlamaInstallationStatus.installed);
        value['version'] = 'version: 0.5.0 release (fabricated)';
        await marker.writeAsString(jsonEncode(value));
        await reopened.refreshInstallation();
        expect(reopened.state.installation, LlamaInstallationStatus.failed);
        expect(reopened.executablePath, isNull);
        expect(reopened.binarySha256, isNull);
        expect(reopened.observedVersion, isNull);
        await marker.writeAsString(text);
        await reopened.refreshInstallation();
        expect(reopened.state.installation, LlamaInstallationStatus.installed);
        final extra = await File(
          '${directory.path}/${release.tag}/foreign.dylib',
        ).writeAsString('unexpected dependency');
        await reopened.refreshInstallation();
        expect(reopened.state.installation, LlamaInstallationStatus.failed);
        await extra.delete();
        final binary = File('${directory.path}/${release.tag}/llama-server');
        await binary.writeAsString('changed binary');
        await reopened.refreshInstallation();
        expect(reopened.state.installation, LlamaInstallationStatus.failed);
        await expectLater(
          reopened.install(verifiedArchive: archive),
          throwsA(isA<LlamaEngineException>()),
        );
        expect(await binary.readAsString(), 'changed binary');
      },
    );
  }
  for (final output in [
    'version: 0.5.0 (build 11146, commit 7fe450e19)\nbuilt for Darwin arm64',
    'version: 0.5.0-dev (build 11381, commit 7fe450e19)\nbuilt for Darwin arm64',
    'version: 0.5.0-dev (build 11146, commit 000000000)\nbuilt for Darwin arm64',
    'version: 0.5.0-dev (build 11146, commit 7fe450e19)\nbuilt for Darwin x86_64',
  ]) {
    test(
      'fixed standard installation rejects inaccurate observed identity: $output',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-standard-invalid-',
        );
        addTearDown(() => root.delete(recursive: true));
        final library = ModelLibrary();
        addTearDown(library.close);
        final data = engineArchive(artifactTag: 'b11146');
        final archive = await File('${root.path}/archive.tar.gz')
            .writeAsBytes(data);
        final engine = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/owned'),
          io: _ObservedIO(output),
          release: LlamaRelease(
            tag: standardLlamaRelease.tag,
            artifactTag: standardLlamaRelease.artifactTag,
            expectedBuild: standardLlamaRelease.expectedBuild,
            expectedBinaryVersion: standardLlamaRelease.expectedBinaryVersion,
            supportsSystemone: false,
            commit: standardLlamaRelease.commit,
            url: standardLlamaRelease.url,
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        );
        addTearDown(engine.close);
        await expectLater(
          engine.install(verifiedArchive: archive),
          throwsA(isA<LlamaEngineException>()),
        );
        expect(engine.state.installation, LlamaInstallationStatus.failed);
        expect(engine.executablePath, isNull);
        expect(engine.state.instances, isEmpty);
        expect(await Directory('${root.path}/owned/v0.5.0').exists(), isFalse);
      },
    );
  }
  test('semantic v0.5.0 installs its same-commit b11146 archive without inventing a release binary version', () async {
    final root = await Directory.systemTemp.createTemp('gmd-semantic-install-');
    addTearDown(() => root.delete(recursive: true));
    final data = engineArchive(artifactTag: 'b11146');
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(data);
    final library = ModelLibrary();
    addTearDown(library.close);
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      io: _StandardIO(),
      release: LlamaRelease(
        tag: 'v0.5.0',
        artifactTag: 'b11146',
        expectedBuild: 11146,
        commit: '7fe450e19305b828c199d602c23a8337aaa1f03b',
        url: Uri.parse('https://github.com/fixture/b11146'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
    );
    addTearDown(engine.close);
    await engine.install(verifiedArchive: archive);
    expect(engine.state.installation, LlamaInstallationStatus.installed);
    expect(
      engine.observedVersion,
      contains('0.5.0-dev (build 11146, commit 7fe450e19)'),
    );
    expect(engine.state.instances, isEmpty);
    await engine.refreshInstallation();
    expect(engine.state.installation, LlamaInstallationStatus.installed);
  });
  test('two managed selections retain separate archive and binary identity and removal scope', () async {
    final root = await Directory.systemTemp.createTemp('gmd-dual-managed-');
    addTearDown(() => root.delete(recursive: true));
    final library = ModelLibrary();
    addTearDown(library.close);
    final use = ModelUseRegistry(library);
    final owned = Directory('${root.path}/owned');
    final engines = <LlamaEngine>[];
    final archives = <File>[];
    for (final standard in [false, true]) {
      final data = engineArchive(artifactTag: standard ? 'b11146' : 'b11381');
      archives.add(
        await File('${root.path}/${standard ? 'standard' : 'jev'}.tar.gz')
            .writeAsBytes(data),
      );
      engines.add(
        LlamaEngine(
          library: library,
          installationDirectory: owned,
          useRegistry: use,
          io: standard ? _StandardIO() : _ManagedIO(),
          release: LlamaRelease(
            tag: standard ? 'v0.5.0' : 'b11381',
            artifactTag: standard ? 'b11146' : 'b11381',
            expectedBuild: standard ? 11146 : 11381,
            commit: standard
                ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                : '836d57176',
            url: Uri.parse(
              'https://github.com/fixture/${standard ? 'b11146' : 'b11381'}',
            ),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        ),
      );
      addTearDown(engines.last.close);
    }
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engines.first,
      standardEngine: engines.last,
      useRegistry: use,
      registryFile: File('${root.path}/registry.json'),
    );
    addTearDown(catalog.close);
    expect(catalog.state.entries, hasLength(2));
    expect(
      catalog.state.entries.every(
        (e) => e.status == LlamaInstallationStatus.absent,
      ),
      isTrue,
    );
    await catalog
        .providerFor(EngineCatalog.standardId)
        .install(verifiedArchive: archives.last);
    await catalog.installOfficial(verifiedArchive: archives.first);
    await catalog.refresh();
    final standard = catalog.state.entries.singleWhere(
      (e) => e.id == EngineCatalog.standardId,
    );
    expect(standard.release!.tag, 'v0.5.0');
    expect(standard.release!.archiveRoot, 'llama-b11146');
    expect(standard.binaryVersion!.semanticVersion, '0.5.0-dev');
    expect(standard.binaryVersion!.build, 11146);
    expect(
      standard.binarySha256,
      '1e4556a3af5b64777d8d102f3404c84d4a28d50ebc931e0098e27916acdb92eb',
    );
    expect(standard.archiveSha256, isNot(standard.binarySha256));
    expect(standard.installationId, EngineCatalog.standardId);
    final plan = await catalog.prepareRemoval(EngineCatalog.standardId);
    await catalog.remove(plan, confirmed: true);
    expect(engines.last.executablePath, isNull);
    expect(engines.first.state.installation, LlamaInstallationStatus.installed);
    expect(await File(engines.first.executablePath!).exists(), isTrue);
  });

  test('linking registers observed local content and version without copying or owning the external engine', () async {
    final root = await Directory.systemTemp.createTemp('jev-engine-link-');
    addTearDown(() => root.delete(recursive: true));
    final external = Directory('${root.path}/external');
    await external.create();
    final binary = await File('${external.path}/llama-server')
        .writeAsString('local native engine fixture');
    await Process.run('/bin/chmod', ['+x', binary.path]);
    final before = await binary.stat();
    final library = ModelLibrary();
    addTearDown(library.close);
    final use = ModelUseRegistry(library);
    final official = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      io: _LinkIO(),
      useRegistry: use,
    );
    addTearDown(official.close);
    final catalog = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
      io: _LinkIO(),
    );
    addTearDown(catalog.close);

    final entry = await catalog.link(external.path);

    expect(entry.source, EngineSource.linked);
    expect(entry.status, LlamaInstallationStatus.installed);
    expect(entry.version, contains('build 12000, commit abcdef123'));
    expect(entry.path, await binary.resolveSymbolicLinks());
    expect(
      entry.sha256,
      '791fc5ec9286fdc6c4a53a6b43f0d11f43792f632436a8c225db3ff88a851536',
    );
    expect((await binary.stat()).modified, before.modified);
    expect(await Directory('${root.path}/owned').exists(), isFalse);
    expect(catalog.providerFor(entry.id).executablePath, entry.path);
  });

  test('removing a persisted local association preserves every external engine file', () async {
    final root = await Directory.systemTemp.createTemp('jev-engine-unlink-');
    addTearDown(() => root.delete(recursive: true));
    final external = Directory('${root.path}/external');
    await external.create();
    final binary = await File('${external.path}/llama-server')
        .writeAsString('local native engine fixture');
    await Process.run('/bin/chmod', ['+x', binary.path]);
    final companion = await File('${external.path}/libllama.dylib')
        .writeAsString('external dependency');
    final library = ModelLibrary();
    addTearDown(library.close);
    final use = ModelUseRegistry(library);
    final official = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      io: _LinkIO(),
      useRegistry: use,
    );
    addTearDown(official.close);
    final record = File('${root.path}/private/engines.json');
    final first = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: record,
      io: _LinkIO(),
    );
    final entry = await first.link(external.path);
    first.close();
    final reopened = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: record,
      io: _LinkIO(),
    );
    addTearDown(reopened.close);
    await reopened.refresh();
    expect(
      reopened.state.entries
          .singleWhere((value) => value.id == entry.id)
          .source,
      EngineSource.linked,
    );

    final plan = await reopened.prepareRemoval(entry.id);
    expect(plan.paths, isEmpty);
    await reopened.remove(plan, confirmed: false);
    expect(reopened.state.entries, hasLength(2));
    await reopened.remove(plan, confirmed: true);
    expect(reopened.state.entries, hasLength(1));
    expect(await binary.readAsString(), 'local native engine fixture');
    expect(await companion.readAsString(), 'external dependency');
    final again = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: record,
      io: _LinkIO(),
    );
    addTearDown(again.close);
    await again.refresh();
    expect(again.state.entries, hasLength(1));
  });

  test('dependency link changes invalidate an association even when both library contents stay unchanged', () async {
    final root = await Directory.systemTemp.createTemp(
      'jev-engine-dependencies-',
    );
    addTearDown(() => root.delete(recursive: true));
    final external = Directory('${root.path}/external');
    await external.create();
    final binary = await File('${external.path}/llama-server')
        .writeAsString('local native engine fixture');
    await Process.run('/bin/chmod', ['+x', binary.path]);
    await File('${external.path}/one.dylib').writeAsString('library one');
    await File('${external.path}/two.dylib').writeAsString('library two');
    final link = await Link('${external.path}/libllama.dylib')
        .create('one.dylib');
    final library = ModelLibrary();
    addTearDown(library.close);
    final use = ModelUseRegistry(library);
    final official = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/owned'),
      io: _LinkIO(),
      useRegistry: use,
    );
    addTearDown(official.close);
    final catalog = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
      io: _LinkIO(),
    );
    addTearDown(catalog.close);
    final entry = await catalog.link(external.path);
    await link.update('two.dylib');

    await catalog.refresh();

    expect(
      catalog.state.entries.singleWhere((value) => value.id == entry.id).status,
      LlamaInstallationStatus.failed,
    );
    expect(catalog.providerFor(entry.id).executablePath, isNull);
  });

  test('managed engine removal confirms an exact installation range and preserves sibling files', () async {
    final root = await Directory.systemTemp.createTemp('jev-engine-remove-');
    addTearDown(() => root.delete(recursive: true));
    final data = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(data);
    final library = ModelLibrary();
    addTearDown(library.close);
    final use = ModelUseRegistry(library);
    final owned = Directory('${root.path}/owned');
    await owned.create();
    final sibling = await File('${owned.path}/keep.txt')
        .writeAsString('unrelated file');
    final official = LlamaEngine(
      library: library,
      installationDirectory: owned,
      io: _ManagedIO(),
      useRegistry: use,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
    );
    addTearDown(official.close);
    final catalog = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
    );
    addTearDown(catalog.close);
    await catalog.installOfficial(verifiedArchive: archive);

    final plan = await catalog.prepareRemoval(EngineCatalog.officialId);
    expect(plan.paths, hasLength(2));
    expect(
      plan.paths.any((path) => path.endsWith('/b11381/llama-server')),
      isTrue,
    );
    expect(
      plan.paths.any((path) => path.endsWith('/b11381/installation.json')),
      isTrue,
    );
    expect(plan.paths.contains(sibling.path), isFalse);
    var actualSize = 0;
    for (final path in plan.paths) {
      actualSize += await File(path).length();
    }
    expect(plan.sizeBytes, actualSize);
    await catalog.remove(plan, confirmed: false);
    expect(official.state.installation, LlamaInstallationStatus.installed);
    await catalog.remove(plan, confirmed: true);
    expect(official.state.installation, LlamaInstallationStatus.absent);
    expect(await Directory('${owned.path}/b11381').exists(), isFalse);
    expect(await sibling.readAsString(), 'unrelated file');
    expect(await archive.exists(), isTrue);
  });

  test('a fresh catalog cannot register its own installed engine as an unowned association', () async {
    final root = await Directory.systemTemp.createTemp(
      'jev-engine-owned-link-',
    );
    addTearDown(() => root.delete(recursive: true));
    final data = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(data);
    final library = ModelLibrary();
    addTearDown(library.close);
    final use = ModelUseRegistry(library);
    final release = LlamaRelease(
      tag: 'b11381',
      commit: '836d57176',
      url: Uri.parse('https://github.com/fixture'),
      sha256: sha256.convert(data).toString(),
      sizeBytes: data.length,
    );
    final owned = Directory('${root.path}/owned');
    final original = LlamaEngine(
      library: library,
      installationDirectory: owned,
      io: _ManagedIO(),
      release: release,
      useRegistry: use,
    );
    addTearDown(original.close);
    await original.install(verifiedArchive: archive);
    final fresh = LlamaEngine(
      library: library,
      installationDirectory: owned,
      io: _ManagedIO(),
      release: release,
      useRegistry: use,
    );
    addTearDown(fresh.close);
    final catalog = EngineCatalog(
      library: library,
      officialEngine: fresh,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
      io: _ManagedIO(),
    );
    addTearDown(catalog.close);
    await expectLater(
      catalog.link('${owned.path}/b11381'),
      throwsA(
        isA<LlamaEngineException>().having(
          (error) => error.message,
          'reason',
          contains('已由本应用管理'),
        ),
      ),
    );
    expect(catalog.state.entries, hasLength(1));
    expect(await catalog.registryFile.exists(), isFalse);
  });
}

class _LinkIO implements EngineProcessIO {
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.single == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 12000, commit abcdef123)\nbuilt for Darwin arm64',
        '',
      );
    }
    return const EngineCommandResult(
      0,
      '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device',
      '',
    );
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) =>
      throw UnimplementedError();
}

class _ObservedIO extends _ManagedIO {
  _ObservedIO(this.output);
  final String output;
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      expect(timeout, const Duration(seconds: 10));
      return EngineCommandResult(0, output, '');
    }
    return super.run(executable, arguments, timeout: timeout);
  }
}

class _StandardIO extends _ManagedIO {
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      expect(timeout, const Duration(seconds: 10));
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11146, commit 7fe450e19)\nbuilt for Darwin arm64',
        '',
      );
    }
    return super.run(executable, arguments, timeout: timeout);
  }
}

class _ManagedIO extends _LinkIO {
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file' || arguments.singleOrNull == '--help') {
      return super.run(executable, arguments, timeout: timeout);
    }
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
