import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/model_library.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/qwen2_mlx_layout.dart';

void main() {
  test('an indexed weight alias does not create another package', () async {
    final root = await Directory.systemTemp.createTemp('gmd-indexed-link-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = Qwen2MlxFixture().bytes(indexed: true);
    for (final entry in bytes.entries) {
      await File('${root.path}/${entry.key}').writeAsBytes(entry.value);
    }
    final name = bytes.keys.singleWhere(
      (name) => name.endsWith('.safetensors'),
    );
    await Link('${root.path}/alias.safetensors').create('${root.path}/$name');
    final library = ModelLibrary();
    addTearDown(library.close);
    final assets = await library.scan(root);
    expect(assets, hasLength(1));
    expect(assets.single.integrity, AssetIntegrity.complete);
    expect(
      assets.single.files.map((file) => file.realPath).toSet().length,
      assets.single.files.length,
    );
  });
  test('active external target and retargeted link reject deletion', () async {
    final root = await Directory.systemTemp.createTemp('gmd-link-protection-');
    addTearDown(() => root.delete(recursive: true));
    final external = await Directory('${root.path}/external').create();
    final weight = await writeDecisionKev(external);
    final replacement = await weight.copy('${external.path}/replacement.gguf');
    final libraryRoot = await Directory('${root.path}/library').create();
    final link = await Link('${libraryRoot.path}/linked.gguf')
        .create(weight.path);
    final library = ModelLibrary();
    addTearDown(library.close);
    final asset = (await library.scan(libraryRoot)).single;
    await library.setFilesInUse([weight.path]);
    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    await library.setFilesInUse([]);
    final plan = await library.prepareDeletion([asset.id]);
    await link.update(replacement.path);
    await expectLater(
      library.delete(plan, confirmed: true),
      throwsA(isA<LibraryException>()),
    );
    expect(await link.exists(), isTrue);
    expect(await weight.exists(), isTrue);
    expect(await replacement.exists(), isTrue);
  });

  test(
    'overlapping roots and aliases deduplicate paths, copies remain separate',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-model-roots-');
      addTearDown(() => root.delete(recursive: true));
      final models = await Directory('${root.path}/models').create();
      final first = await Directory('${models.path}/first').create();
      final weight = await writeDecisionKev(first);
      final second = await Directory('${models.path}/second').create();
      await weight.copy('${second.path}/copy.gguf');
      final alias = await Link('${root.path}/alias').create(models.path);
      final library = ModelLibrary();
      addTearDown(library.close);
      final assets = await library.scanDirectories([
        models,
        first,
        Directory(alias.path),
      ]);
      expect(assets, hasLength(2));
      final selected = assets.singleWhere(
        (a) => a.files.single.path == weight.path,
      );
      await library.verify([selected.id]);
      expect(
        library.state.artifacts
            .singleWhere((a) => a.id == selected.id)
            .fingerprintsVerified,
        isTrue,
      );
      expect(
        library.state.artifacts
            .singleWhere((a) => a.id != selected.id)
            .fingerprintsVerified,
        isFalse,
      );
      final plan = await library.prepareDeletion([selected.id]);
      await library.delete(plan, confirmed: true);
      expect(await weight.exists(), isFalse);
      expect(await File('${second.path}/copy.gguf').exists(), isTrue);
    },
  );

  test('a linked reference stays the deletion identity when the target root is also linked', () async {
    final root = await Directory.systemTemp.createTemp('gmd-model-link-roots-');
    addTearDown(() => root.delete(recursive: true));
    final external = await Directory('${root.path}/external').create();
    final weight = await writeDecisionKev(external);
    final local = await Directory('${root.path}/local').create();
    final link = await Link('${local.path}/linked.gguf').create(weight.path);
    final library = ModelLibrary();
    addTearDown(library.close);
    final asset = (await library.scanDirectories([local, external])).single;
    final plan = await library.prepareDeletion([asset.id]);
    await library.delete(plan, confirmed: true);
    expect(await link.exists(), isFalse);
    expect(await weight.exists(), isTrue);
  });

  test(
    'linked weight is deduplicated and deletion preserves external models',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-library-link-');
      addTearDown(() => root.delete(recursive: true));
      final external = await Directory('${root.path}/external').create();
      final weight = await writeDecisionKev(external);
      final original = await weight.readAsBytes();
      final unrelated = await weight.copy('${external.path}/unrelated.gguf');
      final libraryRoot = await Directory('${root.path}/library').create();
      final link = await Link('${libraryRoot.path}/linked.gguf')
          .create(weight.path);
      await Link('${libraryRoot.path}/second.gguf').create(weight.path);
      final library = ModelLibrary();
      addTearDown(library.close);

      final found = await library.scan(libraryRoot);
      expect(found, hasLength(1));
      final asset = (await library.verify([found.single.id])).single;
      expect(asset.fingerprintsVerified, isTrue);
      final plan = await library.prepareDeletion([asset.id]);
      expect(
        await library.delete(plan, confirmed: true),
        DeletionResult.deleted,
      );
      expect(await link.exists(), isFalse);
      expect(await weight.readAsBytes(), original);
      expect(await unrelated.readAsBytes(), original);
    },
  );
}
