import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/model_library.dart';

void main() {
  test('model directory packages retain actual variants and exclude noise and ongoing transfers from operations', () async {
    final root = await Directory.systemTemp.createTemp('jev-packages-');
    final library = ModelLibrary();
    addTearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });
    final q4 = await _gguf(root, 'author/choice/Q4_0.gguf');
    final q8 = await _gguf(root, 'author/choice/variants/Q8_0.gguf');
    final neighbor = await _gguf(root, 'author/neighbor/model.gguf');
    final transfer = await _gguf(
      root,
      'author/choice/downloading_new.gguf.part',
    );
    final banner = await _binary(root, 'author/choice/banner.bin');
    final noise = await _binary(root, '.DS_Store');
    await _binary(root, 'labs/unsupported/layers/layer-0.bin');
    await _binary(root, 'labs/unsupported/layers/layer-1.bin');
    await File('${root.path}/labs/unsupported/config.json').writeAsString(
      jsonEncode({
        'model_type': 'unlisted_encoder',
        'architectures': ['UnlistedEncoder'],
      }),
    );
    final inventory = await library.scan(root);

    final catalog = await LocalModelPackages.discover(root, inventory);

    expect(catalog.packages, hasLength(3));
    final choice = catalog.packages.singleWhere(
      (package) => package.directoryPath == '${root.path}/author/choice',
    );
    expect(choice.name, 'author/choice');
    expect(choice.variants, hasLength(2));
    expect(
      choice.variants
          .expand((variant) => variant.files)
          .map((file) => file.path)
          .toSet(),
      {q4.path, q8.path},
    );
    expect(
      choice.artifactIds,
      containsAll(
        inventory
            .where(
              (artifact) => artifact.files.any(
                (file) => file.path == q4.path || file.path == q8.path,
              ),
            )
            .map((artifact) => artifact.id),
      ),
    );
    final deletion = await library.prepareDeletion(choice.artifactIds);
    expect(deletion.files.map((file) => file.path).toSet(), {q4.path, q8.path});
    expect(
      await library.delete(deletion, confirmed: false),
      DeletionResult.cancelled,
    );
    expect(await neighbor.exists(), isTrue);
    expect(await banner.exists(), isTrue);
    expect(await transfer.exists(), isTrue);
    expect(await noise.exists(), isTrue);
    final unknown = catalog.packages.singleWhere(
      (package) => package.name == 'labs/unsupported',
    );
    expect(unknown.variants, hasLength(1));
    expect(unknown.variants.single.artifacts, hasLength(2));
    expect(
      unknown.variants.single.artifacts.every(
        (artifact) => artifact.integrity == AssetIntegrity.unknown,
      ),
      isTrue,
    );
    expect(
      catalog.residualArtifacts.any(
        (artifact) => artifact.files.any((file) => file.path == noise.path),
      ),
      isTrue,
    );
  });

  test('manifest-backed unknown model directory is one unsupported package without asserting loadability', () async {
    final root = await Directory.systemTemp.createTemp('jev-packages-');
    final library = ModelLibrary();
    addTearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });
    final directory = '${root.path}/external/opaque-splash';
    for (final path in [
      'target/head.bin',
      'target/embedding.bin',
      'target/layers/0.bin',
      'draft/model.bin',
    ]) {
      await _binary(root, 'external/opaque-splash/$path');
    }
    await Directory('$directory/tokenizer').create();
    await File('$directory/tokenizer/config.json')
        .writeAsString(jsonEncode({'tokenizer_class': 'Tokenizer'}));
    await File('$directory/manifest.json').writeAsString(
      jsonEncode({
        'schema_version': 3,
        'model': 'External Opaque Splash',
        'format': {
          'name': 'splash-packed-q4',
          'draft_layer_magic': 'MDFD0004',
          'target_layer_magic': 'MDFL0006',
          'vision_magic': 'MDFV0001',
        },
        'artifacts': [
          'target/head.bin',
          'target/embedding.bin',
          'target/layers/0.bin',
          'draft/model.bin',
        ],
        'execution_geometry': {'layers': 1},
        'upstream': {'repository': 'external/opaque-splash'},
      }),
    );

    final catalog = await LocalModelPackages.discover(
      root,
      await library.scan(root),
    );

    expect(catalog.packages, hasLength(1));
    final package = catalog.packages.single;
    expect(package.directoryPath, directory);
    expect(package.variants, hasLength(1));
    expect(package.variants.single.label, contains('未支持'));
    expect(package.variants.single.artifacts, hasLength(4));
    expect(
      package.variants.single.artifacts.every(
        (artifact) =>
            artifact.kind == AssetKind.unknown &&
            artifact.integrity == AssetIntegrity.unknown &&
            !artifact.fingerprintsVerified &&
            !artifact.sourceVerified,
      ),
      isTrue,
    );
    expect(catalog.residualArtifacts, isEmpty);
  });

  test('sole actual projector is a package companion while ambiguous projectors stay read-only', () async {
    final root = await Directory.systemTemp.createTemp('jev-packages-');
    final library = ModelLibrary();
    addTearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });
    final primary = await _gguf(
      root,
      'author/vision/model-Q8_0.gguf',
      architecture: 'llama',
    );
    final projector = await _gguf(
      root,
      'author/vision/mmproj-BF16.gguf',
      architecture: 'clip',
    );
    final otherPrimary = await _gguf(
      root,
      'author/ambiguous/model-Q4_0.gguf',
      architecture: 'llama',
    );
    await _gguf(
      root,
      'author/ambiguous/mmproj-one-F16.gguf',
      architecture: 'clip',
    );
    await _gguf(
      root,
      'author/ambiguous/mmproj-two-BF16.gguf',
      architecture: 'clip',
    );

    final catalog = await LocalModelPackages.discover(
      root,
      await library.scan(root),
    );

    final vision = catalog.packages.singleWhere(
      (package) => package.name == 'author/vision',
    );
    expect(vision.variants, hasLength(1));
    expect(vision.variants.single.files.map((file) => file.path).toSet(), {
      primary.path,
      projector.path,
    });
    expect(vision.variants.single.artifacts, hasLength(2));
    final ambiguous = catalog.packages.singleWhere(
      (package) => package.name == 'author/ambiguous',
    );
    expect(ambiguous.variants, hasLength(1));
    expect(ambiguous.variants.single.files.single.path, otherPrimary.path);
    expect(ambiguous.details, hasLength(3));
  });
}

