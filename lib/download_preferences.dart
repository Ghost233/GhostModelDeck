import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'model_downloader.dart';

class DownloadPreferences extends ChangeNotifier {
  DownloadPreferences({required this.file});

  factory DownloadPreferences.user() => DownloadPreferences(
    file: File(
      '${Platform.environment['HOME']}/Library/Application Support/'
      'GhostModelDeck/download-preferences.json',
    ),
  );

  final File file;
  DownloadSource _source = DownloadSource.hf;
  DownloadSource get source => _source;

  Future<void> load() async {
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _source = DownloadSource.values.byName(data['source'] as String);
    notifyListeners();
  }

  Future<void> saveSource(DownloadSource source) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'source': source.name}),
      flush: true,
    );
    await temporary.rename(file.path);
    _source = source;
    notifyListeners();
  }
}
