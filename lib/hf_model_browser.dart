import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

enum RequestStatus { idle, loading, ready, empty, failed }

enum MetadataOrigin { online, cache }

class HfRepositorySummary {
  const HfRepositorySummary({
    required this.id,
    this.task,
    this.downloads,
    this.license,
  });

  final String id;
  final String? task;
  final int? downloads;
  final String? license;
}

class HfModelFile {
  const HfModelFile({
    required this.path,
    this.sizeBytes,
    this.blobId,
    this.sha256,
    this.isLfs,
  });

  final String path;
  final int? sizeBytes;
  final String? blobId;
  final String? sha256;
  final bool? isLfs;

  /// A filename label, not a determination of engine compatibility.
  String get format {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '未知';
    final extension = name.substring(dot + 1).toLowerCase();
    return extension == 'safetensors' ? 'Safetensors' : extension.toUpperCase();
  }
}

/// Validated configuration evidence, never an engine compatibility claim.
class NativeModelConfiguration {
  const NativeModelConfiguration({required this.bits, required this.groupSize});
  final int bits;
  final int groupSize;
  String get quantization => '${bits}bit · group $groupSize';

  static NativeModelConfiguration? fromJson(Map<String, dynamic> config) {
    final quant = config['quantization'];
    if (quant is! Map) return null;
    final bits = quant['bits'];
    final group = quant['group_size'];
    if (bits is! int || bits <= 0 || bits > 32 || group is! int || group <= 0) {
      return null;
    }
    return NativeModelConfiguration(bits: bits, groupSize: group);
  }
}

class HfRepositoryFiles {
  HfRepositoryFiles({
    required this.summary,
    required this.revision,
    required this.requestedRevision,
    required this.source,
    required List<HfModelFile> files,
    Map<String, NativeModelConfiguration> configurations = const {},
  }) : files = List.unmodifiable(files),
       configurations = Map.unmodifiable(configurations);

  final HfRepositorySummary summary;
  final String revision;
  final String requestedRevision;
  final Uri source;
  final List<HfModelFile> files;

  /// Keys are repository-relative config.json paths at [revision].
  final Map<String, NativeModelConfiguration> configurations;
}

class HfBrowserState {
  HfBrowserState({
    this.query = '',
    this.searchStatus = RequestStatus.idle,
    this.searchError,
    this.searchOrigin,
    List<HfRepositorySummary> repositories = const [],
    this.activeRepositoryId,
    this.requestedRevision = 'main',
    this.repositoryStatus = RequestStatus.idle,
    this.repositoryError,
    this.repositoryOrigin,
    this.repository,
    Set<String> selectedFilePaths = const {},
  }) : repositories = List.unmodifiable(repositories),
       selectedFilePaths = Set.unmodifiable(selectedFilePaths);

  final String query;
  final RequestStatus searchStatus;
  final String? searchError;
  final MetadataOrigin? searchOrigin;
  final List<HfRepositorySummary> repositories;
  final String? activeRepositoryId;
  final String requestedRevision;
  final RequestStatus repositoryStatus;
  final String? repositoryError;
  final MetadataOrigin? repositoryOrigin;
  final HfRepositoryFiles? repository;
  final Set<String> selectedFilePaths;

  List<HfModelFile> get selectedFiles => List.unmodifiable(
    repository?.files.where((file) => selectedFilePaths.contains(file.path)) ??
        const <HfModelFile>[],
  );

  int? get selectedBytes {
    var total = 0;
    for (final file in selectedFiles) {
      if (file.sizeBytes == null) return null;
      total += file.sizeBytes!;
    }
    return total;
  }
}

/// Application entry for HF discovery. UI and other callers share this state.
class HfModelBrowser {
  HfModelBrowser({Uri? endpoint, this._cacheDirectory})
    : _endpoint = endpoint ?? Uri.parse('https://huggingface.co') {
    _client.connectionTimeout = const Duration(seconds: 20);
    _client.userAgent = 'GhostModelDeck/0.1';
  }

