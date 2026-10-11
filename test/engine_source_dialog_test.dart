import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_source_build.dart';
import 'package:ghost_model_deck/engine_source_dialog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/council_runtime.dart';

void main() {
  testWidgets('Git source build entry is visible beside install and link', (
    tester,
  ) async {
    late Directory root;
    late ModelLibrary library;
    late LlamaEngine engine;
    late EngineCatalog catalog;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('gmd-source-entry-');
      library = ModelLibrary();
      engine = LlamaEngine(
        library: library,
        installationDirectory: Directory('${root.path}/engine'),
      );
      catalog = EngineCatalog(
        library: library,
        officialEngine: engine,
        useRegistry: ModelUseRegistry(library),
        registryFile: File('${root.path}/registry.json'),
      );
    });
    addTearDown(
      () => tester.runAsync(() async {
        await catalog.shutdown();
        catalog.close();
        engine.close();
        library.close();
        await root.delete(recursive: true);
      }),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EnginePage(
              catalog: catalog,
              pickEngineDirectory: () async => null,
            ),
          ),
        ),
      );
      await catalog.refresh();
    });
    await tester.pumpAndSettle();
    expect(find.text('从 Git 构建'), findsOneWidget);
    expect(find.text('关联引擎'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
    expect(find.text('运行'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source dialog validates inputs and reports all missing tools before cloning',
    (tester) async {
      final fixture = await _dialogFixture(tester, missingCmake: true);
      await _open(tester, fixture.catalog);
      await tester.tap(find.byKey(const Key('engine-source-build')));
      await tester.pumpAndSettle();
      expect(find.text('请输入引擎名称'), findsOneWidget);
      expect(find.text('请输入仓库路径或地址'), findsOneWidget);
      expect(fixture.io.commands, isEmpty);
      await _set(tester, 'engine-source-cmake', '/fixture/missing-cmake');
      await tester.runAsync(() async {
        await tester.ensureVisible(
          find.byKey(const Key('engine-source-check-tools')),
        );
        await tester.tap(find.byKey(const Key('engine-source-check-tools')));
        await _until(
          () => find
              .byKey(const Key('engine-source-tools-status'))
              .evaluate()
              .isNotEmpty,
          tester,
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('缺少编译工具'), findsOneWidget);
      expect(find.textContaining('cmake 不可用'), findsOneWidget);
      expect(find.textContaining('请指定已安装的 CMake'), findsOneWidget);
      expect(
        fixture.io.commands.where((args) => args.contains('clone')),
        isEmpty,
      );
      expect(
        fixture.runtime.engine.state.instances.single.hasLiveProcess,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful source build registers the requested engine without restarting a live model',
    (tester) async {
      final fixture = await _dialogFixture(tester);
      final before = fixture.runtime.engine.state.instances.single;
      await _open(tester, fixture.catalog);
      await _fill(tester, source: 'https://github.com/ggml-org/llama.cpp');
      await tester.ensureVisible(
        find.byKey(const Key('engine-source-systemone')),
      );
      await tester.tap(find.byKey(const Key('engine-source-systemone')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('engine-source-build')));
        await _until(
          () => find
              .byKey(const Key('engine-source-success'))
              .evaluate()
              .isNotEmpty,
          tester,
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('已登记引擎：本地源码'), findsOneWidget);
      final entry = fixture.catalog.state.entries.singleWhere(
        (entry) => entry.name == '本地源码',
      );
      expect(entry.sourceBuild!['supports_systemone'], isFalse);
      expect(entry.status, LlamaInstallationStatus.installed);
      expect(fixture.catalog.providerFor(entry.id).executablePath, entry.path);
      expect(
        fixture.io.commands.firstWhere((args) => args.contains('clone')),
        contains('https://github.com/ggml-org/llama.cpp'),
      );
      expect(
        fixture.io.commands.any((args) => args.contains('dev^{commit}')),
        isTrue,
      );
      expect(fixture.io.executables, contains('/fixture/custom-cmake'));
      final after = fixture.runtime.engine.state.instances.single;
      expect(after.id, before.id);
      expect(after.generation, before.generation);
      expect(after.status, LlamaInstanceStatus.ready);
      expect(after.hasLiveProcess, isTrue);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EnginePage(
                catalog: fixture.catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await fixture.catalog.refresh();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('引擎详情').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('来源地址 https://github.com/ggml-org/llama.cpp'),
        findsOneWidget,
      );
      expect(find.textContaining('请求版本 dev'), findsOneWidget);
      expect(
        find.textContaining('实际提交 0123456789abcdef0123456789abcdef01234567'),
        findsOneWidget,
      );
      expect(find.textContaining('构建日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel tool preflight closes its owned process and never presents late success',
    (tester) async {
      final fixture = await _dialogFixture(tester, holdPreflight: true);
      await _open(tester, fixture.catalog);
      await _set(tester, 'engine-source-cmake', '/fixture/custom-cmake');
      await tester.runAsync(() async {
        await tester.ensureVisible(
          find.byKey(const Key('engine-source-check-tools')),
        );
        await tester.tap(find.byKey(const Key('engine-source-check-tools')));
        await fixture.io.started.future.timeout(const Duration(seconds: 3));
        await tester.pump();
      });
      await tester.pump();
      expect(find.text('取消检查'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('engine-source-cancel')));
        await _until(
          () => find
              .byKey(const Key('engine-source-error'))
              .evaluate()
              .isNotEmpty,
          tester,
        );
      });
      await tester.pumpAndSettle();
      expect(fixture.io.held!.groupAlive, isFalse);
      expect(find.byKey(const Key('engine-source-tools-status')), findsNothing);
      expect(find.text('编译工具检查通过'), findsNothing);
      expect(
        fixture.io.commands.where((args) => args.contains('clone')),
        isEmpty,
      );
      expect(
        fixture.runtime.engine.state.instances.single.hasLiveProcess,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled build waits for owned compiler cleanup and retains the live model',
    (tester) async {
      final fixture = await _dialogFixture(tester, holdBuild: true);
      final before = fixture.runtime.engine.state.instances.single;
      await _open(tester, fixture.catalog);
      await _fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('engine-source-build')));
        await fixture.io.started.future.timeout(const Duration(seconds: 3));
        await tester.pump();
      });
      await tester.pump();
      expect(find.text('编译引擎'), findsOneWidget);
      expect(find.text('取消构建'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('engine-source-cancel')));
        await _until(
          () => find
              .byKey(const Key('engine-source-error'))
              .evaluate()
              .isNotEmpty,
          tester,
        );
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('源码引擎构建已取消'), findsOneWidget);
      expect(fixture.io.held!.groupAlive, isFalse);
      expect(
        fixture.catalog.state.entries.any((entry) => entry.name == '本地源码'),
        isFalse,
      );
      expect(fixture.runtime.engine.state.instances.single.id, before.id);
      expect(
        fixture.runtime.engine.state.instances.single.hasLiveProcess,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed compile presents original error and logs without registering or stopping a model',
    (tester) async {
      final fixture = await _dialogFixture(tester, failBuild: true);
      await _open(tester, fixture.catalog);
      await _fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('engine-source-build')));
        await _until(
          () => find
              .byKey(const Key('engine-source-error'))
              .evaluate()
              .isNotEmpty,
          tester,
        );
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('compile failed'), findsOneWidget);
      expect(
        fixture.catalog.state.entries.any((entry) => entry.name == '本地源码'),
        isFalse,
      );
      expect(
        fixture.runtime.engine.state.instances.single.hasLiveProcess,
        isTrue,
      );
      expect(find.byKey(const Key('engine-source-log')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _set(WidgetTester tester, String key, String value) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(Key(key)), value);
}

Future<void> _fill(
  WidgetTester tester, {
  String source = '/fixture/source',
}) async {
  await _set(tester, 'engine-source-name', '本地源码');
  await _set(tester, 'engine-source-address', source);
  await _set(tester, 'engine-source-ref', 'dev');
  await _set(tester, 'engine-source-cmake', '/fixture/custom-cmake');
}

Future<void> _open(WidgetTester tester, EngineCatalog catalog) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => EngineSourceDialog(catalog: catalog),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _until(bool Function() ready, WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('source dialog did not reach expected business state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

Future<({CouncilRuntime runtime, EngineCatalog catalog, _BuildIO io})>
_dialogFixture(
  WidgetTester tester, {
  bool missingCmake = false,
  bool failBuild = false,
  bool holdBuild = false,
  bool holdPreflight = false,
}) async {
  late CouncilRuntime runtime;
  late EngineCatalog catalog;
  late _BuildIO io;
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      runtime = await CouncilRuntime.create(modelCount: 1);
      io = _BuildIO(
        missingCmake: missingCmake,
        failBuild: failBuild,
        holdBuild: holdBuild,
        holdPreflight: holdPreflight,
      );
      final builder = EngineSourceBuilder(
        Directory('${runtime.root.path}/source-builds'),
        io: io,
      );
      catalog = EngineCatalog(
        library: runtime.library,
        officialEngine: runtime.engine,
        useRegistry: runtime.engine.useRegistry,
        registryFile: File('${runtime.root.path}/source-engines.json'),
        sourceBuilder: builder,
        io: _InspectIO(),
      );
    }, _SourceNetwork()),
  );
  addTearDown(
    () => tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await catalog.shutdown();
      catalog.close();
      await runtime.close();
    }),
  );
  return (runtime: runtime, catalog: catalog, io: io);
}

/// Restore only the fixture loopback HTTP boundary, instead of Flutter's
/// default test override that returns 400 before contacting the engine.
class _SourceNetwork extends HttpOverrides {}

class _BuildIO implements EngineSourceProcessIO {
  _BuildIO({
    this.missingCmake = false,
    this.failBuild = false,
    this.holdBuild = false,
    this.holdPreflight = false,
  });
  final bool missingCmake, failBuild, holdBuild, holdPreflight;
  final commands = <List<String>>[];
  final executables = <String>[];
  final started = Completer<void>();
  _BuildChild? held;
  @override
  Future<EngineSourceProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    commands.add(List.of(arguments));
    executables.add(executable);
    if (missingCmake && executable.contains('cmake')) {
      throw const ProcessException('cmake', [], 'not installed');
    }
    if (holdPreflight &&
        executable.contains('cmake') &&
        arguments.contains('--version')) {
      held = _BuildChild('cmake version 3.31.12\n', null);
      started.complete();
      return held!;
    }
    var output = '', code = 0;
    if (executable == '/usr/bin/uname') {
      output = 'arm64\n';
    } else if (executable == '/usr/bin/xcrun') {
      output = '/fixture/${arguments.last}\n';
    } else if (executable == '/usr/bin/file') {
      output = 'Mach-O 64-bit executable arm64\n';
    } else if (arguments.contains('--version')) {
      output = executable.endsWith('/llama-server')
          ? 'version: 0.6.0-dev (build 11457, commit 0123456789)\nbuilt for Darwin arm64\n'
          : '${executable.contains('cmake') ? 'cmake version 3.31.12' : 'fixture version'}\n';
    } else if (arguments.contains('--help')) {
      output = '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device\n';
    } else if (arguments.contains('clone')) {
      final checkout = await Directory(arguments.last).create(recursive: true);
      await File('${checkout.path}/CMakeLists.txt').writeAsString('fixture');
    } else if (arguments.contains('rev-parse')) {
      output = '0123456789abcdef0123456789abcdef01234567\n';
    } else if (arguments.contains('--build')) {
      if (holdBuild) {
        held = _BuildChild('', null);
        started.complete();
        return held!;
      }
      if (failBuild) {
        code = 7;
        output = 'compile failed\n';
      } else {
        final bin = await Directory(
          '${arguments[arguments.indexOf('--build') + 1]}/bin',
        ).create(recursive: true);
        final executable = await File('${bin.path}/llama-server')
            .writeAsString('only external IO fixture');
        final chmod = await Process.run('/bin/chmod', ['+x', executable.path]);
        if (chmod.exitCode != 0) throw StateError('fixture chmod failed');
        await File('${bin.path}/libllama.dylib')
            .writeAsString('fixture dependency');
      }
    }
    return _BuildChild(output, code);
  }
}

class _BuildChild implements EngineSourceProcess {
  _BuildChild(String output, int? code)
    : stdout = Stream.value(utf8.encode(output)) {
    if (code != null) _exit.complete(code);
  }
  final _exit = Completer<int>();
  @override
  int get pid => 900101;
  @override
  Future<int> get exited => _exit.future;
  @override
  final Stream<List<int>> stdout;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool get groupAlive => !_exit.isCompleted;
  @override
  bool killGroup(ProcessSignal signal) {
    if (!_exit.isCompleted) _exit.complete(143);
    return true;
  }
}

class _InspectIO implements EngineProcessIO {
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async =>
      throw StateError('source dialog must never start a model');
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.contains('--version')) {
      return const EngineCommandResult(
        0,
        'version: 0.6.0-dev (build 11457, commit 0123456789)\nbuilt for Darwin arm64',
        '',
      );
    }
    if (arguments.contains('--help')) {
      return const EngineCommandResult(
        0,
        '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device',
        '',
      );
    }
    throw StateError('unexpected source inspection command');
  }
}
