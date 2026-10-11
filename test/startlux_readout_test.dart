import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/startlux_readout.dart';
import 'package:ghost_model_deck/startlux_runtime.dart';

void main() {
  final runtime = StartluxPreparedRuntime(
    pythonPath: '/fixture/runtime/bin/python3',
    fingerprint: 'fixture-runtime-fingerprint',
    provenance: const {'python': 'fixture', 'architecture': 'arm64'},
    reused: true,
  );
  final nativeEndpoint = Uri.parse('http://127.0.0.1:51001');

  Future<Directory> cache() async {
    final directory = await Directory.systemTemp.createTemp('gmd-readout-');
    addTearDown(() => directory.delete(recursive: true));
    return directory;
  }

  Future<Uint8List> assets(String name) => File(name).readAsBytes();

  test('fixed packaged assets start an owned typed endpoint with provenance', () async {
    final root = await cache();
    final children = <_Child>[];
    final arguments = <List<String>>[];
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: root,
      assets: assets,
      spawn: (executable, argv) async {
        expect(executable, runtime.pythonPath);
        arguments.add(argv);
        final child = _Child()..ready();
        children.add(child);
        return child;
      },
    );
    final readout = await factory.start(
      nativeEndpoint: nativeEndpoint,
      alias: 'test-startlux',
      generation: 7,
      cancellation: DecisionCancellation(),
    );
    expect(readout.endpoint, Uri.parse('http://127.0.0.1:51002'));
    expect(readout.endpoint, isNot(nativeEndpoint));
    expect(readout.pid, children.single.pid);
    expect(arguments.single.take(2), ['-I', '-B']);
    expect(
      arguments.single,
      containsAllInOrder([
        '--llama',
        '$nativeEndpoint',
        '--name',
        'test-startlux',
        '--generation',
        '7',
      ]),
    );
    expect(arguments.single.join(' '), isNot(contains('.lmstudio')));
    expect(
      readout.sourceIdentity['author_pin'],
      StartluxReadoutFactory.authorPin,
    );
    expect(readout.sourceIdentity['runtime_fingerprint'], runtime.fingerprint);
    expect(
      readout.sourceIdentity['model_sha256'],
      StartluxReadoutFactory.supportedModelSha256,
    );
    expect(readout.sourceIdentity['generation'], 7);
    expect(
      readout.sourceIdentity['code_fingerprint'],
      matches(RegExp(r'^[a-f0-9]{64}$')),
    );
    expect(
      readout.sourceIdentity['tokenizer_fingerprint'],
      matches(RegExp(r'^[a-f0-9]{64}$')),
    );
    expect(
      readout.sourceIdentity['temperature_sha256'],
      matches(RegExp(r'^[a-f0-9]{64}$')),
    );
    expect(
      () => readout.sourceIdentity['runtime'] = null,
      throwsUnsupportedError,
    );
    await readout.stop();
    await readout.stop();
    expect(await readout.exited, 0);
    expect(children.single.signals, [ProcessSignal.sigterm]);
    final cached = File(
      '${root.path}/${StartluxReadoutFactory.manifestSha256}/managed_transport.py',
    );
    expect(await cached.exists(), isTrue);
    final restart = await factory.start(
      nativeEndpoint: nativeEndpoint,
      alias: 'test-startlux',
      generation: 7,
      cancellation: DecisionCancellation(),
    );
    await restart.stop();
    expect(children, hasLength(2));
  });

  test('pre-cancelled startup reads no assets and spawns nothing', () async {
    var loads = 0;
    var forks = 0;
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: await cache(),
      assets: (path) async {
        loads++;
        return assets(path);
      },
      spawn: (_, _) async {
        forks++;
        return _Child();
      },
    );
    await expectLater(
      factory.start(
        nativeEndpoint: nativeEndpoint,
        alias: 'test-startlux',
        generation: 7,
        cancellation: DecisionCancellation()..cancel(),
      ),
      throwsStateError,
    );
    expect(loads, 0);
    expect(forks, 0);
  });

  test('cancelling startup awaits owned process cleanup', () async {
    final child = _Child();
    final forked = Completer<void>();
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: await cache(),
      assets: assets,
      spawn: (_, _) async {
        forked.complete();
        return child;
      },
    );
    final cancellation = DecisionCancellation();
    final starting = factory.start(
      nativeEndpoint: nativeEndpoint,
      alias: 'test-startlux',
      generation: 7,
      cancellation: cancellation,
    );
    final failed = expectLater(starting, throwsStateError);
    await forked.future;
    cancellation.cancel();
    await failed;
    expect(await child.exited, 0);
    expect(child.signals, [ProcessSignal.sigterm]);
  });

  test(
    'wrong generation readiness preserves failure and stops owned child',
    () async {
      final child = _Child()..ready(generation: 6);
      final factory = StartluxReadoutFactory(
        runtime,
        cacheRoot: await cache(),
        assets: assets,
        spawn: (_, _) async => child,
      );
      await expectLater(
        factory.start(
          nativeEndpoint: nativeEndpoint,
          alias: 'test-startlux',
          generation: 7,
          cancellation: DecisionCancellation(),
        ),
        throwsFormatException,
      );
      expect(child.signals, [ProcessSignal.sigterm]);
    },
  );

  test('unexpected exit remains observable with its actual code', () async {
    final child = _Child()..ready();
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: await cache(),
      assets: assets,
      spawn: (_, _) async => child,
    );
    final readout = await factory.start(
      nativeEndpoint: nativeEndpoint,
      alias: 'test-startlux',
      generation: 7,
      cancellation: DecisionCancellation(),
    );
    child.finish(23);
    expect(await readout.exited, 23);
    await readout.stop();
    expect(child.signals, isEmpty);
  });

  test('startup failure and cleanup failure are both preserved', () async {
    final child = _Child()..ready(generation: 6);
    child.throwOnKill = true;
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: await cache(),
      assets: assets,
      spawn: (_, _) async => child,
    );
    try {
      await expectLater(
        factory.start(
          nativeEndpoint: nativeEndpoint,
          alias: 'test-startlux',
          generation: 7,
          cancellation: DecisionCancellation(),
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('readiness identity mismatch') &&
                error.toString().contains('fixture cleanup failed'),
          ),
        ),
      );
    } finally {
      child.finish(23);
    }
  });

  test(
    'failed readiness retains its live readout owner when cleanup fails',
    () async {
      final child = _Child()..ready(generation: 6);
      child.throwOnKill = true;
      final unrelated = _Child()..ready();
      final factory = StartluxReadoutFactory(
        runtime,
        cacheRoot: await cache(),
        assets: assets,
        spawn: (_, _) async => child,
      );
      Object? failure;
      try {
        try {
          await factory.start(
            nativeEndpoint: nativeEndpoint,
            alias: 'test-startlux',
            generation: 7,
            cancellation: DecisionCancellation(),
          );
        } catch (error) {
          failure = error;
        }
        expect(failure, isNotNull);
        expect(failure.toString(), contains('readiness identity mismatch'));
        expect(failure.toString(), contains('fixture cleanup failed'));
        StartluxReadout? retained;
        // The new public error contract carries the residual owner. Dynamic
        // access lets the original implementation reach a behavioral red.
        try {
          retained = (failure as dynamic).readout as StartluxReadout;
        } on NoSuchMethodError {
          retained = null;
        }
        expect(
          retained,
          isNotNull,
          reason: 'live sidecar must remain owned after failed startup cleanup',
        );
        expect(retained!.pid, child.pid);
        expect(child.signals, [ProcessSignal.sigterm]);
        child.throwOnKill = false;
        await retained.stop();
        expect(await retained.exited, 0);
        await retained.stop();
        expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigterm]);
        expect(unrelated.signals, isEmpty);
      } finally {
        child.finish(23);
        unrelated.finish(23);
        await unrelated.stdout.drain<void>();
        await unrelated.stderr.drain<void>();
      }
    },
  );

  test('modified bundled code is rejected before process creation', () async {
    var forks = 0;
    final root = await cache();
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: root,
      assets: (path) async => path.endsWith('/managed_transport.py')
          ? Uint8List.fromList(utf8.encode('raise RuntimeError("untrusted")'))
          : assets(path),
      spawn: (_, _) async {
        forks++;
        return _Child();
      },
    );
    await expectLater(
      factory.start(
        nativeEndpoint: nativeEndpoint,
        alias: 'test-startlux',
        generation: 7,
        cancellation: DecisionCancellation(),
      ),
      throwsFormatException,
    );
    expect(forks, 0);
    expect(await root.list().toList(), isEmpty);
  });

  test('reuse rechecks cached code and preserves the damaged cache', () async {
    final root = await cache();
    var forks = 0;
    final factory = StartluxReadoutFactory(
      runtime,
      cacheRoot: root,
      assets: assets,
      spawn: (_, _) async {
        forks++;
        return _Child()..ready();
      },
    );
    final readout = await factory.start(
      nativeEndpoint: nativeEndpoint,
      alias: 'test-startlux',
      generation: 7,
      cancellation: DecisionCancellation(),
    );
    await readout.stop();
    final cached = File(
      '${root.path}/${StartluxReadoutFactory.manifestSha256}/managed_transport.py',
    );
    await cached.writeAsString('modified cached code');
    await expectLater(
      factory.start(
        nativeEndpoint: nativeEndpoint,
        alias: 'test-startlux',
        generation: 7,
        cancellation: DecisionCancellation(),
      ),
      throwsFormatException,
    );
    expect(forks, 1);
    expect(await cached.readAsString(), 'modified cached code');
  });
}

class _Child implements StartluxReadoutProcess {
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  final signals = <ProcessSignal>[];
  bool throwOnKill = false;
  @override
  int get pid => 101;
  @override
  Future<int> get exited => _exit.future;
  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;

  void ready({int generation = 7}) {
    _out.add(
      utf8.encode(
        '${jsonEncode({'status': 'ready', 'port': 51002, 'model': 'test-startlux', 'pin': StartluxReadoutFactory.authorPin, 'generation': generation})}\n',
      ),
    );
  }

  void finish(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_out.close());
    unawaited(_err.close());
  }

  @override
  bool kill(ProcessSignal signal) {
    signals.add(signal);
    if (throwOnKill) throw StateError('fixture cleanup failed');
    finish(0);
    return true;
  }
}
