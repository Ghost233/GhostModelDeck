import 'dart:convert';
import 'dart:io';

import 'llama_engine.dart';
import 'model_library.dart';

/// Prepares metadata and references, without copying or hashing model weights.
Future<Directory> prepareSplashModel({
  required EngineProcessIO io,
  required File python,
  required Directory engine,
  required Directory root,
  required LibraryArtifact artifact,
  Directory? previous,
  DecisionCancellation? cancellation,
}) async {
  void checkCancellation() {
    if (cancellation?.isCancelled ?? false) throw StateError('Splash 模型准备已取消');
  }

  checkCancellation();
  final stem = artifact.name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final localName = stem.isEmpty ? 'model' : stem;
  final result = await io.run(python.path, [
    '-B',
    '-P',
    '-c',
    splashPreparationProgram,
    jsonEncode({
      'engine': engine.path,
      'root': root.path,
      'model':
          artifact.repoId ??
          'local/${localName.length > 80 ? localName.substring(0, 80) : localName}',
      'files': [
        for (final file in artifact.files)
          if (file.path.endsWith('.gguf') || file.path.endsWith('.safetensors'))
            file.realPath,
      ],
      'previous': previous?.path,
    }),
  ], timeout: const Duration(seconds: 60));
  checkCancellation();
  if (result.exitCode != 0) {
    throw StateError('Splash 模型准备失败：${result.stderr.trim()}');
  }
  final value = jsonDecode(result.stdout);
  if (value is! Map || value['directory'] is! String) {
    throw const FormatException('Splash 模型准备结果无效');
  }
  final directory = Directory(
    await Directory(value['directory']).resolveSymbolicLinks(),
  );
  final owner = await root.resolveSymbolicLinks();
  if (!directory.path.startsWith('$owner/')) {
    throw const FormatException('Splash 运行目录不属于 GMD');
  }
  return directory;
}

