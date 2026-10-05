import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'hf_model_browser.dart';
import 'model_package.dart';

enum DownloadSource { hf, lmStudio }

enum DownloadStatus {
  idle,
  downloading,
  verifying,
  installed,
  cancelled,
  interrupted,
  restartRequired,
  conflict,
  failed,
}

class DownloadState {
  const DownloadState({
    this.status = DownloadStatus.idle,
    this.repositoryId,
    this.revision,
    this.currentFile,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.error,
    this.installationId,
    this.libraryPath,
    this.modelPackageId,
    this.modelLabel,
    this.variantId,
    this.variantLabel,
    this.source,
    this.reusedExisting = false,
  });

  final DownloadStatus status;
  final String? repositoryId;
  final String? revision;
  final String? currentFile;
  final int downloadedBytes;
  final int? totalBytes;
  final String? error;
  final String? installationId;
  final String? libraryPath;
  final String? modelPackageId;
  final String? modelLabel;
  final String? variantId;
  final String? variantLabel;
  final DownloadSource? source;
  final bool reusedExisting;

  bool get isActive =>
      status == DownloadStatus.downloading ||
      status == DownloadStatus.verifying;
}

/// Application entry for fixed-revision asset downloads and installations.
class ModelDownloader {
  ModelDownloader({Uri? hfEndpoint, Uri? lmStudioEndpoint})
    : _hfEndpoint = hfEndpoint ?? Uri.parse('https://huggingface.co'),
      _lmStudioEndpoint =
          lmStudioEndpoint ??
          Uri.parse('https://search.lmstudio.ai/v1/hf-proxy/');

  final Uri _hfEndpoint;
  final Uri _lmStudioEndpoint;
  final _changes = StreamController<DownloadState>.broadcast(sync: true);
  DownloadState _state = const DownloadState();
  HttpClient? _client;
  HttpClientRequest? _request;
  StreamIterator<List<int>>? _body;
  Future<void>? _bodyCancellation;
  _DownloadCleanupFailure? _cleanupFailure;
  bool _cancelled = false;
  bool _closed = false;
  Future<void>? _operation;
  Future<void>? _closing;
  String? _repositoryId;
  String? _revision;
  String? _currentFile;
  String? _libraryPath;
  ModelPackageSelection? _packageSelection;
  DownloadSource? _source;
  bool _reusedExisting = false;
  int _downloadedBytes = 0;
  int? _totalBytes;

  DownloadState get state => _state;
  Stream<DownloadState> get changes => _changes.stream;
  bool get acceptsDownloads => !_closed;

  Future<void> downloadPackage({
    required ModelPackageSelection selection,
    required HfRepositoryFiles currentRepository,
    required Directory libraryDirectory,
    DownloadSource source = DownloadSource.hf,
    bool restart = false,
  }) => _run(
    () => _downloadPackage(
      selection: selection,
      currentRepository: currentRepository,
      libraryDirectory: libraryDirectory,
      source: source,
      restart: restart,
    ),
  );

