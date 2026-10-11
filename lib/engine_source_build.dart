import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'llama_engine.dart';

enum EngineSourceBuildPhase {
  validating,
  cloning,
  checkout,
  configuring,
  building,
  inspecting,
  complete,
  failed,
  cancelled,
}

class EngineSourceBuildRequest {
  EngineSourceBuildRequest({
    required this.source,
    required this.name,
    this.ref,
    this.cmakePath,
    this.supportsSystemone = true,
  }) {
    if (name.trim().isEmpty ||
        source.trim().isEmpty ||
        source.startsWith('-') ||
        source.contains('\u0000')) {
      throw const FormatException('源码位置与引擎名称需要有效非空值');
    }
    final uri = Uri.tryParse(source);
    final githubHttps =
        uri?.scheme == 'https' &&
        uri?.host == 'github.com' &&
        uri!.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        RegExp(r'^/[^/]+/[^/]+/?$').hasMatch(uri.path);
    final githubSsh = RegExp(
      r'^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$',
    ).hasMatch(source);
    if (!source.startsWith('/') && !githubHttps && !githubSsh) {
      throw const FormatException('请输入本地 Git 仓库绝对路径或无凭据的 GitHub 地址');
    }
    if (ref != null &&
        (ref!.trim().isEmpty ||
            ref!.startsWith('-') ||
            ref!.contains('\u0000') ||
            ref!.contains('\n'))) {
      throw const FormatException('Git ref 不能为空、包含换行或以选项前缀开始');
    }
    if (cmakePath != null &&
        (cmakePath!.trim().isEmpty ||
            cmakePath!.startsWith('-') ||
            cmakePath!.contains('\u0000'))) {
      throw const FormatException('CMake 可执行路径无效');
    }
  }
  final String source;
  final String name;
  final String? ref;
  final String? cmakePath;
  final bool supportsSystemone;
}

class EngineSourceToolchain {
  EngineSourceToolchain(
    Map<String, String> executables,
    Map<String, String> versions,
    List<String> missing,
  ) : executables = Map.unmodifiable(executables),
      versions = Map.unmodifiable(versions),
      missing = List.unmodifiable(missing);
  final Map<String, String> executables;
  final Map<String, String> versions;
  final List<String> missing;
  bool get available => missing.isEmpty;
  Map<String, Object?> toJson() => {
    'executables': executables,
    'versions': versions,
    'missing': missing,
  };
}

class EngineSourceBuildProgress {
  const EngineSourceBuildProgress(this.phase, this.logText);
  final EngineSourceBuildPhase phase;
  final String logText;
}

class EngineSourceBuildResult {
  EngineSourceBuildResult({
    required this.executablePath,
    required this.buildDirectory,
    required this.checkoutDirectory,
    required this.commit,
    required this.logPath,
    required this.installation,
    required Map<String, Object?> provenance,
  }) : provenance = Map.unmodifiable(provenance);
  final String executablePath;
  final LinkedLlamaInstallation installation;
  final Directory buildDirectory;
  final Directory checkoutDirectory;
  final String commit;
  final String logPath;
  final Map<String, Object?> provenance;
}

class EngineSourceBuildCancelled implements Exception {
  const EngineSourceBuildCancelled();
  @override
  String toString() => '源码引擎构建已取消';
}

class EngineSourceBuildException implements Exception {
  const EngineSourceBuildException(this.message, {this.exitCode, this.logPath});
  final String message;
  final int? exitCode;
  final String? logPath;
  @override
  String toString() => '$message${logPath == null ? '' : '；日志：$logPath'}';
}

abstract interface class EngineSourceProcess {
  int get pid;
  Future<int> get exited;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  bool get groupAlive;
  bool killGroup(ProcessSignal signal);
}

abstract interface class EngineSourceProcessIO {
  Future<EngineSourceProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  });
}

