import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';

void main() {
  test(
    'stopping one provider retains the other provider model file reservation',
    () async {
      final root = await Directory.systemTemp.createTemp('jev-shared-use-');
      addTearDown(() => root.delete(recursive: true));
      final first = await writeDecisionKev(root);
      final second = await first.copy('${first.parent.path}/Other-Q8.gguf');
      final library = ModelLibrary();
      addTearDown(library.close);
      await library.scan(root);
      final registry = ModelUseRegistry(library);
      final lm = Object(), standalone = Object();
      await registry.update(lm, [first.path]);
      await registry.update(standalone, [second.path]);
      await registry.update(lm, []);
      final secondPath = await second.resolveSymbolicLinks();
      final secondId = library.state.artifacts
          .singleWhere((value) => value.files.single.path == secondPath)
          .id;
      await expectLater(
        library.prepareDeletion([secondId]),
        throwsA(isA<LibraryException>()),
      );
      expect(await second.exists(), isTrue);
      await registry.update(standalone, []);
      final plan = await library.prepareDeletion([secondId]);
      expect(
        await library.delete(plan, confirmed: true),
        DeletionResult.deleted,
      );
      expect(await first.exists(), isTrue);
    },
  );
}
