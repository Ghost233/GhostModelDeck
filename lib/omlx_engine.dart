import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'chat_protocol.dart';
import 'engine_runtime.dart';
import 'model_library.dart';
import 'model_use_registry.dart';

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

/// Injectable seam for launching the owned front-end `serve` process. The
/// production adapter uses Process.start; tests hand out boundary doubles.
abstract class OmlxPoolIO {
  Future<OmlxPoolChild> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
  });
}

abstract class OmlxPoolChild {
  int get pid;
  Future<int> get exitCode;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  void kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

class _NativeOmlxPoolChild implements OmlxPoolChild {
  _NativeOmlxPoolChild(this._process);
  final Process _process;
  @override
  int get pid => _process.pid;
  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

class NativeOmlxPoolIO implements OmlxPoolIO {
  const NativeOmlxPoolIO();
  @override
  Future<OmlxPoolChild> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
    );
    return _NativeOmlxPoolChild(process);
  }
}

/// Last path segment after the final separator (model id from its directory).
String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Everything before the final separator (the owning model directory).
String _dirName(String path) => path.substring(0, path.lastIndexOf('/'));

/// Request-facing failures of the owned pool. [notReady] is a fence verdict,
/// never a hidden retry or background load.
enum OmlxRequestKind {
  notReady,
  cancelled,
  serviceFailed,
  invalidResponse,
  timeout,
}

class OmlxRequestException implements Exception {
  const OmlxRequestException(this.kind, this.message);
  final OmlxRequestKind kind;
  final String message;
  @override
  String toString() => message;
}

/// Owns the native oMLX installation, its exact validation lifecycle, and the
/// owned front-end model pool: one supervised serve process per generation,
/// pin-only enablement, fenced routing, and exact stop/recycle semantics.
class OmlxEngine implements EngineRuntime {
  OmlxEngine({
    required this.installationDirectory,
    OmlxProcessIO? io,
    this._library,
    OmlxPoolIO? poolIo,
    this._useRegistry,
    this._poolLoadTimeout = const Duration(seconds: 120),
    this._poolStopTimeout = const Duration(seconds: 20),
  }) : io = io ?? NativeOmlxProcessIO(),
       _poolIo = poolIo ?? const NativeOmlxPoolIO();
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
  final ModelLibrary? _library;
  final OmlxPoolIO _poolIo;
  final ModelUseRegistry? _useRegistry;
  final Duration _poolLoadTimeout;
  final Duration _poolStopTimeout;
  final List<_OmlxRun> _runs = <_OmlxRun>[];
  _OmlxPool? _pool;
  Future<void> _poolQueue = Future<void>.value();
  int _runtimeIds = 0;
  int _poolGeneration = 0;
  int _startHolds = 0;
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

  /// `%Mp%Lp` keeps the set-uid/set-gid/sticky digit that `%Lp` alone drops;
  /// macOS prints a sticky directory such as /private/tmp as plain 777
  /// without it, which made trusted system sticky roots unreachable.
  static const _statFields = '%u:%g:%Mp%Lp:%HT';

