import 'dart:convert';
import 'dart:io';

import 'library_directory_settings.dart';

/// Initializes the current application configuration without importing old data.
/// Model files, engine installations and historical results are never traversed.
class ApplicationConfiguration {
  ApplicationConfiguration({required this.directory});

  final Directory directory;
  Future<void>? _preparing;
  static const _profile = 'saved-instances-v1';

  Future<void> prepare() => _preparing ??= _prepare().whenComplete(() {
    _preparing = null;
  });

  Future<void> _prepare() async {
    final marker = File('${directory.path}/configuration-profile.json');
    if (await marker.exists()) {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map || value['profile'] != _profile) {
        throw const FormatException('应用配置版本无效');
      }
      return;
    }
    final downloadPath = await LibraryDirectorySettings.defaultDirectory();
    final initial = <String, Map<String, Object?>>{
      'settings.json': {
        'schema': 2,
        'downloadPath': downloadPath,
        'libraryPaths': [downloadPath],
      },
      'download-preferences.json': {'source': 'hf'},
      'engines.json': {'schema': 1, 'linked': <Object?>[]},
      'jev_models.json': {'schema': 1, 'models': <Object?>[]},
      'public_models.json': {
        'schema': 2,
        'enabled': <Object?>[],
        'publicIds': <String, String>{},
      },
      'startup-models.json': {'schema': 1, 'entries': <Object?>[]},
      'launch-instances.json': {'schema': 1, 'instances': <Object?>[]},
    };
    await directory.create(recursive: true);
    for (final entry in initial.entries) {
      await _write(entry.key, entry.value);
    }
    // Publish the marker last: failed initialization remains visibly retryable.
    await _write('configuration-profile.json', {'profile': _profile});
  }

  Future<void> _write(String name, Map<String, Object?> value) async {
    final target = '${directory.path}/$name';
    final temporary = File('$target.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(target);
  }
}
