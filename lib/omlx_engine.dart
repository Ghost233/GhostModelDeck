import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class OmlxException implements Exception {
  const OmlxException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum OmlxInstallationStatus { notInstalled, installing, installed, failed }

/// Observed installer identity, not a model capability or Ready assertion.
class OmlxRuntimeIdentity {
  const OmlxRuntimeIdentity({required this.python, required this.architecture});
  final String python;
  final String architecture;
}

class OmlxReceipt {
  const OmlxReceipt({
    required this.bundleManifestSha256,
    required this.entries,
    required this.sizeBytes,
    required this.runtimeIdentity,
    this.dmgSha256,
  });
  String get releaseLabel => '0.7.0';
  String get build => '2987';
  final String bundleManifestSha256;
  final int entries;
  final int sizeBytes;
  final String? dmgSha256;
  final OmlxRuntimeIdentity runtimeIdentity;
  Map<String, Object?> toJson() => {
    'release': releaseLabel,
    'build': build,
    'bundleManifestSha256': bundleManifestSha256,
    'entries': entries,
    'sizeBytes': sizeBytes,
    'dmgSha256': dmgSha256,
    'python': runtimeIdentity.python,
    'architecture': runtimeIdentity.architecture,
  };
  static OmlxReceipt fromJson(Object? value) {
    if (value is! Map ||
        value['release'] != '0.7.0' ||
        value['build'] != '2987' ||
        value['bundleManifestSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(value['bundleManifestSha256'] as String) ||
        value['entries'] is! int ||
        (value['entries'] as int) <= 0 ||
        value['sizeBytes'] is! int ||
        (value['sizeBytes'] as int) <= 0 ||
        value['python'] != '3.11.10' ||
        value['architecture'] != 'arm64' ||
        (value['dmgSha256'] != null &&
            value['dmgSha256'] != OmlxEngine.dmgDigest)) {
      throw const OmlxException('oMLX 安装收据无效');
    }
    return OmlxReceipt(
      bundleManifestSha256: value['bundleManifestSha256'] as String,
      entries: value['entries'] as int,
      sizeBytes: value['sizeBytes'] as int,
      runtimeIdentity: const OmlxRuntimeIdentity(
        python: '3.11.10',
        architecture: 'arm64',
      ),
      dmgSha256: value['dmgSha256'] as String?,
    );
  }
}

class OmlxState {
  const OmlxState({
    required this.status,
    this.receipt,
    this.error,
    this.residualDirectory,
    this.ownedDevice,
  });
  final OmlxInstallationStatus status;
  final OmlxReceipt? receipt;
  final String? error;

  /// Retained on cleanup failure. Never advertised as removable/installed.
  final String? residualDirectory;
  final String? ownedDevice;
}

class OmlxRemovalPlan {
  OmlxRemovalPlan._(this._owner, this.receipt, this.bundlePath);
  final Object _owner;
  final OmlxReceipt receipt;
  final String bundlePath;
  int get sizeBytes => receipt.sizeBytes;
}

/// Injectable adapters are only process and artifact HTTP I/O, not business rules.
abstract interface class OmlxProcessIO {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  });
  Future<void> download(Uri url, File destination);
}

class NativeOmlxProcessIO implements OmlxProcessIO {
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    final child = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        'LC_ALL': 'C',
        ...environment,
      },
      includeParentEnvironment: false,
    );
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    try {
      if (input != null) child.stdin.write(input);
      await child.stdin.close();
      final code = await child.exitCode.timeout(timeout);
      final collected = await Future.wait([output, errors]);
      return ProcessResult(child.pid, code, collected[0], collected[1]);
    } catch (_) {
      // A failed stdin write/close or decode owns the child just as a timeout does.
      // Kill and collect before the installation operation can release admission.
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      try {
        await Future.wait([output, errors]);
      } catch (_) {
        /* Discard raw output. */
      }
      throw const OmlxException('oMLX 原生检查失败或超时，子进程已回收');
    }
  }

  @override
  Future<void> download(Uri url, File destination) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 60);
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw const OmlxException('oMLX 官方分发下载失败');
      }
      final sink = destination.openWrite();
      try {
        await response.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}

class _Manifest {
  const _Manifest(this.digest, this.entries, this.bytes);
  final String digest;
  final int entries;
  final int bytes;
}

/// Owns only native installation/protocol validation. No callable model runtime.
class OmlxEngine {
  OmlxEngine({required this.installationDirectory, OmlxProcessIO? io})
    : io = io ?? NativeOmlxProcessIO();
  static const dmgDigest =
      '2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0';
  static const artifactUrl =
      'https://github.com/jundot/omlx/releases/download/v0.7.0/oMLX-0.7.0-macos26-27.dmg';
  static const builderPath =
      '/Users/cryingneko/Workspace/omlx/omlx/packaging/_export/cpython-3.11/lib/python3.11/site-packages';
  final OmlxProcessIO io;
  final Directory installationDirectory;
  final _changes = StreamController<OmlxState>.broadcast();
  OmlxState _state = const OmlxState(
    status: OmlxInstallationStatus.notInstalled,
  );
  final _inspectionResiduals = <String>{};
  OmlxState get state => _state;
  Stream<OmlxState> get changes => _changes.stream;
  Future<void> _operations = Future.value();
  int _epoch = 0;
  bool _closed = false;
  bool _held = false;
  int _admissionHolds = 0;
  void Function() holdInstallationAdmission() {
    _admissionHolds++;
    _epoch++;
    var released = false;
    return () {
      if (!released) {
        released = true;
        _admissionHolds--;
      }
    };
  }

