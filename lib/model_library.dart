import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hf_model_browser.dart';

enum AssetKind { decision, chat, adapter, encoder, unknown }

enum AssetIntegrity { complete, incomplete, corrupt, unknown }

enum EngineCapability { awaitingVerification, unsupported }

enum FingerprintKind { inventory, fullContent }

class LibraryArtifact {
  LibraryArtifact({
    required this.id,
    required List<LibraryFile> files,
    required this.format,
    required this.kind,
    required this.integrity,
    required this.engineCapability,
    this.architecture,
    this.quantization,
    this.decisionType,
    this.sourceVerified = false,
    this.repoId,
    this.revision,
    this.license,
    List<String> diagnostics = const [],
  }) : files = List.unmodifiable(files),
       diagnostics = List.unmodifiable(diagnostics);

  final String id;
  final List<LibraryFile> files;
  final String format;
  final AssetKind kind;
  final AssetIntegrity integrity;
  final EngineCapability engineCapability;
  final String? architecture;

  /// Configuration evidence only; neither tensor validation nor engine support.
  final String? quantization;
  final String? decisionType;
  final bool sourceVerified;
  final String? repoId;
  final String? revision;
  final String? license;
  final List<String> diagnostics;
  String get name =>
      repoId ?? files.first.path.split(Platform.pathSeparator).last;
  int get sizeBytes => files.fold(0, (sum, file) => sum + file.sizeBytes);
  bool get fingerprintsVerified =>
      files.isNotEmpty && files.every((file) => file.sha256 != null);
}

class LibraryFile {
  const LibraryFile({
    required this.path,
    required this.sizeBytes,
    this.sha256,
    this.modifiedAtUtc,
    this.prefixSha256,
    this.prefixBytes = 0,
  });
  final String path;
  final int sizeBytes;
  final String? sha256;
  final DateTime? modifiedAtUtc;
  final String? prefixSha256;
  final int prefixBytes;
  FingerprintKind get fingerprintKind =>
      sha256 == null ? FingerprintKind.inventory : FingerprintKind.fullContent;
}

class LibraryState {
  LibraryState({
    this.rootPath,
    this.scanning = false,
    this.error,
    List<LibraryArtifact> artifacts = const [],
  }) : artifacts = List.unmodifiable(artifacts);
  final String? rootPath;
  final bool scanning;
  final String? error;
  final List<LibraryArtifact> artifacts;
}

class LibraryException implements Exception {
  const LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DeletionPlan {
  DeletionPlan._(this._owner, this.rootPath, List<LibraryFile> files)
    : files = List.unmodifiable(files);
  final Object _owner;
  final String rootPath;
  final List<LibraryFile> files;
  int get sizeBytes => files.fold(0, (sum, file) => sum + file.sizeBytes);
}

enum DeletionResult { cancelled, deleted }

class ModelLibrary {
  final _changes = StreamController<LibraryState>.broadcast();
  LibraryState _state = LibraryState();
  LibraryState get state => _state;
  Stream<LibraryState> get changes => _changes.stream;
  int _generation = 0;
  final _filesInUse = <String>{};
  bool _deleting = false;
  Set<String> _deletingPaths = {};

  Future<List<LibraryArtifact>> scan(
    Directory root, {
    bool verifyFiles = false,
  }) => _scan(root, verifyFiles: verifyFiles);

  Future<List<LibraryArtifact>> _scan(
    Directory root, {
    required bool verifyFiles,
    Set<String>? fullPaths,
    Set<String>? selectedIds,
  }) async {
    final generation = ++_generation;
    final previous = state;
    _publish(LibraryState(rootPath: root.absolute.path, scanning: true));
    try {
      final rootPath = await root.resolveSymbolicLinks();
      final discovered = <_ScannedFile>[];
      final allFiles = <String, File>{};
      final records = <String, LibraryFile>{};
      final prefixes = <String, (String, int)>{};
      Future<LibraryFile> record(String path) async {
        if (records.containsKey(path)) return records[path]!;
        final file = allFiles[path]!;
        await _requireRealFile(rootPath, path);
        final stat = await file.stat();
        final fingerprint = verifyFiles || fullPaths?.contains(path) == true
            ? (await sha256.bind(file.openRead()).first).toString()
            : null;
        await _requireRealFile(rootPath, path);
        final after = await file.stat();
        if (stat.size != after.size || stat.modified != after.modified) {
          throw const LibraryException('文件在扫描期间变化，请重新扫描');
        }
        return records[path] = LibraryFile(
          path: path,
          sizeBytes: stat.size,
          sha256: fingerprint,
          modifiedAtUtc: stat.modified.toUtc(),
          prefixSha256: prefixes[path]?.$1,
          prefixBytes: prefixes[path]?.$2 ?? 0,
        );
      }

      await for (final entity in Directory(
        rootPath,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File ||
            entity.path.startsWith('$rootPath/.ghostmodeldeck/')) {
          continue;
        }
        allFiles[entity.path] = entity;
        if (fullPaths != null && !fullPaths.contains(entity.path)) continue;
        await _requireRealFile(rootPath, entity.path);
        final stat = await entity.stat();
        final reader = await entity.open();
        late Uint8List prefix;
        _Inspection? inspection;
        try {
          prefix = await reader.read(stat.size < 65536 ? stat.size : 65536);
          inspection = _inspect(prefix, stat.size);
          while (inspection?.needsMoreBytes == true &&
              prefix.length < stat.size &&
              prefix.length < _headerLimit) {
            var next = prefix.length * 4;
            if (inspection!.format == 'Safetensors' && prefix.length >= 8) {
              next =
                  ByteData.sublistView(prefix).getUint64(0, Endian.little) + 8;
            }
            if (next > _headerLimit) next = _headerLimit;
            if (next > stat.size) next = stat.size;
            final extra = await reader.read(next - prefix.length);
            if (extra.isEmpty) break;
            prefix =
                (BytesBuilder()
                      ..add(prefix)
                      ..add(extra))
                    .toBytes();
            inspection = _inspect(prefix, stat.size);
          }
        } finally {
          await reader.close();
        }
        prefixes[entity.path] = (
          sha256.convert(prefix).toString(),
          prefix.length,
        );
        if (inspection == null) continue;
        discovered.add(_ScannedFile(await record(entity.path), inspection));
      }
      final groupFiles = fullPaths == null
          ? allFiles
          : {
              for (final entry in allFiles.entries)
                if (fullPaths.contains(entry.key)) entry.key: entry.value,
            };
      final safetensors = await _groupSafetensors(
        discovered,
        groupFiles,
        record,
      );
      final artifacts = [
        ..._groupGguf(
          discovered
              .where((file) => !safetensors.consumed.contains(file.file.path))
              .toList(),
        ),
        ...safetensors.artifacts,
      ]..sort((a, b) => a.files.first.path.compareTo(b.files.first.path));
      final verified = await _applyManifests(
        rootPath,
        artifacts,
        allFiles,
        record,
        {
          for (final file in discovered)
            if (file.inspection.format == 'GGUF' ||
                file.inspection.format == 'Safetensors')
              file.file.path,
        },
      );
      if (generation == _generation) {
        final displayed =
            selectedIds == null
                  ? verified
                  : [
                      ...previous.artifacts.where(
                        (artifact) => !selectedIds.contains(artifact.id),
                      ),
                      ...verified,
                    ]
              ..sort(
                (a, b) => a.files.first.path.compareTo(b.files.first.path),
              );
        _publish(LibraryState(rootPath: rootPath, artifacts: displayed));
      }
      return List.unmodifiable(verified);
    } on LibraryException catch (error) {
      if (generation == _generation) {
        _publish(
          LibraryState(rootPath: root.absolute.path, error: error.message),
        );
      }
      return [];
    } on FileSystemException {
      if (generation == _generation) {
        _publish(
          LibraryState(rootPath: root.absolute.path, error: '无法读取所选模型库'),
        );
      }
      return [];
    }
  }