  final Uri _endpoint;
  final Directory? _cacheDirectory;
  final HttpClient _client = HttpClient();
  final _changes = StreamController<HfBrowserState>.broadcast(sync: true);
  HfBrowserState _state = HfBrowserState();
  int _searchGeneration = 0;
  int _repositoryGeneration = 0;
  bool _closed = false;

  HfBrowserState get state => _state;
  Stream<HfBrowserState> get changes => _changes.stream;

  Future<void> search(String input) async {
    final query = input.trim();
    final generation = ++_searchGeneration;
    final repositoryGeneration = ++_repositoryGeneration;
    if (query.isEmpty) {
      _publish(HfBrowserState());
      return;
    }
    _publish(HfBrowserState(query: query, searchStatus: RequestStatus.loading));
    final repositoryId = _repositoryInput(query);
    try {
      if (repositoryId != null) {
        _updateRepository(
          id: repositoryId,
          requestedRevision: 'main',
          status: RequestStatus.loading,
        );
        final metadata = await _readRepository(
          repositoryId,
          'main',
          () =>
              generation == _searchGeneration &&
              repositoryGeneration == _repositoryGeneration,
        );
        final repository = metadata.value;
        if (generation != _searchGeneration || _closed) return;
        _updateSearch(
          repositories: [repository.summary],
          status: RequestStatus.ready,
          origin: metadata.origin,
          error: metadata.error,
        );
        if (repositoryGeneration == _repositoryGeneration) {
          _updateRepository(
            id: repository.summary.id,
            requestedRevision: 'main',
            status: repository.files.isEmpty
                ? RequestStatus.empty
                : RequestStatus.ready,
            repository: repository,
            origin: metadata.origin,
            error: metadata.error,
          );
        }
        return;
      }
      final metadata = await _readMetadata<List<HfRepositorySummary>>(
        _endpoint.replace(
          pathSegments: ['api', 'models'],
          queryParameters: {'search': query, 'limit': '50'},
        ),
        (data) {
          if (data is! List) throw const FormatException('Expected model list');
          return data.map((item) => _summary(_object(item))).toList();
        },
        (repositories) => repositories.map(_summaryJson).toList(),
        current: () => generation == _searchGeneration,
      );
      final repositories = metadata.value;
      if (generation != _searchGeneration || _closed) return;
      _updateSearch(
        repositories: repositories,
        status: repositories.isEmpty
            ? RequestStatus.empty
            : RequestStatus.ready,
        origin: metadata.origin,
        error: metadata.error,
      );
    } catch (error) {
      if (generation != _searchGeneration || _closed) return;
      _updateSearch(
        status: RequestStatus.failed,
        error: _failureMessage(error),
      );
      if (repositoryId != null &&
          repositoryGeneration == _repositoryGeneration) {
        _updateRepository(
          id: repositoryId,
          requestedRevision: 'main',
          status: RequestStatus.failed,
          error: _failureMessage(error),
        );
      }
    }
  }

  Future<void> selectRepository(String id, {String revision = 'main'}) async {
    final requestedRevision = revision.trim().isEmpty
        ? 'main'
        : revision.trim();
    final generation = ++_repositoryGeneration;
    _updateRepository(
      id: id,
      requestedRevision: requestedRevision,
      status: RequestStatus.loading,
    );
    try {
      final metadata = await _readRepository(
        id,
        requestedRevision,
        () => generation == _repositoryGeneration,
      );
      final repository = metadata.value;
      if (generation != _repositoryGeneration || _closed) return;
      _updateRepository(
        id: repository.summary.id,
        requestedRevision: requestedRevision,
        status: repository.files.isEmpty
            ? RequestStatus.empty
            : RequestStatus.ready,
        repository: repository,
        origin: metadata.origin,
        error: metadata.error,
      );
    } catch (error) {
      if (generation != _repositoryGeneration || _closed) return;
      _updateRepository(
        id: id,
        requestedRevision: requestedRevision,
        status: RequestStatus.failed,
        error: _failureMessage(error),
      );
    }
  }

