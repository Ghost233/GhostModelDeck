import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/splash_preparation.dart';

import 'fixtures/splash_1_4_help.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture, SplashTestProcessIO;

// External installer I/O seam; GMD's preparation runs in a real Python process.
const _publicInstaller = r'''
import hashlib, json
from pathlib import Path
class ModelError(Exception): pass
def prepare_local_model(target, draft=None, *, mmproj=None, language_only=False, models_dir=None):
    engine = Path(__file__).parent.parent
    mode = json.loads((engine / 'public-mode.json').read_text())
    (engine / 'public-call.json').write_text(json.dumps(dict(target=str(target), draft=str(draft) if draft else None, mmproj=mmproj, language_only=language_only, models_dir=str(models_dir))))
    if mode.get('failure'): raise ModelError(mode['failure'])
    target, root = Path(target), Path(models_dir)
    if mode.get('implicit_draft'): draft = Path(mode['implicit_draft'])
    key = hashlib.sha256(json.dumps([str(target), str(draft), mode], sort_keys=True).encode()).hexdigest()
    directory = root / '.resolved' / key
    if mode.get('outside'): directory = engine / 'outside'
    if directory.exists(): return directory
    directory.mkdir(parents=True)
    metadata = root / '.metadata' / key
    metadata.mkdir(parents=True)
    (metadata / 'config.json').write_text('{"vocab_size": 32}')
    (metadata / 'tokenizer.json').write_text('{}')
    (metadata / 'tokenizer_config.json').write_text('{}')
    targets = list(target.glob('*.safetensors')) if target.is_dir() else [target]
    if mode.get('extra_target'):
        extra = engine / 'extra.gguf'
        extra.write_text('unselected')
        targets.append(extra)
    paths = {'target/' + p.name:p for p in targets}
    paths.update({'config.json':metadata / 'config.json', 'tokenizer/config.json':metadata / 'config.json', 'tokenizer/tokenizer.json':metadata / 'tokenizer.json', 'tokenizer/tokenizer_config.json':metadata / 'tokenizer_config.json'})
    if draft:
        for p in Path(draft).iterdir():
            if p.is_file() and p.name != 'model.safetensors.index.json': paths['draft/' + p.name] = p
    files = {}
    for name, path in paths.items():
        path = path.resolve()
        link = directory / name
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(path)
        stat = path.stat()
        files[name] = dict(path=str(path), bytes=stat.st_size, mtime_ns=stat.st_mtime_ns, ctime_ns=stat.st_ctime_ns, digest=hashlib.sha256(path.read_bytes()).hexdigest())
    record = dict(version=1, model=str(target), family=mode.get('family','Qwen3.5-4B'), target_format='mlx-affine' if target.is_dir() else 'gguf', vision_format='none', sources=dict(target=dict(repo=str(target),revision=None), draft=dict(repo=str(draft),revision=None) if draft else None), files=files)
    (directory / 'model.json').write_text(json.dumps(record))
    return directory
''';

