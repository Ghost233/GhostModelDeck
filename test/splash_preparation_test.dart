import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/splash_preparation.dart';

void main() {
  test('managed preparation repairs a deleted-worktree draft, reuses directories and preserves source weights', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd splash preparation ',
    );
    addTearDown(() => root.delete(recursive: true));
    final engine = Directory('${root.path}/engine');
    final module = File('${engine.path}/install/gguf.py');
    await module.parent.create(recursive: true);
    await File('${module.parent.path}/__init__.py').writeAsString('');
    // The process seam supplies metadata; assembly ownership and file references
    // are exercised by the production preparation program in a real process.
    await module.writeAsString('''
import json
def derived_files(path):
    config = json.dumps(dict(model_type='qwen3_5', text_config=dict(hidden_size=16, num_hidden_layers=2, vocab_size=32))).encode()
    return {'config.json': config, 'tokenizer/tokenizer.json': b'{}', 'tokenizer/tokenizer_config.json': b'{}'}
''');
    final target = File('${root.path}/library/model.gguf');
    await target.parent.create();
    await target.writeAsString('existing selected model weights');
    final targetStat = await target.stat();
    final draft = Directory(
      '${engine.path}/install/models-local/drafts/local/source',
    );
    await draft.create(recursive: true);
    await File('${draft.path}/config.json').writeAsString(
      jsonEncode({'hidden_size': 16, 'num_target_layers': 2, 'vocab_size': 32}),
    );
    final draftWeights = await File('${draft.path}/model.safetensors')
        .writeAsString('existing draft weights');
    final previous = Directory('${root.path}/old-assembly');
    await previous.create();
    await File('${previous.path}/model.json').writeAsString(
      jsonEncode({
        'sources': {
          'draft': {
            'repo':
                '${root.path}/.codex/worktrees/deleted/GhostSplash/install/models-local/drafts/local/source',
          },
        },
      }),
    );
    final asset = LibraryArtifact(
      id: 'selected',
      files: [LibraryFile(path: target.path, sizeBytes: targetStat.size)],
      format: 'GGUF',
      kind: AssetKind.decision,
      integrity: AssetIntegrity.unknown,
      engineCapability: EngineCapability.awaitingVerification,
    );
    final managed = Directory('${root.path}/application-support/splash-models');
    Future<Directory> prepare() => prepareSplashModel(
      io: NativeEngineProcessIO(),
      python: File(Platform.environment['GMD_TEST_PYTHON']!),
      engine: engine,
      root: managed,
      artifact: asset,
      previous: previous,
    );
    final first = await prepare();
    final manifest = File('${first.path}/model.json');
    final before = await manifest.stat();
    final second = await prepare();
    expect(second.path, first.path);
    expect((await manifest.stat()).modified, before.modified);
    expect(first.path, startsWith('${await managed.resolveSymbolicLinks()}/'));
    expect(
      await Link('${first.path}/target/model.gguf').resolveSymbolicLinks(),
      await target.resolveSymbolicLinks(),
    );
    expect(
      await Link('${first.path}/draft/model.safetensors')
          .resolveSymbolicLinks(),
      await draftWeights.resolveSymbolicLinks(),
    );
    expect(await target.readAsString(), 'existing selected model weights');
    expect((await target.stat()).modified, targetStat.modified);
    expect(await draftWeights.readAsString(), 'existing draft weights');
    expect(await File('${first.path}/tokenizer/config.json').exists(), isTrue);
    expect(
      await manifest.readAsString(),
      isNot(contains('/.codex/worktrees/')),
    );
    final record = jsonDecode(await manifest.readAsString()) as Map;
    expect(record['model'], 'local/model-gguf');
    expect(
      record['files']['target/model.gguf']['fingerprint_kind'],
      'inventory',
    );
    await File('${first.path}/tokenizer/config.json')
        .writeAsString('damaged metadata');
    final repaired = await prepare();
    expect(repaired.path, isNot(first.path));
    expect(
      await File('${repaired.path}/tokenizer/config.json').readAsString(),
      isNot('damaged metadata'),
    );
    expect((await prepare()).path, repaired.path);
    // A changed source gets a new immutable directory; an old run keeps its files.
    await target.writeAsString('a different selected model weight file');
    final updated = await prepare();
    expect(updated.path, isNot(first.path));
    expect(await manifest.exists(), isTrue);
    await draftWeights.delete();
    await expectLater(prepare(), throwsA(isA<StateError>()));
    expect(await manifest.exists(), isTrue);
  });

  test(
    'cancellation during preparation prevents a late result being used',
    () async {
      final io = _HeldPreparation();
      final token = DecisionCancellation();
      final pending = prepareSplashModel(
        io: io,
        python: File('/unused/python'),
        engine: Directory('/unused/engine'),
        root: Directory('/unused/models'),
        artifact: LibraryArtifact(
          id: 'selected',
          repoId: 'fixture/selected',
          files: const [],
          format: 'GGUF',
          kind: AssetKind.chat,
          integrity: AssetIntegrity.unknown,
          engineCapability: EngineCapability.awaitingVerification,
        ),
        cancellation: token,
      );
      final rejected = expectLater(pending, throwsA(isA<StateError>()));
      await io.arrived.future.timeout(const Duration(seconds: 2));
      token.cancel();
      io.release.complete();
      await rejected;
      expect(io.starts, 0);
    },
  );
}

class _HeldPreparation implements EngineProcessIO {
  final arrived = Completer<void>();
  final release = Completer<void>();
  var starts = 0;
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    arrived.complete();
    await release.future;
    return const EngineCommandResult(0, '{}', '');
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    starts++;
    throw UnimplementedError();
  }
}