  Directory get _versionDirectory =>
      Directory('${installationDirectory.path}/0.7.0');
  Directory get bundle => Directory('${_versionDirectory.path}/oMLX.app');
  File get _marker => File('${_versionDirectory.path}/installation.json');
  void _set(OmlxState state) {
    _state = _inspectionResiduals.isEmpty
        ? state
        : OmlxState(
            status: OmlxInstallationStatus.failed,
            receipt: state.receipt,
            error: state.error ?? 'oMLX 私有检查目录清理未完成',
            residualDirectory:
                state.residualDirectory ?? _inspectionResiduals.first,
            ownedDevice: state.ownedDevice,
          );
    if (!_changes.isClosed) _changes.add(_state);
  }

  Future<T> _serial<T>(Future<T> Function(int epoch) work) {
    if (_closed || _held || _admissionHolds != 0) {
      return Future.error(const OmlxException('oMLX 安装管理正在退出或回收'));
    }
    final epoch = _epoch;
    final result = _operations.then((_) {
      _check(epoch);
      return work(epoch);
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _check(int epoch) {
    if (_closed || epoch != _epoch) throw const OmlxException('oMLX 操作已取消');
  }

  Future<ProcessResult> _run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 120),
    String? input,
    String? cwd,
    Map<String, String> env = const {},
  }) async {
    final result = await io.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: cwd,
      environment: {'LC_ALL': 'C', ...env},
      input: input,
    );
    if (result.exitCode != 0) throw const OmlxException('oMLX 原生验证失败');
    return result;
  }

  Future<Map<String, Object?>> _plist(String input) async {
    final result = await _run('/usr/bin/plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      '-',
    ], input: input);
    final value = jsonDecode(result.stdout.toString());
    if (value is! Map<String, dynamic>) {
      throw const OmlxException('oMLX 原生属性格式无效');
    }
    return Map<String, Object?>.from(value);
  }

  Future<int> _uid() async {
    final result = await _run('/usr/bin/id', [
      '-u',
    ], timeout: const Duration(seconds: 10));
    final uid = int.tryParse(result.stdout.toString().trim());
    if (uid == null || uid <= 0) {
      throw const OmlxException('oMLX 启动安全检查无法确认当前用户');
    }
    return uid;
  }

  Future<void> _safeDirectory(
    String path,
    int uid, {
    bool private = false,
    bool sticky = false,
  }) async {
    final result = await _run('/usr/bin/stat', [
      '-f',
      '%u:%g:%Lp:%HT',
      path,
    ], timeout: const Duration(seconds: 10));
    final fields = result.stdout.toString().trim().split(':');
    final owner = fields.length == 4 ? int.tryParse(fields[0]) : null;
    final mode = fields.length == 4 ? int.tryParse(fields[2], radix: 8) : null;
    final trustedSticky =
        sticky && owner == 0 && mode != null && mode & 0x200 != 0;
    if (owner == null ||
        mode == null ||
        fields[3] != 'Directory' ||
        (!trustedSticky && mode & 0x12 != 0) ||
        ((owner != 0 && owner != uid) && mode & 0x80 != 0) ||
        (private && (owner != uid || mode & 0x3f != 0))) {
      throw const OmlxException('oMLX 路径存在链接、权限歧义或其他用户可写祖先');
    }
    final acl = await _run('/bin/ls', [
      '-lde',
      path,
    ], timeout: const Duration(seconds: 10));
    final lines = acl.stdout.toString().trim().split('\n');
    if (lines.length != 1 ||
        !RegExp(r'^d[rwxstST-]{9}[@]?\s').hasMatch(lines[0])) {
      throw const OmlxException('oMLX 路径 ACL 无法安全分类');
    }
  }

  Future<void> _ancestors(String path, int uid, {bool sticky = false}) async {
    await _safeDirectory('/', uid, sticky: sticky);
    var current = '';
    for (final part in path.split('/').where((p) => p.isNotEmpty)) {
      current = '$current/$part';
      await _safeDirectory(current, uid, sticky: sticky);
    }
  }

  Future<void> _builderGate() async {
    final uid = await _uid();
    await _safeDirectory('/', uid);
    var path = '';
    var missing = false;
    for (final part in builderPath.split('/').where((p) => p.isNotEmpty)) {
      path = '$path/$part';
      final result = await io.run(
        '/usr/bin/stat',
        ['-f', '%u:%g:%Lp:%HT', path],
        timeout: const Duration(seconds: 10),
        environment: const {'LC_ALL': 'C'},
      );
      if (result.exitCode != 0) {
        // No bool.exists: permission/parse/other errors do not count as absence.
        if (result.exitCode == 1 &&
            result.stderr.toString().contains('No such file or directory')) {
          missing = true;
          continue;
        }
        throw const OmlxException('oMLX builder 路径无法安全分类');
      }
      if (missing) throw const OmlxException('oMLX builder 路径检查发生变化');
      try {
        await _safeDirectory(path, uid);
      } on OmlxException {
        throw const OmlxException('oMLX builder 路径存在链接、权限歧义或其他用户可写祖先');
      }
      if (path == builderPath) {
        throw const OmlxException('oMLX builder 路径存在，拒绝启动 Python');
      }
    }
    if (!missing) throw const OmlxException('oMLX builder 路径存在');
  }

  Future<Directory> _privateDirectory(String prefix) async {
    await installationDirectory.create(recursive: true);
    final parent = Directory(
      await installationDirectory.resolveSymbolicLinks(),
    );
    await _ancestors(parent.path, await _uid(), sticky: true);
    final directory = await parent.createTemp(prefix);
    try {
      await _run('/bin/chmod', [
        '700',
        directory.path,
      ], timeout: const Duration(seconds: 10));
      await _safeDirectory(directory.path, await _uid(), private: true);
      return directory;
    } catch (_) {
      // Creation already transferred ownership even if setup never returned.
      _inspectionResiduals.add(directory.path);
      _set(
        const OmlxState(
          status: OmlxInstallationStatus.failed,
          error: 'oMLX 私有目录初始化未完成，保留现场',
        ),
      );
      throw const OmlxException('oMLX 私有目录初始化未完成，保留现场');
    }
  }

  Future<void> _signature(Directory app) async {
    await _run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      app.path,
    ]);
    await _run('/usr/sbin/spctl', [
      '--assess',
      '--type',
      'execute',
      '--verbose',
      app.path,
    ]);
    final identity = await _run('/usr/bin/codesign', [
      '-dv',
      '--verbose=4',
      app.path,
    ]);
    final lines = identity.stderr.toString().split('\n');
    if (!lines.contains('Identifier=app.omlx') ||
        !lines.contains('TeamIdentifier=PSK5Q5T46L')) {
      throw const OmlxException('oMLX 原生签名身份不符');
    }
    final plist = await _run('/usr/bin/plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      '${app.path}/Contents/Info.plist',
    ]);
    final value = jsonDecode(plist.stdout.toString());
    if (value is! Map ||
        value['CFBundleIdentifier'] != 'app.omlx' ||
        value['CFBundleShortVersionString'] != '0.7.0' ||
        value['CFBundleVersion'] != '2987') {
      throw const OmlxException('oMLX 发布标签或构建身份不符');
    }
  }

  Future<_Manifest> _inventory(Directory app) async {
    final canonical = await app.resolveSymbolicLinks();
    if (canonical != app.absolute.path) {
      throw const OmlxException('oMLX app 根路径不能是链接');
    }
    final records = <String>[];
    var bytes = 0;
    await for (final entity in app.list(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(app.path.length + 1);
      if (relative.contains('\n') || relative.contains('\r')) {
        throw const OmlxException('oMLX 资源路径无效');
      }
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        final target = await Link(entity.path).target();
        if (target.startsWith('/') ||
            !(_inside(await entity.resolveSymbolicLinks(), app.path))) {
          throw const OmlxException('oMLX 相对资源链接越界或失效');
        }
        records.add(jsonEncode([relative, 'link', target]));
      } else if (type == FileSystemEntityType.file) {
        final file = File(entity.path);
        final stat = await file.stat();
        bytes += stat.size;
        records.add(
          jsonEncode([
            relative,
            'file',
            stat.mode & 0xfff,
            stat.size,
            (await sha256.bind(file.openRead()).first).toString(),
          ]),
        );
      } else if (type == FileSystemEntityType.directory) {
        records.add(
          jsonEncode([
            relative,
            'directory',
            (await entity.stat()).mode & 0xfff,
          ]),
        );
      } else {
        throw const OmlxException('oMLX app 包含不支持的资源类型');
      }
    }
    for (final path in [
      'Contents/Info.plist',
      'Contents/MacOS/omlx-cli',
      'Contents/Resources/Python/cpython-3.11/bin/python3',
      'Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages/sitecustomize.py',
      'Contents/Resources/omlx/__init__.py',
    ]) {
      if (await FileSystemEntity.type('${app.path}/$path') !=
          FileSystemEntityType.file) {
        throw const OmlxException('oMLX 完整 app 资源缺失');
      }
    }
    records.sort();
    return _Manifest(
      sha256.convert(utf8.encode(records.join('\n'))).toString(),
      records.length,
      bytes,
    );
  }

  bool _inside(String path, String root) =>
      path == root || path.startsWith('$root/');
  Future<void> _bundleOwnership(Directory app) async {
    final uid = await _uid();
    await _ancestors(app.path, uid, sticky: true);
    final paths = <String>[app.path];
    await for (final entry in app.list(recursive: true, followLinks: false)) {
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.link) {
        paths.add(entry.path);
      }
    }
    for (var index = 0; index < paths.length; index += 200) {
      final batch = paths.sublist(
        index,
        index + 200 > paths.length ? paths.length : index + 200,
      );
      final result = await _run('/usr/bin/stat', [
        '-f',
        '%u:%g:%Lp:%HT',
        ...batch,
      ]);
      final lines = result.stdout.toString().trim().split('\n');
      if (lines.length != batch.length) {
        throw const OmlxException('oMLX 资源所有权证据不完整');
      }
      for (final line in lines) {
        final fields = line.split(':');
        final owner = fields.length == 4 ? int.tryParse(fields[0]) : null;
        final mode = fields.length == 4
            ? int.tryParse(fields[2], radix: 8)
            : null;
        if (owner == null ||
            mode == null ||
            mode & 0x12 != 0 ||
            ((owner != uid && owner != 0) && mode & 0x80 != 0)) {
          throw const OmlxException('oMLX 资源可由其他本地用户修改');
        }
      }
      // ACL presence is rejected rather than guessing group membership/deny order.
      final acl = await _run('/bin/ls', ['-lde', ...batch]);
      final aclLines = acl.stdout.toString().trim().split('\n');
      if (aclLines.length != batch.length ||
          aclLines.any(
            (line) => !RegExp(r'^[d-][rwxstST-]{9}[@]?\s').hasMatch(line),
          )) {
        throw const OmlxException('oMLX 资源 ACL 存在或无法解析');
      }
    }
  }

  Future<ProcessResult> _python(
    Directory app,
    Directory cwd,
    String executable,
    List<String> arguments,
  ) async {
    await _builderGate();
    await _safeDirectory(cwd.path, await _uid(), private: true);
    await _bundleOwnership(app);
    // Full-bundle ownership enumeration can be slow; make the baked-path check
    // again immediately before each launch, not only before that enumeration.
    await _builderGate();
    final resources = '${app.path}/Contents/Resources';
    final result = await _run(
      executable,
      arguments,
      timeout: Duration(seconds: executable.endsWith('/omlx-cli') ? 60 : 120),
      cwd: cwd.path,
      env: {
        'HOME': cwd.path,
        'TMPDIR': cwd.path,
        'PYTHONNOUSERSITE': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        if (executable.endsWith('/python3'))
          'PYTHONHOME': '$resources/Python/cpython-3.11',
        if (executable.endsWith('/python3'))
          'PYTHONPATH':
              '$resources:$resources/Python/framework-mlx-base/lib/python3.11/site-packages',
      },
    );
    return result;
  }

  static const _identityProbe = '''
import json, sys, platform, importlib.metadata as md
import omlx, mlx.core as mx, mlx_lm, fastapi, transformers
with mx.stream(mx.gpu):
    a = mx.array([[1., 2.], [3., 4.]])
    b = mx.array([[5., 6.], [7., 8.]])
    c = a @ b
    mx.eval(c)
    mx.synchronize()
print(json.dumps({"python": platform.python_version(), "architecture": platform.machine(),
 "prefix": sys.prefix, "paths": sys.path,
 "origins": sorted(set(m.__file__ for m in sys.modules.values() if getattr(m, "__file__", None))),
 "versions": {n: md.version(n) for n in ["omlx", "mlx", "mlx-lm", "fastapi", "transformers"]}, "gpu": c.tolist()}))
''';
  Future<OmlxReceipt> _inspect(
    Directory app,
    int epoch, {
    String? dmgSha256,
  }) async {
    if (_inspectionResiduals.isNotEmpty ||
        _state.residualDirectory != null ||
        _state.ownedDevice != null) {
      throw const OmlxException('oMLX 清理残留未解决，拒绝新检查');
    }
    await _builderGate();
    _check(epoch);
    final canonical = Directory(await app.resolveSymbolicLinks());
    if (canonical.path != app.absolute.path) {
      throw const OmlxException('oMLX app 根路径不能是链接');
    }
    final before = await _inventory(canonical);
    await _signature(canonical);
    final cwd = await _privateDirectory('.inspect-');
    try {
      _check(epoch);
      final version = await _python(
        canonical,
        cwd,
        '${canonical.path}/Contents/MacOS/omlx-cli',
        ['--version'],
      );
      if (version.stdout.toString().trim() != '0.7.0') {
        throw const OmlxException('oMLX CLI 版本不符');
      }
      _check(epoch);
      final probe = await _python(
        canonical,
        cwd,
        '${canonical.path}/Contents/Resources/Python/cpython-3.11/bin/python3',
        ['-s', '-c', _identityProbe],
      );
      final identity = jsonDecode(probe.stdout.toString());
      const versions = {
        'omlx': '0.7.0',
        'mlx': '0.32.2',
        'mlx-lm': '0.31.4.dev132+g94cdcae13',
        'fastapi': '0.142.2',
        'transformers': '5.17.0',
      };
      if (identity is! Map ||
          identity['python'] != '3.11.10' ||
          identity['architecture'] != 'arm64' ||
          identity['prefix'] !=
              '${canonical.path}/Contents/Resources/Python/cpython-3.11' ||
          identity['paths'] is! List ||
          identity['origins'] is! List ||
          (identity['origins'] as List).isEmpty ||
          identity['versions'] is! Map ||
          versions.entries.any((e) => identity['versions'][e.key] != e.value) ||
          jsonEncode(identity['gpu']) != '[[19.0,22.0],[43.0,50.0]]') {
        throw const OmlxException('oMLX Python、依赖或 Metal 身份验证失败');
      }
      for (final origin in identity['origins'] as List) {
        if (origin is! String ||
            !_inside(origin, canonical.path) ||
            !_inside(
              await File(origin).resolveSymbolicLinks(),
              canonical.path,
            )) {
          throw const OmlxException('oMLX 观察到包外 Python 模块');
        }
      }
      for (final path in identity['paths'] as List) {
        if (path is! String ||
            !(path == '' ||
                path == cwd.path ||
                path == builderPath ||
                _inside(path, canonical.path))) {
          throw const OmlxException('oMLX Python 搜索路径不符合已批准的有限例外');
        }
      }
      _check(epoch);
      await _signature(canonical);
      final after = await _inventory(canonical);
      if (before.digest != after.digest) {
        throw const OmlxException('oMLX 验证期间 app 发生变化');
      }
      return OmlxReceipt(
        bundleManifestSha256: after.digest,
        entries: after.entries,
        sizeBytes: after.bytes,
        dmgSha256: dmgSha256,
        runtimeIdentity: const OmlxRuntimeIdentity(
          python: '3.11.10',
          architecture: 'arm64',
        ),
      );
    } finally {
      // A private directory is ours, never the linked application or model path.
      try {
        if (await cwd.resolveSymbolicLinks() != cwd.path) {
          throw const OmlxException('oMLX 私有检查目录发生变化');
        }
        await cwd.delete(recursive: true);
      } catch (_) {
        _inspectionResiduals.add(cwd.path);
        _set(
          OmlxState(
            status: OmlxInstallationStatus.failed,
            error: 'oMLX 私有检查目录清理未完成',
            residualDirectory: _state.residualDirectory,
            ownedDevice: _state.ownedDevice,
          ),
        );
        throw const OmlxException('oMLX 私有检查目录清理未完成，保留现场');
      }
    }
  }

  Future<OmlxReceipt> inspectLinked(Directory app) => _serial((epoch) async {
    try {
      return await _inspect(app.absolute, epoch);
    } on OmlxException {
      rethrow;
    } catch (_) {
      throw const OmlxException('oMLX 完整 app 验证失败；原生输出已丢弃');
    }
  });

  /// Unlink/removal rechecks content without launching the foreign application.
  Future<String> linkedDigest(Directory app) => _serial((epoch) async {
    try {
      final result = await _inventory(app);
      _check(epoch);
      return result.digest;
    } catch (_) {
      throw const OmlxException('oMLX 关联 app 内容无法重新确认');
    }
  });

  Future<void> install({File? verifiedArtifact}) => _serial((epoch) async {
    Directory? work;
    String? ownedDevice;
    bool detached = false;
    bool attachAttempted = false;
    bool published = false;
    _Manifest? publishedManifest;
    final publishedMetadata = <String, String>{};
    if (_state.residualDirectory != null || _state.ownedDevice != null) {
      throw const OmlxException('oMLX 清理残留尚未解决，禁止新安装');
    }
    _set(const OmlxState(status: OmlxInstallationStatus.installing));
    try {
      // Existence is lexical, including dangling symlinks; never overwrite.
      if (await FileSystemEntity.type(
            _versionDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw const OmlxException('oMLX 目标已存在，请验证或移除后重试');
      }
      if (verifiedArtifact != null) await _verifyArtifact(verifiedArtifact);
      work = await _privateDirectory('.install-');
      final artifact = verifiedArtifact ?? File('${work.path}/official.dmg');
      if (verifiedArtifact == null) {
        await io.download(Uri.parse(artifactUrl), artifact);
      }
      await _verifyArtifact(
        artifact,
      ); // Even a preverified artifact is rehashed here.
      _check(epoch);
      final mount = await Directory('${work.path}/readonly-mount').create();
      attachAttempted = true;
      final attach = await _run('/usr/bin/hdiutil', [
        'attach',
        '-readonly',
        '-nobrowse',
        '-noautoopen',
        '-plist',
        '-mountpoint',
        mount.path,
        artifact.path,
      ]);
      final attachment = await _plist(attach.stdout.toString());
      final entities = attachment['system-entities'];
      if (entities is! List) throw const OmlxException('oMLX 挂载所有权不明确，保留现场');
      final disks = entities
          .whereType<Map>()
          .map((e) => e['dev-entry'])
          .whereType<String>()
          .toSet();
      final mounted = entities
          .whereType<Map>()
          .where((e) => e['mount-point'] == mount.path)
          .toList();
      if (mounted.length != 1) throw const OmlxException('oMLX 挂载位置不明确，保留现场');
      final info = await _diskInfo(mount.path);
      final stores = info['APFSPhysicalStores'];
      if (info['MountPoint'] != mount.path ||
          info['BusProtocol'] != 'Disk Image' ||
          info['Writable'] != false ||
          stores is! List ||
          stores.length != 1 ||
          stores[0] is! Map) {
        throw const OmlxException('oMLX 只读挂载身份验证失败，保留现场');
      }
      final store = stores[0]['APFSPhysicalStore'];
      if (store is! String || !RegExp(r'^disk[0-9]+s[0-9]+$').hasMatch(store)) {
        throw const OmlxException('oMLX 物理设备身份无效');
      }
      final device = '/dev/${store.replaceFirst(RegExp(r's[0-9]+$'), '')}';
      if (!disks.contains(device)) {
        throw const OmlxException('oMLX 物理设备不属于当前挂载');
      }
      final deviceInfo = await _diskInfo(device);
      if (deviceInfo['DeviceNode'] != device ||
          deviceInfo['WholeDisk'] != true ||
          deviceInfo['BusProtocol'] != 'Disk Image') {
        throw const OmlxException('oMLX 整盘身份验证失败');
      }
      ownedDevice = device;
      _check(epoch);
      final source = Directory('${mount.path}/oMLX.app');
      await _signature(source);
      final sourceInventory = await _inventory(source);
      final staging = await Directory('${work.path}/staging').create();
      final copied = Directory('${staging.path}/oMLX.app');
      await _run('/usr/bin/ditto', [
        '--rsrc',
        '--extattr',
        '--acl',
        source.path,
        copied.path,
      ], timeout: const Duration(seconds: 180));
      if ((await _inventory(copied)).digest != sourceInventory.digest) {
        throw const OmlxException('oMLX 完整 app 复制内容不符');
      }
      await _inspect(copied, epoch, dmgSha256: dmgDigest);
      // No publication while an owned device still needs cleanup.
      await _detach(device, mount.path);
      detached = true;
      _check(epoch);
      if (await FileSystemEntity.type(
            _versionDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw const OmlxException('oMLX 发布目标发生变化');
      }
      publishedManifest = await _inventory(copied);
      await staging.rename(_versionDirectory.path);
      published = true;
      final receipt = await _inspect(bundle, epoch, dmgSha256: dmgDigest);
      final temporary = File('${_marker.path}.tmp');
      final metadata = jsonEncode({'schema': 1, 'receipt': receipt.toJson()});
      await temporary.writeAsString(metadata, flush: true);
      publishedMetadata[temporary.path] = metadata;
      await temporary.rename(_marker.path);
      publishedMetadata.remove(temporary.path);
      publishedMetadata[_marker.path] = metadata;
      _check(epoch);
      _set(
        OmlxState(status: OmlxInstallationStatus.installed, receipt: receipt),
      );
    } catch (_) {
      _set(
        const OmlxState(
          status: OmlxInstallationStatus.failed,
          error: 'oMLX 安装未完成；没有模型运行能力或 Ready 证明',
        ),
      );
      // Only undo a publication created by this operation with unchanged app bytes.
      if (published && publishedManifest != null) {
        try {
          if (await _versionDirectory.resolveSymbolicLinks() !=
                  _versionDirectory.path ||
              (await _inventory(bundle)).digest != publishedManifest.digest) {
            throw const OmlxException('oMLX 发布后内容变化，保留现场');
          }
          final entries = await _versionDirectory
              .list(followLinks: false)
              .toList();
          final owned = {bundle.path, ...publishedMetadata.keys};
          if (entries.length != owned.length ||
              entries.any((entry) => !owned.contains(entry.path))) {
            throw const OmlxException('oMLX 发布目录含未拥有文件，保留现场');
          }
          for (final entry in publishedMetadata.entries) {
            if (await FileSystemEntity.type(entry.key, followLinks: false) !=
                    FileSystemEntityType.file ||
                await File(entry.key).readAsString() != entry.value) {
              throw const OmlxException('oMLX 发布收据发生变化，保留现场');
            }
          }
          await _versionDirectory.delete(recursive: true);
        } catch (_) {
          _set(
            OmlxState(
              status: OmlxInstallationStatus.failed,
              error: 'oMLX 发布清理未完成',
              residualDirectory: _versionDirectory.path,
            ),
          );
        }
      }
      throw const OmlxException('oMLX 安装验证失败或取消；原生输出已丢弃');
    } finally {
      if (ownedDevice != null && !detached) {
        try {
          await _detach(ownedDevice, '${work!.path}/readonly-mount');
          detached = true;
        } catch (_) {
          _set(
            OmlxState(
              status: OmlxInstallationStatus.failed,
              error: 'oMLX 自有设备清理未完成',
              ownedDevice: ownedDevice,
              residualDirectory: work?.path,
            ),
          );
        }
      }
      // Unknown mount ownership: never detach guesses or delete its mountpoint.
      if (work != null) {
        if ((attachAttempted && ownedDevice == null) ||
            (ownedDevice != null && !detached)) {
          _set(
            OmlxState(
              status: OmlxInstallationStatus.failed,
              error: 'oMLX 挂载残留需人工确认',
              ownedDevice: ownedDevice,
              residualDirectory: work.path,
            ),
          );
        } else {
          try {
            if (await work.resolveSymbolicLinks() != work.path) {
              throw const OmlxException('oMLX 自有目录发生变化');
            }
            await work.delete(recursive: true);
          } catch (_) {
            _inspectionResiduals.add(
              work.path,
            ); // No active/ambiguous mount reaches this branch.
            _set(
              OmlxState(
                status: OmlxInstallationStatus.failed,
                error: 'oMLX 自有目录清理未完成',
                residualDirectory: work.path,
              ),
            );
          }
        }
      }
    }
  });
  Future<void> _verifyArtifact(File artifact) async {
    if (await artifact.length() != 830879938 ||
        (await sha256.bind(artifact.openRead()).first).toString() !=
            dmgDigest) {
      throw const OmlxException('oMLX 官方 DMG 摘要或大小不符');
    }
  }

  Future<Map<String, Object?>> _diskInfo(String device) async {
    final result = await _run('/usr/sbin/diskutil', ['info', '-plist', device]);
    return _plist(result.stdout.toString());
  }

  Future<void> _detach(String device, String mountPath) async {
    final mounted = await _diskInfo(mountPath);
    final stores = mounted['APFSPhysicalStores'];
    if (mounted['MountPoint'] != mountPath ||
        mounted['BusProtocol'] != 'Disk Image' ||
        mounted['Writable'] != false ||
        stores is! List ||
        stores.length != 1 ||
        stores[0] is! Map ||
        stores[0]['APFSPhysicalStore'] is! String ||
        !RegExp(r'^disk[0-9]+s[0-9]+$')
            .hasMatch(stores[0]['APFSPhysicalStore'] as String) ||
        '/dev/${(stores[0]['APFSPhysicalStore'] as String).replaceFirst(RegExp(r's[0-9]+$'), '')}' !=
            device) {
      throw const OmlxException('oMLX 自有挂载与整盘关联已变化，拒绝卸载');
    }
    final info = await _diskInfo(device);
    if (info['DeviceNode'] != device ||
        info['WholeDisk'] != true ||
        info['BusProtocol'] != 'Disk Image') {
      throw const OmlxException('oMLX 待卸载自有整盘身份发生变化');
    }
    await _run('/usr/bin/hdiutil', [
      'detach',
      device,
    ], timeout: const Duration(seconds: 60));
  }

  Future<void> refreshInstallation() => _serial((epoch) async {
    // A metadata refresh must not erase unresolved device/directory ownership.
    if (_state.residualDirectory != null || _state.ownedDevice != null) return;
    if (await FileSystemEntity.type(
          _versionDirectory.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      _set(const OmlxState(status: OmlxInstallationStatus.notInstalled));
      return;
    }
    try {
      final marker = jsonDecode(await _marker.readAsString());
      if (marker is! Map || marker['schema'] != 1) {
        throw const OmlxException('oMLX 收据无效');
      }
      final expected = OmlxReceipt.fromJson(marker['receipt']);
      if (expected.dmgSha256 != dmgDigest) {
        throw const OmlxException('oMLX 受管来源未验证');
      }
      final actual = await _inspect(bundle, epoch, dmgSha256: dmgDigest);
      if (actual.bundleManifestSha256 != expected.bundleManifestSha256) {
        throw const OmlxException('oMLX app 内容已变化');
      }
      _set(
        OmlxState(status: OmlxInstallationStatus.installed, receipt: actual),
      );
    } catch (_) {
      _set(
        const OmlxState(
          status: OmlxInstallationStatus.failed,
          error: 'oMLX 安装未通过重新验证；保留原有内容',
        ),
      );
    }
  });
  Future<void> _ownedRemovalRange(OmlxReceipt expected) async {
    try {
      if (await _versionDirectory.resolveSymbolicLinks() !=
          _versionDirectory.path) {
        throw const OmlxException('oMLX 受管目录身份发生变化');
      }
      final entries = await _versionDirectory.list(followLinks: false).toList();
      if (entries.length != 2 ||
          entries.any((e) => e.path != bundle.path && e.path != _marker.path) ||
          await FileSystemEntity.type(_marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await _marker.length() > 65536) {
        throw const OmlxException('oMLX 删除范围含未拥有文件或收据链接');
      }
      final value = jsonDecode(await _marker.readAsString());
      if (value is! Map ||
          value.length != 2 ||
          value['schema'] != 1 ||
          value['receipt'] is! Map ||
          (value['receipt'] as Map).length != expected.toJson().length ||
          jsonEncode(OmlxReceipt.fromJson(value['receipt']).toJson()) !=
              jsonEncode(expected.toJson())) {
        throw const OmlxException('oMLX 删除收据发生变化');
      }
    } on OmlxException {
      rethrow;
    } catch (_) {
      throw const OmlxException('oMLX 删除范围无法安全确认');
    }
  }

  Future<OmlxRemovalPlan> prepareRemoval() => _serial((epoch) async {
    if (_state.status != OmlxInstallationStatus.installed ||
        _state.receipt == null ||
        _state.residualDirectory != null ||
        _state.ownedDevice != null) {
      throw const OmlxException('oMLX 未通过验证或存在清理残留');
    }
    await _ownedRemovalRange(_state.receipt!);
    final current = await _inventory(bundle);
    if (current.digest != _state.receipt!.bundleManifestSha256) {
      throw const OmlxException('oMLX 删除前内容变化');
    }
    _check(epoch);
    return OmlxRemovalPlan._(this, _state.receipt!, bundle.path);
  });
  Future<void> removeInstallation(
    OmlxRemovalPlan plan, {
    required bool confirmed,
  }) => _serial((epoch) async {
    if (!confirmed) return;
    if (!identical(plan._owner, this) ||
        plan.bundlePath != bundle.path ||
        _state.receipt?.bundleManifestSha256 !=
            plan.receipt.bundleManifestSha256 ||
        _state.residualDirectory != null ||
        _state.ownedDevice != null ||
        (await _inventory(bundle)).digest !=
            plan.receipt.bundleManifestSha256) {
      throw const OmlxException('oMLX 删除计划已失效或不属于当前安装');
    }
    await _ownedRemovalRange(plan.receipt);
    _check(epoch);
    final canonical = await _versionDirectory.resolveSymbolicLinks();
    if (canonical != _versionDirectory.path) {
      throw const OmlxException('oMLX 删除目录发生变化');
    }
    await _versionDirectory.delete(recursive: true);
    _set(const OmlxState(status: OmlxInstallationStatus.notInstalled));
  });
  Future<void> _retryResidualCleanup() async {
    final originallyInspected = Set<String>.of(_inspectionResiduals);
    for (final path in originallyInspected) {
      try {
        final directory = Directory(path);
        final parent = await directory.parent.resolveSymbolicLinks();
        if (parent != await installationDirectory.resolveSymbolicLinks()) {
          throw const OmlxException('oMLX 清理父目录变化');
        }
        await _ancestors(parent, await _uid(), sticky: true);
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          if (await directory.resolveSymbolicLinks() != path) {
            throw const OmlxException('oMLX 清理目录变为链接');
          }
          await _safeDirectory(path, await _uid(), private: true);
          await directory.delete(recursive: true);
        }
        _inspectionResiduals.remove(path);
      } catch (_) {
        throw const OmlxException('oMLX 私有检查残留无法安全清理');
      }
    }
    var clearedDevice = false;
    var remaining = _state.residualDirectory;
    if (originallyInspected.contains(remaining)) remaining = null;
    if (_state.ownedDevice != null && remaining != null) {
      try {
        final work = Directory(remaining);
        if (await work.resolveSymbolicLinks() != work.path ||
            await work.parent.resolveSymbolicLinks() !=
                await installationDirectory.resolveSymbolicLinks()) {
          throw const OmlxException('oMLX 自有挂载目录变化');
        }
        await _safeDirectory(work.path, await _uid(), private: true);
        await _detach(_state.ownedDevice!, '${work.path}/readonly-mount');
        // Record successful detach before a directory-cleanup failure.
        _set(
          OmlxState(
            status: OmlxInstallationStatus.failed,
            error: 'oMLX 自有目录待清理',
            residualDirectory: remaining,
          ),
        );
        _inspectionResiduals.add(work.path);
        await work.delete(recursive: true);
        _inspectionResiduals.remove(work.path);
        remaining = null;
        clearedDevice = true;
      } catch (_) {
        throw const OmlxException('oMLX 自有挂载残留无法安全清理');
      }
    }
    if (remaining != null || _state.ownedDevice != null) {
      throw const OmlxException('oMLX 挂载所有权不明确或目录清理未完成；保留现场');
    }
    if (originallyInspected.isNotEmpty || clearedDevice) {
      _set(
        const OmlxState(
          status: OmlxInstallationStatus.failed,
          error: 'oMLX 残留已清理；安装需重新验证',
        ),
      );
    }
  }

  void beginShutdown() {
    _closed = true;
    _epoch++;
  }

  Future<void> shutdown() async {
    beginShutdown();
    await _operations;
    await _retryResidualCleanup();
  }

  Future<void> stopManaged() async {
    _held = true;
    _epoch++;
    try {
      await _operations;
      await _retryResidualCleanup();
    } finally {
      _held = false;
    }
  }

  void close() {
    beginShutdown();
    _changes.close();
  }
}
