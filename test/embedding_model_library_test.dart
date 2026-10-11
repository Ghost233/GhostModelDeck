import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/model_library.dart';

import 'fixtures/decision_gguf.dart';

void main() {
  test('non-causal embedding GGUF is recognized separately from chat and decisions', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-embedding-recognition-',
    );
    addTearDown(() => root.delete(recursive: true));
    final library = ModelLibrary();
    addTearDown(library.close);
    await writeEmbeddingGguf(root);
    final artifact = (await library.scan(root, verifyFiles: true)).single;
    expect(artifact.kind, AssetKind.embedding);
    expect(artifact.integrity, AssetIntegrity.complete);
    expect(artifact.embeddingDimensions, 2);
    expect(artifact.hasStartluxReadout, isFalse);
    expect(artifact.fingerprintsVerified, isTrue);
  });
}