  void setFileSelected(String path, bool selected) {
    final repository = _state.repository;
    if (repository == null ||
        !repository.files.any((file) => file.path == path)) {
      throw ArgumentError.value(
        path,
        'path',
        'Not a file in the current revision',
      );
    }
    final paths = {..._state.selectedFilePaths};
    selected ? paths.add(path) : paths.remove(path);
    _updateRepository(
      id: _state.activeRepositoryId!,
      requestedRevision: _state.requestedRevision,
      status: _state.repositoryStatus,
      repository: repository,
      selectedFilePaths: paths,
      origin: _state.repositoryOrigin,
      error: _state.repositoryError,
    );
  }

  void close() {
    _closed = true;
    _client.close(force: true);
    _changes.close();
  }

  void _publish(HfBrowserState state) {
    if (_closed) return;
    _state = state;
    _changes.add(state);
  }

  void _updateSearch({
    required RequestStatus status,
    List<HfRepositorySummary> repositories = const [],
    String? error,
    MetadataOrigin? origin,
  }) {
    _publish(
      HfBrowserState(
        query: _state.query,
        searchStatus: status,
        searchError: error,
        searchOrigin: origin,
        repositories: repositories,
        activeRepositoryId: _state.activeRepositoryId,
        requestedRevision: _state.requestedRevision,
        repositoryStatus: _state.repositoryStatus,
        repositoryError: _state.repositoryError,
        repositoryOrigin: _state.repositoryOrigin,
        repository: _state.repository,
        selectedFilePaths: _state.selectedFilePaths,
      ),
    );
  }

  void _updateRepository({
    required String id,
    required String requestedRevision,
    required RequestStatus status,
    HfRepositoryFiles? repository,
    String? error,
    MetadataOrigin? origin,
    Set<String> selectedFilePaths = const {},
  }) {
    _publish(
      HfBrowserState(
        query: _state.query,
        searchStatus: _state.searchStatus,
        searchError: _state.searchError,
        searchOrigin: _state.searchOrigin,
        repositories: _state.repositories,
        activeRepositoryId: id,
        requestedRevision: requestedRevision,
        repositoryStatus: status,
        repositoryError: error,
        repositoryOrigin: origin,
        repository: repository,
        selectedFilePaths: selectedFilePaths,
      ),
    );
  }

  Uri _repositoryUri(String id, String revision) => _endpoint.replace(
    pathSegments: ['api', 'models', ...id.split('/'), 'revision', revision],
    queryParameters: {'blobs': 'true'},
  );

  Future<({HfRepositoryFiles value, MetadataOrigin origin, String? error})>
  _readRepository(String id, String revision, bool Function() current) async {
    final metadata = await _readMetadata<HfRepositoryFiles>(
      _repositoryUri(id, revision),
      (data) => _parseRepository(data, revision),
      _repositoryJson,
      parseCached: (data) => _parseRepository(data, revision, cached: true),
      current: current,
      aliases: (repository) => [
        _repositoryUri(repository.summary.id, repository.revision),
        if (id != repository.summary.id)
          _repositoryUri(repository.summary.id, revision),
      ],
    );
    final repository = metadata.value;
    final configurations = <String, NativeModelConfiguration>{};
    // Only read bounded native-model configs; preserve the existing JEV path.
    for (final file
        in repository.files
            .where(
              (file) =>
                  file.path == 'config.json' ||
                  file.path.endsWith('/config.json'),
            )
            .take(32)) {
      if (!current() || _closed) break;
      final prefix = file.path.substring(
        0,
        file.path.length - 'config.json'.length,
      );
      if (repository.files.any(
            (item) => item.path == '${prefix}rl_agent_config.json',
          ) ||
          !repository.files.any(
            (item) =>
                item.path.startsWith(prefix) &&
                item.path.endsWith('.safetensors'),
          )) {
        continue;
      }
      try {
        final config = await _readConfiguration(repository, file);
        if (config != null) configurations[file.path] = config;
      } on IOException {
        // Discovery remains usable; unavailable evidence is not inferred.
      } on FormatException {
        // Invalid/changed content cannot supply a quantization label.
      } on TimeoutException {
        // Config evidence is optional, not a fabricated compatibility result.
      }
    }
    return (
      value: HfRepositoryFiles(
        summary: repository.summary,
        revision: repository.revision,
        requestedRevision: repository.requestedRevision,
        source: repository.source,
        files: repository.files,
        configurations: configurations,
      ),
      origin: metadata.origin,
      error: metadata.error,
    );
  }