void main() {
  test(
    'public launches refresh stale or unread help before composing argv',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      for (final cached in ['', '--tokenizer DIRECTORY  legacy tokenizer\n']) {
        final installation = SplashInstallation.fromJson({
          ...fixture.installation.toJson(),
          'help': cached,
        });
        final engine = SplashEngine(
          installation: installation,
          library: fixture.library,
          useRegistry: ModelUseRegistry(fixture.library),
          io: _PublicProcessIO(fixture.io),
          runtimeDirectory: Directory(
            '${fixture.root.path}/cached-${cached.length}',
          ),
          configurationFor: (_) =>
              EngineLaunchConfiguration(family: EngineFamily.splash),
          saveBinding: (_) async {},
        );
        try {
          final run = await engine.startWithConfiguration(
            fixture.asset.id,
            EngineLaunchConfiguration(
              family: EngineFamily.splash,
              drafter: const DrafterConfiguration(enabled: false),
              formValues: {'--experimental-quantized-ffn': 'on'},
            ),
          );
          expect(run.status, RuntimeInstanceStatus.ready);
          expect(
            fixture.io.launchArguments.last,
            isNot(contains('--tokenizer')),
          );
          expect(
            fixture.io.launchArguments.last,
            containsAllInOrder(['--experimental-quantized-ffn', 'on']),
          );
        } finally {
          await engine.shutdown();
          await engine.close();
        }
      }
    },
  );

  test('public local preparation preserves native record and selected sources through restart', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final io = _PublicProcessIO(fixture.io);
    final engine = SplashEngine(
      installation: fixture.installation,
      library: fixture.library,
      useRegistry: ModelUseRegistry(fixture.library),
      io: io,
      runtimeDirectory: Directory('${fixture.root.path}/runtime'),
      configurationFor: (_) =>
          EngineLaunchConfiguration(family: EngineFamily.splash),
      saveBinding: (_) async {},
    );
    addTearDown(engine.close);
    addTearDown(engine.shutdown);
    final config = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      drafter: const DrafterConfiguration(enabled: false),
      formValues: {'--experimental-quantized-ffn': 'on'},
    );
    final binding = await engine.prepareModelBinding(
      fixture.asset.id,
      configuration: config,
    );
    final manifest = File('${binding.assembly.path}/model.json');
    final originalManifest = await manifest.readAsBytes();
    final record = jsonDecode(utf8.decode(originalManifest)) as Map;
    expect(record.containsKey('gmd_drafter'), isFalse);
    expect(record.containsKey('gmd_preparation'), isFalse);
    expect(binding.assemblyModel, record['model']);
    expect(binding.nativeModel, splashModelName(fixture.asset));
    expect(binding.nativeModel, startsWith('local/'));
    expect(
      SplashModelBinding.fromJson(binding.toJson()).assemblyModel,
      binding.assemblyModel,
    );
    expect((await _call(fixture))['language_only'], isTrue);
    expect((await _call(fixture))['draft'], isNull);
    fixture.io.startupFeatures = {
      'experimental_quantized_ffn': true,
      'ffn_cache_bytes': 0,
    };
    for (var index = 0; index < 2; index++) {
      final run = await engine.startWithConfiguration(
        fixture.asset.id,
        config,
        launchInstanceId: 'public',
      );
      expect(run.status, RuntimeInstanceStatus.ready);
      final arguments = fixture.io.launchArguments.last;
      expect(arguments, isNot(contains('--tokenizer')));
      expect(arguments, containsAllInOrder(['--model', binding.nativeModel]));
      expect(
        arguments,
        containsAllInOrder(['--experimental-quantized-ffn', 'on']),
      );
      expect(engine.actualQuantizedFfnFor('public'), (
        enabled: true,
        cacheBytes: 0,
      ));
      await engine.stop(run.id);
    }
    expect(await manifest.readAsBytes(), originalManifest);
    await manifest.writeAsString(
      jsonEncode({...record, 'model': '/wrong/source'}),
    );
    await expectLater(
      engine.startWithConfiguration(fixture.asset.id, config),
      throwsA(
        isA<SplashEngineException>().having(
          (e) => e.message,
          'identity',
          contains('身份已变化'),
        ),
      ),
    );
  });

  test(
    'public explicit DFlash keeps every selected shard and compact validation',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final draft = await _draft(fixture, sharded: true);
      final directory = await _prepare(
        fixture,
        DrafterConfiguration(enabled: true, path: draft.path),
      );
      expect((await _call(fixture))['draft'], draft.path);
      final record = jsonDecode(
        await File('${directory.path}/model.json').readAsString(),
      ) as Map;
      expect(
        (record['files'] as Map).keys,
        containsAll([
          'draft/config.json',
          'draft/a.safetensors',
          'draft/b.safetensors',
        ]),
      );
      await expectLater(
        _prepare(
          fixture,
          DrafterConfiguration(enabled: true, path: draft.path),
          compact: true,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'compact validation',
            contains('ranking'),
          ),
        ),
      );
      expect(await File('${draft.path}/a.safetensors').exists(), isTrue);
    },
  );

  for (final family in ['Qwen3.5-4B', 'Kev-4B', 'D3-mini', 'Laya']) {
    test(
      'public $family NoDraft uses the explicit disabled selection',
      () async {
        final fixture = await _fixture(mode: {'family': family});
        addTearDown(fixture.close);
        final directory = await _prepare(
          fixture,
          const DrafterConfiguration(enabled: false),
        );
        final record = jsonDecode(
          await File('${directory.path}/model.json').readAsString(),
        ) as Map;
        expect(record['family'], family);
        expect((record['sources'] as Map)['draft'], isNull);
        expect((await _call(fixture))['draft'], isNull);
      },
    );
  }

  for (final refusal in [
    'implicit_draft',
    'extra_target',
    'outside',
    'failure',
  ]) {
    test(
      'public $refusal rejection never falls back to legacy preparation',
      () async {
        final fixture = await _fixture();
        addTearDown(fixture.close);
        final mode = <String, Object?>{};
        if (refusal == 'implicit_draft') {
          mode[refusal] = (await _draft(fixture)).path;
        } else {
          mode[refusal] = refusal == 'failure'
              ? 'native public model refusal'
              : true;
        }
        await File('${fixture.source.path}/public-mode.json')
            .writeAsString(jsonEncode(mode));
        await expectLater(
          _prepare(fixture, const DrafterConfiguration(enabled: false)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'public error preserved',
              contains(switch (refusal) {
                'implicit_draft' =>
                  'drafter differs from the explicit selection',
                'extra_target' => 'target differs from the selected model',
                'outside' => 'outside GMD ownership',
                _ => 'native public model refusal',
              }),
            ),
          ),
        );
        expect(
          await File('${fixture.source.path}/public-call.json').exists(),
          isTrue,
        );
      },
    );
  }

  test(
    'broken public importer is an error rather than a legacy downgrade',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      await File('${fixture.source.path}/install/local.py')
          .writeAsString('raise ImportError("broken public API dependency")');
      await expectLater(
        _prepare(fixture, const DrafterConfiguration(enabled: false)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'import error',
            contains('broken public API dependency'),
          ),
        ),
      );
    },
  );
  test('held-model engines require the public local preparer', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    await File('${fixture.source.path}/install/local.py').delete();
    await expectLater(
      _prepare(fixture, const DrafterConfiguration(enabled: false)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'missing API',
          contains('需要 install.local.prepare_local_model'),
        ),
      ),
    );
  });

  test('public MLX preparation passes one directory and preserves all selected shards', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final directory = await Directory('${fixture.root.path}/mlx').create();
    final files = <LibraryFile>[];
    for (final name in ['a', 'b']) {
      final file = await File('${directory.path}/$name.safetensors')
          .writeAsString('external MLX fixture shard');
      files.add(LibraryFile(path: file.path, sizeBytes: await file.length()));
    }
    final asset = LibraryArtifact(
      id: 'mlx',
      files: files,
      format: 'Safetensors',
      kind: AssetKind.chat,
      integrity: AssetIntegrity.unknown,
      engineCapability: EngineCapability.awaitingVerification,
    );
    final prepared = await prepareSplashModel(
      io: NativeEngineProcessIO(),
      python: File(Platform.environment['GMD_TEST_PYTHON']!),
      engine: fixture.source,
      root: Directory('${fixture.root.path}/public-models'),
      artifact: asset,
      drafter: const DrafterConfiguration(enabled: false),
      recognition: fixture.installation.recognition,
    );
    expect((await _call(fixture))['target'], directory.path);
    final record = jsonDecode(
      await File('${prepared.path}/model.json').readAsString(),
    ) as Map;
    expect(record['target_format'], 'mlx-affine');
    expect(
      (record['files'] as Map).keys,
      containsAll(['target/a.safetensors', 'target/b.safetensors']),
    );
  });
}