  Future<void> _downloadPackage({
    required ModelPackageSelection selection,
    required HfRepositoryFiles currentRepository,
    required Directory libraryDirectory,
    required DownloadSource source,
    required bool restart,
  }) async {
    if (_closed || _state.isActive) return;
    _packageSelection = selection;
    _source = source;
    _reusedExisting = false;
    _cancelled = false;
    _repositoryId = selection.modelPackage.repository.summary.id;
    _revision = selection.modelPackage.repository.revision;
    _libraryPath = libraryDirectory.absolute.path;
    _currentFile = null;
    _downloadedBytes = 0;
    _totalBytes = selection.variant.sizeBytes;
    _publish(DownloadStatus.verifying);
    try {
      final original = selection.modelPackage.repository;
      if (!RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(currentRepository.revision) ||
          !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
              .hasMatch(currentRepository.summary.id)) {
        throw const FormatException('需要模型仓库和固定 commit');
      }
      if (original.summary.id != currentRepository.summary.id ||
          original.revision != currentRepository.revision) {
        throw const _DownloadFailure(DownloadStatus.failed, '模型包选择已过期，请重新选择版本');
      }
      final packages = ModelPackage.discover(currentRepository)
          .where((package) => package.id == selection.modelPackage.id);
      if (packages.length != 1) {
        throw const _DownloadFailure(DownloadStatus.failed, '模型包已变化');
      }
      final current = packages.single.selectVariant(selection.variant.id);
      if (!current.variant.canDownload ||
          jsonEncode(_fileIdentity(current.variant.files)) !=
              jsonEncode(_fileIdentity(selection.variant.files))) {
        throw _DownloadFailure(
          DownloadStatus.failed,
          current.variant.unavailableReason ?? '模型包文件关系已变化',
        );
      }
      _packageSelection = current;
      validateAssetPath(currentRepository.summary.id);
      if (currentRepository.summary.id.startsWith('.ghostmodeldeck/')) {
        throw const FormatException('仓库名与应用元数据目录冲突');
      }
      if (await _reuseInstalledPackage(current, libraryDirectory)) {
        return;
      }
      _checkCancelled();
      await _downloadFiles(
        repository: currentRepository,
        selectedFilePaths: current.variant.files
            .map((file) => file.path)
            .toSet(),
        libraryDirectory: libraryDirectory,
        source: source,
        restart: restart,
        packageSelection: current,
      );
    } catch (error) {
      if (error is _DownloadCleanupFailure) {
        _publish(DownloadStatus.failed, error: error.toString());
        rethrow;
      } else if (_cancelled) {
        _publish(DownloadStatus.cancelled);
      } else if (error is _DownloadFailure) {
        _publish(error.status, error: error.message);
      } else {
        _publish(
          DownloadStatus.failed,
          error: error is FormatException ? error.message : '模型包无法解析或读取',
        );
      }
    }
  }

  Future<void> download({
    required HfRepositoryFiles repository,
    required Set<String> selectedFilePaths,
    required Directory libraryDirectory,
    DownloadSource source = DownloadSource.hf,
    bool restart = false,
  }) => _run(
    () => _downloadFiles(
      repository: repository,
      selectedFilePaths: selectedFilePaths,
      libraryDirectory: libraryDirectory,
      source: source,
      restart: restart,
    ),
  );

  Future<void> _run(Future<void> Function() action) {
    if (_closed || _operation != null) return Future<void>.value();
    final operation = Completer<void>();
    _operation = operation.future;
    unawaited(
      Future<void>.sync(action).then<void>(
        (_) {
          _operation = null;
          operation.complete();
        },
        onError: (Object error, StackTrace stack) {
          _operation = null;
          operation.completeError(error, stack);
        },
      ),
    );
    return operation.future;
  }