const splashPreparationProgram = r'''
# Ghost Model Deck Splash preparation
import fcntl, hashlib, json, os, shutil, sys, tempfile
from pathlib import Path

request = json.loads(sys.argv[1])
engine = Path(request['engine']).resolve(strict=True)
root = Path(request['root']).absolute()
root.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(engine))

def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False).encode()

def identity(path):
    stat = path.stat()
    return dict(path=str(path), bytes=stat.st_size,
                mtime_ns=stat.st_mtime_ns, ctime_ns=stat.st_ctime_ns)

def stable(path):
    return '/.codex/worktrees/' not in str(path)

def read_json(path):
    return json.loads(path.read_text())

def draft_files(directory):
    index = directory / 'model.safetensors.index.json'
    names = sorted(set(read_json(index)['weight_map'].values())) if index.is_file() else ['model.safetensors']
    files = {'draft/config.json': directory / 'config.json'}
    for name in names:
        if Path(name).name != name:
            raise ValueError('Invalid draft shard path')
        files['draft/' + name] = directory / name
    return files if all(path.is_file() for path in files.values()) else None

def prepare():
    targets = [Path(path).resolve(strict=True) for path in request['files']]
    if not targets or any(not stable(path) for path in targets):
        raise ValueError('Selected model must be stored outside temporary worktrees')
    files = {'target/' + path.name: path for path in targets}
    if len(files) != len(targets):
        raise ValueError('Duplicate model shard names')
    generated = {}
    adapters = {}
    gguf_target = all(path.suffix == '.gguf' for path in targets)
    if gguf_target:
        from install import gguf
        adapters['gguf'] = hashlib.sha256(Path(gguf.__file__).read_bytes()).hexdigest()
        generated.update(gguf.derived_files(targets[0]))
        config = json.loads(generated['config.json'])
        generated['tokenizer/config.json'] = generated['config.json']
    else:
        source = targets[0].parent
        config = read_json(source / 'config.json')
        generated['config.json'] = (source / 'config.json').read_bytes()
        generated['tokenizer/config.json'] = generated['config.json']
        for name in ['tokenizer.json', 'tokenizer_config.json', 'tokenizer.model', 'chat_template.jinja', 'special_tokens_map.json']:
            path = source / name
            if path.is_file(): generated['tokenizer/' + name] = path.read_bytes()
        if 'tokenizer/tokenizer.json' not in generated and 'tokenizer/tokenizer.model' not in generated:
            raise ValueError('Selected model has no local tokenizer files')

    text = config.get('text_config', config)
    candidates = []
    previous = request.get('previous')
    old = {}
    if previous and (Path(previous) / 'model.json').is_file():
        try:
            old = read_json(Path(previous) / 'model.json')
        except (ValueError, OSError):
            pass  # An obsolete directory is only a hint, never a dependency.
    if old:
        recorded = (old.get('sources') or {}).get('draft') or {}
        location = recorded.get('repo', '')
        if '/install/' in location:
            candidates.append(engine / 'install' / location.split('/install/', 1)[1])
    drafts = engine / 'install/models-local/drafts'
    if drafts.is_dir():
        candidates.extend(sorted(drafts.glob('*/source')))
        candidates.extend(sorted(drafts.glob('*/bf16')))
    chosen = None
    for candidate in candidates:
        if not (candidate / 'config.json').is_file(): continue
        candidate = candidate.resolve()
        if not stable(candidate): continue
        draft = read_json(candidate / 'config.json')
        if (draft.get('hidden_size') != text.get('hidden_size') or
            draft.get('num_target_layers') != text.get('num_hidden_layers') or
            draft.get('vocab_size') != text.get('vocab_size')):
            continue
        found = draft_files(candidate)
        if found:
            files.update({name: path.resolve(strict=True) for name, path in found.items()})
            chosen = candidate
            break
    if chosen is None and (old.get('sources') or {}).get('draft'):
        raise ValueError('Previously selected draft is missing; no matching draft exists in the selected engine installation')

    inputs = dict(version=1, model=request['model'], adapter=adapters,
                  files={name: identity(path) for name, path in files.items()},
                  metadata={name: hashlib.sha256(data).hexdigest() for name, data in generated.items()})
    key = hashlib.sha256(encoded(inputs)).hexdigest()
    destination = root / key
    suffix = 1
    while destination.exists():
        manifest = destination / 'model.json'
        if manifest.is_file():
            record = read_json(manifest)
            try:
                references_match = all(
                    (destination / name).resolve(strict=True) == Path(entry['path']).resolve(strict=True)
                    for name, entry in record['files'].items())
                metadata_matches = all(
                    hashlib.sha256((destination / name).read_bytes()).hexdigest() == digest
                    for name, digest in inputs['metadata'].items())
                if record.get('gmd_preparation') == key and references_match and metadata_matches:
                    return destination
            except (OSError, KeyError):
                pass
        suffix += 1
        destination = root / (key + '-' + str(suffix))
    stage = Path(tempfile.mkdtemp(prefix='.preparing-', dir=root))
    try:
        records = {}
        for name, path in files.items():
            link = stage / name
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(path)
            entry = identity(path)
            # This is a labelled inventory identity, never a weight-content hash.
            entry.update(digest=hashlib.sha256(encoded(entry)).hexdigest(), fingerprint_kind='inventory')
            records[name] = entry
        for name, data in generated.items():
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            entry = identity(path)
            entry.update(path=str(destination / name), digest=hashlib.sha256(data).hexdigest(), fingerprint_kind='fullContent')
            records[name] = entry
        record = dict(version=1, gmd_preparation=key, model=request['model'],
                      family=config.get('model_type', 'unknown'),
                      target_format='gguf' if gguf_target else 'mlx-affine', vision_format='none',
                      sources=dict(target=dict(repo=str(targets[0].parent), revision=None),
                                   draft=dict(repo=str(chosen), revision=None) if chosen else None), files=records)
        (stage / 'model.json').write_bytes(encoded(record))
        if {name: identity(path) for name, path in files.items()} != inputs['files']:
            raise ValueError('Model files changed during preparation')
        stage.rename(destination)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    return destination

try:
    with (root / '.prepare.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        directory = prepare()
    print(json.dumps(dict(directory=str(directory))))
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
''';