/// A fixed, app-owned C launcher establishes the session before exec. The
/// command remains a normal Dart child, so exitCode is the real monitored code.
class NativeEngineSourceProcessIO implements EngineSourceProcessIO {
  NativeEngineSourceProcessIO({this.toolsDirectory});
  final Directory? toolsDirectory;
  Directory? _ownedTools;
  Process? _bootstrap;
  Future<void>? _bootstrapStopping;
  final _bootstrapChildren = <int>{};
  final _starting = <DecisionCancellation>{};
  final _done = <Completer<void>>{};
  Future<String>? _runner;
  String? _runnerSha;
  bool _closed = false;
  static const _readyLine = 'GMD_SOURCE_PROCESS_READY\n';
  static const _runnerCode = r"""
#include <unistd.h>
#include <stdio.h>
int main(int argc,char **argv) {
  if(argc<2) return 64;
  if(setsid()<0) { perror("setsid"); return 70; }
  static const char ready[]="GMD_SOURCE_PROCESS_READY\n";
  if(write(2,ready,sizeof(ready)-1)<0) return 74;
  execvp(argv[1],argv+1);
  perror("execvp"); return 127;
}
""";
  @override
  Future<EngineSourceProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) => startScoped(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    cancellation: DecisionCancellation(),
  );

  Future<EngineSourceProcess> startScoped(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required DecisionCancellation cancellation,
  }) async {
    if (!Platform.isMacOS) {
      throw const EngineSourceBuildException('源码构建仅支持 macOS arm64');
    }
    if (_closed || cancellation.isCancelled) {
      throw const EngineSourceBuildCancelled();
    }
    final done = Completer<void>();
    _done.add(done);
    _starting.add(cancellation);
    try {
      final runner = await (_runner ??= _compileRunner(cancellation));
      if (_closed || cancellation.isCancelled) {
        throw const EngineSourceBuildCancelled();
      }
      if ((await sha256.bind(File(runner).openRead()).first).toString() !=
          _runnerSha) {
        throw const EngineSourceBuildException('自有进程启动器内容发生改变');
      }
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('GIT_DIR')
        ..remove('GIT_WORK_TREE')
        ..remove('GIT_INDEX_FILE')
        ..remove('GIT_OBJECT_DIRECTORY')
        ..remove('GIT_ALTERNATE_OBJECT_DIRECTORIES')
        ..['GIT_TERMINAL_PROMPT'] = '0'
        ..['GCM_INTERACTIVE'] = 'never';
      final process = await Process.start(
        runner,
        [executable, ...arguments],
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: false,
      );
      final stderr = StreamController<List<int>>();
      final ready = Completer<void>();
      final pending = <int>[];
      final prefix = utf8.encode(_readyLine);
      final subscription = process.stderr.listen(
        (bytes) {
          if (ready.isCompleted) {
            stderr.add(bytes);
            return;
          }
          pending.addAll(bytes);
          if (pending.length < prefix.length) return;
          if (!List<int>.generate(
            prefix.length,
            (i) => i,
          ).every((i) => pending[i] == prefix[i])) {
            ready.completeError(
              EngineSourceBuildException(
                '自有启动器未建立进程组：${utf8.decode(pending, allowMalformed: true)}',
              ),
            );
            return;
          }
          ready.complete();
          if (pending.length > prefix.length) {
            stderr.add(pending.sublist(prefix.length));
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!ready.isCompleted) {
            ready.completeError(error, stack);
          } else {
            stderr.addError(error, stack);
          }
        },
        onDone: () {
          if (!ready.isCompleted) {
            ready.completeError(
              EngineSourceBuildException(
                '自有启动器在握手前退出：${utf8.decode(pending, allowMalformed: true)}',
              ),
            );
          }
          unawaited(stderr.close());
        },
      );
      void terminate() {
        if (_sourceGroupOf(process.pid) == process.pid) {
          Process.killPid(-process.pid, ProcessSignal.sigterm);
        } else {
          process.kill(ProcessSignal.sigterm);
        }
      }

      final unlink = cancellation.listen(terminate);
      try {
        await process.stdin.close();
        // A very short command may have exited already. Only consume the real
        // readiness bytes; never race its exit against delivery of those bytes.
        await ready.future.timeout(const Duration(seconds: 5));
        if (_closed || cancellation.isCancelled) {
          throw const EngineSourceBuildCancelled();
        }
        return _NativeSourceProcess(process, stderr.stream);
      } catch (error, stack) {
        terminate();
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          if (_sourceGroupOf(process.pid) == process.pid) {
            Process.killPid(-process.pid, ProcessSignal.sigkill);
          }
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 5));
        }
        await subscription.cancel();
        await process.stdout.drain<void>();
        unawaited(stderr.close());
        Error.throwWithStackTrace(error, stack);
      } finally {
        unlink();
      }
    } finally {
      _starting.remove(cancellation);
      _done.remove(done);
      done.complete();
    }
  }

  Future<String> _compileRunner(DecisionCancellation cancellation) async {
    try {
      final root =
          toolsDirectory ??
          Directory(await Directory.systemTemp.resolveSymbolicLinks());
      await _realRoot(root);
      final directory = await root.createTemp('.source-process-');
      _ownedTools = directory;
      final source = File('${directory.path}/session.c');
      await source.writeAsString(_runnerCode);
      final output = '${directory.path}/session';
      final compiler = await Process.start('/usr/bin/xcrun', [
        'clang',
        source.path,
        '-o',
        output,
      ]);
      _bootstrap = compiler;
      final stdout = compiler.stdout.transform(utf8.decoder).join();
      final stderr = compiler.stderr.transform(utf8.decoder).join();
      final unlink = cancellation.listen(
        () => compiler.kill(ProcessSignal.sigstop),
      );
      try {
        final result = await Future.any<Object>([
          compiler.exitCode,
          cancellation.whenCancelled.then(
            (_) => const EngineSourceBuildCancelled(),
          ),
        ]).timeout(const Duration(seconds: 60));
        if (cancellation.isCancelled || _closed) {
          throw const EngineSourceBuildCancelled();
        }
        final out = await stdout;
        final err = await stderr;
        if (result != 0) {
          throw EngineSourceBuildException(
            'Clang 无法准备自有进程启动器：$out $err',
            exitCode: result as int,
          );
        }
        _runnerSha = (await sha256.bind(File(output).openRead()).first)
            .toString();
        _bootstrap = null;
        return output;
      } catch (error, stack) {
        try {
          await _stopBootstrap(compiler);
          _bootstrap = null;
        } catch (cleanup) {
          Error.throwWithStackTrace(
            EngineSourceBuildException('$error；启动器编译收尾失败：$cleanup'),
            stack,
          );
        }
        await Future.wait([stdout, stderr]);
        rethrow;
      } finally {
        unlink();
      }
    } catch (_) {
      _runner = null;
      rethrow;
    }
  }

  Future<void> _stopBootstrap(Process process) {
    if (_bootstrapStopping != null) return _bootstrapStopping!;
    final operation = _stopBootstrapOwned(process);
    _bootstrapStopping = operation;
    unawaited(
      operation.then<void>(
        (_) {
          _bootstrapStopping = null;
        },
        onError: (Object _, StackTrace _) {
          _bootstrapStopping = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _stopBootstrapOwned(Process process) async {
    process.kill(ProcessSignal.sigstop);
    Future<void> collect(int parent) async {
      final found = await Process.run('/usr/bin/pgrep', ['-P', '$parent']);
      if (found.exitCode != 0 && found.exitCode != 1) {
        throw const EngineSourceBuildException('无法读取自有编译子进程');
      }
      for (final text in (found.stdout as String).split(RegExp(r'\s+'))) {
        final child = int.tryParse(text);
        if (child == null || child <= 0 || child == pid) continue;
        if (_bootstrapChildren.add(child)) {
          Process.killPid(child, ProcessSignal.sigstop);
          await collect(child);
        }
      }
    }

    await collect(process.pid);
    for (final child in _bootstrapChildren.toList().reversed) {
      Process.killPid(child, ProcessSignal.sigterm);
      Process.killPid(child, ProcessSignal.sigcont);
    }
    process.kill(ProcessSignal.sigterm);
    process.kill(ProcessSignal.sigcont);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      for (final child in _bootstrapChildren) {
        Process.killPid(child, ProcessSignal.sigkill);
      }
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
    }
    for (final child in _bootstrapChildren) {
      if (_sourceKill(child, 0) == 0) {
        Process.killPid(child, ProcessSignal.sigkill);
      }
    }
    final watch = Stopwatch()..start();
    while (_bootstrapChildren.any((child) => _sourceKill(child, 0) == 0) &&
        watch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (_bootstrapChildren.any((child) => _sourceKill(child, 0) == 0)) {
      throw const EngineSourceBuildException('启动器编译子进程尚未完全退出');
    }
    _bootstrapChildren.clear();
  }

  Future<void> close() async {
    _closed = true;
    for (final token in _starting.toList()) {
      token.cancel();
    }
    final bootstrap = _bootstrap;
    if (bootstrap != null) {
      await _stopBootstrap(bootstrap);
      _bootstrap = null;
    }
    await Future.wait(_done.map((done) => done.future).toList());
    final directory = _ownedTools;
    if (directory != null) {
      await directory.delete(recursive: true);
      _ownedTools = null;
    }
  }
}

class _NativeSourceProcess implements EngineSourceProcess {
  const _NativeSourceProcess(this.process, this.stderr);
  final Process process;
  @override
  int get pid => process.pid;
  @override
  Future<int> get exited => process.exitCode;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  bool get groupAlive {
    if (_sourceKill(-pid, 0) == 0) return true;
    return _sourceErrno() != 3;
  }

  @override
  bool killGroup(ProcessSignal signal) => Process.killPid(-pid, signal);
}

final _sourceKill = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
    );
final _sourceGroupOf = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32), int Function(int)>('getpgid');
int _sourceErrno() => DynamicLibrary.process()
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__error',
    )()
    .value;