  Future<List<LibraryArtifact>> verify(Iterable<String> artifactIds) async {
    if (state.scanning || _deleting || state.rootPath == null) {
      throw const LibraryException('请等待当前操作完成');
    }
    final ids = artifactIds.toSet();
    final selected = state.artifacts
        .where((artifact) => ids.contains(artifact.id))
        .toList();
    if (ids.isEmpty || selected.length != ids.length) {
      throw const LibraryException('所选资产已变化，请重新选择');
    }
    final paths = {
      for (final artifact in selected)
        for (final file in artifact.files) file.path,
    };
    final artifacts = await _scan(
      Directory(state.rootPath!),
      verifyFiles: false,
      fullPaths: paths,
      selectedIds: ids,
    );
    final verified = artifacts
        .where(
          (artifact) => artifact.files.any((file) => paths.contains(file.path)),
        )
        .toList();
    if (verified.length != selected.length ||
        verified.any((artifact) => !artifact.fingerprintsVerified)) {
      throw const LibraryException('所选资产文件组已变化，请重新选择并核验');
    }
    return List.unmodifiable(verified);
  }

  void _publish(LibraryState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  Future<DeletionPlan> prepareDeletion(Iterable<String> artifactIds) async {
    if (state.scanning || _deleting || state.rootPath == null) {
      throw const LibraryException('请等待当前操作完成');
    }
    final ids = artifactIds.toSet();
    final selected = state.artifacts
        .where((artifact) => ids.contains(artifact.id))
        .toList();
    if (ids.isEmpty || selected.length != ids.length) {
      throw const LibraryException('所选资产已变化，请重新选择');
    }
    final root = state.rootPath!;
    final files = {
      for (final artifact in selected)
        for (final file in artifact.files) file.path: file,
    };
    await _assertNotInUse(files.values);
    final snapshots = <LibraryFile>[];
    try {
      for (final file in files.values) {
        snapshots.add(await _snapshot(root, file));
      }
    } on FileSystemException catch (error) {
      throw LibraryException('无法读取所选文件: ${error.path ?? ''}');
    }
    await _assertNotInUse(snapshots);
    snapshots.sort((a, b) => a.path.compareTo(b.path));
    return DeletionPlan._(this, root, snapshots);
  }

  Future<DeletionResult> delete(
    DeletionPlan plan, {
    required bool confirmed,
  }) async {
    if (!confirmed) return DeletionResult.cancelled;
    if (!identical(plan._owner, this)) {
      throw const LibraryException('删除计划不属于当前模型库');
    }
    if (_deleting || plan.files.isEmpty) throw const LibraryException('当前不能删除');
    _deleting = true;
    _deletingPaths = plan.files.map((file) => file.path).toSet();
    var deleted = 0;
    try {
      await _assertNotInUse(plan.files);
      // Validate every file before deleting the first one.
      final validated = <LibraryFile>[];
      for (final file in plan.files) {
        validated.add(await _snapshot(plan.rootPath, file));
      }
      for (final file in validated) {
        await _assertNotInUse(plan.files);
        await _requireRealFile(plan.rootPath, file.path);
        final stat = await File(file.path).stat();
        if (stat.size != file.sizeBytes ||
            stat.modified.toUtc() != file.modifiedAtUtc) {
          throw LibraryException('文件已变化，请重新扫描: ${file.path}');
        }
        if (_filesInUse.contains(file.path)) {
          throw LibraryException('文件仍在使用，请先停止实例: ${file.path}');
        }
        await File(file.path).delete();
        deleted++;
      }
      return DeletionResult.deleted;
    } on LibraryException catch (error) {
      if (deleted > 0) {
        throw LibraryException('已删除 $deleted 个文件；${error.message}');
      }
      rethrow;
    } on FileSystemException catch (error) {
      throw LibraryException('已删除 $deleted 个文件；删除失败: ${error.path ?? ''}');
    } finally {
      _deleting = false;
      _deletingPaths = {};
      if (deleted > 0 && state.rootPath == plan.rootPath) {
        await scan(Directory(plan.rootPath));
      }
    }
  }

  Future<LibraryFile> _snapshot(String root, LibraryFile expected) async {
    if (await Directory(root).resolveSymbolicLinks() != root) {
      throw const LibraryException('模型库目录已变化');
    }
    await _requireRealFile(root, expected.path);
    final file = File(expected.path);
    final before = await file.stat();
    if (before.size != expected.sizeBytes ||
        expected.sha256 == null &&
            expected.modifiedAtUtc != null &&
            before.modified.toUtc() != expected.modifiedAtUtc) {
      throw LibraryException('文件已变化，请重新扫描: ${expected.path}');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    await _requireRealFile(root, expected.path);
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        expected.sha256 != null && digest != expected.sha256) {
      throw LibraryException('文件已变化，请重新扫描: ${expected.path}');
    }
    return LibraryFile(
      path: expected.path,
      sizeBytes: after.size,
      sha256: digest,
      modifiedAtUtc: after.modified.toUtc(),
    );
  }

  Future<void> _assertNotInUse(Iterable<LibraryFile> files) async {
    for (final file in files) {
      for (final active in _filesInUse.toList()) {
        var same = active == file.path;
        if (!same) {
          try {
            same = await FileSystemEntity.identical(active, file.path);
          } on FileSystemException {
            /* Unavailable active path. */
          }
        }
        if (same) throw LibraryException('文件仍在使用，请先停止实例: ${file.path}');
      }
      if (_filesInUse.contains(file.path)) {
        throw LibraryException('文件仍在使用，请先停止实例: ${file.path}');
      }
    }
  }

  Future<void> setFilesInUse(Iterable<String> paths) async {
    final canonical = <String>{};
    for (final path in paths) {
      try {
        canonical.add(await File(path).resolveSymbolicLinks());
      } on FileSystemException {
        canonical.add(File(path).absolute.uri.normalizePath().toFilePath());
      }
    }
    if (_deleting && canonical.any(_deletingPaths.contains)) {
      throw const LibraryException('文件正在删除，暂不能启用实例');
    }
    _filesInUse
      ..clear()
      ..addAll(canonical);
  }

  void close() {
    _generation++;
    _changes.close();
  }
}

bool _inside(String root, String path) =>
    path != root &&
    path.startsWith(
      root.endsWith(Platform.pathSeparator)
          ? root
          : '$root${Platform.pathSeparator}',
    );

Future<void> _requireRealFile(String root, String path) async {
  if (!_inside(root, path) ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file ||
      await File(path).resolveSymbolicLinks() != path) {
    throw LibraryException('文件已变更或超出模型库: $path');
  }
}

Future<List<LibraryArtifact>> _applyManifests(
  String root,
  List<LibraryArtifact> artifacts,
  Map<String, File> allFiles,
  Future<LibraryFile> Function(String) record,
  Set<String> weightPaths,
) async {
  final directory = Directory('$root/.ghostmodeldeck/installations');
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      await directory.resolveSymbolicLinks() != directory.path) {
    return artifacts;
  }
  final manifests = <Map<String, dynamic>>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    await _requireRealFile(root, entity.path);
    final value = await _readJson(entity);
    if (value == null ||
        value['version'] != 1 ||
        value['id'] is! String ||
        value['repoId'] is! String ||
        value['revision'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(value['revision'] as String) ||
        !['hf', 'lmStudio', 'local'].contains(value['source']) ||
        (value['source'] == 'local' &&
            (value['reusedExisting'] != true ||
                value['sourceTransferPerformed'] != false)) ||
        value['files'] is! List) {
      continue;
    }
    final files = value['files'] as List;
    if (files.isEmpty ||
        files.length > 100000 ||
        files.any(
          (file) =>
              file is! Map ||
              file['path'] is! String ||
              _relativeFile(root, file['path'] as String) == null ||
              file['sizeBytes'] is! int ||
              file['sizeBytes'] < 0 ||
              file['sha256'] is! String ||
              !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(file['sha256'] as String),
        )) {
      continue;
    }
    if (files.map((file) => file['path']).toSet().length != files.length) {
      continue;
    }
    manifests.add(value);
  }
  final result = <LibraryArtifact>[];
  for (final artifact in artifacts) {
    // Shared config/tokenizer files cannot establish a model's receipt identity.
    // Anchor on every structurally inspected weight, regardless of filename.
    final corePaths = artifact.files
        .where(
          (file) => weightPaths.contains(file.path) || artifact.format == '未知',
        )
        .map((file) => file.path)
        .toSet();
    final matching = manifests.where((manifest) {
      final receiptPaths = {
        for (final file in manifest['files'] as List)
          _relativeFile(root, file['path'] as String),
      };
      return corePaths.isNotEmpty && receiptPaths.containsAll(corePaths);
    }).toList();
    if (matching.isEmpty) {
      result.add(artifact);
      continue;
    }
    int matchScore(Map<String, dynamic> manifest) {
      var score = 0;
      for (final expected in manifest['files'] as List) {
        for (final actual in artifact.files) {
          if (actual.path == _relativeFile(root, expected['path'] as String) &&
              actual.sizeBytes == expected['sizeBytes'] &&
              actual.sha256 == (expected['sha256'] as String).toLowerCase()) {
            score += 1000000;
            if (expected['upstreamSha256'] is String &&
                actual.sha256 ==
                    (expected['upstreamSha256'] as String).toLowerCase()) {
              score++;
            }
          }
        }
      }
      return score;
    }

    // An older revision may have a receipt for a path now occupied by a new one.
    matching.sort((a, b) => matchScore(b).compareTo(matchScore(a)));
    final manifest = matching.first;
    final diagnostics = [...artifact.diagnostics];
    var integrity = artifact.integrity;
    var sourceVerified = artifact.fingerprintsVerified;
    final files = {for (final file in artifact.files) file.path: file};
    final covered = <String>{};
    for (final entry in manifest['files'] as List) {
      final path = _relativeFile(root, entry['path'] as String)!;
      if (!allFiles.containsKey(path)) {
        sourceVerified = false;
        if (integrity != AssetIntegrity.corrupt) {
          integrity = AssetIntegrity.incomplete;
        }
        diagnostics.add('安装记录缺少文件: ${entry['path']}');
        continue;
      }
      covered.add(path);
      final actual = await record(path);
      files[path] = actual;
      if (actual.sizeBytes != entry['sizeBytes'] ||
          actual.sha256 != null &&
              actual.sha256 != (entry['sha256'] as String).toLowerCase()) {
        integrity = AssetIntegrity.corrupt;
        sourceVerified = false;
        diagnostics.add('安装记录指纹不符: ${entry['path']}');
        continue;
      }
      if (actual.sha256 == null) {
        sourceVerified = false;
        continue;
      }
      final upstream = entry['upstreamSha256'];
      final blob = entry['gitBlobId'];
      if (upstream is String &&
          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(upstream)) {
        if (actual.sha256 != upstream.toLowerCase()) {
          integrity = AssetIntegrity.corrupt;
          sourceVerified = false;
          diagnostics.add('上游 SHA-256 不符: ${entry['path']}');
        }
      } else if (entry['isLfs'] == false &&
          blob is String &&
          RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(blob)) {
        final digest =
            (await sha1.bind(_gitBlob(allFiles[path]!, actual.sizeBytes)).first)
                .toString();
        if (digest != blob.toLowerCase()) {
          integrity = AssetIntegrity.corrupt;
          sourceVerified = false;
          diagnostics.add('上游 Git 对象不符: ${entry['path']}');
        }
      } else {
        sourceVerified = false;
      }
    }
    if (artifact.files.any((file) => !covered.contains(file.path))) {
      sourceVerified = false;
    }
    if (!sourceVerified) diagnostics.add('来源未通过上游校验');
    result.add(
      LibraryArtifact(
        id: artifact.id,
        files: files.values.toList(),
        format: artifact.format,
        kind: artifact.kind,
        integrity: integrity,
        engineCapability: artifact.engineCapability,
        architecture: artifact.architecture,
        quantization: artifact.quantization,
        decisionType: artifact.decisionType,
        sourceVerified: sourceVerified,
        repoId: manifest['repoId'] as String,
        revision: manifest['revision'] as String,
        license: manifest['license'] is String
            ? manifest['license'] as String
            : null,
        diagnostics: diagnostics,
      ),
    );
  }
  return result;
}

Stream<List<int>> _gitBlob(File file, int size) async* {
  yield utf8.encode('blob $size\u0000');
  yield* file.openRead();
}

const _headerLimit = 32 * 1024 * 1024;

class _ScannedFile {
  const _ScannedFile(this.file, this.inspection);
  final LibraryFile file;
  final _Inspection inspection;
}

class _Inspection {
  _Inspection(
    this.format,
    this.integrity, {
    this.metadata = const {},
    this.tensors = const {},
    this.diagnostics = const [],
    this.needsMoreBytes = false,
  });
  final String format;
  final AssetIntegrity integrity;
  final Map<String, Object?> metadata;
  final Map<String, List<int>> tensors;
  final List<String> diagnostics;
  final bool needsMoreBytes;
}

_Inspection? _inspect(Uint8List bytes, int size) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x47 &&
      bytes[2] == 0x55 &&
      bytes[3] == 0x46) {
    try {
      return _readGguf(bytes, size);
    } on _ScanLimit {
      return _Inspection(
        'GGUF',
        AssetIntegrity.unknown,
        diagnostics: ['Metadata 超过扫描上限'],
        needsMoreBytes: true,
      );
    } on FormatException catch (error) {
      return _Inspection(
        'GGUF',
        AssetIntegrity.corrupt,
        diagnostics: [error.message],
      );
    }
  }
  final possibleSafeLength = bytes.length >= 9
      ? ByteData.sublistView(bytes).getUint64(0, Endian.little)
      : 0;
  if (bytes.length >= 9 &&
      bytes[8] == 0x7b &&
      possibleSafeLength >= 2 &&
      (possibleSafeLength <= size - 8 || possibleSafeLength <= _headerLimit)) {
    try {
      return _readSafetensors(bytes, size);
    } on _ScanLimit {
      return _Inspection(
        'Safetensors',
        AssetIntegrity.unknown,
        diagnostics: ['Header 超过扫描上限'],
        needsMoreBytes: true,
      );
    } on FormatException catch (error) {
      return _Inspection(
        'Safetensors',
        AssetIntegrity.corrupt,
        diagnostics: [error.message],
      );
    }
  }
  if (bytes.isEmpty) return _Inspection('未知', AssetIntegrity.unknown);
  try {
    final text = utf8.decode(bytes, allowMalformed: size > bytes.length);
    if (!text.contains('\u0000')) {
      return null; // Descriptive text is not a weight artifact.
    }
  } on FormatException {
    // Keep unrecognized binary files visible, regardless of their filename.
  }
  return _Inspection('未知', AssetIntegrity.unknown, diagnostics: ['未识别的二进制格式']);
}