  Future<NativeModelConfiguration?> _readConfiguration(
    HfRepositoryFiles repository,
    HfModelFile file,
  ) async {
    const limit = 1024 * 1024;
    const timeout = Duration(seconds: 20);
    if (file.sizeBytes != null && file.sizeBytes! > limit ||
        file.path.contains('\\') ||
        file.path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    final uri = _endpoint.replace(
      pathSegments: [
        ...repository.summary.id.split('/'),
        'resolve',
        repository.revision,
        ...file.path.split('/'),
      ],
      query: '',
    );
    final request = await _client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > limit) return null;
      bytes.addAll(chunk);
    }
    if (file.sizeBytes != null && file.sizeBytes != bytes.length) return null;
    if (file.sha256 != null &&
        sha256.convert(bytes).toString() != file.sha256!.toLowerCase()) {
      return null;
    }
    if (file.isLfs == false &&
        file.blobId != null &&
        sha1.convert([
              ...utf8.encode('blob ${bytes.length}\u0000'),
              ...bytes,
            ]).toString() !=
            file.blobId!.toLowerCase()) {
      return null;
    }
    return NativeModelConfiguration.fromJson(
      _object(jsonDecode(utf8.decode(bytes))),
    );
  }

  HfRepositoryFiles _parseRepository(
    dynamic raw,
    String revision, {
    bool cached = false,
  }) {
    final data = _object(raw);
    final sha = data['sha'];
    final siblings = data['siblings'];
    if (sha is! String || !RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(sha)) {
      throw const FormatException('Missing fixed commit');
    }
    if (siblings is! List) throw const FormatException('Missing file list');
    final files = siblings.map((sibling) {
      final file = _object(sibling);
      final path = file['rfilename'];
      if (path is! String || path.isEmpty) {
        throw const FormatException('Missing file path');
      }
      final lfs = file['lfs'];
      if (lfs != null && lfs is! Map) {
        throw const FormatException('Malformed LFS metadata');
      }
      final lfsData = lfs is Map ? lfs : const {};
      return HfModelFile(
        path: path,
        sizeBytes: ((file['size'] ?? lfsData['size']) as num?)?.toInt(),
        blobId: file['blobId'] as String?,
        sha256: lfsData['sha256'] as String?,
        isLfs: lfs is Map
            ? true
            : cached
            ? file['isLfs'] as bool?
            : false,
      );
    }).toList();
    return HfRepositoryFiles(
      summary: _summary(data),
      revision: sha,
      requestedRevision: revision,
      source: _endpoint,
      files: files,
    );
  }

  Future<({T value, MetadataOrigin origin, String? error})> _readMetadata<T>(
    Uri uri,
    T Function(dynamic) parse,
    dynamic Function(T) serialize, {
    required bool Function() current,
    T Function(dynamic)? parseCached,
    List<Uri> Function(T)? aliases,
  }) async {
    try {
      final raw = await _getJson(uri);
      final value = parse(raw);
      final public = raw is List
          ? !raw.any((item) => item is Map && item['private'] == true)
          : raw is! Map || raw['private'] != true;
      if (public && current() && !_closed) {
        final data = serialize(value);
        for (final key in {uri, ...?aliases?.call(value)}) {
          await _writeCache(key, data, current);
        }
      }
      return (value: value, origin: MetadataOrigin.online, error: null);
    } catch (error) {
      final cached = await _readCache(uri, parseCached ?? parse);
      if (cached == null) rethrow;
      return (
        value: cached,
        origin: MetadataOrigin.cache,
        error: _failureMessage(error),
      );
    }
  }

  File? _cacheFile(Uri uri) {
    final directory = _cacheDirectory;
    if (directory == null) return null;
    final key = sha256.convert(utf8.encode(uri.toString()));
    return File('${directory.path}/hf-metadata-v1-$key.json');
  }

  Future<T?> _readCache<T>(Uri uri, T Function(dynamic) parse) async {
    final file = _cacheFile(uri);
    if (file == null) return null;
    try {
      final data = _object(jsonDecode(await file.readAsString()));
      if (data['version'] != 1) return null;
      return parse(data['payload']);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> _writeCache(
    Uri uri,
    dynamic payload,
    bool Function() current,
  ) async {
    final directory = _cacheDirectory;
    final file = _cacheFile(uri);
    if (directory == null || file == null || !current() || _closed) return;
    Directory? staging;
    try {
      await directory.create(recursive: true);
      staging = await directory.createTemp('.hf-write-');
      final temporary = File('${staging.path}/metadata.json');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'payload': payload}),
        flush: true,
      );
      if (current() && !_closed) await temporary.rename(file.path);
    } on FileSystemException {
      // A cache failure must not replace successfully fetched online metadata.
    } finally {
      if (staging != null) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // Only this write's temporary directory is eligible for cleanup.
        }
      }
    }
  }

  Future<dynamic> _getJson(Uri uri) async {
    const timeout = Duration(seconds: 20);
    final request = await _client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw _HfRequestFailure(response.statusCode);
    }
    return jsonDecode(body);
  }
}

