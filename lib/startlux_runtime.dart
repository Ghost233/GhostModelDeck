import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'engine_runtime.dart';

class StartluxRuntimeCancelled implements Exception {
  const StartluxRuntimeCancelled();
  @override
  String toString() => 'StartLux 运行时准备已取消';
}

class StartluxRuntimeCleanupException implements Exception {
  StartluxRuntimeCleanupException(
    this.originalError,
    List<String> errors, {
    this.previousFailure,
  }) : cleanupErrors = List.unmodifiable(errors);
  final Object? originalError;
  final List<String> cleanupErrors;
  final StartluxRuntimeCleanupException? previousFailure;
  @override
  String toString() =>
      '${originalError ?? 'StartLux 运行时准备收尾失败'}; '
      '${previousFailure == null ? '' : '先前准备失败：$previousFailure; '}'
      '清理失败：${cleanupErrors.join('; ')}';
}

class StartluxRuntimeProgress {
  const StartluxRuntimeProgress(
    this.phase,
    this.downloadedBytes,
    this.totalBytes,
  );
  final String phase;
  final int downloadedBytes;
  final int totalBytes;
}

class StartluxPreparedRuntime {
  StartluxPreparedRuntime({
    required this.pythonPath,
    required this.fingerprint,
    required Map<String, Object?> provenance,
    required this.reused,
  }) : provenance = Map.unmodifiable(provenance);
  final String pythonPath;
  final String fingerprint;
  final Map<String, Object?> provenance;
  final bool reused;
}

/// App-owned preparation. Completed caches are persistent; close only cancels
/// this owner's pending download/process and removes its unfinished staging.
class StartluxRuntime {
  StartluxRuntime(
    this.cacheRoot, {
    required this.assets,
    HttpClient Function()? createHttpClient,
  }) : _createHttpClient = createHttpClient ?? HttpClient.new;

  static const assetRoot = 'assets/startlux_runtime';
  static const pythonVersion = '3.12.15';
  static const owner = 'ghost-model-deck-startlux-runtime-v1';
  static const prototypeOwner =
      'ghost-model-deck-startlux-runtime-prototype-v1';
  static const _identityCode =
      "import json,platform,sys;print(json.dumps({'version':platform.python_version(),'system':platform.system(),'machine':platform.machine(),'executable':sys.executable}))";
  static const _packagesCode =
      "import importlib.metadata,json;print(json.dumps(sorted([{'name':d.metadata['Name'],'version':d.version} for d in importlib.metadata.distributions()],key=lambda x:x['name'].lower())))";
  // A new session confines all ensurepip/pip descendants to this owned group.
  static const _sessionCode =
      'import os,sys;os.setsid();os.execv(sys.executable,[sys.executable,*sys.argv[1:]])';

  final Directory cacheRoot;
  final Future<Uint8List> Function(String) assets;
  final HttpClient Function() _createHttpClient;
  DecisionCancellation? _active;
  Completer<void>? _preparing;
  Future<void>? _closing;
  bool _closed = false;
  StartluxPreparedRuntime? prepared;
  final List<String> cleanupErrors = [];
  StartluxRuntimeCleanupException? _lastCleanupFailure;