_Inspection _readSafetensors(Uint8List bytes, int size) {
  final length = ByteData.sublistView(bytes).getUint64(0, Endian.little);
  if (length < 2 || length > size - 8) {
    throw const FormatException('Safetensors header 已截断');
  }
  if (length > bytes.length - 8) throw _ScanLimit();
  final raw = jsonDecode(utf8.decode(bytes.sublist(8, 8 + length)));
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('Safetensors header 异常');
  }
  final tensors = <String, List<int>>{};
  final ranges = <(int, int)>[];
  var knownSizes = true;
  final payloadSize = size - 8 - length;
  for (final entry in raw.entries) {
    if (entry.key == '__metadata__') {
      if (entry.value is! Map ||
          !(entry.value as Map).values.every((value) => value is String)) {
        throw const FormatException('Safetensors metadata 异常');
      }
      continue;
    }
    final value = entry.value;
    if (value is! Map) throw const FormatException('Safetensors tensor 字段异常');
    final shape = value['shape'];
    final offsets = value['data_offsets'];
    if (shape is! List ||
        shape.length > 16 ||
        shape.any((value) => value is! int || value < 0) ||
        offsets is! List ||
        offsets.length != 2 ||
        offsets.any((value) => value is! int || value < 0) ||
        offsets[1] < offsets[0] ||
        offsets[1] > payloadSize) {
      throw const FormatException('Safetensors tensor 范围异常');
    }
    var elements = 1;
    for (final dimension in shape.cast<int>()) {
      if (dimension > 0 && elements > payloadSize ~/ dimension + 1) {
        throw const FormatException('Safetensors tensor 大小异常');
      }
      elements *= dimension;
    }
    const widths = {
      'BOOL': 1,
      'U8': 1,
      'I8': 1,
      'U16': 2,
      'I16': 2,
      'U32': 4,
      'I32': 4,
      'U64': 8,
      'I64': 8,
      'F16': 2,
      'BF16': 2,
      'F32': 4,
      'F64': 8,
      'F8_E4M3': 1,
      'F8_E5M2': 1,
    };
    if (value['dtype'] is! String) {
      throw const FormatException('Safetensors dtype 字段异常');
    }
    final width = widths[value['dtype']];
    if (width == null) {
      knownSizes = false;
    } else if (elements * width != offsets[1] - offsets[0]) {
      throw const FormatException('Safetensors tensor 字节数不符');
    }
    tensors[entry.key] = shape.cast<int>();
    ranges.add((offsets[0] as int, offsets[1] as int));
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  var end = 0;
  for (final range in ranges) {
    if (range.$1 != end) throw const FormatException('Safetensors 数据有空洞或重叠');
    end = range.$2;
  }
  if (end != payloadSize) throw const FormatException('Safetensors 数据未完整索引');
  return _Inspection(
    'Safetensors',
    knownSizes ? AssetIntegrity.complete : AssetIntegrity.unknown,
    tensors: tensors,
    diagnostics: knownSizes ? [] : ['未知 tensor dtype'],
  );
}