  Future<void> _downloadFiles({
    required HfRepositoryFiles repository,
    required Set<String> selectedFilePaths,
    required Directory libraryDirectory,
    required DownloadSource source,
    required bool restart,
    ModelPackageSelection? packageSelection,
  }) async {
    if (_closed || (packageSelection == null && _state.isActive)) return;
    _packageSelection = packageSelection;
    _source = source;
    _reusedExisting = false;
    _cancelled = false;
    _repositoryId = repository.summary.id;
    _revision = repository.revision;
    _currentFile = null;
    _libraryPath = libraryDirectory.absolute.path;
    _downloadedBytes = 0;
    _totalBytes = null;
    _publish(DownloadStatus.downloading);
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..autoUncompress = false
      ..userAgent = 'GhostModelDeck/0.1';
    try {
      if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
              .hasMatch(repository.summary.id) ||
          !RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(repository.revision) ||
          selectedFilePaths.isEmpty) {
        throw const FormatException('需要仓库、固定 commit 和所选文件');
      }
      validateAssetPath(repository.summary.id);
      if (repository.summary.id.startsWith('.ghostmodeldeck/')) {
        throw const FormatException('仓库名与应用元数据目录冲突');
      }
      final selected =
          repository.files
              .where((file) => selectedFilePaths.contains(file.path))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (selected.length != selectedFilePaths.length) {
        throw const FormatException('所选文件不属于此版本');
      }
      final files = resolveAssetFiles(repository.files, selected);
      for (final file in files) {
        validateAssetPath(file.path);
      }
      if (files.every((file) => file.sizeBytes != null)) {
        _totalBytes = files.fold<int>(
          0,
          (total, file) => total + file.sizeBytes!,
        );
      }
      await libraryDirectory.create(recursive: true);
      final root = Directory(await libraryDirectory.resolveSymbolicLinks());
      _libraryPath = root.path;
      final id = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                repository.summary.id,
                repository.revision,
                files.map((file) => file.path).toList(),
              ]),
            ),
          )
          .toString();
      final stage = await _directory(root, '.ghostmodeldeck/downloads/$id');
      if (restart) {
        await stage.delete(recursive: true);
        await stage.create();
      }
      final records = <Map<String, dynamic>>[];
      final staged = <File>[];
      final endpoint = source == DownloadSource.hf
          ? _hfEndpoint
          : _lmStudioEndpoint;
      final available = repository.files.toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final identity = {
        'repoId': repository.summary.id,
        'revision': repository.revision,
        'source': source.name,
        'endpoint': endpoint.toString(),
        'files': available
            .map(
              (file) => [
                file.path,
                file.sizeBytes,
                file.sha256,
                file.blobId,
                file.isLfs,
              ],
            )
            .toList(),
        'plannedFiles': files.map((file) => file.path).toList(),
      };
      final snapshotFile = File('${stage.path}/download.json');
      final Map<String, dynamic> snapshot;
      if (await snapshotFile.exists()) {
        try {
          snapshot = jsonDecode(
            await snapshotFile.readAsString(),
          ) as Map<String, dynamic>;
          if (jsonEncode(snapshot['identity']) != jsonEncode(identity) ||
              snapshot['files'] is! Map<String, dynamic>) {
            throw const FormatException('暂存任务身份不匹配');
          }
        } catch (_) {
          throw const _DownloadFailure(
            DownloadStatus.restartRequired,
            '来源、版本或暂存任务已变化；需要重新下载',
          );
        }
      } else {
        snapshot = {'identity': identity, 'files': <String, dynamic>{}};
        await _saveSnapshot(snapshotFile, snapshot);
      }
      final fileSnapshots = snapshot['files'] as Map<String, dynamic>;
      final assets = await _directory(stage, 'files');
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final file = files[fileIndex];
        _checkCancelled();
        _currentFile = file.path;
        _publish(DownloadStatus.downloading);
        final parent = file.path.contains('/')
            ? file.path.substring(0, file.path.lastIndexOf('/'))
            : '';
        await _directory(assets, parent);
        final partial = File('${assets.path}/${file.path}.part');
        final partialType = await FileSystemEntity.type(
          partial.path,
          followLinks: false,
        );
        if (partialType != FileSystemEntityType.notFound &&
            partialType != FileSystemEntityType.file) {
          throw const _DownloadFailure(
            DownloadStatus.conflict,
            '暂存文件是目录或链接，未修改',
          );
        }
        final saved = fileSnapshots[file.path] as Map<String, dynamic>? ?? {};
        if (saved['invalid'] == true) {
          throw const _DownloadFailure(
            DownloadStatus.restartRequired,
            '保留片段未通过校验；需要重新下载',
          );
        }
        final uri = endpoint.replace(
          pathSegments: [
            ...endpoint.pathSegments.where((part) => part.isNotEmpty),
            ...repository.summary.id.split('/'),
            'resolve',
            repository.revision,
            ...file.path.split('/'),
          ],
        );
        final cachedSize = partialType == FileSystemEntityType.file
            ? await partial.length()
            : null;
        final completePayload =
            cachedSize != null &&
            cachedSize == file.sizeBytes &&
            (file.sha256 != null ||
                (file.isLfs == false && file.blobId != null));
        if (cachedSize != null &&
            (saved['complete'] == true || completePayload)) {
          _downloadedBytes += cachedSize;
          _publish(DownloadStatus.downloading);
        } else {
          fileSnapshots[file.path] = saved;
          await _receive(
            file,
            partial,
            uri,
            saved,
            () => _saveSnapshot(snapshotFile, snapshot),
          );
        }
        _checkCancelled();
        _publish(DownloadStatus.verifying);
        final size = await partial.length();
        final digest = (await sha256.bind(partial.openRead()).first).toString();
        final checksGitBlob = file.isLfs == false && file.blobId != null;
        final gitDigest = checksGitBlob
            ? (await sha1.bind(_gitBlobBytes(partial, size)).first).toString()
            : null;
        if ((file.sizeBytes != null && size != file.sizeBytes) ||
            (file.sha256 != null && digest != file.sha256!.toLowerCase()) ||
            (checksGitBlob && gitDigest != file.blobId!.toLowerCase()) ||
            (saved['complete'] == true && digest != saved['sha256']) ||
            (saved['totalBytes'] != null && size != saved['totalBytes'])) {
          saved['invalid'] = true;
          await _saveSnapshot(snapshotFile, snapshot);
          throw const _DownloadFailure(DownloadStatus.failed, '文件大小或内容哈希校验失败');
        }
        saved['complete'] = true;
        saved['sha256'] = digest;
        await _saveSnapshot(snapshotFile, snapshot);
        records.add({
          'path': '${repository.summary.id}/${file.path}',
          'sizeBytes': size,
          'sha256': digest,
          'upstreamSha256': file.sha256,
          'gitBlobId': file.blobId,
          'isLfs': file.isLfs,
          'upstreamVerified': file.sha256 != null || checksGitBlob,
        });
        staged.add(partial);
        if (file.path.endsWith('.index.json')) {
          dynamic data;
          try {
            data = jsonDecode(await partial.readAsString());
          } on FormatException {
            if (isWeightIndexFile(file.path)) rethrow;
          }
          final weights = data is Map ? data['weight_map'] : null;
          if (weights is! Map ||
              weights.isEmpty ||
              weights.values.any((value) => value is! String)) {
            if (isWeightIndexFile(file.path)) {
              throw const FormatException('权重索引缺少有效 weight_map');
            }
            continue;
          }
          for (final companion in resolveAssetFiles(repository.files, [
            file,
          ], requiredSidecars: true)) {
            if (!files.any((item) => item.path == companion.path)) {
              files.add(companion);
            }
          }
          for (final weight in weights.values.toSet().cast<String>()) {
            validateAssetPath(weight);
            final path = parent.isEmpty ? weight : '$parent/$weight';
            final matches = repository.files.where((item) => item.path == path);
            if (matches.isEmpty) {
              throw const FormatException('索引引用的权重不在此版本清单中');
            }
            if (!files.any((item) => item.path == path)) {
              files.add(matches.single);
            }
          }
          _totalBytes = files.every((item) => item.sizeBytes != null)
              ? files.fold<int>(0, (sum, item) => sum + item.sizeBytes!)
              : null;
        }
      }
      _checkCancelled();
      final installationId = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                repository.summary.id,
                repository.revision,
                files.map((file) => file.path).toList()..sort(),
              ]),
            ),
          )
          .toString();
      final manifest = File('${stage.path}/installation.json');
      await manifest.writeAsString(
        jsonEncode({
          'version': 1,
          'id': installationId,
          'repoId': repository.summary.id,
          'revision': repository.revision,
          'source': source.name,
          'sourceEndpoint': endpoint.toString(),
          'license': repository.summary.license,
          'files': records,
        }),
        flush: true,
      );
      await _install(root, staged, records, manifest, installationId);
      await stage.delete(recursive: true);
      _publish(DownloadStatus.installed, installationId: installationId);
    } catch (error) {
      if (error is _DownloadCleanupFailure) {
        _publish(DownloadStatus.failed, error: error.toString());
        rethrow;
      } else if (_cancelled) {
        _publish(DownloadStatus.cancelled);
      } else if (error is _DownloadFailure) {
        _publish(error.status, error: error.message);
      } else if (error is IOException || error is TimeoutException) {
        _publish(DownloadStatus.interrupted, error: '连接或文件操作中断');
      } else {
        _publish(
          DownloadStatus.failed,
          error: error is FormatException ? error.message : '下载失败',
        );
      }
    } finally {
      try {
        await _cleanUp([
          () async => await _bodyCancellation,
          () async => await _body?.cancel(),
          () => _client?.close(force: true),
        ]);
      } finally {
        _body = null;
        _bodyCancellation = null;
        _request = null;
        _client = null;
      }
    }
  }

  Future<bool> _reuseInstalledPackage(
    ModelPackageSelection selection,
    Directory libraryDirectory,
  ) async {
    if (!await libraryDirectory.exists()) return false;
    final root = Directory(await libraryDirectory.resolveSymbolicLinks());
    _libraryPath = root.path;
    final repository = selection.modelPackage.repository;
    final files = selection.variant.files.toList();
    // Expand from the installed index rather than trusting a receipt's file
    // list. Every expanded file is still checked against the fixed metadata.
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      if (!isWeightIndexFile(file.path)) continue;
      _checkCancelled();
      final index = File('${root.path}/${repository.summary.id}/${file.path}');
      final type = await FileSystemEntity.type(index.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return false;
      if (type != FileSystemEntityType.file ||
          await index.resolveSymbolicLinks() != index.path) {
        throw const _DownloadFailure(
          DownloadStatus.conflict,
          '现有权重索引是目录或链接，未修改',
        );
      }
      try {
        final data = jsonDecode(await index.readAsString());
        final weights = data is Map ? data['weight_map'] : null;
        if (weights is! Map ||
            weights.isEmpty ||
            weights.values.any((value) => value is! String)) {
          throw const FormatException('无效 weight_map');
        }
        final slash = file.path.lastIndexOf('/');
        final prefix = slash < 0 ? '' : file.path.substring(0, slash + 1);
        for (final weight in weights.values.toSet().cast<String>()) {
          validateAssetPath(weight);
          final matches = repository.files.where(
            (item) => item.path == '$prefix$weight',
          );
          if (matches.length != 1) throw const FormatException('索引引用不属于此版本');
          if (!files.any((item) => item.path == matches.single.path)) {
            files.add(matches.single);
          }
        }
      } on FormatException {
        throw const _DownloadFailure(
          DownloadStatus.conflict,
          '现有权重索引与固定模型包不一致，未修改',
        );
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    _totalBytes = files.every((file) => file.sizeBytes != null)
        ? files.fold<int>(0, (sum, file) => sum + file.sizeBytes!)
        : null;
    final id = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              repository.summary.id,
              repository.revision,
              files.map((file) => file.path).toList()..sort(),
            ]),
          ),
        )
        .toString();
    final manifestFile = File(
      '${root.path}/.ghostmodeldeck/installations/$id.json',
    );
    Map<String, dynamic>? manifest;
    if (await manifestFile.exists()) {
      if (await manifestFile.resolveSymbolicLinks() != manifestFile.path) {
        throw const _DownloadFailure(DownloadStatus.conflict, '安装记录是链接，未修改');
      }
      try {
        final data = jsonDecode(await manifestFile.readAsString());
        final metadata = {
          for (final file in files)
            '${repository.summary.id}/${file.path}': file,
        };
        final rows = data is Map && data['files'] is List
            ? data['files'] as List
            : null;
        final validRows =
            rows != null &&
            rows.length == files.length &&
            rows.map((row) => row is Map ? row['path'] : null).toSet().length ==
                files.length &&
            rows.every((row) {
              if (row is! Map) return false;
              final file = metadata[row['path']];
              return file != null &&
                  row['sizeBytes'] is int &&
                  row['sizeBytes'] >= 0 &&
                  (file.sizeBytes == null ||
                      row['sizeBytes'] == file.sizeBytes) &&
                  row['sha256'] is String &&
                  RegExp(r'^[0-9a-fA-F]{64}$')
                      .hasMatch(row['sha256'] as String) &&
                  row['upstreamSha256'] == file.sha256 &&
                  row['gitBlobId'] == file.blobId &&
                  row['isLfs'] == file.isLfs;
            });
        if (data is Map<String, dynamic> &&
            data['version'] == 1 &&
            data['id'] == id &&
            data['repoId'] == repository.summary.id &&
            data['revision'] == repository.revision &&
            ['hf', 'lmStudio', 'local'].contains(data['source']) &&
            (data['source'] != 'local' ||
                (data['reusedExisting'] == true &&
                    data['sourceTransferPerformed'] == false)) &&
            validRows) {
          manifest = data;
        }
      } on FormatException {
        // A malformed record does not prove that a package is installed.
      }
      if (manifest == null) {
        throw const _DownloadFailure(
          DownloadStatus.conflict,
          '安装记录与固定模型包不一致，未修改',
        );
      }
    }
    final records = <Map<String, dynamic>>[];
    var allPresent = true;
    for (final file in files) {
      _checkCancelled();
      validateAssetPath(file.path);
      final relative = '${repository.summary.id}/${file.path}';
      final target = File('${root.path}/$relative');
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        allPresent = false;
        continue;
      }
      if (type != FileSystemEntityType.file ||
          await target.resolveSymbolicLinks() != target.path) {
        throw _DownloadFailure(
          DownloadStatus.conflict,
          '$relative 已是目录或链接，未修改',
        );
      }
      _currentFile = file.path;
      final size = await target.length();
      _downloadedBytes += size;
      _publish(DownloadStatus.verifying);
      final digest = (await sha256.bind(target.openRead()).first).toString();
      final known = (manifest?['files'] as List?)
          ?.where((record) => record is Map && record['path'] == relative)
          .toList();
      final saved = known?.length == 1 ? known!.single as Map : null;
      final checksGit = file.isLfs == false && file.blobId != null;
      final gitDigest = checksGit
          ? (await sha1.bind(_gitBlobBytes(target, size)).first).toString()
          : null;
      if ((file.sizeBytes != null && size != file.sizeBytes) ||
          (file.sha256 != null && digest != file.sha256!.toLowerCase()) ||
          (checksGit && gitDigest != file.blobId!.toLowerCase()) ||
          (saved != null &&
              (digest != (saved['sha256'] as String).toLowerCase() ||
                  size != saved['sizeBytes']))) {
        throw _DownloadFailure(
          DownloadStatus.conflict,
          '$relative 现有内容与固定版本不一致，未修改',
        );
      }
      if (file.sha256 == null && !checksGit && saved == null) {
        allPresent = false;
      }
      records.add({
        'path': relative,
        'sizeBytes': size,
        'sha256': digest,
        'upstreamSha256': file.sha256,
        'gitBlobId': file.blobId,
        'isLfs': file.isLfs,
        'upstreamVerified': file.sha256 != null || checksGit,
      });
    }
    _checkCancelled();
    if (!allPresent) return false;
    if (manifest == null) {
      await _directory(root, '.ghostmodeldeck/installations');
      final temporary = File('${manifestFile.path}.new');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'id': id,
          'repoId': repository.summary.id,
          'revision': repository.revision,
          'source': 'local',
          'requestedSource': _source?.name,
          'reusedExisting': true,
          'sourceTransferPerformed': false,
          'license': repository.summary.license,
          'metadataEndpoint': repository.source.toString(),
          'files': records,
        }),
        flush: true,
      );
      _checkCancelled();
      if (_linkFile(temporary, manifestFile) != 0) {
        await temporary.delete();
        throw const _DownloadFailure(DownloadStatus.conflict, '安装记录已存在，未覆盖');
      }
      await temporary.delete();
    }
    _source = switch (manifest?['source']) {
      'hf' => DownloadSource.hf,
      'lmStudio' => DownloadSource.lmStudio,
      _ => null,
    };
    _reusedExisting = true;
    _publish(DownloadStatus.installed, installationId: id);
    return true;
  }

  Future<void> _receive(
    HfModelFile file,
    File partial,
    Uri uri,
    Map<String, dynamic> saved,
    Future<void> Function() save,
  ) async {
    final offset = await partial.exists() ? await partial.length() : 0;
    _downloadedBytes += offset;
    _publish(DownloadStatus.downloading);
    _checkCancelled();
    final validator = saved['etag'];
    if (offset > 0 &&
        (saved['acceptsRanges'] != true ||
            validator is! String ||
            !validator.startsWith('"') ||
            !validator.endsWith('"'))) {
      throw const _DownloadFailure(
        DownloadStatus.restartRequired,
        '此来源没有可验证的续传能力；需要重新下载',
      );
    }
    _request = await _client!.getUrl(uri);
    _checkCancelled();
    _request!.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (offset > 0) {
      _request!.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      _request!.headers.set(HttpHeaders.ifRangeHeader, validator);
    }
    final response = await _request!.close().timeout(
      const Duration(seconds: 30),
    );
    _checkCancelled();
    if (response.statusCode >= HttpStatus.badRequest &&
        response.statusCode != HttpStatus.requestedRangeNotSatisfiable) {
      throw _DownloadFailure(
        DownloadStatus.failed,
        '下载请求失败 (${response.statusCode})',
      );
    }
    final etag = response.headers.value(HttpHeaders.etagHeader);
    final commit = response.headers.value('x-repo-commit');
    if (commit != null && commit.toLowerCase() != _revision!.toLowerCase()) {
      throw const _DownloadFailure(
        DownloadStatus.restartRequired,
        '远端版本与固定 commit 不一致；需要重新下载',
      );
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw const _DownloadFailure(DownloadStatus.failed, '来源返回了压缩内容，无法验证文件字节');
    }
    if (offset > 0) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (response.statusCode != HttpStatus.partialContent ||
          etag != validator ||
          range == null ||
          int.parse(range.group(1)!) != offset ||
          int.parse(range.group(2)!) < offset ||
          int.parse(range.group(2)!) >= int.parse(range.group(3)!) ||
          (saved['totalBytes'] != null &&
              int.parse(range.group(3)!) != saved['totalBytes']) ||
          (file.sizeBytes != null &&
              int.parse(range.group(3)!) != file.sizeBytes) ||
          (response.contentLength >= 0 &&
              response.contentLength !=
                  int.parse(range.group(2)!) - offset + 1)) {
        throw const _DownloadFailure(
          DownloadStatus.restartRequired,
          '来源未保持版本或未正确响应 Range；保留片段',
        );
      }
      saved['totalBytes'] = int.parse(range.group(3)!);
    } else {
      if (response.statusCode != HttpStatus.ok) {
        throw _DownloadFailure(
          DownloadStatus.failed,
          '下载请求失败 (${response.statusCode})',
        );
      }
      if (file.sizeBytes != null &&
          response.contentLength >= 0 &&
          file.sizeBytes != response.contentLength) {
        throw const _DownloadFailure(
          DownloadStatus.failed,
          '来源返回的文件大小与版本清单不一致',
        );
      }
      saved['etag'] = etag;
      saved['acceptsRanges'] =
          response.headers
              .value(HttpHeaders.acceptRangesHeader)
              ?.toLowerCase() ==
          'bytes';
      saved['totalBytes'] = response.contentLength >= 0
          ? response.contentLength
          : file.sizeBytes;
    }
    await save();
    _checkCancelled();
    final output = await partial.open(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    _body = StreamIterator(response.timeout(const Duration(seconds: 30)));
    try {
      _checkCancelled();
      while (await _body!.moveNext()) {
        _checkCancelled();
        final chunk = _body!.current;
        await output.writeFrom(chunk);
        _downloadedBytes += chunk.length;
        _publish(DownloadStatus.downloading);
        _checkCancelled();
      }
    } finally {
      try {
        await _cleanUp([
          () async => await _bodyCancellation,
          () async => await _body?.cancel(),
          output.close,
        ]);
      } finally {
        _body = null;
      }
    }
  }

  Future<void> _install(
    Directory root,
    List<File> staged,
    List<Map<String, dynamic>> records,
    File manifest,
    String id,
  ) async {
    final linked = <(File, File)>[];
    try {
      for (var i = 0; i < staged.length; i++) {
        _checkCancelled();
        final path = records[i]['path'] as String;
        await _directory(root, path.substring(0, path.lastIndexOf('/')));
        final target = File('${root.path}/$path');
        final type = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.file &&
            await target.length() == records[i]['sizeBytes'] &&
            (await sha256.bind(target.openRead()).first).toString() ==
                records[i]['sha256']) {
          continue;
        }
        if (type != FileSystemEntityType.notFound) {
          throw const _DownloadFailure(
            DownloadStatus.conflict,
            '同名正式文件内容不同或目标为目录/链接，未覆盖',
          );
        }
        if (_linkFile(staged[i], target) != 0) {
          throw const _DownloadFailure(
            DownloadStatus.conflict,
            '同名正式文件已存在，未覆盖',
          );
        }
        linked.add((staged[i], target));
      }
      _checkCancelled();
      await _directory(root, '.ghostmodeldeck/installations');
      _checkCancelled();
      final target = File(
        '${root.path}/.ghostmodeldeck/installations/$id.json',
      );
      if (_linkFile(manifest, target) != 0) {
        throw const _DownloadFailure(DownloadStatus.conflict, '安装记录已存在，未覆盖');
      }
    } catch (_) {
      await _cleanUp([
        for (final (temporary, target) in linked.reversed)
          () async {
            if (await FileSystemEntity.identical(temporary.path, target.path)) {
              await target.delete();
            }
          },
      ]);
      rethrow;
    }
  }

  Future<void> _cleanUp(Iterable<FutureOr<void> Function()> releases) async {
    for (final release in releases) {
      try {
        await release();
      } catch (error) {
        _cleanupFailure ??= error is _DownloadCleanupFailure
            ? error
            : _DownloadCleanupFailure(error);
        _closed = true;
      }
    }
    if (_cleanupFailure != null) throw _cleanupFailure!;
  }

  void _checkCancelled() {
    if (_cancelled) {
      throw const _DownloadFailure(DownloadStatus.cancelled, '已取消');
    }
  }

  void _publish(
    DownloadStatus status, {
    String? error,
    String? installationId,
  }) {
    if (_changes.isClosed) return;
    _state = DownloadState(
      status: status,
      repositoryId: _repositoryId,
      revision: _revision,
      currentFile: _currentFile,
      downloadedBytes: _downloadedBytes,
      totalBytes: _totalBytes,
      error: error,
      installationId: installationId,
      libraryPath: _libraryPath,
      modelPackageId: _packageSelection?.modelPackage.id,
      modelLabel: _packageSelection?.modelPackage.label,
      variantId: _packageSelection?.variant.id,
      variantLabel: _packageSelection?.variant.label,
      source: _source,
      reusedExisting: _reusedExisting,
    );
    _changes.add(_state);
  }

  void cancel() {
    if (!_state.isActive) return;
    _cancelled = true;
    for (final release in <void Function()>[
      () => _request?.abort(
        const _DownloadFailure(DownloadStatus.cancelled, '已取消'),
      ),
      () {
        _bodyCancellation ??= _body?.cancel().then<void>((_) {});
        // The receive/download finalizers own and await this first cancellation.
        _bodyCancellation?.ignore();
      },
      () => _client?.close(force: true),
    ]) {
      try {
        release();
      } catch (error) {
        _cleanupFailure ??= _DownloadCleanupFailure(error);
        _closed = true;
      }
    }
  }

  /// Seal new downloads and wait for owned file handles and installation
  /// rollback before the application exits.
  Future<void> close() => _closing ??= _finishClosing();

  Future<void> _finishClosing() async {
    _closed = true;
    await _cleanUp([cancel, () async => await _operation, _changes.close]);
  }
}