  void cancelPreparation() => _active?.cancel();

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    cancelPreparation();
    await _preparing?.future;
    final cleanupFailure = _lastCleanupFailure;
    if (cleanupFailure != null) throw cleanupFailure;
  }

  Future<StartluxPreparedRuntime> prepare(
    DecisionCancellation cancellation, {
    void Function(StartluxRuntimeProgress)? onProgress,
  }) async {
    if (_closed) throw StateError('StartLux 运行时已关闭');
    if (_preparing != null) throw StateError('StartLux 运行时正在准备');
    final done = Completer<void>();
    _preparing = done;
    final token = DecisionCancellation();
    _active = token;
    final remove = cancellation.listen(token.cancel);
    RandomAccessFile? lockHandle;
    File? lock;
    Directory? staging;
    bool ownsCache = false;
    bool ownsLock = false;
    Object? primaryError;
    StackTrace? primaryStack;
    prepared = null;
    final previousFailure = _lastCleanupFailure;
    final previousCleanupCount = cleanupErrors.length;
    try {
      _check(token);
      if (!Platform.isMacOS || Platform.version.isEmpty) {
        throw const FormatException('仅支持 macOS arm64 的 StartLux 运行时');
      }
      final machine = await _run('/usr/bin/uname', ['-m'], token);
      if (machine.trim() != 'arm64') {
        throw const FormatException('仅支持 macOS arm64 的 StartLux 运行时');
      }
      final specification = await _specification();
      _check(token);
      await _realParents(cacheRoot.parent);
      final cacheType = await FileSystemEntity.type(
        cacheRoot.path,
        followLinks: false,
      );
      if (cacheType != FileSystemEntityType.notFound &&
          cacheType != FileSystemEntityType.directory) {
        throw const FormatException('运行时缓存必须是实体目录；已保留外部内容');
      }
      lock = File('${cacheRoot.path}.prepare-lock');
      // Exclusive creation rejects another owner or a stale/unknown lock.
      await lock.create(exclusive: true);
      ownsLock = true;
      lockHandle = await lock.open(mode: FileMode.writeOnly);
      await lockHandle.writeString(jsonEncode({'owner': owner, 'pid': pid}));
      if (cacheType == FileSystemEntityType.directory) {
        onProgress?.call(const StartluxRuntimeProgress('verify-cache', 0, 0));
        final result = await _reuse(specification, token);
        _check(token);
        prepared = result;
        onProgress?.call(const StartluxRuntimeProgress('reused', 0, 0));
        return result;
      }
      staging = await cacheRoot.parent.createTemp('.startlux-runtime-');
      final archive = File('${staging.path}/python.tar.gz');
      await _download(specification.python, archive, token, onProgress);
      final unpacked = Directory('${staging.path}/unpacked');
      await extractStartluxRuntimeArchive(archive, unpacked, token);
      await _run('/bin/chmod', [
        '755',
        '${unpacked.path}/python/bin/python3.12',
      ], token);
      final temporaryPython = '${unpacked.path}/python/bin/python3';
      _identity(await _python(temporaryPython, ['-c', _identityCode], token));
      // Create venv at its permanent path: entry points contain absolute paths.
      await unpacked.rename(cacheRoot.path);
      ownsCache = true;
      await File('${cacheRoot.path}/owner.json').writeAsString(
        jsonEncode({'owner': owner, 'fingerprint': specification.fingerprint}),
      );
      final requirements = File('${cacheRoot.path}/requirements.lock');
      await requirements.writeAsBytes(specification.requirements);
      final wheels = await Directory('${cacheRoot.path}/wheels').create();
      for (final wheel in specification.wheels) {
        await _download(
          wheel,
          File('${wheels.path}/${wheel.filename}'),
          token,
          onProgress,
        );
      }
      final python = '${cacheRoot.path}/python/bin/python3';
      onProgress?.call(const StartluxRuntimeProgress('install', 0, 0));
      await _python(python, ['-m', 'venv', '${cacheRoot.path}/venv'], token);
      final venv = '${cacheRoot.path}/venv/bin/python';
      await _python(venv, [
        '-m',
        'pip',
        '--isolated',
        '--disable-pip-version-check',
        'install',
        '--require-hashes',
        '--only-binary=:all:',
        '--no-deps',
        '--no-cache-dir',
        '--no-index',
        '--find-links',
        wheels.path,
        '-r',
        requirements.path,
      ], token);
      await _python(venv, [
        '-m',
        'pip',
        '--isolated',
        '--disable-pip-version-check',
        'check',
      ], token);
      final identity = _identity(
        await _python(venv, ['-c', _identityCode], token),
      );
      final packages = _packages(
        await _python(venv, ['-c', _packagesCode], token),
      );
      _checkPackages(packages, specification.wheels);
      final files = await _tree(cacheRoot, token);
      final receipt = <String, Object?>{
        'owner': owner,
        'fingerprint': specification.fingerprint,
        'identity': identity,
        'asset': specification.python.provenance,
        'wheels': specification.wheels.map((e) => e.provenance).toList(),
        'requirements_sha256': sha256
            .convert(specification.requirements)
            .toString(),
        'packages': packages,
        'files': files,
      };
      _check(token);
      await File('${cacheRoot.path}/complete.json')
          .writeAsString(jsonEncode(receipt));
      final result = _prepared(receipt, false);
      _check(token);
      prepared = result;
      onProgress?.call(const StartluxRuntimeProgress('ready', 0, 0));
      return result;
    } catch (error, stack) {
      primaryError = error;
      primaryStack = stack;
      if (ownsCache) {
        try {
          await cacheRoot.delete(recursive: true);
        } catch (error) {
          cleanupErrors.add(error.toString());
        }
      }
      rethrow;
    } finally {
      if (staging != null) {
        try {
          await staging.delete(recursive: true);
        } catch (error) {
          cleanupErrors.add(error.toString());
        }
      }
      if (lockHandle != null) {
        try {
          await lockHandle.close();
        } catch (error) {
          cleanupErrors.add(error.toString());
        }
      }
      if (ownsLock) {
        try {
          await lock!.delete();
        } catch (error) {
          cleanupErrors.add(error.toString());
        }
      }
      remove();
      _active = null;
      _preparing = null;
      done.complete();
      if (primaryError != null) prepared = null;
      if (cleanupErrors.length > previousCleanupCount ||
          primaryError != null && previousFailure != null) {
        prepared = null;
        final failure = StartluxRuntimeCleanupException(
          primaryError,
          cleanupErrors,
          previousFailure: previousFailure,
        );
        _lastCleanupFailure = failure;
        Error.throwWithStackTrace(failure, primaryStack ?? StackTrace.current);
      }
      if (primaryError == null) {
        // Only a verified new preparation with successful owned cleanup may
        // resolve the prior failure; an unsuccessful retry keeps it visible.
        cleanupErrors.clear();
        _lastCleanupFailure = null;
      }
    }
  }

  Future<_Specification> _specification() async {
    final pythonBytes = await assets('$assetRoot/python-asset.json');
    final wheelBytes = await assets('$assetRoot/wheels.json');
    final requirements = await assets('$assetRoot/requirements.lock');
    final pythonMap = _map(jsonDecode(utf8.decode(pythonBytes)));
    final asset = _map(pythonMap['asset']);
    if (pythonMap['tag'] != '20261009' ||
        asset['name'] !=
            'cpython-3.12.15+20261009-aarch64-apple-darwin-install_only_stripped.tar.gz' ||
        asset['size'] != 25030095 ||
        asset['digest'] !=
            'sha256:233f8e15255b3e1d1fd47ea5dd5230dfed803f371138e896e54d98c60ae19f6f') {
      throw const FormatException('CPython 来源不是固定 macOS arm64 发行资产');
    }
    final python = _Download(
      asset['name'] as String,
      Uri.parse(asset['browser_download_url'] as String),
      asset['size'] as int,
      (asset['digest'] as String).substring(7),
      asset,
    );
    if (python.uri.scheme != 'https' || python.uri.host != 'github.com') {
      throw const FormatException('CPython 下载地址不是官方 HTTPS 来源');
    }
    final wheelMap = _map(jsonDecode(utf8.decode(wheelBytes)));
    final raw = wheelMap['packages'];
    if (raw is! List || raw.length != 37) {
      throw const FormatException('StartLux wheel 清单无效');
    }
    final wheels = <_Download>[];
    final names = <String>{};
    for (final entry in raw) {
      final item = _map(entry);
      final filename = item['filename'];
      final hash = item['sha256'];
      final size = item['size'];
      final name = item['name'];
      final version = item['version'];
      final url = item['url'];
      if (filename is! String ||
          filename.contains('/') ||
          !filename.endsWith('.whl') ||
          !(filename.endsWith('-none-any.whl') ||
              filename.endsWith('_arm64.whl')) ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          size is! int ||
          size <= 0 ||
          name is! String ||
          version is! String ||
          url is! String ||
          !names.add(_normalize(name))) {
        throw const FormatException('StartLux wheel 平台或摘要无效');
      }
      final uri = Uri.parse(url);
      if (uri.scheme != 'https' || uri.host != 'files.pythonhosted.org') {
        throw const FormatException('wheel 下载地址不是 PyPI 官方 HTTPS 来源');
      }
      wheels.add(_Download(filename, uri, size, hash, item));
    }
    final expectedRequirements = wheels
        .map(
          (w) =>
              '${w.provenance['name']}==${w.provenance['version']} --hash=sha256:${w.hash}',
        )
        .join('\n');
    if (utf8.decode(requirements).trim() != expectedRequirements) {
      throw const FormatException('pip 锁文件与固定 wheel 清单不一致');
    }
    return _Specification(
      python,
      wheels,
      requirements,
      sha256.convert([
        ...pythonBytes,
        ...wheelBytes,
        ...requirements,
      ]).toString(),
    );
  }

  Future<void> _download(
    _Download artifact,
    File target,
    DecisionCancellation token,
    void Function(StartluxRuntimeProgress)? progress,
  ) async {
    _check(token);
    final client = _createHttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    final release = token.listen(() => client.close(force: true));
    RandomAccessFile? output;
    final digestSink = _DigestSink();
    final hash = sha256.startChunkedConversion(digestSink);
    var received = 0;
    final watch = Stopwatch()..start();
    try {
      await target.create(exclusive: true);
      output = await target.open(mode: FileMode.writeOnly);
      _check(token);
      final request = await client
          .getUrl(artifact.uri)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength >= 0 &&
              response.contentLength != artifact.size)) {
        throw FormatException(
          '下载HTTP状态或长度无效：${artifact.filename}/${response.statusCode}',
        );
      }
      await for (final block in response.timeout(const Duration(seconds: 30))) {
        _check(token);
        received += block.length;
        if (received > artifact.size ||
            watch.elapsed > const Duration(minutes: 10)) {
          throw FormatException('下载超过固定长度或期限：${artifact.filename}');
        }
        hash.add(block);
        await output.writeFrom(block);
        progress?.call(
          StartluxRuntimeProgress(artifact.filename, received, artifact.size),
        );
      }
      hash.close();
      if (received != artifact.size ||
          digestSink.value?.toString() != artifact.hash) {
        throw FormatException('下载长度或SHA256不一致：${artifact.filename}');
      }
      _check(token);
    } catch (_) {
      if (token.isCancelled) throw const StartluxRuntimeCancelled();
      rethrow;
    } finally {
      try {
        await output?.close();
      } catch (error) {
        cleanupErrors.add(error.toString());
      }
      release();
      client.close(force: true);
    }
  }

  Future<StartluxPreparedRuntime> _reuse(
    _Specification specification,
    DecisionCancellation token,
  ) async {
    final file = File('${cacheRoot.path}/complete.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('已有缓存缺少完整验收记录；已保留');
    }
    final receipt = _map(jsonDecode(await file.readAsString()));
    if (![owner, prototypeOwner].contains(receipt['owner']) ||
        receipt['fingerprint'] != specification.fingerprint) {
      throw const FormatException('已有缓存来源或固定输入不一致；已保留');
    }
    if (!_jsonEqual(receipt['asset'], specification.python.provenance) ||
        !_jsonEqual(
          receipt['wheels'],
          specification.wheels.map((w) => w.provenance).toList(),
        ) ||
        receipt['requirements_sha256'] !=
            sha256.convert(specification.requirements).toString()) {
      throw const FormatException('已有缓存的来源清单或锁文件摘要不一致；已保留');
    }
    final recorded = _map(receipt['files']);
    final actual = await _tree(cacheRoot, token);
    if (!_jsonEqual(actual, recorded)) {
      throw const FormatException('运行时缓存文件或SHA256改变；已保留');
    }
    // Validate installed runtime before returning a cached path to another owner.
    final python = '${cacheRoot.path}/venv/bin/python';
    final identity = _identity(
      await _python(python, ['-c', _identityCode], token),
    );
    final packages = _packages(
      await _python(python, ['-c', _packagesCode], token),
    );
    if (!_jsonEqual(packages, receipt['packages'])) {
      throw const FormatException('已有运行时的实际包版本发生改变；已保留');
    }
    _checkPackages(packages, specification.wheels);
    receipt['identity'] = identity;
    return _prepared(receipt, true);
  }

  StartluxPreparedRuntime _prepared(
    Map<String, Object?> receipt,
    bool reused,
  ) => StartluxPreparedRuntime(
    pythonPath: '${cacheRoot.path}/venv/bin/python',
    fingerprint: receipt['fingerprint'] as String,
    provenance: {
      'provider': 'ghost-model-deck',
      'platform': 'macOS arm64',
      'identity': receipt['identity'],
      'cpython': receipt['asset'],
      'wheels': receipt['wheels'],
      'requirementsSha256': receipt['requirements_sha256'],
      'packages': receipt['packages'],
    },
    reused: reused,
  );

  Future<String> _python(
    String python,
    List<String> args,
    DecisionCancellation token,
  ) => _run(
    python,
    ['-I', '-B', '-c', _sessionCode, '-I', '-B', ...args],
    token,
    group: true,
  );

  Future<String> _run(
    String executable,
    List<String> args,
    DecisionCancellation token, {
    bool group = false,
  }) async {
    _check(token);
    final environment = Map<String, String>.of(Platform.environment)
      ..remove('PYTHONPATH')
      ..remove('PYTHONHOME')
      ..remove('VIRTUAL_ENV')
      ..remove('PIP_INDEX_URL')
      ..remove('PIP_EXTRA_INDEX_URL')
      ..remove('PIP_CONFIG_FILE')
      ..['PYTHONNOUSERSITE'] = '1'
      ..['PIP_CONFIG_FILE'] = '/dev/null'
      ..['PIP_NO_CACHE_DIR'] = '1';
    final process = await Process.start(
      executable,
      args,
      environment: environment,
      includeParentEnvironment: false,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    void terminate(ProcessSignal signal) {
      if (group) Process.killPid(-process.pid, signal);
      process.kill(signal);
    }

    final release = token.listen(() => terminate(ProcessSignal.sigterm));
    try {
      final result = await Future.any<Object>([
        process.exitCode,
        token.whenCancelled.then((_) => const StartluxRuntimeCancelled()),
      ]).timeout(const Duration(minutes: 20));
      if (result is StartluxRuntimeCancelled) throw result;
      final output = await stdout;
      final error = await stderr;
      if (result != 0) {
        throw ProcessException(
          executable,
          args,
          '$output\n$error',
          result as int,
        );
      }
      _check(token);
      return output;
    } catch (_) {
      terminate(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        terminate(ProcessSignal.sigkill);
        await process.exitCode;
      }
      await stdout;
      await stderr;
      rethrow;
    } finally {
      release();
    }
  }

  static Map<String, Object?> _identity(String output) {
    final value = _map(jsonDecode(output));
    if (value['version'] != pythonVersion ||
        value['system'] != 'Darwin' ||
        value['machine'] != 'arm64') {
      throw const FormatException('准备后的 Python 版本或平台不一致');
    }
    return value;
  }

  static List<Map<String, Object?>> _packages(String output) {
    final value = jsonDecode(output);
    if (value is! List) throw const FormatException('实际包清单无效');
    return value.map(_map).toList();
  }

  static void _checkPackages(
    List<Map<String, Object?>> packages,
    List<_Download> wheels,
  ) {
    final actual = <String, String>{};
    for (final package in packages) {
      final name = package['name'];
      final version = package['version'];
      if (name is! String ||
          version is! String ||
          actual.containsKey(_normalize(name))) {
        throw const FormatException('实际包清单含无效或重复项目');
      }
      actual[_normalize(name)] = version;
    }
    for (final wheel in wheels) {
      if (actual.remove(_normalize(wheel.provenance['name'] as String)) !=
          wheel.provenance['version']) {
        throw const FormatException('实际包版本与固定 wheel 不一致');
      }
    }
    if (actual.keys.any((name) => name != 'pip')) {
      throw const FormatException('隔离运行时中出现未锁定的额外包');
    }
  }
}