Future<Map<String, dynamic>?> _readJson(File file) async {
  if (await file.length() > _headerLimit) return null;
  try {
    final value = jsonDecode(await file.readAsString());
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

String? _relativeFile(String directory, String relative) {
  final parts = relative.split('/');
  if (relative.isEmpty ||
      relative.startsWith('/') ||
      relative.contains('\\') ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  return '$directory/$relative';
}

class _SafetensorsGroups {
  const _SafetensorsGroups(this.artifacts, this.consumed);
  final List<LibraryArtifact> artifacts;
  final Set<String> consumed;
}

Future<_SafetensorsGroups> _groupSafetensors(
  List<_ScannedFile> discovered,
  Map<String, File> allFiles,
  Future<LibraryFile> Function(String) record,
) async {
  final weights = {
    for (final file in discovered.where(
      (file) => file.inspection.format == 'Safetensors',
    ))
      file.file.path: file,
  };
  final consumed = <String>{};
  final artifacts = <LibraryArtifact>[];
  final jsonCache = <String, Map<String, dynamic>?>{};
  Future<Map<String, dynamic>?> json(String path) async {
    if (jsonCache.containsKey(path)) return jsonCache[path];
    final file = allFiles[path];
    return jsonCache[path] = file == null ? null : await _readJson(file);
  }

  Future<void> bundle(
    String directory,
    List<_ScannedFile> selected, {
    String? indexPath,
    Map<String, dynamic>? index,
  }) async {
    final files = <String, LibraryFile>{
      for (final file in selected) file.file.path: file.file,
    };
    final diagnostics = selected
        .expand((file) => file.inspection.diagnostics)
        .toList();
    var integrity =
        selected.any(
          (file) => file.inspection.integrity == AssetIntegrity.corrupt,
        )
        ? AssetIntegrity.corrupt
        : selected.any(
            (file) => file.inspection.integrity == AssetIntegrity.unknown,
          )
        ? AssetIntegrity.unknown
        : AssetIntegrity.complete;
    void missing(String message) {
      if (integrity != AssetIntegrity.corrupt) {
        integrity = AssetIntegrity.incomplete;
      }
      diagnostics.add(message);
    }

    final tensors = <String, List<int>>{};
    for (final file in selected) {
      for (final entry in file.inspection.tensors.entries) {
        if (tensors.containsKey(entry.key)) {
          integrity = AssetIntegrity.corrupt;
          diagnostics.add('重复 tensor');
        }
        tensors[entry.key] = entry.value;
      }
    }
    if (indexPath != null) {
      files[indexPath] = await record(indexPath);
      final mapping = index!['weight_map'] as Map;
      for (final entry in mapping.entries) {
        final path = entry.value is String
            ? _relativeFile(directory, entry.value as String)
            : null;
        if (path == null || !weights.containsKey(path)) {
          missing('索引引用的权重文件缺失');
          continue;
        }
        if (!weights[path]!.inspection.tensors.containsKey(entry.key)) {
          missing('索引引用的 tensor 缺失');
        }
      }
      if (mapping.length != tensors.length) missing('权重与索引 tensor 集合不符');
    } else if (selected.length > 1) {
      if (integrity != AssetIntegrity.corrupt) {
        integrity = AssetIntegrity.unknown;
      }
      diagnostics.add('多文件权重尚未关联索引');
    }
    Future<Map<String, dynamic>?> companion(String relative) async {
      final path = '$directory/$relative';
      if (allFiles.containsKey(path)) {
        files[path] = await record(path);
        final result = await json(path);
        if (result == null) {
          if (await allFiles[path]!.length() > _headerLimit) {
            if (integrity == AssetIntegrity.complete) {
              integrity = AssetIntegrity.unknown;
            }
            diagnostics.add('$relative 超过扫描上限');
          } else {
            integrity = AssetIntegrity.corrupt;
            diagnostics.add('$relative 内容无效');
          }
        }
        return result;
      }
      return null;
    }

    var kind = AssetKind.unknown;
    String? architecture;
    String? decision;
    final adapter = await companion('adapter_config.json');
    final config = await companion('config.json');
    if (adapter?['peft_type'] is String &&
        tensors.keys.any((name) => name.contains('.lora_'))) {
      kind = AssetKind.adapter;
      final base = adapter?['base_model_name_or_path'];
      if (base is String) diagnostics.add('基座 $base 尚未关联');
      if (allFiles.containsKey('$directory/head.pt')) {
        files['$directory/head.pt'] = await record('$directory/head.pt');
      }
      await companion('tokenizer.json');
      await companion('tokenizer_config.json');
      await companion('training_config.json');
      missing('Adapter 的基座与决策 head 尚未关联');
    } else if (config?['model_type'] == 'laya' &&
        config?['architectures'] is List &&
        (config!['architectures'] as List).contains('LayaTypedDecisions')) {
      kind = AssetKind.decision;
      decision = 'laya';
      final encoder = await companion('encoder/config.json');
      final agent = await companion('rl_agent_config.json');
      final tokenizer = await companion('tokenizer/tokenizer.json');
      final tokenizerConfig = await companion(
        'tokenizer/tokenizer_config.json',
      );
      architecture = encoder?['model_type'] is String
          ? encoder!['model_type'] as String
          : null;
      if (encoder?['model_type'] != 'modernbert' ||
          agent == null ||
          tokenizer == null ||
          tokenizerConfig == null) {
        missing('缺少 Laya encoder/head/tokenizer 配置');
      } else {
        final required = _layaSafetensorsDimensions(encoder!, agent);
        if (required == null) {
          missing('Laya 配置缺少有效 head 或 encoder 参数');
        } else {
          for (final entry in required.entries) {
            if (!_dimensionsMatch(tensors[entry.key], entry.value)) {
              missing('缺少或不匹配 ${entry.key}');
            }
          }
        }
        final model = tokenizer['model'];
        final vocab = model is Map ? model['vocab'] : null;
        final added = tokenizer['added_tokens'];
        if (model is! Map ||
            model['type'] is! String ||
            vocab is! Map ||
            vocab.isEmpty) {
          missing('Tokenizer 词表未核验');
        }
        for (final key in ['cls_token', 'sep_token', 'mask_token']) {
          final token = tokenizerConfig[key];
          final inAdded =
              added is List &&
              added.any(
                (value) =>
                    value is Map &&
                    value['content'] == token &&
                    value['id'] is int,
              );
          if (token is! String ||
              token.isEmpty ||
              (vocab is! Map || !vocab.containsKey(token)) && !inAdded) {
            missing('Tokenizer 缺少 $key');
          }
        }
      }
    } else {
      final declared = config?['architectures'];
      architecture = config?['model_type'] is String
          ? config!['model_type'] as String
          : null;
      if (declared is List &&
          declared.any(
            (value) => value is String && value.endsWith('ForCausalLM'),
          )) {
        kind = AssetKind.chat;
      }
      if (config == null) {
        missing('缺少可识别的模型配置');
      } else if (integrity != AssetIntegrity.corrupt &&
          integrity != AssetIntegrity.incomplete) {
        integrity = AssetIntegrity.unknown;
      }
      diagnostics.add('架构必要 tensor 布局尚未核验');
      for (final name in [
        'tokenizer.json',
        'tokenizer_config.json',
        'special_tokens_map.json',
        'added_tokens.json',
        'vocab.json',
        'generation_config.json',
      ]) {
        await companion(name);
      }
      // Text/binary tokenizer fallbacks are assets too, not JSON documents.
      for (final name in [
        'merges.txt',
        'vocab.txt',
        'tokenizer.model',
        'chat_template.jinja',
      ]) {
        final path = '$directory/$name';
        if (allFiles.containsKey(path)) files[path] = await record(path);
      }
    }
    if (selected.isEmpty || tensors.isEmpty) missing('缺少权重');
    consumed.addAll(files.keys);
    final paths = files.keys.toList()..sort();
    artifacts.add(
      LibraryArtifact(
        id: sha256.convert(utf8.encode(paths.join('\n'))).toString(),
        files: files.values.toList(),
        format: 'Safetensors',
        kind: kind,
        integrity: integrity,
        architecture: architecture,
        quantization:
            config != null && (indexPath != null || selected.length == 1)
            ? NativeModelConfiguration.fromJson(config)?.quantization
            : null,
        decisionType: decision,
        engineCapability: EngineCapability.awaitingVerification,
        diagnostics: diagnostics,
      ),
    );
  }

  for (final file in allFiles.values.where(
    (file) => file.path.endsWith('.safetensors.index.json'),
  )) {
    final index = await json(file.path);
    if (index?['weight_map'] is! Map || (index!['weight_map'] as Map).isEmpty) {
      continue;
    }
    final directory = file.parent.path;
    final selected = <String, _ScannedFile>{};
    for (final value in (index['weight_map'] as Map).values) {
      final path = value is String ? _relativeFile(directory, value) : null;
      if (path != null && weights.containsKey(path)) {
        selected[path] = weights[path]!;
      }
    }
    await bundle(
      directory,
      selected.values.toList(),
      indexPath: file.path,
      index: index,
    );
  }
  final remaining = <String, List<_ScannedFile>>{};
  for (final file in weights.values.where(
    (file) => !consumed.contains(file.file.path),
  )) {
    remaining.putIfAbsent(File(file.file.path).parent.path, () => []).add(file);
  }
  for (final entry in remaining.entries) {
    await bundle(entry.key, entry.value);
  }
  return _SafetensorsGroups(artifacts, consumed);
}

// Original Laya tensor names are mapped by the same pinned conversion/bert.py
// and gguf-py/gguf/tensor_mapping.py used for the GGUF graph above.
Map<String, List<int>>? _layaSafetensorsDimensions(
  Map<String, dynamic> encoder,
  Map<String, dynamic> agent,
) {
  final hidden = encoder['hidden_size'];
  final count = encoder['num_hidden_layers'];
  final vocab = encoder['vocab_size'];
  final intermediate = encoder['intermediate_size'];
  final heads = agent['head_layers'];
  final attentionHeads = encoder['num_attention_heads'];
  final temperatures = agent['temperature'];
  if (hidden is! int ||
      hidden <= 0 ||
      vocab is! int ||
      vocab <= 0 ||
      intermediate is! int ||
      intermediate <= 0 ||
      count is! int ||
      count <= 0 ||
      count > 10000 ||
      heads is! int ||
      heads <= 0 ||
      heads > 10000 ||
      attentionHeads is! int ||
      attentionHeads <= 0 ||
      hidden % attentionHeads != 0 ||
      agent['head_max_len'] is! int ||
      (agent['head_max_len'] as int) <= 0 ||
      temperatures is! List ||
      temperatures.length != 3 ||
      temperatures.any(
        (value) => value is! num || !value.isFinite || value <= 0,
      )) {
    return null;
  }
  return {
    'encoder.embeddings.tok_embeddings.weight': [vocab, hidden],
    'encoder.embeddings.norm.weight': [hidden],
    'encoder.final_norm.weight': [hidden],
    'type_emb.weight': [3, hidden],
    'scorer.0.weight': [hidden],
    'scorer.0.bias': [hidden],
    'scorer.1.weight': [hidden, hidden],
    'scorer.1.bias': [hidden],
    'scorer.3.weight': [1, hidden],
    'scorer.3.bias': [1],
    for (var index = 0; index < count; index++) ...{
      if (index > 0) 'encoder.layers.$index.attn_norm.weight': [hidden],
      'encoder.layers.$index.attn.Wqkv.weight': [3 * hidden, hidden],
      'encoder.layers.$index.attn.Wo.weight': [hidden, hidden],
      'encoder.layers.$index.mlp.Wi.weight': [2 * intermediate, hidden],
      'encoder.layers.$index.mlp.Wo.weight': [hidden, intermediate],
      'encoder.layers.$index.mlp_norm.weight': [hidden],
    },
    for (var index = 0; index < heads; index++) ...{
      'head.layers.$index.norm1.weight': [hidden],
      'head.layers.$index.norm1.bias': [hidden],
      'head.layers.$index.self_attn.in_proj_weight': [3 * hidden, hidden],
      'head.layers.$index.self_attn.in_proj_bias': [3 * hidden],
      'head.layers.$index.self_attn.out_proj.weight': [hidden, hidden],
      'head.layers.$index.self_attn.out_proj.bias': [hidden],
      'head.layers.$index.norm2.weight': [hidden],
      'head.layers.$index.norm2.bias': [hidden],
      'head.layers.$index.linear1.weight': [4 * hidden, hidden],
      'head.layers.$index.linear1.bias': [4 * hidden],
      'head.layers.$index.linear2.weight': [hidden, 4 * hidden],
      'head.layers.$index.linear2.bias': [hidden],
    },
  };
}

_Inspection _readGguf(Uint8List bytes, int size) {
  final reader = _BinaryReader(bytes, size)..offset = 4;
  final version = reader.u32();
  if (version != 2 && version != 3) {
    return _Inspection(
      'GGUF',
      AssetIntegrity.unknown,
      diagnostics: ['不支持的 GGUF 版本 $version'],
    );
  }
  final tensorCount = reader.u64();
  final metadataCount = reader.u64();
  if (tensorCount > 100000 || metadataCount > 100000) {
    throw const FormatException('GGUF 数量字段异常');
  }
  final metadata = <String, Object?>{};
  for (var index = 0; index < metadataCount; index++) {
    final key = reader.string();
    if (metadata.containsKey(key)) {
      throw const FormatException('GGUF 重复 metadata');
    }
    metadata[key] = reader.value(reader.u32());
  }
  final tensors = <String, List<int>>{};
  final ranges = <(int, int)>[];
  var knownSizes = true;
  for (var index = 0; index < tensorCount; index++) {
    final name = reader.string();
    if (tensors.containsKey(name)) {
      throw const FormatException('GGUF 重复 tensor');
    }
    final nDimensions = reader.u32();
    if (nDimensions < 1 || nDimensions > 4) {
      throw const FormatException('GGUF tensor 维度异常');
    }
    final dimensions = List.generate(nDimensions, (_) => reader.u64());
    final type = reader.u32();
    final offset = reader.u64();
    var elements = 1;
    for (final dimension in dimensions) {
      if (dimension <= 0 || elements > (size * 256) ~/ dimension) {
        throw const FormatException('GGUF tensor 大小异常');
      }
      elements *= dimension;
    }
    final layout = _ggmlSizes[type];
    if (layout == null) {
      knownSizes = false;
      ranges.add((offset, offset + 1));
    } else {
      if (dimensions.first % layout.$1 != 0) {
        throw const FormatException('GGUF 量化块大小异常');
      }
      ranges.add((offset, offset + (elements ~/ layout.$1) * layout.$2));
    }
    tensors[name] = dimensions;
  }
  final alignment = metadata['general.alignment'] ?? 32;
  if (alignment is! int ||
      alignment < 1 ||
      alignment > 4096 ||
      (alignment & (alignment - 1)) != 0) {
    throw const FormatException('GGUF 对齐字段异常');
  }
  final dataStart = ((reader.offset + alignment - 1) ~/ alignment) * alignment;
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  var previousEnd = 0;
  for (final range in ranges) {
    if (range.$1 % alignment != 0 ||
        range.$1 < previousEnd ||
        range.$2 > size - dataStart) {
      throw const FormatException('GGUF tensor 数据缺失或重叠');
    }
    previousEnd = range.$2;
  }
  return _Inspection(
    'GGUF',
    knownSizes ? AssetIntegrity.complete : AssetIntegrity.unknown,
    metadata: metadata,
    tensors: tensors,
    diagnostics: knownSizes ? [] : ['未知 tensor 编码，尚不能核验全部数据'],
  );
}

// Block length and byte size from llama.cpp 836d57176dc699a726c55418e4f96b8ca628e1bf,
// gguf-py/gguf/constants.py. Unlisted encodings stay unverified.
const _ggmlSizes = <int, (int, int)>{
  0: (1, 4),
  1: (1, 2),
  2: (32, 18),
  3: (32, 20),
  6: (32, 22),
  7: (32, 24),
  8: (32, 34),
  9: (32, 36),
  10: (256, 84),
  11: (256, 110),
  12: (256, 144),
  13: (256, 176),
  14: (256, 210),
  15: (256, 292),
  16: (256, 66),
  17: (256, 74),
  18: (256, 98),
  19: (256, 50),
  20: (32, 18),
  21: (256, 110),
  22: (256, 82),
  23: (256, 136),
  24: (1, 1),
  25: (1, 2),
  26: (1, 4),
  27: (1, 8),
  28: (1, 8),
  29: (256, 56),
  30: (1, 2),
  34: (256, 54),
  35: (256, 66),
  39: (32, 17),
  40: (64, 36),
  41: (128, 18),
  42: (64, 18),
};

class _ScanLimit implements Exception {}

class _ArrayValues {
  const _ArrayValues(this.type, this.count, this.fingerprint, this.values);
  final int type;
  final int count;
  final String fingerprint;
  final List<Object?>? values;
}

class _BinaryReader {
  _BinaryReader(this.bytes, this.fileSize) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  final int fileSize;
  int offset = 0;

  void need(int length) {
    if (length < 0 || offset > fileSize - length) {
      throw const FormatException('GGUF header 已截断');
    }
    if (offset > bytes.length - length) throw _ScanLimit();
  }

  int u32() {
    need(4);
    final result = data.getUint32(offset, Endian.little);
    offset += 4;
    return result;
  }

  int u64() {
    need(8);
    final result = data.getUint64(offset, Endian.little);
    offset += 8;
    if (result < 0) throw const FormatException('GGUF 数量溢出');
    return result;
  }

  String string() {
    final length = u64();
    need(length);
    final result = utf8.decode(bytes.sublist(offset, offset + length));
    offset += length;
    return result;
  }

  Object? value(int type) {
    if (type == 8) return string();
    if (type == 9) {
      final arrayType = u32();
      final count = u64();
      if (arrayType == 9 || count > fileSize) {
        throw const FormatException('GGUF 数组异常');
      }
      final start = offset;
      final values = count <= 4096 && arrayType != 8 ? <Object?>[] : null;
      for (var index = 0; index < count; index++) {
        final item = value(arrayType);
        values?.add(item);
      }
      return _ArrayValues(
        arrayType,
        count,
        sha256.convert(bytes.sublist(start, offset)).toString(),
        values,
      );
    }
    const sizes = {
      0: 1,
      1: 1,
      2: 2,
      3: 2,
      4: 4,
      5: 4,
      6: 4,
      7: 1,
      10: 8,
      11: 8,
      12: 8,
    };
    final size = sizes[type];
    if (size == null) throw const FormatException('GGUF metadata 类型异常');
    need(size);
    final result = switch (type) {
      0 => data.getUint8(offset),
      1 => data.getInt8(offset),
      2 => data.getUint16(offset, Endian.little),
      3 => data.getInt16(offset, Endian.little),
      4 => data.getUint32(offset, Endian.little),
      5 => data.getInt32(offset, Endian.little),
      6 => data.getFloat32(offset, Endian.little),
      7 => data.getUint8(offset) == 1,
      10 => data.getUint64(offset, Endian.little),
      11 => data.getInt64(offset, Endian.little),
      12 => data.getFloat64(offset, Endian.little),
      _ => null,
    };
    offset += size;
    return result;
  }
}

List<LibraryArtifact> _groupGguf(List<_ScannedFile> files) {
  final groups = <String, List<_ScannedFile>>{};
  for (final file in files) {
    final metadata = file.inspection.metadata;
    var key = file.file.path;
    final count = metadata['split.count'];
    final number = metadata['split.no'];
    if (file.inspection.format == 'GGUF' &&
        count is int &&
        count > 1 &&
        number is int) {
      final name = File(file.file.path).uri.pathSegments.last;
      final match = RegExp(r'^(.*)-(\d{5})-of-(\d{5})\.gguf$').firstMatch(name);
      if (match != null &&
          int.parse(match[2]!) == number + 1 &&
          int.parse(match[3]!) == count) {
        key = '${File(file.file.path).parent.path}/${match[1]}';
      } else if (metadata['general.name'] is String) {
        key =
            '${File(file.file.path).parent.path}/${metadata['general.name']}:$count';
      }
    }
    groups.putIfAbsent(key, () => []).add(file);
  }
  return groups.values.map(_ggufArtifact).toList()
    ..sort((a, b) => a.files.first.path.compareTo(b.files.first.path));
}

LibraryArtifact _ggufArtifact(List<_ScannedFile> files) {
  final first = files.firstWhere(
    (file) => file.inspection.metadata['split.no'] == 0,
    orElse: () => files.first,
  );
  final metadata = first.inspection.metadata;
  final architectureValue = metadata['general.architecture'];
  final architecture = architectureValue is String ? architectureValue : null;
  final decision = architecture == null
      ? null
      : metadata['$architecture.decision.type'];
  final decisionType = decision is String ? decision : null;
  final diagnostics = files
      .expand((file) => file.inspection.diagnostics)
      .toList();
  var integrity =
      files.any((file) => file.inspection.integrity == AssetIntegrity.corrupt)
      ? AssetIntegrity.corrupt
      : files.any((file) => file.inspection.integrity == AssetIntegrity.unknown)
      ? AssetIntegrity.unknown
      : AssetIntegrity.complete;
  var kind = AssetKind.unknown;
  final tensors = <String, List<int>>{};
  for (final file in files) {
    for (final tensor in file.inspection.tensors.entries) {
      if (tensors.containsKey(tensor.key)) {
        integrity = AssetIntegrity.corrupt;
        diagnostics.add('分片含重复 tensor');
      }
      tensors[tensor.key] = tensor.value;
    }
  }
  void missing(String detail) {
    if (integrity != AssetIntegrity.corrupt &&
        integrity != AssetIntegrity.unknown) {
      integrity = AssetIntegrity.incomplete;
    }
    diagnostics.add(detail);
  }

  final splitCount = metadata['split.count'];
  if (splitCount is int && splitCount > 1) {
    final numbers = files
        .map((file) => file.inspection.metadata['split.no'])
        .toSet();
    if (splitCount > 100000 ||
        numbers.length != splitCount ||
        !numbers.contains(0) ||
        numbers.any(
          (value) => value is! int || value < 0 || value >= splitCount,
        )) {
      missing('GGUF 分片缺失');
    }
    if (metadata['split.tensors.count'] != tensors.length) {
      missing('GGUF 分片 tensor 总数不符');
    }
    for (final file in files) {
      if (file.inspection.metadata['split.count'] != splitCount ||
          file.inspection.metadata['split.tensors.count'] !=
              metadata['split.tensors.count']) {
        missing('GGUF 分片 metadata 不匹配');
      }
    }
  }
  if (first.inspection.format != 'GGUF') {
    integrity = AssetIntegrity.unknown;
  } else if (architecture == null || tensors.isEmpty) {
    missing('缺少架构或权重');
  } else {
    final tokenizer = metadata['tokenizer.ggml.tokens'];
    if (metadata['tokenizer.ggml.model'] is! String ||
        tokenizer is! _ArrayValues ||
        tokenizer.type != 8 ||
        tokenizer.count == 0) {
      missing('缺少嵌入 tokenizer');
    }
    final decisionMarker = metadata.keys.any(
      (key) => key.endsWith('.decision.type'),
    );
    if (architecture == 'qwen35' && decisionType == 'kev' ||
        architecture == 'modern-bert' && decisionType == 'laya') {
      kind = AssetKind.decision;
      if (metadata['tokenizer.chat_template.systemone'] is! String ||
          (metadata['tokenizer.chat_template.systemone'] as String)
              .trim()
              .isEmpty) {
        missing('缺少 systemone 模板');
      }
      for (final type in ['choice', 'score', 'noul']) {
        final temperature =
            metadata['$architecture.decision.temperature.$type'];
        if (temperature is! num || !temperature.isFinite || temperature <= 0) {
          missing('缺少有效 $type 温度');
        }
      }
      final required = _requiredDecisionTensors(architecture, metadata);
      if (required == null) {
        missing('决策架构 metadata 不完整');
      } else {
        for (final name in required) {
          if (!tensors.containsKey(name)) missing('缺少 $name');
        }
        if (architecture == 'qwen35') {
          final output = metadata['qwen35.embedding_length_out'];
          final embedding = metadata['qwen35.embedding_length'];
          if (output is! int ||
              output <= 0 ||
              output.isOdd ||
              embedding is! int ||
              embedding <= 0 ||
              !_dimensionsMatch(tensors['cls.output.weight'], [
                embedding,
                output,
              ]) ||
              !_dimensionsMatch(tensors['cls.output.bias'], [output])) {
            missing('Pointer head 尺寸不符');
          }
        } else {
          final embedding = metadata['modern-bert.embedding_length'];
          final blocks = metadata['modern-bert.block_count'];
          final heads = metadata['modern-bert.decision.block_count'];
          if (embedding is! int ||
              embedding <= 0 ||
              blocks is! int ||
              heads is! int) {
            missing('决策 head 尺寸 metadata 不完整');
          } else {
            final dimensions = <String, List<int>>{
              'token_types.weight': [embedding, 3],
              'cls.weight': [embedding, embedding],
              'cls.bias': [embedding],
              'cls.norm.weight': [embedding],
              'cls.norm.bias': [embedding],
              'cls.output.bias': [1],
              for (var index = blocks - heads; index < blocks; index++) ...{
                'blk.$index.attn_norm.weight': [embedding],
                'blk.$index.attn_norm.bias': [embedding],
                'blk.$index.attn_qkv.weight': [embedding, 3 * embedding],
                'blk.$index.attn_qkv.bias': [3 * embedding],
                'blk.$index.attn_output.weight': [embedding, embedding],
                'blk.$index.attn_output.bias': [embedding],
                'blk.$index.ffn_norm.weight': [embedding],
                'blk.$index.ffn_norm.bias': [embedding],
                'blk.$index.ffn_up.weight': [embedding, 4 * embedding],
                'blk.$index.ffn_up.bias': [4 * embedding],
                'blk.$index.ffn_down.weight': [4 * embedding, embedding],
                'blk.$index.ffn_down.bias': [embedding],
              },
            };
            // The pinned Laya graph runs a scalar scorer for each of the three
            // token types, then concatenates the scores. GGML pads omitted
            // trailing tensor dimensions with 1.
            if (!_scalarScorerDimensionsMatch(
                  tensors['cls.output.weight'],
                  embedding,
                ) ||
                dimensions.entries.any(
                  (entry) => !_dimensionsMatch(tensors[entry.key], entry.value),
                )) {
              missing('决策 head 或 scorer 尺寸不符');
            }
          }
        }
      }
    } else if (!decisionMarker &&
        [
          'qwen35',
          'qwen2',
          'qwen3',
          'llama',
          'mistral',
          'gemma',
          'gemma2',
          'gemma3',
          'phi3',
        ].contains(architecture)) {
      kind = AssetKind.chat;
      final template = metadata['tokenizer.chat_template'];
      if (template is! String || template.trim().isEmpty) {
        missing('缺少普通 chat 模板');
      }
    } else if (!decisionMarker &&
        ['modern-bert', 'bert', 'nomic-bert'].contains(architecture)) {
      kind = AssetKind.encoder;
      missing('Encoder 尚未关联决策 head');
    } else {
      if (integrity != AssetIntegrity.corrupt) {
        integrity = AssetIntegrity.unknown;
      }
      diagnostics.add('架构或决策布局尚未核验');
    }
  }
  final paths = files.map((file) => file.file.path).toList()..sort();
  return LibraryArtifact(
    id: sha256.convert(utf8.encode(paths.join('\n'))).toString(),
    files: files.map((file) => file.file).toList(),
    format: first.inspection.format,
    kind: kind,
    integrity: integrity,
    architecture: architecture,
    decisionType: decisionType,
    engineCapability: EngineCapability.awaitingVerification,
    diagnostics: diagnostics,
  );
}

bool _dimensionsMatch(List<int>? actual, List<int> expected) =>
    actual != null &&
    actual.length == expected.length &&
    List.generate(
      expected.length,
      (index) => actual[index] == expected[index],
    ).every((value) => value);

bool _scalarScorerDimensionsMatch(List<int>? actual, int embedding) =>
    actual != null &&
    actual.isNotEmpty &&
    actual.first == embedding &&
    actual.skip(1).every((dimension) => dimension == 1);

// Required graph tensors from pinned src/models/qwen35.cpp and modern-bert.cpp;
// this is file completeness evidence, never a running-engine capability claim.
Set<String>? _requiredDecisionTensors(
  String architecture,
  Map<String, Object?> metadata,
) {
  final count = metadata['$architecture.block_count'];
  if (count is! int || count <= 0 || count > 10000) return null;
  final required = <String>{
    'token_embd.weight',
    'output_norm.weight',
    'cls.output.weight',
    'cls.output.bias',
  };
  if (architecture == 'qwen35') {
    for (final key in [
      'embedding_length',
      'embedding_length_out',
      'context_length',
      'feed_forward_length',
      'attention.head_count',
      'attention.head_count_kv',
      'ssm.conv_kernel',
      'ssm.inner_size',
      'ssm.state_size',
      'ssm.time_step_rank',
      'ssm.group_count',
    ]) {
      final value = metadata['qwen35.$key'];
      if (value is! int || value <= 0) return null;
    }
    final epsilon = metadata['qwen35.attention.layer_norm_rms_epsilon'];
    final rope = metadata['qwen35.rope.dimension_sections'];
    if (epsilon is! num ||
        !epsilon.isFinite ||
        epsilon <= 0 ||
        rope is! _ArrayValues ||
        rope.count != 4) {
      return null;
    }
    final interval = metadata['qwen35.full_attention_interval'] ?? 4;
    if (interval is! int || interval <= 0) return null;
    final recurrent = metadata['qwen35.attention.recurrent_layers'];
    if (recurrent != null &&
        (recurrent is! _ArrayValues || recurrent.values?.length != count)) {
      return null;
    }
    for (var index = 0; index < count; index++) {
      final prefix = 'blk.$index';
      for (final suffix in [
        'attn_norm.weight',
        'post_attention_norm.weight',
        'ffn_gate.weight',
        'ffn_up.weight',
        'ffn_down.weight',
      ]) {
        required.add('$prefix.$suffix');
      }
      final isRecurrent = recurrent is _ArrayValues
          ? recurrent.values![index] == true || recurrent.values![index] == 1
          : (index + 1) % interval != 0;
      final suffixes = isRecurrent
          ? [
              'attn_qkv.weight',
              'attn_gate.weight',
              'ssm_conv1d.weight',
              'ssm_dt.bias',
              'ssm_a',
              'ssm_beta.weight',
              'ssm_alpha.weight',
              'ssm_norm.weight',
              'ssm_out.weight',
            ]
          : [
              'attn_q.weight',
              'attn_k.weight',
              'attn_v.weight',
              'attn_output.weight',
              'attn_q_norm.weight',
              'attn_k_norm.weight',
            ];
      for (final suffix in suffixes) {
        required.add('$prefix.$suffix');
      }
    }
  } else {
    final headCount = metadata['modern-bert.decision.block_count'];
    if (headCount is! int ||
        headCount <= 0 ||
        headCount >= count ||
        metadata['tokenizer.ggml.token_type_count'] != 3) {
      return null;
    }
    final maxTokens = metadata['modern-bert.decision.max_head_tokens'];
    if (maxTokens is! int || maxTokens <= 0) return null;
    required.addAll([
      'token_embd_norm.weight',
      'token_types.weight',
      'cls.weight',
      'cls.bias',
      'cls.norm.weight',
      'cls.norm.bias',
    ]);
    for (var index = 0; index < count; index++) {
      final head = index >= count - headCount;
      final suffixes = [
        'attn_qkv.weight',
        'attn_output.weight',
        'ffn_up.weight',
        'ffn_down.weight',
        'ffn_norm.weight',
        if (index > 0 || head) 'attn_norm.weight',
        if (head) ...[
          'attn_norm.bias',
          'attn_qkv.bias',
          'attn_output.bias',
          'ffn_norm.bias',
          'ffn_up.bias',
          'ffn_down.bias',
        ],
      ];
      for (final suffix in suffixes) {
        required.add('blk.$index.$suffix');
      }
    }
  }
  return required;
}