class EngineSourceBuilder {
  EngineSourceBuilder(
    this.managedRoot, {
    this.cmakePath,
    EngineSourceProcessIO? io,
  }) : io = io ?? NativeEngineSourceProcessIO(),
       _ownsIO = io == null;
  final Directory managedRoot;
  final String? cmakePath;
  final EngineSourceProcessIO io;
  final bool _ownsIO;
  final _changes = StreamController<EngineSourceBuildProgress>.broadcast();
  Stream<EngineSourceBuildProgress> get changes => _changes.stream;
  final _tokens = <DecisionCancellation>{};
  final _operations = <Completer<void>>{};
  final _children = <EngineSourceProcess>{};
  DecisionCancellation? _building;
  bool _closed = false;
  Future<void>? _closing;
  String _log = '';
  File? _logFile;
  EngineSourceBuildPhase _phase = EngineSourceBuildPhase.validating;
  void Function(EngineSourceBuildProgress)? _progress;
  final _commands = <Map<String, Object?>>[];
  void cancelBuild() => _building?.cancel();

  Future<EngineSourceToolchain> preflight({
    String? cmakePath,
    DecisionCancellation? cancellation,
  }) async {
    if (_closed) throw StateError('源码构建器已关闭');
    final token = DecisionCancellation();
    final unlink = cancellation?.listen(token.cancel);
    final done = Completer<void>();
    _operations.add(done);
    _tokens.add(token);
    final executables = <String, String>{};
    final versions = <String, String>{};
    final missing = <String>[];
    try {
      if (!Platform.isMacOS) missing.add('仅支持 macOS arm64');
      try {
        if ((await _command(
              '/usr/bin/uname',
              ['-m'],
              token,
              timeout: const Duration(seconds: 15),
            )).trim() !=
            'arm64') {
          missing.add('宿主架构需要 arm64');
        }
      } on EngineSourceBuildCancelled {
        rethrow;
      } catch (error) {
        missing.add('宿主架构检查失败：$error');
      }
      Future<void> probe(
        String key,
        String executable,
        List<String> arguments,
      ) async {
        try {
          final version = await _command(
            executable,
            arguments,
            token,
            timeout: const Duration(seconds: 15),
          );
          if (version.trim().isEmpty) throw const FormatException('工具版本为空');
          executables[key] = executable;
          versions[key] = version.trim();
        } on EngineSourceBuildCancelled {
          rethrow;
        } catch (error) {
          missing.add('$key 不可用：$error');
        }
      }

      await probe('git', '/usr/bin/git', ['--version']);
      for (final compiler in ['clang', 'clang++']) {
        try {
          final path = (await _command(
            '/usr/bin/xcrun',
            ['--find', compiler],
            token,
            timeout: const Duration(seconds: 15),
          )).trim();
          if (!path.startsWith('/')) throw const FormatException('编译器需要绝对路径');
          await probe(compiler, path, ['--version']);
        } on EngineSourceBuildCancelled {
          rethrow;
        } catch (error) {
          missing.add('$compiler 不可用：$error');
        }
      }
      final requested = cmakePath ?? this.cmakePath;
      final cmake = _findCmake(requested);
      await probe('cmake', cmake, ['--version']);
      if (!executables.containsKey('cmake')) {
        missing.add('请指定已安装的 CMake 可执行路径；不会自动安装');
      }
      return EngineSourceToolchain(executables, versions, missing);
    } finally {
      unlink?.call();
      _tokens.remove(token);
      _operations.remove(done);
      done.complete();
    }
  }

