import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/omlx_engine.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

class _BuilderIO implements OmlxProcessIO {
  final commands = <String>[];
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    commands.add(executable);
    if (executable == '/usr/bin/id') return ProcessResult(1, 0, '501\n', '');
    if (executable == '/usr/bin/stat') {
      return ProcessResult(1, 0, '0:0:0755:Directory\n', '');
    }
    if (executable == '/bin/ls') {
      return ProcessResult(1, 0, 'drwxr-xr-x  root wheel path\n', '');
    }
    throw StateError('Unexpected process: $executable');
  }

  @override
  Future<void> download(Uri url, File destination) =>
      throw StateError('No download');
}

class _ValidBundleIO extends _BuilderIO {
  _ValidBundleIO(this.bundle);
  final Directory bundle;
  int pythonLaunches = 0;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    commands.add(executable);
    if (executable == '/usr/bin/stat') {
      if (arguments.last.startsWith('/Users/cryingneko')) {
        return ProcessResult(1, 1, '', 'No such file or directory');
      }
      return ProcessResult(
        1,
        0,
        List.filled(arguments.length - 2, '501:20:0700:Directory').join('\n'),
        '',
      );
    }
    if (executable == '/usr/bin/codesign') {
      return ProcessResult(
        1,
        0,
        '',
        'Identifier=app.omlx\nTeamIdentifier=PSK5Q5T46L\n',
      );
    }
    if (executable == '/usr/sbin/spctl') {
      return ProcessResult(1, 0, '', 'accepted');
    }
    if (executable == '/usr/bin/plutil') {
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'CFBundleIdentifier': 'app.omlx',
          'CFBundleShortVersionString': '0.7.0',
          'CFBundleVersion': '2987',
        }),
        '',
      );
    }
    if (executable.endsWith('/omlx-cli') || executable.endsWith('/python3')) {
      pythonLaunches++;
      expect(workingDirectory, isNotNull);
      expect(
        environment.keys.any(
          (key) => key.startsWith('DYLD') || key.startsWith('OMLX'),
        ),
        isFalse,
      );
      if (executable.endsWith('/omlx-cli')) {
        return ProcessResult(1, 0, '0.7.0\n', '');
      }
      // The official artifact ships omlx as a source package with
      // `_version.py` and no dist-info: a probe asking importlib.metadata
      // for omlx dies exactly like the frozen r62 native stderr, while
      // reading `omlx.__version__` succeeds.
      final script = arguments.contains('-c')
          ? arguments[arguments.indexOf('-c') + 1]
          : '';
      if (!script.contains('omlx.__version__')) {
        return ProcessResult(
          1,
          1,
          '',
          'Traceback (most recent call last):\n'
              '  File "<string>", line 12, in <module>\n'
              'importlib.metadata.PackageNotFoundError: '
              'No package metadata was found for omlx\n',
        );
      }
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'python': '3.11.10',
          'architecture': 'arm64',
          'prefix': '${bundle.path}/Contents/Resources/Python/cpython-3.11',
          'paths': [bundle.path, OmlxEngine.builderPath, workingDirectory],
          'origins': ['${bundle.path}/Contents/Resources/omlx/__init__.py'],
          'versions': {
            'omlx': '0.7.0',
            'mlx': '0.32.2',
            'mlx-lm': '0.31.4.dev132+g94cdcae13',
            'fastapi': '0.142.2',
            'transformers': '5.17.0',
          },
          'gpu': [
            [19.0, 22.0],
            [43.0, 50.0],
          ],
        }),
        '',
      );
    }
    if (executable == '/bin/ls') {
      return ProcessResult(
        1,
        0,
        List.filled(
          arguments.length - 1,
          'drwx------  owner group path',
        ).join('\n'),
        '',
      );
    }
    if (executable == '/bin/chmod') return ProcessResult(1, 0, '', '');
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _UnsafeGateIO extends _ValidBundleIO {
  _UnsafeGateIO(super.bundle, this.failure);
  final String failure;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    if (failure == 'ACL' &&
        executable == '/bin/ls' &&
        arguments.last == '/Users') {
      return ProcessResult(
        1,
        0,
        'drwxr-xr-x+ root wheel path\n 0: user:foreign allow write\n',
        '',
      );
    }
    if (executable == '/usr/bin/stat' && arguments.last == '/Users') {
      switch (failure) {
        case 'foreign owner':
          return ProcessResult(1, 0, '502:20:0755:Directory\n', '');
        case 'foreign writable':
          return ProcessResult(1, 0, '0:0:0775:Directory\n', '');
        case 'dangling link':
          return ProcessResult(1, 0, '0:0:0755:Symbolic Link\n', '');
        case 'permission':
          return ProcessResult(1, 1, '', 'Permission denied SECRET-SENTINEL');
        case 'parse':
          return ProcessResult(1, 0, 'AMBIGUOUS SECRET-SENTINEL', '');
      }
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _CleanupFailureIO extends _ValidBundleIO {
  _CleanupFailureIO(super.bundle, this.foreign);
  final Directory foreign;
  Directory? saved;
  String? cwd;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    final result = await super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
    if (executable.endsWith('/python3')) {
      cwd = workingDirectory!;
      saved = await Directory(cwd!).rename('$cwd-saved');
      await Link(cwd!).create(foreign.path);
    }
    return result;
  }
}

class _PrivateSetupFailureIO extends _ValidBundleIO {
  _PrivateSetupFailureIO(super.bundle);
  String? created;
  bool failing = true;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    if (executable == '/bin/chmod' && failing) {
      created = arguments.last;
      return ProcessResult(1, 1, '', 'SECRET-SENTINEL');
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _BlockingBundleIO extends _ValidBundleIO {
  _BlockingBundleIO(super.bundle);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    if (executable.endsWith('/omlx-cli') && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _StickyAncestorIO extends _ValidBundleIO {
  _StickyAncestorIO(super.bundle, this.ancestor);
  final String ancestor;
  int ancestorStats = 0;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    // `stat -f %Mp%Lp` keeps the sticky digit: /private/tmp prints 1777.
    if (executable == '/usr/bin/stat' && arguments.last == ancestor) {
      ancestorStats++;
      return ProcessResult(1, 0, '0:0:1777:Directory\n', '');
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _WorldWritableAncestorIO extends _ValidBundleIO {
  _WorldWritableAncestorIO(super.bundle, this.ancestor);
  final String ancestor;
  int ancestorStats = 0;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    // A root-owned 0777 directory without the sticky bit is untrusted.
    if (executable == '/usr/bin/stat' && arguments.last == ancestor) {
      ancestorStats++;
      return ProcessResult(1, 0, '0:0:0777:Directory\n', '');
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _DenyAclIO extends _ValidBundleIO {
  _DenyAclIO(super.bundle);
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    // Standard macOS home directories carry `group:everyone deny delete`.
    if (executable == '/bin/ls' &&
        arguments.length == 2 &&
        arguments.last == '/tmp') {
      return ProcessResult(
        1,
        0,
        'drwxr-xr-x+ 0 root wheel path\n 0: group:everyone deny delete\n',
        '',
      );
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

class _OfficialModesIO extends _ValidBundleIO {
  _OfficialModesIO(super.bundle);
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    // The official 0.7.0 bundle ships 1158x0o664 CPython files and 48x0o775
    // entries; a foreign bundle in that state must still be rejected.
    if (executable == '/usr/bin/stat' && arguments.length > 3) {
      return ProcessResult(
        1,
        0,
        List.filled(
          arguments.length - 2,
          '501:20:0664:Regular File',
        ).join('\n'),
        '',
      );
    }
    return super.run(
      executable,
      arguments,
      timeout: timeout,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
    );
  }
}

Future<Directory> _bundle(Directory root) async {
  final app = Directory('${root.path}/foreign.app');
  for (final name in [
    'Contents/Info.plist',
    'Contents/MacOS/omlx-cli',
    'Contents/Resources/Python/cpython-3.11/bin/python3',
    'Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages/sitecustomize.py',
    'Contents/Resources/omlx/__init__.py',
  ]) {
    final file = File('${app.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsString('fixture-only $name');
  }
  return app;
}

void main() {
  for (final failure in [
    'foreign owner',
    'foreign writable',
    'dangling link',
    'permission',
    'parse',
    'ACL',
  ]) {
    test(
      'public linked inspection rejects $failure before any Python and redacts raw evidence',
      () async {
        final root = await Directory.systemTemp.createTemp('gmd-omlx-gate-');
        addTearDown(() => root.delete(recursive: true));
        final app = await _bundle(root);
        final io = _UnsafeGateIO(app, failure);
        final engine = OmlxEngine(
          installationDirectory: Directory('${root.path}/owned'),
          io: io,
        );
        addTearDown(engine.close);
        await expectLater(
          engine.inspectLinked(app),
          throwsA(
            isA<OmlxException>().having(
              (e) => e.toString(),
              'redacted',
              isNot(contains('SECRET-SENTINEL')),
            ),
          ),
        );
        expect(io.pythonLaunches, 0);
        expect(engine.state.receipt, isNull);
      },
    );
  }

  test(
    'trusted sticky root-owned world-writable ancestor is accepted',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-sticky-');
      addTearDown(() => root.delete(recursive: true));
      final app = await _bundle(root);
      final io = _StickyAncestorIO(
        app,
        await root.parent.resolveSymbolicLinks(),
      );
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
        io: io,
      );
      addTearDown(engine.close);
      final receipt = await engine.inspectLinked(app);
      expect(receipt.releaseLabel, '0.7.0');
      expect(io.ancestorStats, greaterThan(0));
      expect(io.pythonLaunches, 3);
    },
  );

  test(
    'world-writable root ancestor without the sticky bit still fails closed',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-omlx-world-writable-',
      );
      addTearDown(() => root.delete(recursive: true));
      final app = await _bundle(root);
      final io = _WorldWritableAncestorIO(
        app,
        await root.parent.resolveSymbolicLinks(),
      );
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
        io: io,
      );
      addTearDown(engine.close);
      await expectLater(
        engine.inspectLinked(app),
        throwsA(isA<OmlxException>()),
      );
      expect(io.pythonLaunches, 0);
      expect(io.ancestorStats, greaterThan(0));
      expect(engine.state.receipt, isNull);
    },
  );

  test(
    'deny-only ACL on an ancestor is classified safe before Python',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-deny-acl-');
      addTearDown(() => root.delete(recursive: true));
      final app = await _bundle(root);
      final io = _DenyAclIO(app);
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
        io: io,
      );
      addTearDown(engine.close);
      final receipt = await engine.inspectLinked(app);
      expect(receipt.releaseLabel, '0.7.0');
      expect(io.pythonLaunches, 3);
    },
  );

  test(
    'foreign bundle with official group-writable modes still fails closed',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-official-');
      addTearDown(() => root.delete(recursive: true));
      final app = await _bundle(root);
      final io = _OfficialModesIO(app);
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
        io: io,
      );
      addTearDown(engine.close);
      await expectLater(
        engine.inspectLinked(app),
        throwsA(
          isA<OmlxException>().having(
            (e) => e.message,
            'ownership gate',
            contains('可由其他本地用户修改'),
          ),
        ),
      );
      expect(io.pythonLaunches, 0);
      expect(engine.state.receipt, isNull);
    },
  );

  test('private inspection cleanup never follows foreign link and aggregate stop retains retryable residual', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final app = await _bundle(root);
    final foreign = await Directory('${root.path}/unowned').create();
    final marker = File('${foreign.path}/keep.txt');
    await marker.writeAsString('not ours');
    final io = _CleanupFailureIO(app, foreign);
    final engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
    );
    addTearDown(engine.close);
    await expectLater(engine.inspectLinked(app), throwsA(isA<OmlxException>()));
    expect(engine.state.residualDirectory, io.cwd);
    await expectLater(engine.stopManaged(), throwsA(isA<OmlxException>()));
    expect(await marker.readAsString(), 'not ours');
    // Repair only the test-created link, then the same public aggregate operation
    // can retry cleanup without invoking Python or deleting foreign content.
    await Link(io.cwd!).delete();
    await io.saved!.rename(io.cwd!);
    final launches = io.pythonLaunches;
    await engine.stopManaged();
    expect(engine.state.residualDirectory, isNull);
    expect(io.pythonLaunches, launches);
    expect(await marker.readAsString(), 'not ours');
  });

  test('catalog shutdown failure retains ownership and retries repaired inspection cleanup', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-shutdown-');
    addTearDown(() => root.delete(recursive: true));
    final app = await _bundle(root);
    final foreign = await Directory('${root.path}/foreign').create();
    final marker = await File('${foreign.path}/keep.txt')
        .writeAsString('unowned');
    final io = _CleanupFailureIO(app, foreign);
    final library = ModelLibrary();
    addTearDown(library.close);
    final cpp = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/cpp'),
    );
    addTearDown(cpp.close);
    final engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: cpp,
      omlxEngine: engine,
      useRegistry: ModelUseRegistry(library),
      registryFile: File('${root.path}/engines.json'),
    );
    addTearDown(catalog.close);
    await expectLater(catalog.link(app.path), throwsA(isA<OmlxException>()));
    await expectLater(catalog.shutdown(), throwsA(isA<StateError>()));
    expect(engine.state.residualDirectory, io.cwd);
    await expectLater(catalog.link(app.path), throwsA(isA<StateError>()));
    await Link(io.cwd!).delete();
    await io.saved!.rename(io.cwd!);
    final launches = io.pythonLaunches;
    await catalog.shutdown();
    expect(engine.state.residualDirectory, isNull);
    expect(io.pythonLaunches, launches);
    expect(await marker.readAsString(), 'unowned');
  });

  test('failed private directory setup retains its exact created path for safe cleanup retry', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-omlx-private-setup-',
    );
    addTearDown(() => root.delete(recursive: true));
    final app = await _bundle(root);
    final io = _PrivateSetupFailureIO(app);
    final engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
    );
    addTearDown(engine.close);
    await expectLater(
      engine.inspectLinked(app),
      throwsA(
        isA<OmlxException>().having(
          (e) => e.toString(),
          'redacted',
          isNot(contains('SECRET-SENTINEL')),
        ),
      ),
    );
    expect(io.created, isNotNull);
    expect(engine.state.residualDirectory, io.created);
    expect(await Directory(io.created!).exists(), isTrue);
    expect(io.pythonLaunches, 0);
    io.failing = false;
    await engine.stopManaged();
    expect(engine.state.residualDirectory, isNull);
    expect(await Directory(io.created!).exists(), isFalse);
  });

  test('catalog recycle holds installation admission until accepted late work drains and cancels linked publication', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-admission-');
    addTearDown(() => root.delete(recursive: true));
    final app = await _bundle(root);
    final io = _BlockingBundleIO(app);
    final library = ModelLibrary();
    addTearDown(library.close);
    final cpp = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/cpp'),
    );
    addTearDown(cpp.close);
    final engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
    );
    final registry = File('${root.path}/engines.json');
    final catalog = EngineCatalog(
      library: library,
      officialEngine: cpp,
      omlxEngine: engine,
      useRegistry: ModelUseRegistry(library),
      registryFile: registry,
    );
    addTearDown(catalog.close);
    final linking = expectLater(
      catalog.link(app.path),
      throwsA(isA<OmlxException>()),
    );
    await io.started.future;
    final acceptedLate = expectLater(
      catalog.installManaged(EngineCatalog.omlxId),
      throwsA(isA<OmlxException>()),
    );
    final stopping = catalog.stopManaged();
    await expectLater(engine.install(), throwsA(isA<OmlxException>()));
    await expectLater(
      catalog.link(app.path),
      throwsA(isA<LlamaEngineException>()),
    );
    io.release.complete();
    await Future.wait([linking, acceptedLate, stopping]);
    expect(io.pythonLaunches, 1);
    expect(await registry.exists(), isFalse);
    expect(
      catalog.state.entries.where((e) => e.source == EngineSource.linked),
      isEmpty,
    );
    expect(await app.exists(), isTrue);
    // The aggregate operation releases temporary admission only after draining.
    final linked = await catalog.link(app.path);
    expect(linked.family, EngineFamily.omlx);
  });

  test('managed removal never owns extra files beside the persisted app and receipt', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-omlx-owned-removal-',
    );
    addTearDown(() => root.delete(recursive: true));
    final foreign = await _bundle(root);
    final installation = Directory('${root.path}/owned');
    final version = await Directory('${installation.path}/0.7.0')
        .create(recursive: true);
    final app = await foreign.rename('${version.path}/oMLX.app');
    final engine = OmlxEngine(
      installationDirectory: installation,
      io: _ValidBundleIO(app),
    );
    addTearDown(engine.close);
    final receipt = await engine.inspectLinked(app);
    // Filesystem fixture for a persisted installer receipt, not proof of a DMG transaction.
    await File('${version.path}/installation.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'receipt': {...receipt.toJson(), 'dmgSha256': OmlxEngine.dmgDigest},
      }),
    );
    await engine.refreshInstallation();
    expect(engine.state.status, OmlxInstallationStatus.installed);
    final plan = await engine.prepareRemoval();
    final unrelated = File('${version.path}/unrelated.txt');
    await unrelated.writeAsString('must preserve');
    await expectLater(engine.prepareRemoval(), throwsA(isA<OmlxException>()));
    await expectLater(
      engine.removeInstallation(plan, confirmed: true),
      throwsA(isA<OmlxException>()),
    );
    expect(await unrelated.readAsString(), 'must preserve');
    expect(await app.exists(), isTrue);
  });

  test('same catalog links, reopens and unlinks full app with a callable pool and without deleting foreign bytes', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-catalog-');
    addTearDown(() => root.delete(recursive: true));
    final bundle = await _bundle(root);
    final io = _ValidBundleIO(bundle);
    final library = ModelLibrary();
    addTearDown(library.close);
    final registry = ModelUseRegistry(library);
    EngineCatalog catalog() {
      final cpp = LlamaEngine(
        library: library,
        installationDirectory: Directory('${root.path}/cpp'),
      );
      addTearDown(cpp.close);
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
        io: io,
      );
      final result = EngineCatalog(
        library: library,
        officialEngine: cpp,
        useRegistry: registry,
        registryFile: File('${root.path}/engines.json'),
        omlxEngine: engine,
      );
      addTearDown(result.close);
      return result;
    }

    final first = catalog();
    final entry = await first.link(bundle.path);
    expect(entry.family, EngineFamily.omlx);
    expect(entry.omlxReceipt?.releaseLabel, '0.7.0');
    expect(entry.release, isNull);
    expect(entry.binaryVersion, isNull);
    expect(first.runtimeFor(entry.id), isA<EngineRuntime>());
    expect(first.runsFor(['model']), isEmpty);
    final registryFile = File('${root.path}/engines.json');
    final validRegistry = await registryFile.readAsString();
    final malformed = jsonDecode(validRegistry) as Map<String, dynamic>;
    (malformed['linked'] as List).add({
      'id': 'malformed',
      'name': 'invalid',
      'path': bundle.path,
      'family': 'omlx',
      'receipt': {'secret': 'SECRET-SENTINEL'},
    });
    final invalidBytes = jsonEncode(malformed);
    await registryFile.writeAsString(invalidBytes);
    final invalidCatalog = catalog();
    await expectLater(
      invalidCatalog.refresh(),
      throwsA(
        isA<OmlxException>().having(
          (e) => e.toString(),
          'redacted',
          isNot(contains('SECRET-SENTINEL')),
        ),
      ),
    );
    expect(
      invalidCatalog.state.entries.where(
        (e) => e.source == EngineSource.linked,
      ),
      isEmpty,
    );
    expect(await registryFile.readAsString(), invalidBytes);
    await registryFile.writeAsString(validRegistry);
    final reopened = catalog();
    await reopened.refresh();
    final linked = reopened.state.entries.singleWhere((e) => e.id == entry.id);
    expect(linked.status, LlamaInstallationStatus.installed);
    final plan = await reopened.prepareRemoval(entry.id);
    expect(plan.paths, isEmpty);
    await expectLater(
      first.remove(plan, confirmed: true),
      throwsA(isA<LlamaEngineException>()),
    );
    final resource = File('${bundle.path}/Contents/Resources/omlx/__init__.py');
    final original = await resource.readAsString();
    await resource.writeAsString('changed after plan');
    await expectLater(
      reopened.remove(plan, confirmed: true),
      throwsA(isA<OmlxException>()),
    );
    expect(reopened.state.entries.any((e) => e.id == entry.id), isTrue);
    await resource.writeAsString(original);
    await reopened.remove(plan, confirmed: false);
    expect(reopened.state.entries.any((e) => e.id == entry.id), isTrue);
    await reopened.remove(plan, confirmed: true);
    expect(reopened.state.entries.any((e) => e.id == entry.id), isFalse);
    expect(
      await File('${bundle.path}/Contents/Resources/omlx/__init__.py')
          .readAsString(),
      'fixture-only Contents/Resources/omlx/__init__.py',
    );
  });
  test(
    'catalog malformed registry JSON is preserved and never exposed in errors',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-registry-');
      addTearDown(() => root.delete(recursive: true));
      final app = await _bundle(root);
      final io = _ValidBundleIO(app);
      final library = ModelLibrary();
      addTearDown(library.close);
      final cpp = LlamaEngine(
        library: library,
        installationDirectory: Directory('${root.path}/cpp'),
      );
      addTearDown(cpp.close);
      final registry = await File('${root.path}/engines.json')
          .writeAsString('{SECRET-SENTINEL');
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
        io: io,
      );
      final catalog = EngineCatalog(
        library: library,
        officialEngine: cpp,
        omlxEngine: engine,
        useRegistry: ModelUseRegistry(library),
        registryFile: registry,
      );
      addTearDown(catalog.close);
      await expectLater(
        catalog.link(app.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'redacted',
            isNot(contains('SECRET-SENTINEL')),
          ),
        ),
      );
      expect(catalog.state.error, isNot(contains('SECRET-SENTINEL')));
      expect(await registry.readAsString(), '{SECRET-SENTINEL');
      expect(io.pythonLaunches, 0);
    },
  );

  test('shutdown cancels inspection before receipt publication and permanently rejects new operations', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final app = await _bundle(root);
    final io = _BlockingBundleIO(app);
    final engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
    );
    addTearDown(engine.close);
    final inspecting = expectLater(
      engine.inspectLinked(app),
      throwsA(isA<OmlxException>()),
    );
    await io.started.future;
    final shuttingDown = engine.shutdown();
    await expectLater(engine.inspectLinked(app), throwsA(isA<OmlxException>()));
    io.release.complete();
    await Future.wait([inspecting, shuttingDown]);
    expect(io.pythonLaunches, 1);
    expect(engine.state.receipt, isNull);
    expect(engine.state.residualDirectory, isNull);
    expect(await engine.installationDirectory.list().toList(), isEmpty);
    expect(await app.exists(), isTrue);
    await expectLater(engine.install(), throwsA(isA<OmlxException>()));
  });

  test('public linked full-app inspection returns distinct bundle and runtime receipt', () async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-valid-');
    addTearDown(() => root.delete(recursive: true));
    final bundle = await _bundle(root);
    final io = _ValidBundleIO(bundle);
    final engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
    );
    addTearDown(engine.close);
    final receipt = await engine.inspectLinked(bundle);
    expect(receipt.releaseLabel, '0.7.0');
    expect(receipt.build, '2987');
    expect(receipt.dmgSha256, isNull);
    expect(receipt.bundleManifestSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(receipt.runtimeIdentity.python, '3.11.10');
    expect(io.pythonLaunches, 3);
    expect(await bundle.exists(), isTrue);
  });
  test(
    'link fails closed before Python when baked builder directory exists',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-link-');
      addTearDown(() => root.delete(recursive: true));
      final io = _BuilderIO();
      final engine = OmlxEngine(installationDirectory: root, io: io);
      addTearDown(engine.close);
      await expectLater(
        engine.inspectLinked(Directory('${root.path}/foreign.app')),
        throwsA(
          isA<OmlxException>().having(
            (e) => e.message,
            'safe error',
            contains('builder'),
          ),
        ),
      );
      expect(
        io.commands.where(
          (command) =>
              command.contains('python') || command.contains('omlx-cli'),
        ),
        isEmpty,
      );
      expect(engine.state.receipt, isNull);
    },
  );
  test(
    'official artifact boundary rehashes before mounting or publishing',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-install-');
      addTearDown(() => root.delete(recursive: true));
      final artifact = await File('${root.path}/not-official.dmg')
          .writeAsString('bad');
      final engine = OmlxEngine(
        installationDirectory: Directory('${root.path}/owned'),
      );
      addTearDown(engine.close);
      await expectLater(
        engine.install(verifiedArtifact: artifact),
        throwsA(isA<OmlxException>()),
      );
      expect(engine.state.status, OmlxInstallationStatus.failed);
      expect(engine.state.receipt, isNull);
      expect(await Directory('${root.path}/owned/0.7.0').exists(), isFalse);
      expect(await artifact.readAsString(), 'bad');
    },
  );
}
