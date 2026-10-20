import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/splash_preparation.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';

import 'fixtures/splash_help.dart';

void main() {
  test('explicit drafter replaces a deleted-worktree binding without changing source weights', () async {
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
class Metadata:
    def __init__(self, path): pass
def scalar_metadata(metadata): return {}
def derived_files(path):
    config = json.dumps(dict(model_type='qwen3_5', text_config=dict(hidden_size=16, num_hidden_layers=2, vocab_size=32))).encode()
    return {'config.json': config, 'tokenizer/tokenizer.json': b'{}', 'tokenizer/tokenizer_config.json': b'{}'}
''');
    final binary = File('${engine.path}/build/splash');
    await binary.parent.create();
    await binary.writeAsString('''#!${Platform.environment['GMD_TEST_PYTHON']!}
import json, sys
if len(sys.argv) > 6:
    draft = json.load(open(sys.argv[-1]))
    if draft.get('architectures') != ['DFlashDraftModel']:
        sys.stderr.write('draft is not a standard DFlash model')
        sys.exit(70)
print('{"family":"Qwen3.5-4B"}')
''');
    await Process.run('chmod', ['+x', binary.path]);
    final target = File('${root.path}/library/model.gguf');
    await target.parent.create();
    await target.writeAsString('existing selected model weights');
    final targetStat = await target.stat();
    final draft = Directory('${root.path}/shared-model-library/drafter');
    await draft.create(recursive: true);
    await File('${draft.path}/config.json').writeAsString(
      jsonEncode({
        'architectures': ['DFlashDraftModel'],
        'hidden_size': 16,
        'num_target_layers': 2,
        'vocab_size': 32,
      }),
    );
    final draftWeights = File('${draft.path}/model.safetensors');
    final header = utf8.encode(
      jsonEncode({
        'weight': {
          'dtype': 'BF16',
          'shape': [1],
          'data_offsets': [0, 2],
        },
      }),
    );
    await draftWeights.writeAsBytes([
      ...(ByteData(
        8,
      )..setUint64(0, header.length, Endian.little)).buffer.asUint8List(),
      ...header,
      0,
      0,
    ]);
    final weightsBefore = await draftWeights.readAsBytes();
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
    Future<Directory> prepare({
      bool legacy = false,
      DrafterConfiguration? policy,
      EngineLaunchConfiguration? configuration,
    }) => prepareSplashModel(
      io: NativeEngineProcessIO(),
      python: File(Platform.environment['GMD_TEST_PYTHON']!),
      engine: engine,
      root: managed,
      artifact: asset,
      configuration: configuration,
      recognition: EngineParameterRecognition.fromHelp(
        splashCurrentHelp,
        family: EngineFamily.splash,
        version: 'fixture current Splash CLI',
      ),
      previous: previous,
      drafter: legacy
          ? null
          : policy ?? DrafterConfiguration(enabled: true, path: draft.path),
    );
    await expectLater(
      prepare(legacy: true),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          contains('旧 drafter 绑定待修复'),
        ),
      ),
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
    expect(await draftWeights.readAsBytes(), weightsBefore);
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
    final ranking = File('${root.path}/ranking.bin');
    Future<void> compactFailure(String reason) => expectLater(
      prepare(
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          drafter: DrafterConfiguration(enabled: true, path: draft.path),
          formValues: {
            '--compact-draft-head': 'on',
            '--compact-draft-ranking': ranking.path,
          },
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'compact reason',
          contains(reason),
        ),
      ),
    );
    await ranking.writeAsString('SPLCHD01invalid');
    await compactFailure('SPLCHD02');
    final rank = ByteData(12 + 32 * 4);
    for (var i = 0; i < 8; i++) {
      rank.setUint8(i, 'SPLCHD02'.codeUnitAt(i));
    }
    rank.setUint32(8, 32, Endian.little);
    for (var i = 0; i < 32; i++) {
      rank.setUint32(12 + i * 4, i == 31 ? 30 : i, Endian.little);
    }
    await ranking.writeAsBytes(rank.buffer.asUint8List());
    await compactFailure('完整词表排列');
    rank.setUint32(12 + 31 * 4, 31, Endian.little);
    await ranking.writeAsBytes(rank.buffer.asUint8List());
    await prepare(
      configuration: EngineLaunchConfiguration(
        family: EngineFamily.splash,
        drafter: DrafterConfiguration(enabled: true, path: draft.path),
        formValues: {
          '--compact-draft-head': 'on',
          '--compact-draft-ranking': ranking.path,
        },
      ),
    );
    final originalMetadataSource = await module.readAsString();
    final compactDraftConfig = File('${draft.path}/config.json');
    final originalDraftConfig = await compactDraftConfig.readAsString();
    await module.writeAsString(
      originalMetadataSource.replaceFirst('vocab_size=32', 'vocab_size=262144'),
    );
    final largeVocabularyDraft =
        jsonDecode(originalDraftConfig) as Map<String, dynamic>;
    largeVocabularyDraft['vocab_size'] = 262144;
    await compactDraftConfig.writeAsString(jsonEncode(largeVocabularyDraft));
    final largeRanking = ByteData(12 + 262144 * 4);
    for (var i = 0; i < 8; i++) {
      largeRanking.setUint8(i, 'SPLCHD02'.codeUnitAt(i));
    }
    largeRanking.setUint32(8, 262144, Endian.little);
    for (var i = 0; i < 262144; i++) {
      largeRanking.setUint32(12 + i * 4, i, Endian.little);
    }
    final completeRanking = largeRanking.buffer.asUint8List();
    Future<Directory> prepareCompact(
      String capacity, {
      String mode = 'on',
      String text = '',
    }) => prepare(
      configuration: EngineLaunchConfiguration(
        family: EngineFamily.splash,
        drafter: DrafterConfiguration(enabled: true, path: draft.path),
        formValues: {
          '--compact-draft-head': mode,
          '--compact-draft-ranking': ranking.path,
          '--compact-draft-capacity': capacity,
        },
        argumentText: text,
      ),
    );
    try {
      await ranking.writeAsBytes(completeRanking);
      for (final capacity in ['512', '98304']) {
        await prepareCompact(capacity);
      }
      for (final capacity in ['511', '513', '98560', '0', '-256']) {
        await expectLater(
          prepareCompact(capacity),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'capacity constraint',
              contains('512–98304'),
            ),
          ),
        );
      }
      for (final data in [
        completeRanking.sublist(0, completeRanking.length - 4),
        [...completeRanking, 0, 0, 0, 0],
      ]) {
        await ranking.writeAsBytes(data);
        await compactFailure('大小或词表不匹配');
      }
      largeRanking.setUint32(8, 262143, Endian.little);
      await ranking.writeAsBytes(completeRanking);
      await compactFailure('大小或词表不匹配');
      largeRanking.setUint32(8, 262144, Endian.little);
      largeRanking.setUint32(12 + 262143 * 4, 262144, Endian.little);
      await ranking.writeAsBytes(completeRanking);
      await compactFailure('完整词表排列');
      await ranking.writeAsString(
        'disabled compact keeps this invalid file untouched',
      );
      await prepareCompact('0', mode: 'off');
      await expectLater(
        prepareCompact('512', mode: 'off', text: '--compact-draft-head on'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'text wins',
            contains('SPLCHD02'),
          ),
        ),
      );
      await expectLater(
        prepareCompact('512', mode: 'off', text: '--compact-draft-h on'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'native prefix text wins',
            contains('SPLCHD02'),
          ),
        ),
      );
      await prepareCompact('512', mode: 'off', text: '--compact-draft on');
      await prepareCompact(
        '512',
        mode: 'off',
        text: '--compact-draft-h on --compact-draft-head off',
      );
      await expectLater(
        prepareCompact(
          '512',
          mode: 'off',
          text: '--compact-draft-head off --compact-draft-h=on',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'last native prefix value wins',
            contains('SPLCHD02'),
          ),
        ),
      );
      await prepare(
        policy: const DrafterConfiguration(enabled: false),
        configuration: EngineLaunchConfiguration(
          family: EngineFamily.splash,
          drafter: const DrafterConfiguration(enabled: false),
          formValues: {
            '--compact-draft-head': 'on',
            '--compact-draft-ranking': '/missing/disabled-ranking.splash',
            '--compact-draft-capacity': '0',
          },
          argumentText: '--compact-draft-head on --compact-draft-ranking /missing/text-ranking.splash --compact-draft-capacity 0',
        ),
      );
      expect(
        await ranking.readAsString(),
        'disabled compact keeps this invalid file untouched',
      );
    } finally {
      await module.writeAsString(originalMetadataSource);
      await compactDraftConfig.writeAsString(originalDraftConfig);
    }
    Future<void> rejects(DrafterConfiguration policy, String reason) =>
        expectLater(
          prepare(policy: policy),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains(reason),
            ),
          ),
        );
    await rejects(const DrafterConfiguration(enabled: true), '请选择本地绝对目录');
    await rejects(
      DrafterConfiguration(
        enabled: true,
        path: '${root.path}/missing-selected',
      ),
      'missing-selected',
    );
    final draftConfig = File('${draft.path}/config.json');
    final originalConfig = await draftConfig.readAsString();
    await draftConfig.delete();
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'config.json',
    );
    await draftConfig.writeAsString('{');
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'drafter 文件检查失败',
    );
    await draftConfig.writeAsString(
      originalConfig.replaceFirst('DFlashDraftModel', 'DFlash2DraftModel'),
    );
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'draft is not a standard DFlash model',
    );
    await draftConfig.writeAsString(originalConfig);
    final index = File('${draft.path}/model.safetensors.index.json');
    await index.writeAsString(
      '{"weight_map":{"weight":"missing-shard.safetensors"}}',
    );
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'missing-shard.safetensors',
    );
    await index.writeAsString(
      '{"weight_map":{"wrong_tensor":"model.safetensors"}}',
    );
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'index does not match',
    );
    await index.writeAsString(
      '{"weight_map":{"weight":"../model.safetensors"}}',
    );
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'Invalid draft shard path',
    );
    await index.delete();
    await draftWeights.writeAsString('truncated');
    await rejects(
      DrafterConfiguration(enabled: true, path: draft.path),
      'safetensors',
    );
    await draftWeights.writeAsBytes(weightsBefore);
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
    final off = await prepare(
      policy: DrafterConfiguration(enabled: false, path: draft.path),
    );
    final offRecord =
        jsonDecode(await File('${off.path}/model.json').readAsString()) as Map;
    expect(offRecord['sources']['draft'], isNull);
    expect(
      (offRecord['files'] as Map).keys.any(
        (key) => (key as String).startsWith('draft/'),
      ),
      isFalse,
    );
    expect(await Directory('${off.path}/draft').exists(), isFalse);
    expect(off.path, isNot(updated.path));
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