  Future<EngineSourceBuildResult> build(
    EngineSourceBuildRequest request,
    DecisionCancellation cancellation, {
    void Function(EngineSourceBuildProgress)? onProgress,
  }) async {
    if (_closed) throw StateError('源码构建器已关闭');
    if (_building != null) throw StateError('已有源码构建正在执行');
    final token = DecisionCancellation();
    final unlink = cancellation.listen(token.cancel);
    final done = Completer<void>();
    _building = token;
    _tokens.add(token);
    _operations.add(done);
    _log = '';
    _commands.clear();
    _progress = onProgress;
    Directory? job;
    try {
      _check(token);
      _emit(EngineSourceBuildPhase.validating);
      final tools = await preflight(
        cmakePath: request.cmakePath,
        cancellation: token,
      );
      if (!tools.available) {
        throw EngineSourceBuildException(tools.missing.join('\n'));
      }
      await _realRoot(managedRoot);
      job = await managedRoot.createTemp('llama-source-');
      _logFile = File('${job.path}/build.log');
      await _logFile!.writeAsString(_log);
      final source = Directory('${job.path}/source');
      final build = Directory('${job.path}/build');
      _emit(EngineSourceBuildPhase.cloning);
      final objectCache = await _objectCache(
        request.source,
        tools.executables['git']!,
        token,
      );
      await _command(tools.executables['git']!, [
        'clone',
        '--no-hardlinks',
        '--progress',
        if (objectCache != null) ...[
          '--reference-if-able',
          objectCache,
          '--dissociate',
        ],
        '--',
        request.source,
        source.path,
      ], token);
      final alternates = File('${source.path}/.git/objects/info/alternates');
      if (await alternates.exists() &&
          (await alternates.readAsString()).trim().isNotEmpty) {
        throw const EngineSourceBuildException('新源码克隆仍依赖旧Git对象库');
      }
      _emit(EngineSourceBuildPhase.checkout);
      String commit;
      try {
        commit = (await _command(tools.executables['git']!, [
          '-C',
          source.path,
          'rev-parse',
          '--verify',
          '${request.ref ?? 'HEAD'}^{commit}',
        ], token)).trim();
      } on EngineSourceBuildException {
        final ref = request.ref;
        if (token.isCancelled ||
            ref == null ||
            ref.startsWith('origin/') ||
            ref.startsWith('refs/') ||
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$').hasMatch(ref)) {
          rethrow;
        }
        // Clone creates only its default local branch. An explicitly selected
        // ordinary branch may exist solely as refs/remotes/origin/<branch>.
        commit = (await _command(tools.executables['git']!, [
          '-C',
          source.path,
          'rev-parse',
          '--verify',
          'refs/remotes/origin/$ref^{commit}',
        ], token)).trim();
      }
      if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
        throw const EngineSourceBuildException('Git 未返回完整40位 commit');
      }
      await _command(tools.executables['git']!, [
        '-C',
        source.path,
        'checkout',
        '--detach',
        commit,
      ], token);
      await _command(tools.executables['git']!, [
        '-C',
        source.path,
        'submodule',
        'update',
        '--init',
        '--recursive',
      ], token);
      final configure = [
        '-S',
        source.path,
        '-B',
        build.path,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DLLAMA_BUILD_SERVER=ON',
        '-DGGML_METAL=ON',
        '-DCMAKE_C_COMPILER=${tools.executables['clang']}',
        '-DCMAKE_CXX_COMPILER=${tools.executables['clang++']}',
      ];
      _emit(EngineSourceBuildPhase.configuring);
      await _command(tools.executables['cmake']!, configure, token);
      _emit(EngineSourceBuildPhase.building);
      await _command(
        tools.executables['cmake']!,
        [
          '--build',
          build.path,
          '--config',
          'Release',
          '--target',
          'llama-server',
          '--parallel',
          '${min(8, Platform.numberOfProcessors)}',
        ],
        token,
        timeout: const Duration(hours: 1),
      );
      _check(token);
      _emit(EngineSourceBuildPhase.inspecting);
      final executable = File('${build.path}/bin/llama-server');
      if (await FileSystemEntity.type(executable.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const EngineSourceBuildException('构建未生成 build/bin/llama-server');
      }
      final installation = await inspectLinkedLlama(
        executable,
        _BuildInspectionIO(this, token),
      );
      final hash = (await sha256.bind(executable.openRead()).first).toString();
      final provenance = <String, Object?>{
        'source': request.source,
        'requested_ref': request.ref,
        'supports_systemone': request.supportsSystemone,
        'object_cache': objectCache,
        'commit': commit,
        'platform': 'macOS arm64',
        'name': request.name,
        'checkout': source.path,
        'build_directory': build.path,
        'executable': executable.path,
        'binary_sha256': hash,
        'binary_version': installation.version,
        'toolchain': tools.toJson(),
        'configure_arguments': configure,
        'commands': List<Map<String, Object?>>.of(_commands),
        'log_path': _logFile!.path,
      };
      await File('${job.path}/build-receipt.json')
          .writeAsString(jsonEncode(provenance), flush: true);
      _check(token);
      _emit(EngineSourceBuildPhase.complete);
      return EngineSourceBuildResult(
        executablePath: executable.path,
        buildDirectory: build,
        checkoutDirectory: source,
        commit: commit,
        logPath: _logFile!.path,
        installation: installation,
        provenance: provenance,
      );
    } catch (error, stack) {
      _emit(
        error is EngineSourceBuildCancelled
            ? EngineSourceBuildPhase.cancelled
            : EngineSourceBuildPhase.failed,
      );
      try {
        if (job != null) {
          await File('${job.path}/failure.json').writeAsString(
            jsonEncode({
              'error': error.toString(),
              'commands': _commands,
              'log_path': _logFile?.path,
            }),
            flush: true,
          );
        }
      } catch (recordError) {
        Error.throwWithStackTrace(
          EngineSourceBuildException(
            '$error；失败记录写入失败：$recordError',
            exitCode: error is EngineSourceBuildException
                ? error.exitCode
                : null,
            logPath: _logFile?.path,
          ),
          stack,
        );
      }
      rethrow;
    } finally {
      _logFile = null;
      _progress = null;
      unlink();
      _tokens.remove(token);
      _operations.remove(done);
      _building = null;
      done.complete();
    }
  }

