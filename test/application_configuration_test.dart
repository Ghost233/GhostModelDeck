import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/application_configuration.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/library_directory_settings.dart';
import 'package:ghost_model_deck/model_downloader.dart';

void main() {
  test(
    'invalid profile reports an error without overwriting configuration',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-invalid-profile-',
      );
      addTearDown(() => root.delete(recursive: true));
      final marker = File('${root.path}/configuration-profile.json');
      await marker.writeAsString('{"profile":"unexpected"}');
      final settings = File('${root.path}/settings.json');
      await settings.writeAsString('saved configuration');
      await expectLater(
        ApplicationConfiguration(directory: root).prepare(),
        throwsFormatException,
      );
      expect(await settings.readAsString(), 'saved configuration');
    },
  );

  test(
    'failed initialization stays retryable and does not publish a profile',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-config-retry-');
      addTearDown(() => root.delete(recursive: true));
      final obstruction = await Directory('${root.path}/settings.json')
          .create();
      final configuration = ApplicationConfiguration(directory: root);
      await expectLater(
        configuration.prepare(),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File('${root.path}/configuration-profile.json').exists(),
        isFalse,
      );
      await obstruction.delete();
      await configuration.prepare();
      expect(
        await LibraryDirectorySettings(file: File('${root.path}/settings.json'))
            .load(),
        isNotEmpty,
      );
    },
  );

  test(
    'fresh configuration preserves assets and saved settings on reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-configuration-');
      addTearDown(() => root.delete(recursive: true));
      final app = await Directory('${root.path}/app').create();
      final preserved = <File>[
        File('${root.path}/models/weights.gguf'),
        File('${app.path}/engines/source/checkout/model.cpp'),
        File('${app.path}/engines/llama.cpp/build/llama-server'),
        File('${app.path}/benchmark-runs/history/results.json'),
      ];
      for (final file in preserved) {
        await file.parent.create(recursive: true);
        await file.writeAsString('preserve ${file.path}');
      }
      for (final name in [
        'settings.json',
        'engines.json',
        'jev_models.json',
        'public_models.json',
        'startup-models.json',
        'launch-instances.json',
      ]) {
        await File('${app.path}/$name').writeAsString('old configuration');
      }

      await ApplicationConfiguration(directory: app).prepare();
      final settings = LibraryDirectorySettings(
        file: File('${app.path}/settings.json'),
      );
      final models = await Directory('${root.path}/selected models').create();
      await settings.save(models.path);
      final preferences = DownloadPreferences(
        file: File('${app.path}/download-preferences.json'),
      );
      addTearDown(preferences.dispose);
      await preferences.saveSource(DownloadSource.lmStudio);

      await ApplicationConfiguration(directory: app).prepare();
      expect(
        await LibraryDirectorySettings(file: settings.file).load(),
        models.path,
      );
      final reopened = DownloadPreferences(file: preferences.file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.source, DownloadSource.lmStudio);
      for (final file in preserved) {
        expect(await file.readAsString(), 'preserve ${file.path}');
      }
      expect(
        await File('${app.path}/launch-instances.json').readAsString(),
        '{"schema":1,"instances":[]}',
      );
    },
  );
}
