import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_labels.dart';
import 'package:ghost_model_deck/engine_source_build.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

void main() {
  for (final injected in [false, true]) {
    test(
      injected
          ? 'builder closes its work without closing caller-owned native process IO'
          : 'builder releases its default native process IO launcher on close',
      () async {
        final root = await _temp('gmd-source-io-owner-');
        addTearDown(() => root.delete(recursive: true));
        final retained = await File('${root.path}/retained.txt')
            .writeAsString('caller data');
        final external = injected ? NativeEngineSourceProcessIO() : null;
        if (external != null) {
          addTearDown(external.close);
        }
        final builder = EngineSourceBuilder(root, io: external);
        addTearDown(builder.close);
        await IOOverrides.runZoned(() async {
          final toolchain = await builder.preflight(
            cmakePath: '/Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/source-engine-tools/cmake-3.31.12-macos-universal/CMake.app/Contents/bin/cmake',
          );
          expect(toolchain.available, isTrue);
          final launchers = await root
              .list()
              .where(
                (entry) =>
                    entry is Directory &&
                    entry.path.contains('/.source-process-'),
              )
              .toList();
          expect(launchers, hasLength(1));
          await builder.close();
          expect(await launchers.single.exists(), injected);
          if (injected) {
            final process = await external!.start(
              '/usr/bin/true',
              [],
              workingDirectory: root.path,
            );
            await Future.wait([
              process.stdout.drain<void>(),
              process.stderr.drain<void>(),
            ]);
            expect(await process.exited, 0);
          }
          expect(await retained.readAsString(), 'caller data');
        }, getSystemTempDirectory: () => root);
      },
    );
  }
  test(
    'source input rejects option injection and credential-bearing addresses',
    () {
      for (final source in [
        '--upload-pack=bad',
        'https://token@github.com/a/b',
        'https://github.com/a/b?token=secret',
      ]) {
        expect(
          () => EngineSourceBuildRequest(source: source, name: 'engine'),
          throwsFormatException,
        );
      }
      expect(
        () => EngineSourceBuildRequest(
          source: '/tmp/repo',
          name: 'engine',
          ref: '--detach',
        ),
        throwsFormatException,
      );
      expect(
        EngineSourceBuildRequest(
          source: 'https://github.com/ggml-org/llama.cpp',
          name: 'engine',
        ).ref,
        isNull,
      );
    },
  );

  test(
    'missing tool preflight lists dependencies without cloning or installing',
    () async {
      final root = await _temp('gmd-source-missing-');
      addTearDown(() => root.delete(recursive: true));
      final io = _FixtureIO(missingCmake: true);
      final builder = EngineSourceBuilder(
        root,
        io: io,
        cmakePath: '/fixture/missing-cmake',
      );
      addTearDown(builder.close);
      final tools = await builder.preflight();
      expect(tools.available, isFalse);
      expect(tools.missing.join(' '), contains('CMake'));
      await expectLater(
        builder.build(
          EngineSourceBuildRequest(source: '/fixture/source', name: 'source'),
          DecisionCancellation(),
        ),
        throwsA(isA<EngineSourceBuildException>()),
      );
      expect(
        io.commands.where((command) => command.arguments.contains('clone')),
        isEmpty,
      );
    },
  );

  test('independent checkout records full commit and retains all build dependencies', () async {
    final root = await _temp('gmd-source-build-');
    addTearDown(() => root.delete(recursive: true));
    final io = _FixtureIO();
    final builder = EngineSourceBuilder(
      root,
      io: io,
      cmakePath: '/fixture/cmake',
    );
    addTearDown(builder.close);
    final result = await builder.build(
      EngineSourceBuildRequest(
        source: '/fixture/source',
        name: 'source',
        ref: 'main',
      ),
      DecisionCancellation(),
    );
    expect(result.commit, '0123456789abcdef0123456789abcdef01234567');
    expect(result.executablePath, endsWith('/build/bin/llama-server'));
    expect(
      await File('${result.buildDirectory.path}/bin/libllama.dylib')
          .readAsString(),
      'dependency',
    );
    expect(
      await File('${result.checkoutDirectory.path}/CMakeLists.txt').exists(),
      isTrue,
    );
    expect(result.provenance['requested_ref'], 'main');
    expect(result.provenance['source'], '/fixture/source');
    expect(
      io.commands.firstWhere((c) => c.arguments.contains('clone')).arguments,
      contains('--no-hardlinks'),
    );
    expect(
      io.commands.any(
        (c) =>
            c.arguments.contains('--detach') &&
            c.arguments.contains(result.commit),
      ),
      isTrue,
    );
    expect(await File(result.logPath).exists(), isTrue);
  });

  test(
    'stderr-only version and help remain available to real source inspection',
    () async {
      final root = await _temp('gmd-source-stderr-');
      addTearDown(() => root.delete(recursive: true));
      final builder = EngineSourceBuilder(
        root,
        io: _FixtureIO(stderrInspection: true),
        cmakePath: '/fixture/cmake',
      );
      addTearDown(builder.close);
      final result = await builder.build(
        EngineSourceBuildRequest(
          source: '/fixture/source',
          name: 'stderr fork',
        ),
        DecisionCancellation(),
      );
      expect(result.installation.version, contains('version: 0.7.0-dev'));
      expect(result.installation.version, contains('Darwin arm64'));
      expect(result.installation.helpOutput, contains('--model'));
      expect(result.installation.helpOutput, contains('--device'));
      final inspected = (result.provenance['commands'] as List).where(
        (row) => (row as Map)['executable'] == result.executablePath,
      );
      expect(
        inspected.map((row) => (row as Map)['exit_code']),
        everyElement(0),
      );
      expect(
        await File(result.logPath).readAsString(),
        contains('Darwin arm64'),
      );
    },
  );

  test(
    'failed compile remains a failed build with original exit and log',
    () async {
      final root = await _temp('gmd-source-failed-');
      addTearDown(() => root.delete(recursive: true));
      final builder = EngineSourceBuilder(
        root,
        io: _FixtureIO(failBuild: true),
        cmakePath: '/fixture/cmake',
      );
      addTearDown(builder.close);
      await expectLater(
        builder.build(
          EngineSourceBuildRequest(source: '/fixture/source', name: 'source'),
          DecisionCancellation(),
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is EngineSourceBuildException &&
                e.exitCode == 7 &&
                e.toString().contains('compile failed'),
          ),
        ),
      );
      expect(await root.list().where((e) => e is Directory).length, 1);
    },
  );

  test(
    'failed diagnostic persistence preserves original compile failure',
    () async {
      final root = await _temp('gmd-source-record-');
      addTearDown(() => root.delete(recursive: true));
      final builder = EngineSourceBuilder(
        root,
        io: _FixtureIO(failBuild: true, failRecord: true),
        cmakePath: '/fixture/cmake',
      );
      addTearDown(builder.close);
      await expectLater(
        builder.build(
          EngineSourceBuildRequest(source: '/fixture/source', name: 'source'),
          DecisionCancellation(),
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is EngineSourceBuildException &&
                e.exitCode == 7 &&
                e.toString().contains('compile failed') &&
                e.toString().contains('失败记录写入失败'),
          ),
        ),
      );
    },
  );

  test('catalog registers only verified source builds and restores their provenance', () async {
    final root = await _temp('gmd-source-catalog-');
    addTearDown(() => root.delete(recursive: true));
    final library = ModelLibrary();
    addTearDown(library.close);
    final processes = _FixtureIO();
    final inspect = _CatalogInspectIO(processes);
    final registry = File('${root.path}/registry.json');
    EngineCatalog catalog(EngineSourceBuilder? builder) => EngineCatalog(
      library: library,
      officialEngine: LlamaEngine(
        library: library,
        installationDirectory: Directory('${root.path}/legacy'),
        io: inspect,
      ),
      useRegistry: ModelUseRegistry(library),
      registryFile: registry,
      io: inspect,
      sourceBuilder: builder,
    );
    final owner = catalog(
      EngineSourceBuilder(
        Directory('${root.path}/sources'),
        io: processes,
        cmakePath: '/fixture/cmake',
      ),
    );
    addTearDown(owner.close);
    final entry = await owner.buildFromSource(
      EngineSourceBuildRequest(
        source: '/fixture/source',
        name: 'dynamic fork',
        ref: 'main',
        supportsSystemone: false,
      ),
    );
    expect(entry.name, 'dynamic fork');
    expect(entry.status, LlamaInstallationStatus.installed);
    expect(engineDisplayName(entry), 'dynamic fork');
    expect(engineSourceLabel(entry), 'Git 源码构建');
    expect(
      entry.sourceBuild!['commit'],
      '0123456789abcdef0123456789abcdef01234567',
    );
    expect(owner.runtimes, contains(owner.runtimeFor(entry.id)));
    expect(entry.sourceBuild!['supports_systemone'], isFalse);
    expect(owner.providerFor(entry.id).declaresSystemone, isFalse);
    final reopened = catalog(null);
    addTearDown(reopened.close);
    await reopened.refresh();
    final restored = reopened.state.entries.singleWhere(
      (e) => e.id == entry.id,
    );
    expect(restored.sourceBuild, entry.sourceBuild);
    expect(reopened.providerFor(restored.id).declaresSystemone, isFalse);
    expect(
      (reopened.runtimeFor(restored.id) as LlamaEngine).sourceBuild,
      entry.sourceBuild,
    );
    expect(restored.path, entry.path);
    await owner.shutdown();
    await reopened.shutdown();
  });

  test(
    'cancel during registry persistence rolls back only the new registration',
    () async {
      final root = await _temp('gmd-source-persist-cancel-');
      addTearDown(() => root.delete(recursive: true));
      final library = ModelLibrary();
      addTearDown(library.close);
      final processes = _FixtureIO();
      final inspect = _CatalogInspectIO(processes);
      final token = DecisionCancellation();
      var armed = false;
      final actual = File('${root.path}/registry.json');
      final registry = _RegistryFile(actual, () {
        if (armed) token.cancel();
      });
      final owner = EngineCatalog(
        library: library,
        officialEngine: LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/legacy'),
          io: inspect,
        ),
        useRegistry: ModelUseRegistry(library),
        registryFile: registry,
        io: inspect,
        sourceBuilder: EngineSourceBuilder(
          Directory('${root.path}/sources'),
          io: processes,
          cmakePath: '/fixture/cmake',
        ),
      );
      addTearDown(owner.close);
      final kept = await owner.buildFromSource(
        EngineSourceBuildRequest(source: '/fixture/source', name: 'keep'),
      );
      armed = true;
      await expectLater(
        owner.buildFromSource(
          EngineSourceBuildRequest(
            source: '/fixture/source',
            name: 'cancelled',
          ),
          cancellation: token,
        ),
        throwsA(isA<EngineSourceBuildCancelled>()),
      );
      expect(
        owner.state.entries
            .where((e) => e.sourceBuild != null)
            .map((e) => e.id),
        [kept.id],
      );
      final rows =
          (jsonDecode(await actual.readAsString()) as Map)['linked'] as List;
      expect(rows.map((row) => (row as Map)['id']), [kept.id]);
      await owner.shutdown();
    },
  );

  test(
    'failed source compilation never adds a selectable catalog registration',
    () async {
      final root = await _temp('gmd-source-catalog-fail-');
      addTearDown(() => root.delete(recursive: true));
      final library = ModelLibrary();
      addTearDown(library.close);
      final processes = _FixtureIO(failBuild: true);
      final inspect = _CatalogInspectIO(processes);
      final registry = File('${root.path}/registry.json');
      final owner = EngineCatalog(
        library: library,
        officialEngine: LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/legacy'),
          io: inspect,
        ),
        useRegistry: ModelUseRegistry(library),
        registryFile: registry,
        io: inspect,
        sourceBuilder: EngineSourceBuilder(
          Directory('${root.path}/sources'),
          io: processes,
          cmakePath: '/fixture/cmake',
        ),
      );
      addTearDown(owner.close);
      final before = owner.state.entries.map((e) => e.id).toList();
      await expectLater(
        owner.buildFromSource(
          EngineSourceBuildRequest(source: '/fixture/source', name: 'failed'),
        ),
        throwsA(isA<EngineSourceBuildException>()),
      );
      expect(owner.state.entries.map((e) => e.id), before);
      expect(await registry.exists(), isFalse);
      await owner.shutdown();
    },
  );

  test('nondefault branch resolves origin tracking ref without modifying local repository', () async {
    final root = await _temp('gmd-source-branch-');
    addTearDown(() => root.delete(recursive: true));
    final source = await Directory('${root.path}/original').create();
    Future<String> git(List<String> args) async {
      final result = await Process.run('/usr/bin/git', [
        '-C',
        source.path,
        ...args,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }

    await git(['init', '-b', 'main']);
    await File('${source.path}/CMakeLists.txt')
        .writeAsString('committed fixture');
    await git(['add', 'CMakeLists.txt']);
    await git([
      '-c',
      'user.name=source-fixture',
      '-c',
      'user.email=fixture@invalid.test',
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '-m',
      'main',
    ]);
    await git(['checkout', '-b', 'dev']);
    await File('${source.path}/dev.txt').writeAsString('dev commit');
    await git(['add', 'dev.txt']);
    await git([
      '-c',
      'user.name=source-fixture',
      '-c',
      'user.email=fixture@invalid.test',
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '-m',
      'dev',
    ]);
    final dev = await git(['rev-parse', 'HEAD']);
    await git(['checkout', 'main']);
    await File('${source.path}/uncommitted.txt').writeAsString('keep');
    final before = await git(['status', '--porcelain']);
    final native = NativeEngineSourceProcessIO(toolsDirectory: root);
    addTearDown(native.close);
    final builder = EngineSourceBuilder(
      Directory('${root.path}/managed'),
      cmakePath: '/fixture/cmake',
      io: _RealGitIO(native, _FixtureIO()),
    );
    addTearDown(builder.close);
    final result = await builder.build(
      EngineSourceBuildRequest(
        source: source.path,
        name: 'dev fork',
        ref: 'dev',
      ),
      DecisionCancellation(),
    );
    expect(result.commit, dev);
    expect(
      await File('${result.checkoutDirectory.path}/dev.txt').readAsString(),
      'dev commit',
    );
    expect(
      await File('${result.checkoutDirectory.path}/uncommitted.txt').exists(),
      isFalse,
    );
    expect(await git(['branch', '--show-current']), 'main');
    expect(await git(['status', '--porcelain']), before);
    final oldConfig = await File('${result.checkoutDirectory.path}/.git/config')
        .readAsString();
    final next = await builder.build(
      EngineSourceBuildRequest(source: source.path, name: 'next HEAD'),
      DecisionCancellation(),
    );
    expect(next.provenance['object_cache'], result.checkoutDirectory.path);
    expect(next.checkoutDirectory.path, isNot(result.checkoutDirectory.path));
    expect(
      await File('${next.checkoutDirectory.path}/.git/objects/info/alternates')
          .exists(),
      isFalse,
    );
    expect(
      await File('${result.checkoutDirectory.path}/.git/config').readAsString(),
      oldConfig,
    );
    expect(await git(['status', '--porcelain']), before);
  });

  test('native process returns actual exit7 and cancellation kills owned descendants only', () async {
    final root = await _temp('gmd-source-native-');
    addTearDown(() => root.delete(recursive: true));
    final code = File('${root.path}/process.c');
    await code.writeAsString(r"""
#include <unistd.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char **argv) {
  if(argc>1 && !strcmp(argv[1],"exit7")) return 7;
  pid_t child=fork();
  if(child==0) { sleep(60); return 0; }
  printf("%d\n", child); fflush(stdout);
  sleep(60); return 0;
}
""");
    final binary = '${root.path}/process';
    final compile = await Process.run('/usr/bin/xcrun', [
      'clang',
      code.path,
      '-o',
      binary,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}');
    final io = NativeEngineSourceProcessIO();
    final exited = await io.start(binary, [
      'exit7',
    ], workingDirectory: root.path);
    final stderr = exited.stderr.drain<void>();
    final stdout = exited.stdout.drain<void>();
    expect(await exited.exited, 7);
    await Future.wait([stderr, stdout]);
    expect(exited.groupAlive, isFalse);
    final peer = await Process.start('/bin/sleep', ['60']);
    final held = await io.start(binary, [], workingDirectory: root.path);
    final first = await held.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .first;
    final descendant = int.parse(first.trim());
    final errors = held.stderr.drain<void>();
    try {
      expect(held.killGroup(ProcessSignal.sigterm), isTrue);
      await held.exited.timeout(const Duration(seconds: 5));
      await errors;
      final watch = Stopwatch()..start();
      while (held.groupAlive && watch.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(held.groupAlive, isFalse);
      expect(Process.killPid(descendant, ProcessSignal.sigcont), isFalse);
      expect(peer.kill(ProcessSignal.sigcont), isTrue);
    } finally {
      if (held.groupAlive) held.killGroup(ProcessSignal.sigkill);
      peer.kill(ProcessSignal.sigterm);
      await peer.exitCode;
    }
  });

  test('cancel and close terminate only owned build process groups', () async {
    final root = await _temp('gmd-source-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final io = _FixtureIO(holdBuild: true);
    final builder = EngineSourceBuilder(
      root,
      io: io,
      cmakePath: '/fixture/cmake',
    );
    final cancellation = DecisionCancellation();
    final pending = builder.build(
      EngineSourceBuildRequest(source: '/fixture/source', name: 'source'),
      cancellation,
    );
    final cancelled = expectLater(
      pending,
      throwsA(isA<EngineSourceBuildCancelled>()),
    );
    await io.buildStarted.future;
    await builder.close();
    await cancelled;
    expect(io.held!.killed, isTrue);
    expect(io.held!.groupAlive, isFalse);
  });
}

class _Command {
  const _Command(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

class _FixtureIO implements EngineSourceProcessIO {
  _FixtureIO({
    this.missingCmake = false,
    this.failBuild = false,
    this.holdBuild = false,
    this.failRecord = false,
    this.stderrInspection = false,
  });
  final bool missingCmake;
  final bool failBuild;
  final bool holdBuild;
  final bool failRecord;
  final bool stderrInspection;
  final commands = <_Command>[];
  final buildStarted = Completer<void>();
  _Child? held;
  @override
  Future<EngineSourceProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    commands.add(_Command(executable, List.of(arguments)));
    if (executable == '/fixture/missing-cmake') {
      throw const ProcessException('cmake', [], 'not installed');
    }
    var output = '';
    var exit = 0;
    if (executable == '/usr/bin/uname') {
      output = 'arm64\n';
    } else if (executable == '/usr/bin/xcrun') {
      output = '/fixture/${arguments.last}\n';
    } else if (executable == '/usr/bin/file') {
      output = 'Mach-O 64-bit executable arm64\n';
    } else if (arguments.contains('--help')) {
      output = '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device\n';
    } else if (arguments.contains('--version')) {
      output =
          '${executable.contains('cmake')
              ? 'cmake version 3.31.12'
              : executable.endsWith('llama-server')
              ? 'version: 0.7.0-dev (build 12345, commit 012345678) built for Darwin arm64'
              : 'version: fixture'}\n';
    } else if (arguments.contains('clone')) {
      final checkout = Directory(arguments.last);
      await checkout.create(recursive: true);
      await File('${checkout.path}/CMakeLists.txt').writeAsString('fixture');
    } else if (arguments.contains('rev-parse')) {
      output = '0123456789abcdef0123456789abcdef01234567\n';
    } else if (arguments.contains('--build')) {
      if (holdBuild) {
        held = _Child('', null);
        buildStarted.complete();
        return held!;
      }
      if (failBuild) {
        exit = 7;
        output = 'compile failed\n';
        if (failRecord) {
          await Directory(
            '${Directory(arguments[arguments.indexOf('--build') + 1]).parent.path}/failure.json',
          ).create();
        }
      } else {
        final bin = await Directory(
          '${arguments[arguments.indexOf('--build') + 1]}/bin',
        ).create(recursive: true);
        final server = await File('${bin.path}/llama-server')
            .writeAsString('server');
        await Process.run('/bin/chmod', ['755', server.path]);
        await File('${bin.path}/libllama.dylib').writeAsString('dependency');
      }
    }
    if (stderrInspection &&
        executable.endsWith('llama-server') &&
        (arguments.contains('--version') || arguments.contains('--help'))) {
      return _Child('', exit, errorOutput: output);
    }
    return _Child(output, exit);
  }
}

class _Child implements EngineSourceProcess {
  _Child(String output, int? code, {String errorOutput = ''})
    : stdout = Stream.value(output.codeUnits),
      stderr = Stream.value(errorOutput.codeUnits) {
    if (code != null) ended.complete(code);
  }
  final ended = Completer<int>();
  bool killed = false;
  @override
  int get pid => 100001;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  Future<int> get exited => ended.future;
  @override
  bool get groupAlive => !ended.isCompleted;
  @override
  bool killGroup(ProcessSignal signal) {
    killed = true;
    if (!ended.isCompleted) ended.complete(143);
    return true;
  }
}

Future<Directory> _temp(String prefix) async {
  final root = await Directory.systemTemp.createTemp(prefix);
  return Directory(await root.resolveSymbolicLinks());
}

class _CatalogInspectIO implements EngineProcessIO {
  const _CatalogInspectIO(this.processes);
  final _FixtureIO processes;
  @override
  Future<EngineChild> start(String executable, List<String> args) =>
      throw UnsupportedError('no model launch');
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> args, {
    required Duration timeout,
  }) async {
    final process = await processes.start(
      executable,
      args,
      workingDirectory: Directory.current.path,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    return EngineCommandResult(
      await process.exited,
      await stdout,
      await stderr,
    );
  }
}

// Inject a real filesystem operation boundary, not catalog/business state.
class _RegistryFile implements File {
  const _RegistryFile(this.file, this.onParentCreated);
  final File file;
  final void Function() onParentCreated;
  @override
  String get path => file.path;
  @override
  Directory get parent => _RegistryDirectory(file.parent, onParentCreated);
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      file.readAsString(encoding: encoding);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RegistryDirectory implements Directory {
  const _RegistryDirectory(this.directory, this.afterCreate);
  final Directory directory;
  final void Function() afterCreate;
  @override
  Future<Directory> create({bool recursive = false}) async {
    final result = await directory.create(recursive: recursive);
    afterCreate();
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RealGitIO implements EngineSourceProcessIO {
  const _RealGitIO(this.native, this.fixture);
  final NativeEngineSourceProcessIO native;
  final _FixtureIO fixture;
  @override
  Future<EngineSourceProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) => executable == '/usr/bin/git'
      ? native.start(executable, arguments, workingDirectory: workingDirectory)
      : fixture.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
}