  Future<void> _safeDirectory(
    String path,
    int uid, {
    bool private = false,
    bool sticky = false,
  }) async {
    final result = await _run('/usr/bin/stat', [
      '-f',
      _statFields,
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
    // Deny-only ACEs (for example the standard `group:everyone deny delete`
    // on macOS home directories) can only restrict access, never widen it;
    // any allow entry or unclassifiable line stays fail-closed.
    if (!RegExp(r'^d[rwxstST-]{9}[+@]?\s').hasMatch(lines[0]) ||
        lines
            .skip(1)
            .any(
              (line) =>
                  !RegExp(r'^\s*\d+: (user|group):\S+ deny [a-z_,]+$')
                      .hasMatch(line),
            )) {
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
        ['-f', _statFields, path],
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
      final result = await _run('/usr/bin/stat', ['-f', _statFields, ...batch]);
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
 "versions": {"omlx": omlx.__version__,
  **{n: md.version(n) for n in ["mlx", "mlx-lm", "fastapi", "transformers"]}}, "gpu": c.tolist()}))
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
      // The official bundle ships group-writable CPython entries; only this
      // owned private copy is normalized, never ancestors or user paths.
      // _inspect below re-verifies manifest, signature and ownership on the
      // normalized bytes before any Python launch.
      await _run('/bin/chmod', [
        '-R',
        'go-w',
        copied.path,
      ], timeout: const Duration(seconds: 180));
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

  // ---------------------------------------------------------------------
  // Owned oMLX model pool (docs/spec.md A04/A05/A07).
  //
  // Installed ≠ Started ≠ Ready. One owned front-end serve process per pool
  // generation; enablement is pin-only settings + fallback-false readback +
  // physical load + physical-row reconciliation + a short real probe. The
  // request fence rejects unknown/cold/disabled/drifted selections without
  // hidden retries or background loads.
  // ---------------------------------------------------------------------

  Future<T> _poolSerial<T>(Future<T> Function() work) {
    final result = _poolQueue.then((_) => work());
    _poolQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  List<RuntimeInstance> get runtimeInstances =>
      List.unmodifiable(_runs.map((run) => run.snapshot()));

  @override
  void Function() holdStartAdmission() {
    if (_closed || _held || _admissionHolds != 0) {
      throw const OmlxException('oMLX 安装管理正在退出或回收');
    }
    _startHolds++;
    var released = false;
    return () {
      if (!released) {
        released = true;
        _startHolds--;
      }
    };
  }

  @override
  Future<RuntimeInstance> startRuntime(String artifactId) {
    if (_closed || _held || _admissionHolds != 0 || _startHolds != 0) {
      return Future.error(const OmlxException('oMLX 安装管理正在退出或回收'));
    }
    return _poolSerial(() => _startRuntime(artifactId));
  }

  Future<RuntimeInstance> _startRuntime(String artifactId) async {
    if (_state.status != OmlxInstallationStatus.installed ||
        _state.receipt == null) {
      throw const OmlxException('oMLX 尚未通过安装核验，模型池不可用');
    }
    final library = _library;
    if (library == null) {
      throw const OmlxException('oMLX 模型池需要已扫描的模型库');
    }
    final List<LibraryArtifact> verified;
    try {
      verified = await library.verify([artifactId]);
    } on LibraryException catch (error) {
      throw OmlxException('oMLX 资产核验失败：${error.message}');
    }
    if (verified.length != 1) {
      throw const OmlxException('oMLX 资产核验已变化，请重新选择并核验');
    }
    final artifact = verified.single;
    if (artifact.kind != AssetKind.chat ||
        artifact.integrity != AssetIntegrity.complete) {
      throw const OmlxException('oMLX 池只启用完整核验的聊天资产');
    }
    final directory = await _modelDirectory(artifact);
    final modelId = _baseName(directory);
    for (final run in _runs.toList()) {
      if (run.artifactId != artifactId) continue;
      if (run.status == RuntimeInstanceStatus.ready) {
        return run.snapshot();
      }
      if (run.status == RuntimeInstanceStatus.stopped ||
          (run.status == RuntimeInstanceStatus.failed && !run.hasLiveProcess)) {
        // A terminal run without a live process is replaced, keeping one
        // visible run per enabled artifact.
        _runs.remove(run);
        continue;
      }
      throw const OmlxException('oMLX 实例正在停止或回收，请稍后重试');
    }
    final pool = await _ensurePool();
    final run = _OmlxRun(
      id: 'omlx-${++_runtimeIds}',
      artifactId: artifactId,
      modelId: modelId,
      directory: directory,
      filePaths: artifact.files.map((file) => file.path).toSet(),
      pool: pool,
    );
    _runs.add(run);
    var loaded = false;
    try {
      await _pin(pool, modelId, true);
      await _load(pool, modelId);
      loaded = true;
      await _checkPhysicalRow(pool, run);
      await _probe(pool, run);
      run.status = RuntimeInstanceStatus.ready;
      run.acceptingRequests = true;
      await _syncUseRegistration();
      return run.snapshot();
    } catch (error) {
      if (loaded) {
        try {
          await _unload(pool, modelId);
        } catch (_) {
          // Best-effort rollback; the failure verdict below stands.
        }
      }
      run.status = RuntimeInstanceStatus.failed;
      run.acceptingRequests = false;
      run.hasLiveProcess = false;
      run.error = pool.redact(error.toString());
      throw OmlxException(run.error!);
    }
  }

  Future<String> _modelDirectory(LibraryArtifact artifact) async {
    if (artifact.files.isEmpty) {
      throw const OmlxException('oMLX 资产没有可核验文件');
    }
    final directories = <String>{};
    for (final file in artifact.files) {
      final resolved = await File(file.path).resolveSymbolicLinks();
      directories.add(_dirName(resolved));
    }
    if (directories.length != 1) {
      throw const OmlxException('oMLX 资产文件组不符合单目录冻结形态');
    }
    return directories.single;
  }

  Future<_OmlxPool> _ensurePool() async {
    final existing = _pool;
    if (existing != null && !existing.dead) return existing;
    if (existing != null) {
      existing.child.kill(ProcessSignal.sigkill);
      existing.client.close(force: true);
      await _retirePoolBase(existing);
      _pool = null;
    }
    final pool = await _spawnPool();
    _pool = pool;
    return pool;
  }

  Future<_OmlxPool> _spawnPool() async {
    final rootPath = _library?.state.rootPath;
    if (rootPath == null) {
      throw const OmlxException('oMLX 模型库尚未扫描');
    }
    final modelRoot = await Directory(rootPath).resolveSymbolicLinks();
    final generation = ++_poolGeneration;

    // Reserve an owned loopback port, then hand it to the service.
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();

    final base = await _privateDirectory('.pool-');
    OmlxPoolChild? child;
    try {
      final apiKey = _poolSecret('k');
      final signingSecret = _poolSecret('s');
      final settings = <String, Object?>{
        'version': '1.0',
        'server': {'host': '127.0.0.1', 'port': port},
        'model': {
          'model_dirs': [modelRoot],
          'model_fallback': false,
        },
        'auth': {
          'api_key': apiKey,
          'secret_key': signingSecret,
          'skip_api_key_verification': false,
          'allow_unauthenticated_inference': false,
          'sub_keys': <Object?>[],
        },
      };
      final settingsFile = File('${base.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode(settings));
      await _run('/bin/chmod', [
        '600',
        settingsFile.path,
      ], timeout: const Duration(seconds: 10));

      child = await _poolIo.start(
        '${bundle.path}/Contents/MacOS/omlx-cli',
        [
          'serve',
          '--model-dir',
          modelRoot,
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
          '--base-path',
          base.path,
          '--no-hf-cache',
        ],
        workingDirectory: base.path,
        environment: {
          'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
          'HOME': base.path,
          'LC_ALL': 'C',
        },
      );
      final pool = _OmlxPool(
        generation: generation,
        child: child,
        base: base,
        port: port,
        apiKey: apiKey,
        signingSecret: signingSecret,
        client: HttpClient(),
      );
      // Watch natural exit before any traffic; stdout/stderr are drained, not
      // logged, so credentials can never reach logs through the child.
      unawaited(child.exitCode.then((code) => _onPoolExit(pool, code)));
      unawaited(child.stdout.drain<void>());
      unawaited(child.stderr.drain<void>());
      await _awaitHealth(pool);
      pool.cookie = await _login(pool);
      await _enforceFallback(pool);
      await _reconcileStale(pool);
      return pool;
    } catch (_) {
      child?.kill(ProcessSignal.sigkill);
      try {
        await base.delete(recursive: true);
      } catch (_) {
        // An owned residual base is safe; the next spawn uses a fresh one.
      }
      rethrow;
    }
  }

  static String _poolSecret(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return '$prefix-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> _onPoolExit(_OmlxPool pool, int code) async {
    if (pool.retired || pool.dead) return;
    await _poolSerial(() async {
      if (pool.retired || pool.dead || !identical(_pool, pool)) return;
      pool.dead = true;
      for (final run in _runs) {
        if (!identical(run.pool, pool) ||
            (run.status != RuntimeInstanceStatus.ready &&
                run.status != RuntimeInstanceStatus.starting)) {
          continue;
        }
        run.status = RuntimeInstanceStatus.failed;
        run.acceptingRequests = false;
        run.hasLiveProcess = false;
        run.error = 'oMLX 服务进程意外退出';
        for (final op in run.inFlight.toList()) {
          op.cancel(
            const OmlxRequestException(
              OmlxRequestKind.serviceFailed,
              'oMLX 服务进程意外退出',
            ),
          );
        }
      }
      await _syncUseRegistration();
    });
  }

  Future<void> _awaitHealth(_OmlxPool pool) async {
    final deadline = DateTime.now().add(_poolLoadTimeout);
    while (true) {
      if (pool.dead) {
        throw const OmlxException('oMLX 服务进程在启动期退出');
      }
      try {
        final request = await pool.client.getUrl(pool.uri('/health'));
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        await response.drain<void>();
        if (response.statusCode == 200) return;
      } catch (_) {
        // Not up yet; keep polling until the deadline.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const OmlxException('oMLX 服务健康检查超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<String> _login(_OmlxPool pool) async {
    final request = await pool.client.postUrl(pool.uri('/admin/api/login'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'api_key': pool.apiKey, 'remember': false}));
    final response = await request.close().timeout(_poolLoadTimeout);
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw OmlxException('oMLX 管理会话登录失败：${pool.redact(body)}');
    }
    for (final header in response.headers['set-cookie'] ?? const <String>[]) {
      final match = RegExp(r'omlx_admin_session=([^;\s]+)').firstMatch(header);
      if (match != null) return match.group(1)!;
    }
    throw const OmlxException('oMLX 管理会话缺少登录凭据');
  }

  Future<Map<String, Object?>> _admin(
    _OmlxPool pool,
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await pool.client.openUrl(method, pool.uri(path));
    request.headers.contentType = ContentType.json;
    request.headers.set('cookie', 'omlx_admin_session=${pool.cookie}');
    request.write(jsonEncode(body));
    final response = await request.close().timeout(_poolLoadTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw OmlxException('oMLX 管理请求失败：${pool.redact(text)}');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const OmlxException('oMLX 管理响应无法投影');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<String> _bearer(
    _OmlxPool pool,
    String method,
    String path,
    Map<String, Object?>? body, {
    Duration? timeout,
  }) async {
    final request = await pool.client.openUrl(method, pool.uri(path));
    request.headers.set('authorization', 'Bearer ${pool.apiKey}');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(timeout ?? _poolLoadTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw OmlxException('oMLX 服务请求失败：${pool.redact(text)}');
    }
    return text;
  }

  Future<void> _pin(_OmlxPool pool, String modelId, bool pinned) async {
    final response = await _admin(
      pool,
      'PUT',
      '/admin/api/models/$modelId/settings',
      {'is_pinned': pinned},
    );
    final settings = response['settings'];
    if (settings is! Map || settings['is_pinned'] != pinned) {
      throw const OmlxException('oMLX 模型 pin 设置读回失败');
    }
  }

  Future<void> _enforceFallback(_OmlxPool pool) async {
    final response = await _admin(pool, 'POST', '/admin/api/global-settings', {
      'model_fallback': false,
    });
    final model = response['model'];
    if (model is! Map || model['model_fallback'] != false) {
      throw const OmlxException('oMLX model_fallback 读回失败');
    }
  }

  /// A resurrected pin or load from a previous service state is unwound
  /// before any enablement work of this generation.
  Future<void> _reconcileStale(_OmlxPool pool) async {
    final text = await _bearer(pool, 'GET', '/v1/models/status', null);
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['models'] is! List) {
      throw const OmlxException('oMLX 状态响应无法投影');
    }
    for (final row in decoded['models'] as List) {
      if (row is! Map || row['source_model_id'] != null) continue;
      final id = row['id'];
      if (id is! String) continue;
      if (row['pinned'] == true) await _pin(pool, id, false);
      if (row['loaded'] == true) await _unload(pool, id);
    }
  }

  Future<void> _load(_OmlxPool pool, String modelId) async {
    try {
      await _bearer(pool, 'POST', '/v1/models/$modelId/load', const {});
    } on OmlxException catch (error) {
      throw OmlxException('oMLX 模型物理装载失败：${pool.redact(error.message)}');
    }
  }

  Future<void> _unload(_OmlxPool pool, String modelId) async {
    try {
      await _bearer(pool, 'POST', '/v1/models/$modelId/unload', const {});
    } on OmlxException catch (error) {
      // An unload rejected because the row is already unloaded still
      // satisfies the exact lifecycle; anything else keeps evidence.
      final row = await _physicalRow(pool, modelId);
      if (row['loaded'] != false) {
        throw OmlxException('oMLX 模型卸载失败：${pool.redact(error.message)}');
      }
    }
  }

  Future<Map<String, Object?>> _physicalRow(
    _OmlxPool pool,
    String modelId,
  ) async {
    final text = await _bearer(pool, 'GET', '/v1/models/status', null);
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['models'] is! List) {
      throw const OmlxException('oMLX 状态响应无法投影');
    }
    for (final row in decoded['models'] as List) {
      if (row is Map &&
          row['id'] == modelId &&
          row['source_model_id'] == null) {
        return Map<String, Object?>.from(row);
      }
    }
    throw const OmlxException('oMLX 状态缺少所选模型的物理行');
  }

  Future<void> _checkPhysicalRow(_OmlxPool pool, _OmlxRun run) async {
    final row = await _physicalRow(pool, run.modelId);
    final path = row['model_path'];
    String? canonical;
    if (path is String) {
      try {
        canonical = await File(path).resolveSymbolicLinks();
      } catch (_) {
        canonical = null;
      }
    }
    if (row['loaded'] != true ||
        row['is_loading'] != false ||
        row['pinned'] != true ||
        canonical == null ||
        canonical != run.directory) {
      throw const OmlxException('oMLX 物理行与冻结构造不一致');
    }
  }

  Future<void> _probe(_OmlxPool pool, _OmlxRun run) async {
    final probe = TextRequest(prompt: 'ping', maxTokens: 8);
    final String text;
    try {
      text = await _bearer(
        pool,
        'POST',
        '/v1/chat/completions',
        probe.toChat(model: run.modelId),
      );
    } on OmlxException catch (error) {
      throw OmlxException('oMLX 短文本探测失败：${error.message}');
    }
    try {
      TextResult.parse(text, expectedModel: run.modelId);
    } on TextProtocolException catch (error) {
      throw OmlxException('oMLX 短文本探测未通过：${error.message}');
    }
  }

  _OmlxRun _admitRun(String instanceId) {
    if (_closed) {
      throw const OmlxRequestException(OmlxRequestKind.notReady, 'oMLX 引擎已关闭');
    }
    for (final run in _runs) {
      if (run.id != instanceId) continue;
      final pool = run.pool;
      if (run.status != RuntimeInstanceStatus.ready ||
          !run.acceptingRequests ||
          !identical(_pool, pool) ||
          pool.dead ||
          pool.retired) {
        throw const OmlxRequestException(
          OmlxRequestKind.notReady,
          'oMLX 实例未就绪或已回收',
        );
      }
      return run;
    }
    throw const OmlxRequestException(OmlxRequestKind.notReady, '未知 oMLX 实例');
  }

  void _release(_OmlxRun run, _OmlxInFlight op) {
    run.inFlight.remove(op);
    if (!op.done.isCompleted) op.done.complete();
  }

  @override
  Future<TextResult> generateText(
    String instanceId,
    TextRequest request, {
    Duration timeout = const Duration(seconds: 30),
    DecisionCancellation? cancellation,
  }) async {
    final run = _admitRun(instanceId);
    final pool = run.pool;
    final op = _OmlxInFlight();
    run.inFlight.add(op);
    final unlisten = cancellation?.listen(
      () => op.cancel(
        const OmlxRequestException(OmlxRequestKind.cancelled, '请求已取消'),
      ),
    );
    try {
      final text = await _inFlightCall(
        pool,
        op,
        '/v1/chat/completions',
        jsonEncode(request.toChat(model: run.modelId)),
        timeout,
      );
      if (op.cancelled) throw op.terminal!;
      try {
        return TextResult.parse(text, expectedModel: run.modelId);
      } on TextProtocolException catch (error) {
        throw OmlxRequestException(
          OmlxRequestKind.invalidResponse,
          'oMLX 响应无效：${error.message}',
        );
      }
    } finally {
      unlisten?.call();
      _release(run, op);
    }
  }

  Future<String> _inFlightCall(
    _OmlxPool pool,
    _OmlxInFlight op,
    String path,
    String body,
    Duration timeout,
  ) async {
    HttpClientRequest? request;
    try {
      request = await pool.client.postUrl(pool.uri(path));
      request.headers.set('authorization', 'Bearer ${pool.apiKey}');
      request.headers.contentType = ContentType.json;
      op.abort = () => request?.abort();
      if (op.cancelled) request.abort();
      request.write(body);
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join();
      if (op.cancelled) throw op.terminal!;
      if (response.statusCode != 200) {
        throw OmlxRequestException(
          OmlxRequestKind.serviceFailed,
          'oMLX 服务拒绝请求：${pool.redact(text)}',
        );
      }
      return text;
    } on TimeoutException {
      request?.abort();
      throw const OmlxRequestException(OmlxRequestKind.timeout, 'oMLX 请求超时');
    } on OmlxRequestException {
      rethrow;
    } catch (_) {
      if (op.cancelled) throw op.terminal!;
      throw const OmlxRequestException(
        OmlxRequestKind.serviceFailed,
        'oMLX 服务连接失败',
      );
    }
  }

  /// Real SSE over the same fenced path: genuine finish/usage/[DONE], abort
  /// on cancellation, never a fabricated terminal frame.
  Stream<TextStreamEvent> streamText(
    String instanceId,
    TextRequest request, {
    DecisionCancellation? cancellation,
  }) async* {
    final run = _admitRun(instanceId);
    final pool = run.pool;
    final op = _OmlxInFlight();
    run.inFlight.add(op);
    final unlisten = cancellation?.listen(
      () => op.cancel(
        const OmlxRequestException(OmlxRequestKind.cancelled, '请求已取消'),
      ),
    );
    HttpClientRequest? nativeRequest;
    try {
      nativeRequest = await pool.client.postUrl(
        pool.uri('/v1/chat/completions'),
      );
      nativeRequest.headers.set('authorization', 'Bearer ${pool.apiKey}');
      nativeRequest.headers.contentType = ContentType.json;
      op.abort = () => nativeRequest?.abort();
      if (op.cancelled) nativeRequest.abort();
      nativeRequest.write(
        jsonEncode(request.toChat(model: run.modelId, stream: true)),
      );
      final response = await nativeRequest.close();
      if (op.cancelled) throw op.terminal!;
      if (response.statusCode != 200) {
        final text = await utf8.decoder.bind(response).join();
        throw OmlxRequestException(
          OmlxRequestKind.serviceFailed,
          'oMLX 服务拒绝请求：${pool.redact(text)}',
        );
      }
      final decoder = TextStreamDecoder(expectedModel: run.modelId);
      var done = false;
      var buffer = '';
      await for (final chunk in utf8.decoder.bind(response)) {
        buffer += chunk;
        int boundary;
        while ((boundary = buffer.indexOf('\n\n')) >= 0) {
          final block = buffer.substring(0, boundary);
          buffer = buffer.substring(boundary + 2);
          for (final line in block.split('\n')) {
            if (!line.startsWith('data:')) continue;
            final data = line.substring(5).trim();
            if (data.isEmpty) continue;
            TextStreamEvent? event;
            try {
              event = decoder.add(data);
            } on TextProtocolException catch (error) {
              throw OmlxRequestException(
                OmlxRequestKind.invalidResponse,
                'oMLX 流无效：${error.message}',
              );
            }
            if (data == '[DONE]') {
              done = true;
            } else if (event != null) {
              yield event;
            }
          }
        }
      }
      if (op.cancelled) throw op.terminal!;
      if (!done) {
        throw const OmlxRequestException(
          OmlxRequestKind.invalidResponse,
          'oMLX 流缺少终止帧',
        );
      }
      yield TextStreamEvent.complete(decoder.finish());
    } on OmlxRequestException {
      rethrow;
    } catch (_) {
      if (op.cancelled) throw op.terminal!;
      throw const OmlxRequestException(
        OmlxRequestKind.serviceFailed,
        'oMLX 流连接失败',
      );
    } finally {
      op.abort = null;
      unlisten?.call();
      _release(run, op);
    }
  }

  @override
  Future<void> stop(String instanceId) {
    _OmlxRun? target;
    for (final run in _runs) {
      if (run.id == instanceId) target = run;
    }
    if (target == null) {
      return Future.error(
        const OmlxRequestException(OmlxRequestKind.notReady, '未知 oMLX 实例'),
      );
    }
    // Seal admission synchronously: late work is rejected immediately, before
    // the drain of already-admitted work completes.
    target.acceptingRequests = false;
    if (target.status == RuntimeInstanceStatus.ready) {
      target.status = RuntimeInstanceStatus.stopping;
    }
    return _poolSerial(() => _stopRun(target!));
  }

  Future<void> _stopRun(_OmlxRun run) async {
    if (run.status == RuntimeInstanceStatus.stopped) return;
    for (final op in run.inFlight.toList()) {
      op.cancel(
        const OmlxRequestException(OmlxRequestKind.cancelled, 'oMLX 实例已停止'),
      );
    }
    while (run.inFlight.isNotEmpty) {
      await Future.wait(run.inFlight.map((op) => op.done.future));
    }
    if (run.status == RuntimeInstanceStatus.failed && !run.hasLiveProcess) {
      run.status = RuntimeInstanceStatus.stopped;
      await _syncUseRegistration();
      return;
    }
    final pool = _pool;
    if (pool == null ||
        pool.dead ||
        !identical(pool, run.pool) ||
        pool.retired) {
      run.status = RuntimeInstanceStatus.stopped;
      run.hasLiveProcess = false;
      run.unloadPending = false;
      await _syncUseRegistration();
      return;
    }
    try {
      await _unload(pool, run.modelId);
      run.status = RuntimeInstanceStatus.stopped;
      run.hasLiveProcess = false;
      run.unloadPending = false;
      run.error = null;
    } on OmlxException catch (error) {
      run.status = RuntimeInstanceStatus.failed;
      run.hasLiveProcess = true;
      run.unloadPending = true;
      run.error = error.message;
      await _syncUseRegistration();
      rethrow;
    }
    await _syncUseRegistration();
  }

  Future<void> _recyclePool() async {
    final live = <_OmlxRun>[];
    for (final run in _runs) {
      if (run.status == RuntimeInstanceStatus.ready ||
          run.status == RuntimeInstanceStatus.starting) {
        run.acceptingRequests = false;
        run.status = RuntimeInstanceStatus.stopping;
      }
      if (run.status == RuntimeInstanceStatus.stopping ||
          (run.status == RuntimeInstanceStatus.failed && run.hasLiveProcess)) {
        live.add(run);
      }
    }
    for (final run in live) {
      for (final op in run.inFlight.toList()) {
        op.cancel(
          const OmlxRequestException(OmlxRequestKind.cancelled, 'oMLX 池正在回收'),
        );
      }
    }
    await _poolSerial(() => _recyclePoolNative(live));
  }

  Future<void> _recyclePoolNative(List<_OmlxRun> live) async {
    final pool = _pool;
    for (final run in live) {
      while (run.inFlight.isNotEmpty) {
        await Future.wait(run.inFlight.map((op) => op.done.future));
      }
    }
    if (pool == null) {
      for (final run in live) {
        run.status = RuntimeInstanceStatus.stopped;
        run.hasLiveProcess = false;
        run.unloadPending = false;
      }
      await _syncUseRegistration();
      return;
    }
    var failed = false;
    if (!pool.dead) {
      for (final run in live) {
        if (!identical(run.pool, pool)) continue;
        try {
          await _unload(pool, run.modelId);
        } catch (_) {
          failed = true;
          run.status = RuntimeInstanceStatus.failed;
          run.hasLiveProcess = true;
          run.unloadPending = true;
          run.error = 'oMLX 池回收未完成：模型仍可能驻留';
        }
      }
    }
    var exited = pool.dead;
    if (!pool.dead) {
      pool.child.kill(ProcessSignal.sigterm);
      exited = await _awaitExit(pool, _poolStopTimeout);
      if (!exited) {
        pool.child.kill(ProcessSignal.sigkill);
        exited = await _awaitExit(pool, _poolStopTimeout);
      }
    }
    if (!exited) failed = true;
    if (failed) {
      // Failed-live residue stays visible and retryable; the owned process
      // and its base are kept as evidence for the next stopManaged.
      for (final run in live) {
        run.status = RuntimeInstanceStatus.failed;
        run.hasLiveProcess = true;
        run.error = 'oMLX 池回收未完成，请重试';
      }
      await _syncUseRegistration();
      throw const OmlxException('oMLX 池回收未完成，请重试');
    }
    pool.retired = true;
    _pool = null;
    pool.client.close(force: true);
    await _retirePoolBase(pool);
    for (final run in live) {
      run.status = RuntimeInstanceStatus.stopped;
      run.hasLiveProcess = false;
      run.unloadPending = false;
    }
    await _syncUseRegistration();
  }

  Future<bool> _awaitExit(_OmlxPool pool, Duration timeout) async {
    try {
      await pool.child.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _retirePoolBase(_OmlxPool pool) async {
    try {
      final base = pool.base;
      if (await base.resolveSymbolicLinks() != base.path) return;
      final parent = await base.parent.resolveSymbolicLinks();
      if (parent != await installationDirectory.resolveSymbolicLinks()) {
        return;
      }
      await base.delete(recursive: true);
    } catch (_) {
      // An owned residual base is safe; the next spawn uses a fresh one.
    }
  }

  Future<void> _syncUseRegistration() async {
    final registry = _useRegistry;
    if (registry == null) return;
    final paths = <String>{};
    for (final run in _runs) {
      final inUse =
          run.status == RuntimeInstanceStatus.ready ||
          run.status == RuntimeInstanceStatus.stopping ||
          (run.status == RuntimeInstanceStatus.failed && run.hasLiveProcess);
      if (inUse) paths.addAll(run.filePaths);
    }
    await registry.update(this, paths);
  }

  void beginShutdown() {
    _closed = true;
    _epoch++;
  }

  @override
  Future<void> shutdown() async {
    beginShutdown();
    try {
      await _recyclePool();
    } finally {
      await _operations;
      await _retryResidualCleanup();
    }
  }

  @override
  Future<void> stopManaged() async {
    _held = true;
    _epoch++;
    try {
      await _recyclePool();
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

/// One enabled model instance inside the owned pool generation.
final class _OmlxRun {
  _OmlxRun({
    required this.id,
    required this.artifactId,
    required this.modelId,
    required this.directory,
    required this.filePaths,
    required this.pool,
  });

  final String id;
  final String artifactId;
  final String modelId;
  final String directory;
  final Set<String> filePaths;
  final _OmlxPool pool;
  final Set<_OmlxInFlight> inFlight = <_OmlxInFlight>{};
  RuntimeInstanceStatus status = RuntimeInstanceStatus.starting;
  bool acceptingRequests = false;
  bool hasLiveProcess = true;
  bool unloadPending = false;
  String? error;

  RuntimeInstance snapshot() => RuntimeInstance(
    id: id,
    artifactId: artifactId,
    status: status,
    generation: pool.generation,
    activeRequests: inFlight.length,
    acceptingRequests: acceptingRequests,
    hasLiveProcess: hasLiveProcess,
    capabilities: status == RuntimeInstanceStatus.ready
        ? const {RuntimeCapability.textGeneration}
        : const {},
    error: error,
  );
}

/// One owned front-end serve process plus its admin session. The
/// [redact] projection is applied before any service text reaches an
/// error message so credentials never leak.
final class _OmlxPool {
  _OmlxPool({
    required this.generation,
    required this.child,
    required this.base,
    required this.port,
    required this.apiKey,
    required this.signingSecret,
    required this.client,
  });

  final int generation;
  final OmlxPoolChild child;
  final Directory base;
  final int port;
  final String apiKey;
  final String signingSecret;
  final HttpClient client;
  String? cookie;
  bool dead = false;
  bool retired = false;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  String redact(String text) =>
      text.replaceAll(apiKey, '***').replaceAll(signingSecret, '***');
}

/// In-flight request handle: stop/recycle cancellation and admission
/// cancellation both flow through [cancel]; [abort] is wired to the live
/// HTTP request as soon as it exists.
final class _OmlxInFlight {
  void Function()? abort;
  OmlxRequestException? terminal;
  final Completer<void> done = Completer<void>();

  bool get cancelled => terminal != null;

  void cancel(OmlxRequestException reason) {
    if (terminal != null) return;
    terminal = reason;
    try {
      abort?.call();
    } catch (_) {
      // Aborting a closed request is harmless.
    }
  }
}