Future<SplashRuntimeFixture> _fixture({
  Map<String, Object?> mode = const {},
}) async {
  final f = await SplashRuntimeFixture.create(helpOutput: splash14Help);
  await File('${f.source.path}/install/__init__.py').writeAsString('');
  await File('${f.source.path}/install/gguf.py')
      .writeAsString('raise RuntimeError("LEGACY FALLBACK")');
  await File('${f.source.path}/install/local.py')
      .writeAsString(_publicInstaller);
  await File('${f.source.path}/public-mode.json')
      .writeAsString(jsonEncode(mode));
  return f;
}

Future<Map<String, dynamic>> _call(SplashRuntimeFixture f) async =>
    jsonDecode(await File('${f.source.path}/public-call.json').readAsString())
        as Map<String, dynamic>;

Future<Directory> _prepare(
  SplashRuntimeFixture f,
  DrafterConfiguration drafter, {
  bool compact = false,
}) => prepareSplashModel(
  io: NativeEngineProcessIO(),
  python: File(Platform.environment['GMD_TEST_PYTHON']!),
  engine: f.source,
  root: Directory('${f.root.path}/public-models'),
  artifact: f.asset,
  drafter: drafter,
  configuration: EngineLaunchConfiguration(
    family: EngineFamily.splash,
    drafter: drafter,
    formValues: {if (compact) '--compact-draft-head': 'on'},
  ),
  recognition: f.installation.recognition,
);

Future<Directory> _draft(SplashRuntimeFixture f, {bool sharded = false}) async {
  final dir = await Directory('${f.root.path}/selected-draft').create();
  await File('${dir.path}/config.json')
      .writeAsString('{"architectures":["DFlashDraftModel"]}');
  if (sharded) {
    await File(
      '${dir.path}/model.safetensors.index.json',
    ).writeAsString('{"weight_map":{"a":"a.safetensors","b":"b.safetensors"}}');
  }
  for (final name in sharded ? ['a', 'b'] : ['model']) {
    final header = utf8.encode(
      jsonEncode({
        name: {
          'dtype': 'BF16',
          'shape': [1],
          'data_offsets': [0, 2],
        },
      }),
    );
    await File('${dir.path}/$name.safetensors').writeAsBytes([
      ...(ByteData(
        8,
      )..setUint64(0, header.length, Endian.little)).buffer.asUint8List(),
      ...header,
      0,
      0,
    ]);
  }
  return dir;
}

class _PublicProcessIO implements SplashProcessIO {
  _PublicProcessIO(this.simulated);
  final SplashTestProcessIO simulated;
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.any(
      (s) => s.contains('# Ghost Model Deck Splash preparation'),
    )) {
      simulated.calls.add(arguments);
      return NativeEngineProcessIO().run(
        Platform.environment['GMD_TEST_PYTHON']!,
        arguments,
        timeout: timeout,
      );
    }
    return simulated.run(executable, arguments, timeout: timeout);
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) =>
      simulated.start(executable, arguments);
  @override
  Future<bool> groupAlive(int ownedParentPid) =>
      simulated.groupAlive(ownedParentPid);
  @override
  Future<void> signalOwnedGroup(int ownedParentPid, ProcessSignal signal) =>
      simulated.signalOwnedGroup(ownedParentPid, signal);
}
