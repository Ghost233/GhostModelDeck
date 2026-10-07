import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/jev_models.dart';

import 'fixtures/council_runtime.dart';

void main() {
  test('shutdown drains admitted save and delete and rejects new registry mutations', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final io = _HeldRegistryIO();
    final file = File('${runtime.root.path}/models.json');
    final council = CouncilController(
      catalog: runtime.catalog,
      modelRegistryFile: file,
      modelRegistryIO: io,
    );
    addTearDown(council.close);
    final saving = council.models.save(
      JevModelDefinition.native(
        name: 'native-kev',
        binding: council.models.availableBindings.single,
      ),
    );
    final deleting = council.models.delete('native-kev');
    await io.entered.future.timeout(const Duration(seconds: 2));
    var stopped = false;
    final shutdown = council.shutdown().then((_) => stopped = true);
    try {
      await Future<void>.delayed(Duration.zero);
      expect(stopped, false, reason: 'accepted persistence has not completed');
      await expectLater(council.models.delete('native-kev'), throwsStateError);
      await expectLater(
        council.models.save(
          JevModelDefinition.native(
            name: 'new',
            binding: council.models.availableBindings.single,
          ),
        ),
        throwsStateError,
      );
      io.release.complete();
      await saving;
      await deleting;
      await shutdown;
      final restored = CouncilController(
        catalog: runtime.catalog,
        modelRegistryFile: file,
      );
      addTearDown(restored.close);
      await restored.models.load();
      expect(restored.models.definitions, isEmpty);
      expect(File('${file.path}.tmp').existsSync(), false);
    } finally {
      if (!io.release.isCompleted) io.release.complete();
      await saving.catchError((Object _) {});
      await deleting.catchError((Object _) {});
      await shutdown;
    }
  });
  test(
    'storage failure remains observable from save shutdown and close',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      addTearDown(runtime.close);
      final failure = FileSystemException('controlled registry write failure');
      final io = _HeldRegistryIO()..failure = failure;
      final council = CouncilController(
        catalog: runtime.catalog,
        modelRegistryFile: File('${runtime.root.path}/models.json'),
        modelRegistryIO: io,
      );
      addTearDown(() => council.close().catchError((Object _) {}));
      final saving = council.models.save(
        JevModelDefinition.native(
          name: 'native-kev',
          binding: council.models.availableBindings.single,
        ),
      );
      final saveRejected = expectLater(saving, throwsA(same(failure)));
      await io.entered.future.timeout(const Duration(seconds: 2));
      final shutdownRejected = expectLater(
        council.shutdown(),
        throwsA(same(failure)),
      );
      io.release.complete();
      await saveRejected;
      await shutdownRejected;
      expect(council.models.definitions, isEmpty);
      await expectLater(council.close(), throwsA(same(failure)));
    },
  );

  test(
    'close waits for admitted persistence before disposing registry listeners',
    () async {
      final runtime = await CouncilRuntime.create(modelCount: 1);
      addTearDown(runtime.close);
      final io = _HeldRegistryIO();
      final file = File('${runtime.root.path}/models.json');
      final council = CouncilController(
        catalog: runtime.catalog,
        modelRegistryFile: file,
        modelRegistryIO: io,
      );
      final saving = council.models.save(
        JevModelDefinition.native(
          name: 'native-kev',
          binding: council.models.availableBindings.single,
        ),
      );
      await io.entered.future.timeout(const Duration(seconds: 2));
      var closed = false;
      final closing = council.close().then((_) => closed = true);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(closed, false);
        io.release.complete();
        await saving;
        await closing;
        final restored = CouncilController(
          catalog: runtime.catalog,
          modelRegistryFile: file,
        );
        addTearDown(restored.close);
        await restored.models.load();
        expect(restored.models.definitions.single.name, 'native-kev');
      } finally {
        if (!io.release.isCompleted) io.release.complete();
        await saving;
        await closing;
      }
    },
  );

  test('shutdown waits for an admitted registry restore', () async {
    final runtime = await CouncilRuntime.create(modelCount: 1);
    addTearDown(runtime.close);
    final file = File('${runtime.root.path}/models.json');
    final writer = CouncilController(
      catalog: runtime.catalog,
      modelRegistryFile: file,
    );
    await writer.models.save(
      JevModelDefinition.native(
        name: 'native-kev',
        binding: writer.models.availableBindings.single,
      ),
    );
    await writer.close();
    final io = _HeldReadIO();
    final restored = CouncilController(
      catalog: runtime.catalog,
      modelRegistryFile: file,
      modelRegistryIO: io,
    );
    addTearDown(restored.close);
    final reading = restored.models.load();
    await io.entered.future.timeout(const Duration(seconds: 2));
    var stopped = false;
    final shutdown = restored.shutdown().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, false);
    io.release.complete();
    await reading;
    await shutdown;
    expect(restored.models.definitions.single.name, 'native-kev');
  });
}

class _HeldRegistryIO extends NativeJevRegistryIO {
  final entered = Completer<void>();
  final release = Completer<void>();
  Object? failure;
  @override
  Future<void> write(File file, String contents) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    final error = failure;
    if (error != null) throw error;
    await super.write(file, contents);
  }
}

class _HeldReadIO extends NativeJevRegistryIO {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> read(File file) async {
    entered.complete();
    await release.future;
    return super.read(file);
  }
}
