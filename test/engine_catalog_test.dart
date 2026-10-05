import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/engine_archive.dart';

void main() {
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