  Future<String?> _objectCache(
    String origin,
    String git,
    DecisionCancellation token,
  ) async {
    String identity(String value) => value.startsWith('https://github.com/')
        ? value
              .replaceFirst(RegExp(r'/?$'), '')
              .replaceFirst(RegExp(r'\.git$'), '')
        : value;
    await for (final entry in managedRoot.list(followLinks: false)) {
      _check(token);
      if (entry is! Directory ||
          !entry.path.split('/').last.startsWith('llama-source-')) {
        continue;
      }
      final source = Directory('${entry.path}/source');
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(
                '${source.path}/.git',
                followLinks: false,
              ) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(
                '${source.path}/.git/objects',
                followLinks: false,
              ) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(
                '${source.path}/.git/HEAD',
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
        continue;
      }
      try {
        final remote = await _commandResult(
          git,
          ['-C', source.path, 'remote', 'get-url', 'origin'],
          token,
          logOutput: false,
        );
        if (remote.exitCode == 0 &&
            identity(remote.stdout.trim()) == identity(origin)) {
          return source.path;
        }
      } on EngineSourceBuildCancelled {
        rethrow;
      } on EngineSourceBuildException {
        continue;
      }
    }
    return null;
  }

  Future<String> _command(
    String executable,
    List<String> args,
    DecisionCancellation token, {
    Duration timeout = const Duration(minutes: 15),
  }) async {
    final result = await _commandResult(
      executable,
      args,
      token,
      timeout: timeout,
    );
    if (result.exitCode != 0) {
      throw EngineSourceBuildException(
        '命令失败 (${result.exitCode})：${result.stderr}${result.stdout}',
        exitCode: result.exitCode,
        logPath: _logFile?.path,
      );
    }
    return result.stdout;
  }