class _Download {
  const _Download(
    this.filename,
    this.uri,
    this.size,
    this.hash,
    this.provenance,
  );
  final String filename;
  final Uri uri;
  final int size;
  final String hash;
  final Map<String, Object?> provenance;
}

class _Specification {
  const _Specification(
    this.python,
    this.wheels,
    this.requirements,
    this.fingerprint,
  );
  final _Download python;
  final List<_Download> wheels;
  final Uint8List requirements;
  final String fingerprint;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

void _check(DecisionCancellation token) {
  if (token.isCancelled) throw const StartluxRuntimeCancelled();
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('运行时记录需要JSON对象');
  }
  return value;
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[-_.]+'), '-');
bool _jsonEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _jsonEqual(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => _jsonEqual(a[i], b[i]));
  }
  return a == b;
}

Future<void> _realParents(Directory directory) async {
  final parent = directory.absolute.parent;
  if (parent.path != directory.absolute.path) await _realParents(parent);
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await directory.create();
  } else if (type != FileSystemEntityType.directory) {
    throw const FormatException('运行时缓存父目录不能是符号链接或外部文件');
  }
}

Future<Map<String, Object?>> _tree(
  Directory root,
  DecisionCancellation token,
) async {
  final files = <String, Object?>{};
  final canonical = await root.resolveSymbolicLinks();
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    _check(token);
    final name = entity.path.substring(root.path.length + 1);
    if (name == 'complete.json') continue;
    if (entity is Link) {
      final target = await entity.resolveSymbolicLinks();
      if (target != canonical && !target.startsWith('$canonical/')) {
        throw const FormatException('运行时缓存链接指向外部；已保留');
      }
      files[name] = {'link': await entity.target()};
    } else if (entity is File) {
      files[name] = {
        'size': await entity.length(),
        'sha256': (await sha256.bind(entity.openRead()).first).toString(),
      };
    } else if (entity is! Directory) {
      throw const FormatException('运行时缓存含特殊文件；已保留');
    }
  }
  return files;
}