List<List<Object?>> _fileIdentity(List<HfModelFile> files) =>
    (files.toList()..sort((a, b) => a.path.compareTo(b.path)))
        .map(
          (file) => <Object?>[
            file.path,
            file.sizeBytes,
            file.sha256,
            file.blobId,
            file.isLfs,
          ],
        )
        .toList();

Future<void> _saveSnapshot(File file, Map<String, dynamic> snapshot) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(snapshot), flush: true);
  await temporary.rename(file.path);
}

Stream<List<int>> _gitBlobBytes(File file, int size) async* {
  yield utf8.encode('blob $size\u0000');
  yield* file.openRead();
}

Future<Directory> _directory(Directory root, String relative) async {
  var current = root;
  for (final part in relative.split('/').where((part) => part.isNotEmpty)) {
    current = Directory('${current.path}/$part');
    final type = await FileSystemEntity.type(current.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const _DownloadFailure(
        DownloadStatus.conflict,
        '目标目录包含同名文件或链接，未修改',
      );
    }
    await current.create();
  }
  return current;
}

final _posixLink = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)
    >('link');

int _linkFile(File source, File target) {
  final from = source.path.toNativeUtf8();
  final to = target.path.toNativeUtf8();
  try {
    return _posixLink(from, to);
  } finally {
    malloc.free(from);
    malloc.free(to);
  }
}

class _DownloadFailure implements Exception {
  const _DownloadFailure(this.status, this.message);
  final DownloadStatus status;
  final String message;
}

class _DownloadCleanupFailure implements Exception {
  const _DownloadCleanupFailure(this.cause);
  final Object cause;
  @override
  String toString() => '下载清理未完成：$cause';
}