  Future<EngineCommandResult> _commandResult(
    String executable,
    List<String> args,
    DecisionCancellation token, {
    Duration timeout = const Duration(minutes: 15),
    bool logOutput = true,
  }) async {
    _check(token);
    final child = await io.start(
      executable,
      args,
      workingDirectory: Directory.current.path,
    );
    _children.add(child);
    final release = token.listen(() {
      try {
        child.killGroup(ProcessSignal.sigterm);
      } catch (_) {
        /* _stop preserves cleanup errors. */
      }
    });
    final out = StringBuffer();
    final err = StringBuffer();
    Future<void> read(Stream<List<int>> stream, StringBuffer buffer) async {
      await for (final text in stream.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        buffer.write(text);
        if (logOutput) {
          _log += text;
          _emit(_phase);
          await _logFile?.writeAsString(text, mode: FileMode.append);
        }
      }
    }

    final stdout = read(child.stdout, out);
    final stderr = read(child.stderr, err);
    try {
      final result = await Future.any<Object>([
        child.exited,
        token.whenCancelled.then((_) => const EngineSourceBuildCancelled()),
      ]).timeout(timeout);
      if (result is EngineSourceBuildCancelled) throw result;
      if (child.groupAlive) {
        throw const EngineSourceBuildException('构建命令退出后仍有自有子进程');
      }
      await Future.wait([stdout, stderr]);
      _commands.add({
        'executable': executable,
        'arguments': List.of(args),
        'pid': child.pid,
        'exit_code': result,
      });
      _check(token);
      return EngineCommandResult(result as int, out.toString(), err.toString());
    } catch (error) {
      try {
        await _stop(child);
      } catch (cleanup) {
        throw EngineSourceBuildException(
          '$error；构建进程收尾失败：$cleanup',
          logPath: _logFile?.path,
        );
      }
      await Future.wait([stdout, stderr]);
      rethrow;
    } finally {
      release();
      if (!child.groupAlive) _children.remove(child);
    }
  }