/// Tar boundary used by the owned downloader. No shell extraction, external
/// Python, hard links, special devices, or writes through archive symlinks.
Future<void> extractStartluxRuntimeArchive(
  File archive,
  Directory destination,
  DecisionCancellation cancellation,
) async {
  _check(cancellation);
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('解包目标必须是本次创建的新目录');
  }
  final bytes = gzip.decode(await archive.readAsBytes());
  final entries = <_TarEntry>[];
  Map<String, String> pax = {};
  Map<String, String> globalPax = {};
  String? longName;
  String? longLink;
  var ended = false;
  for (var offset = 0; offset + 512 <= bytes.length;) {
    _check(cancellation);
    final header = bytes.sublist(offset, offset + 512);
    if (header.every((byte) => byte == 0)) {
      if (offset + 1024 > bytes.length ||
          bytes.skip(offset).any((byte) => byte != 0)) {
        throw const FormatException('tar末尾记录不完整或含额外内容');
      }
      ended = true;
      break;
    }
    final stored = _tarNumber(header, 148, 8);
    var checksum = 0;
    for (var i = 0; i < header.length; i++) {
      checksum += i >= 148 && i < 156 ? 32 : header[i];
    }
    if (checksum != stored) throw const FormatException('tar header校验和无效');
    final size = _tarNumber(header, 124, 12);
    final start = offset + 512;
    if (size < 0 || start + size > bytes.length) {
      throw const FormatException('tar内容不完整');
    }
    final data = bytes.sublist(start, start + size);
    final type = header[156];
    var name = _tarString(header, 0, 100);
    final prefix = _tarString(header, 345, 155);
    if (prefix.isNotEmpty) name = '$prefix/$name';
    var link = _tarString(header, 157, 100);
    offset = start + ((size + 511) ~/ 512) * 512;
    if (offset > bytes.length) {
      throw const FormatException('tar数据padding不完整');
    }
    if (type == 120 || type == 103) {
      final values = _pax(data);
      if (type == 103) {
        globalPax = {...globalPax, ...values};
      } else {
        pax = values;
      }
      continue;
    }
    if (type == 76 || type == 75) {
      final value = utf8.decode(data.takeWhile((b) => b != 0).toList());
      if (type == 76) {
        longName = value;
      } else {
        longLink = value;
      }
      continue;
    }
    final metadata = {...globalPax, ...pax};
    name = metadata['path'] ?? longName ?? name;
    link = metadata['linkpath'] ?? longLink ?? link;
    pax = {};
    longName = longLink = null;
    name = _safePath(name);
    if (type != 0 && type != 48 && type != 53 && type != 50) {
      throw const FormatException('tar含不支持的特殊文件或硬链接');
    }
    if (type == 50) _safeLink(name, link);
    entries.add(_TarEntry(name, type, data, link, _tarNumber(header, 100, 8)));
  }
  if (!ended) throw const FormatException('tar缺少完整末尾记录');
  if (entries.isEmpty) throw const FormatException('CPython tar没有内容');
  final links = entries.where((e) => e.type == 50).map((e) => e.name).toSet();
  final names = <String>{};
  for (final entry in entries) {
    if (!names.add(entry.name) && entry.type != 53) {
      throw const FormatException('tar含重复文件');
    }
    final parts = entry.name.split('/');
    for (var i = 1; i < parts.length; i++) {
      if (links.contains(parts.take(i).join('/'))) {
        throw const FormatException('tar不能通过符号链接写入');
      }
    }
  }
  await destination.create();
  for (final entry in entries.where((e) => e.type != 50)) {
    _check(cancellation);
    final path = '${destination.path}/${entry.name}';
    if (entry.type == 53) {
      await Directory(path).create(recursive: true);
    } else {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.create(exclusive: true);
      final output = await file.open(mode: FileMode.writeOnly);
      try {
        await output.writeFrom(entry.bytes);
      } finally {
        await output.close();
      }
      if (entry.mode & 0x49 != 0) {
        final result = await Process.run('/bin/chmod', ['755', path]);
        if (result.exitCode != 0) throw const FormatException('tar可执行文件权限准备失败');
      }
    }
  }
  for (final entry in entries.where((e) => e.type == 50)) {
    _check(cancellation);
    final link = Link('${destination.path}/${entry.name}');
    await link.parent.create(recursive: true);
    await link.create(entry.link);
  }
  final canonical = await destination.resolveSymbolicLinks();
  for (final entry in entries.where((e) => e.type == 50)) {
    final resolved = await Link('${destination.path}/${entry.name}')
        .resolveSymbolicLinks();
    if (resolved != canonical && !resolved.startsWith('$canonical/')) {
      throw const FormatException('tar链接链指向解包目录外');
    }
  }
}

