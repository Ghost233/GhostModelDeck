import 'dart:convert';
import 'dart:io';

/// Persists the directory choice shared by discovery and downloading.
class LibraryDirectorySettings {
  LibraryDirectorySettings({required this.file});

  factory LibraryDirectorySettings.user() => LibraryDirectorySettings(
    file: File(
      '${_home()}/Library/Application Support/GhostModelDeck/settings.json',
    ),
  );

  final File file;

  Future<String> load() async {
    if (!await file.exists()) return defaultDirectory();
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return data['libraryPath'] as String;
  }

  Future<String> save(String path) async {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', '请输入绝对目录');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'libraryPath': path}),
      flush: true,
    );
    await temporary.rename(file.path);
    return path;
  }

  static Future<String> defaultDirectory() async {
    final home = _home();
    for (final suffix in ['.lmstudio/models', '.cache/lm-studio/models']) {
      final path = '$home/$suffix';
      if (await Directory(path).exists()) return path;
    }
    return '$home/Models/GhostModelDeck';
  }

  static String _home() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) throw StateError('无法读取用户目录');
    return home;
  }
}