  Future<void> _stop(EngineSourceProcess child) async {
    if (child.groupAlive) child.killGroup(ProcessSignal.sigterm);
    try {
      await child.exited.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      child.killGroup(ProcessSignal.sigkill);
      await child.exited.timeout(const Duration(seconds: 5));
    }
    final watch = Stopwatch()..start();
    while (child.groupAlive && watch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (child.groupAlive) {
      child.killGroup(ProcessSignal.sigkill);
      final forced = Stopwatch()..start();
      while (child.groupAlive && forced.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      if (child.groupAlive) {
        throw const EngineSourceBuildException('自有构建进程组尚未完全退出');
      }
    }
  }

  void _check(DecisionCancellation token) {
    if (token.isCancelled || _closed) throw const EngineSourceBuildCancelled();
  }

  void _emit(EngineSourceBuildPhase phase) {
    _phase = phase;
    final event = EngineSourceBuildProgress(phase, _log);
    _progress?.call(event);
    if (!_changes.isClosed) _changes.add(event);
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    final operation = _close();
    _closing = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_closing, operation)) _closing = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _close() async {
    _closed = true;
    for (final token in _tokens.toList()) {
      token.cancel();
    }
    await Future.wait(_operations.map((done) => done.future).toList());
    for (final child in _children.toList()) {
      await _stop(child);
      if (!child.groupAlive) _children.remove(child);
    }
    if (_ownsIO) {
      await (io as NativeEngineSourceProcessIO).close();
    }
    await _changes.close();
  }
}

String _findCmake(String? requested) {
  if (requested != null && requested != 'cmake') return requested;
  final paths = [
    for (final folder in (Platform.environment['PATH'] ?? '').split(':'))
      if (folder.isNotEmpty) '$folder/cmake',
    '/opt/homebrew/bin/cmake',
    '/usr/local/bin/cmake',
    '/Applications/CMake.app/Contents/bin/cmake',
  ];
  for (final path in paths) {
    if (File(path).existsSync()) return path;
  }
  return 'cmake';
}

Future<void> _realRoot(Directory root) async {
  final parent = root.absolute.parent;
  if (parent.path != root.absolute.path) await _realRoot(parent);
  final type = await FileSystemEntity.type(root.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await root.create();
  } else if (type != FileSystemEntityType.directory) {
    throw const EngineSourceBuildException('受管源码目录不能是符号链接或外部文件');
  }
}

class _BuildInspectionIO implements EngineProcessIO {
  const _BuildInspectionIO(this.builder, this.cancellation);
  final EngineSourceBuilder builder;
  final DecisionCancellation cancellation;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) =>
      throw UnsupportedError('仅用于构建产物核验');
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) => builder._commandResult(
    executable,
    arguments,
    cancellation,
    timeout: timeout,
  );
}
