import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/library_directory_settings.dart';
import 'package:ghost_model_deck/model_downloader.dart';

void main() {
  test(
    'download source persists without changing the shared model directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'download-preferences-',
      );
      addTearDown(() => root.delete(recursive: true));
      final library = LibraryDirectorySettings(
        file: File('${root.path}/settings.json'),
      );
      await library.save('${root.path}/shared models');
      final file = File('${root.path}/download-preferences.json');
      final preferences = DownloadPreferences(file: file);
      await preferences.load();
      expect(preferences.source, DownloadSource.hf);
      await preferences.saveSource(DownloadSource.lmStudio);
      final reopened = DownloadPreferences(file: file);
      await reopened.load();
      expect(reopened.source, DownloadSource.lmStudio);
      expect(await library.load(), '${root.path}/shared models');
      await reopened.saveSource(DownloadSource.hf);
      final reset = DownloadPreferences(file: file);
      await reset.load();
      expect(reset.source, DownloadSource.hf);
    },
  );
}
