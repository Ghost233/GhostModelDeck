import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/library_directory_settings.dart';

void main() {
  test(
    'selected shared directory persists without moving its model files',
    () async {
      final root = await Directory.systemTemp.createTemp('jev-settings-');
      addTearDown(() => root.delete(recursive: true));
      final models = await Directory('${root.path}/shared models').create();
      final model = File('${models.path}/existing.gguf');
      await model.writeAsString('existing model bytes');
      final settingsFile = File('${root.path}/app/settings.json');
      final settings = LibraryDirectorySettings(file: settingsFile);

      await settings.save(models.path);
      final reopened = LibraryDirectorySettings(file: settingsFile);

      expect(await reopened.load(), models.path);
      expect(await model.readAsString(), 'existing model bytes');
      expect(await models.list().map((file) => file.path).toList(), [
        model.path,
      ]);
    },
  );
  test('invalid directory input leaves the saved shared path intact', () async {
    final root = await Directory.systemTemp.createTemp('jev-settings-invalid-');
    addTearDown(() => root.delete(recursive: true));
    final settings = LibraryDirectorySettings(
      file: File('${root.path}/settings.json'),
    );
    await settings.save(root.path);
    await expectLater(settings.save('relative/models'), throwsArgumentError);
    expect(await settings.load(), root.path);
  });
}