class _TarEntry {
  const _TarEntry(this.name, this.type, this.bytes, this.link, this.mode);
  final String name;
  final int type;
  final List<int> bytes;
  final String link;
  final int mode;
}

String _tarString(List<int> data, int start, int length) => utf8.decode(
  data.sublist(start, start + length).takeWhile((v) => v != 0).toList(),
);
int _tarNumber(List<int> data, int start, int length) {
  final value = _tarString(data, start, length).trim();
  return value.isEmpty ? 0 : int.parse(value, radix: 8);
}

String _safePath(String value) {
  final parts = value
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (value.startsWith('/') ||
      value.contains('\u0000') ||
      parts.isEmpty ||
      parts.contains('..')) {
    throw const FormatException('tar路径越界');
  }
  return parts.join('/');
}

void _safeLink(String name, String target) {
  if (target.isEmpty || target.startsWith('/') || target.contains('\u0000')) {
    throw const FormatException('tar链接越界');
  }
  final stack = name.split('/')..removeLast();
  for (final part in target.split('/')) {
    if (part == '..') {
      if (stack.isEmpty) throw const FormatException('tar链接越界');
      stack.removeLast();
    } else if (part.isNotEmpty && part != '.') {
      stack.add(part);
    }
  }
}

Map<String, String> _pax(List<int> bytes) {
  final result = <String, String>{};
  for (var offset = 0; offset < bytes.length;) {
    var space = offset;
    while (space < bytes.length && bytes[space] != 32) {
      space++;
    }
    final length = int.parse(ascii.decode(bytes.sublist(offset, space)));
    if (length <= 0 || offset + length > bytes.length) {
      throw const FormatException('PAX记录长度无效');
    }
    if (space >= offset + length - 1 || bytes[offset + length - 1] != 10) {
      throw const FormatException('PAX记录结束符无效');
    }
    final value = utf8.decode(bytes.sublist(space + 1, offset + length - 1));
    final equals = value.indexOf('=');
    if (equals < 1) throw const FormatException('PAX记录字段无效');
    result[value.substring(0, equals)] = value.substring(equals + 1);
    offset += length;
  }
  return result;
}
