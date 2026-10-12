import 'dart:convert';
import 'dart:io';

class ModelDirectories {
  ModelDirectories({
    required this.downloadPath,
    required List<String> libraryPaths,
  }) : libraryPaths = List.unmodifiable({...libraryPaths});
  final String downloadPath;
  final List<String> libraryPaths;
}

/// Multiple library locations, with one destination for new downloads.
class LibraryDirectorySettings {
  LibraryDirectorySettings({required this.file});
  factory LibraryDirectorySettings.user() => LibraryDirectorySettings(
    file: File(
      '${_home()}/Library/Application Support/GhostModelDeck/settings.json',
    ),
  );
  final File file;

  Future<ModelDirectories> loadDirectories() async {
    if (!await file.exists()) {
      final path = await defaultDirectory();
      return ModelDirectories(downloadPath: path, libraryPaths: [path]);
    }
    final data = jsonDecode(await file.readAsString());
    final destination = data is Map ? data['downloadPath'] : null;
    final paths = data is Map ? data['libraryPaths'] : null;
    if (data is! Map ||
        data['schema'] != 2 ||
        destination is! String ||
        paths is! List ||
        paths.any((p) => p is! String || !p.startsWith('/')) ||
        !destination.startsWith('/')) {
      throw const FormatException('模型目录设置无效');
    }
    return ModelDirectories(
      downloadPath: destination,
      libraryPaths: paths.cast<String>(),
    );
  }

  Future<String> load() async => (await loadDirectories()).downloadPath;
  Future<String> save(String path) async {
    final previous = await loadDirectories();
    await saveDirectories(
      ModelDirectories(
        downloadPath: path,
        libraryPaths: [...previous.libraryPaths, path],
      ),
    );
    return path;
  }

  Future<ModelDirectories> saveDirectories(ModelDirectories directories) async {
    if (!directories.downloadPath.startsWith('/') ||
        directories.libraryPaths.any((p) => !p.startsWith('/'))) {
      throw ArgumentError('请输入绝对目录');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 2,
        'downloadPath': directories.downloadPath,
        'libraryPaths': directories.libraryPaths,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
    return directories;
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