String? _repositoryInput(String input) {
  final uri = Uri.tryParse(input);
  if (uri != null && uri.host == 'huggingface.co') {
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length == 1 || segments.length == 2) {
      final id = segments.join('/');
      if (RegExp(r'^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?$').hasMatch(id)) {
        return id;
      }
    }
  }
  return RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(input)
      ? input
      : null;
}

Map<String, dynamic> _summaryJson(HfRepositorySummary repository) => {
  'id': repository.id,
  if (repository.task != null) 'pipeline_tag': repository.task,
  if (repository.downloads != null) 'downloads': repository.downloads,
  if (repository.license != null) 'cardData': {'license': repository.license},
};

Map<String, dynamic> _repositoryJson(HfRepositoryFiles repository) => {
  ..._summaryJson(repository.summary),
  'sha': repository.revision,
  'siblings': [
    for (final file in repository.files)
      {
        'rfilename': file.path,
        if (file.sizeBytes != null) 'size': file.sizeBytes,
        if (file.blobId != null) 'blobId': file.blobId,
        if (file.isLfs != null) 'isLfs': file.isLfs,
        if (file.isLfs == true || file.sha256 != null)
          'lfs': {if (file.sha256 != null) 'sha256': file.sha256},
      },
  ],
};

HfRepositorySummary _summary(Map<String, dynamic> data) {
  final id = data['id'];
  if (id is! String || id.isEmpty) {
    throw const FormatException('Missing repository id');
  }
  final cardData = data['cardData'];
  String? license = cardData is Map ? cardData['license'] as String? : null;
  if (license == null) {
    final tags = data['tags'];
    if (tags is List) {
      for (final tag in tags) {
        if (tag is String && tag.startsWith('license:')) {
          license = tag.substring('license:'.length);
          break;
        }
      }
    }
  }
  return HfRepositorySummary(
    id: id,
    task: data['pipeline_tag'] as String?,
    downloads: (data['downloads'] as num?)?.toInt(),
    license: license,
  );
}

Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected object');
  }
  return value;
}

class _HfRequestFailure implements Exception {
  const _HfRequestFailure(this.statusCode);
  final int statusCode;
}

String _failureMessage(Object error) {
  if (error is _HfRequestFailure) {
    return switch (error.statusCode) {
      401 || 403 => '仓库不可访问 (${error.statusCode})',
      404 => '找不到仓库或版本 (404)',
      429 => 'HF 请求过于频繁 (429)',
      _ => 'HF 请求失败 (${error.statusCode})',
    };
  }
  if (error is TimeoutException) return 'HF 请求超时';
  if (error is IOException) return '网络连接失败';
  if (error is FormatException || error is TypeError) return 'HF 数据格式异常';
  return 'HF 请求失败';
}