Future<File> _gguf(
  Directory root,
  String relative, {
  String? architecture,
}) async {
  final file = File('${root.path}/$relative');
  await file.parent.create(recursive: true);
  final bytes = BytesBuilder()
    ..add([0x47, 0x47, 0x55, 0x46])
    ..add((ByteData(4)..setUint32(0, 3, Endian.little)).buffer.asUint8List())
    ..add(Uint8List(8))
    ..add(
      (ByteData(8)..setUint64(0, architecture == null ? 0 : 1, Endian.little))
          .buffer
          .asUint8List(),
    );
  if (architecture != null) {
    final key = utf8.encode('general.architecture');
    final value = utf8.encode(architecture);
    bytes
      ..add(
        (ByteData(
          8,
        )..setUint64(0, key.length, Endian.little)).buffer.asUint8List(),
      )
      ..add(key)
      ..add((ByteData(4)..setUint32(0, 8, Endian.little)).buffer.asUint8List())
      ..add(
        (ByteData(
          8,
        )..setUint64(0, value.length, Endian.little)).buffer.asUint8List(),
      )
      ..add(value);
  }
  return file.writeAsBytes(bytes.toBytes());
}

Future<File> _binary(Directory root, String relative) async {
  final file = File('${root.path}/$relative');
  await file.parent.create(recursive: true);
  return file.writeAsBytes([0, 255, 0, 255]);
}
