import 'dart:convert';
import 'dart:io';

import 'llama_engine.dart';
import 'model_library.dart';
import 'engine_launch_configuration.dart';
import 'engine_parameter_recognition.dart';

String splashModelName(LibraryArtifact artifact) {
  final stem = artifact.name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final name = stem.isEmpty ? 'model' : stem;
  return artifact.repoId ??
      'local/${name.length > 80 ? name.substring(0, 80) : name}';
}

/// Uses the engine's public local preparer when available. New preparations may
/// read source digests; subsequent preparations reuse the engine's inventory.
Future<Directory> prepareSplashModel({
  required EngineProcessIO io,
  required File python,
  required Directory engine,
  required Directory root,
  required LibraryArtifact artifact,
  Directory? previous,
  DrafterConfiguration? drafter,
  File? nativeBinary,
  EngineLaunchConfiguration? configuration,
  EngineParameterRecognition? recognition,
  DecisionCancellation? cancellation,
}) async {
  void checkCancellation() {
    if (cancellation?.isCancelled ?? false) throw StateError('Splash 模型准备已取消');
  }

  checkCancellation();
  final result = await io.run(python.path, [
    '-B',
    '-P',
    '-c',
    splashPreparationProgram,
    jsonEncode({
      'engine': engine.path,
      'root': root.path,
      'model': splashModelName(artifact),
      'files': [
        for (final file in artifact.files)
          if (file.path.endsWith('.gguf') || file.path.endsWith('.safetensors'))
            file.realPath,
      ],
      'previous': previous?.path,
      'requires_public_preparation':
          recognition?.usesSplashModelRootTokenizer ?? false,
      'drafter': drafter?.toJson(),
      'compact': {
        'enabled':
            configuration?.argumentValue(
              '--compact-draft-head',
              recognition: recognition,
            ) ==
            'on',
        'ranking': configuration?.argumentValue(
          '--compact-draft-ranking',
          recognition: recognition,
        ),
        'capacity': configuration?.argumentValue(
          '--compact-draft-capacity',
          recognition: recognition,
        ),
      },
      'native': nativeBinary?.path ?? '${engine.path}/build/splash',
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
import fcntl, hashlib, json, math, os, shutil, struct, subprocess, sys, tempfile
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
    mapping = read_json(index).get('weight_map') if index.is_file() else None
    if index.is_file() and (not isinstance(mapping, dict) or not mapping or
                            any(not isinstance(k, str) or not isinstance(v, str) for k, v in mapping.items())):
        raise ValueError(f'Invalid draft weight_map: {index}')
    names = sorted(set(mapping.values())) if mapping else ['model.safetensors']
    files = {'draft/config.json': directory / 'config.json'}
    if mapping: files['draft/model.safetensors.index.json'] = index
    tensors = {}
    for name in names:
        if Path(name).name != name or not name.endswith('.safetensors'):
            raise ValueError(f'Invalid draft shard path: {name}')
        path = directory / name
        with path.open('rb') as stream:
            size = path.stat().st_size
            prefix = stream.read(8)
            if len(prefix) != 8: raise ValueError(f'Truncated safetensors: {path}')
            length = struct.unpack('<Q', prefix)[0]
            if not 0 < length <= min(100_000_000, size - 8):
                raise ValueError(f'Invalid safetensors header length: {path}')
            header = json.loads(stream.read(length))
        if not isinstance(header, dict): raise ValueError(f'Invalid safetensors header: {path}')
        spans = []
        for key, tensor in header.items():
            if key == '__metadata__': continue
            if key in tensors: raise ValueError(f'Duplicate draft tensor {key}: {path}')
            if not isinstance(tensor, dict): raise ValueError(f'Invalid draft tensor {key}: {path}')
            shape, offsets = tensor.get('shape'), tensor.get('data_offsets')
            if (tensor.get('dtype') != 'BF16' or not isinstance(shape, list) or len(shape) > 8 or
                any(type(n) is not int or n < 0 for n in shape) or
                not isinstance(offsets, list) or len(offsets) != 2 or
                any(type(n) is not int or n < 0 for n in offsets) or
                offsets[1] - offsets[0] != math.prod(shape) * 2 or offsets[1] > size - 8 - length):
                raise ValueError(f'Invalid BF16 draft tensor {key}: {path}')
            tensors[key] = name
            if offsets[1] > offsets[0]: spans.append(offsets)
        spans.sort()
        if any(a[1] > b[0] for a, b in zip(spans, spans[1:])):
            raise ValueError(f'Overlapping draft tensors: {path}')
        files['draft/' + name] = path
    if not tensors: raise ValueError(f'No draft tensors: {directory}')
    if mapping is not None and mapping != tensors:
        raise ValueError(f'Draft shard index does not match checkpoint tensors: {index}')
    return files

def check_compact(config, chosen):
    compact = request.get('compact') or {}
    if chosen is None or not compact.get('enabled'): return
    capacity = int(compact.get('capacity') or 98304)
    if not 512 <= capacity <= 98304 or capacity % 256:
        raise ValueError('compact capacity 必须在 512–98304 之间，且为 256 的倍数')
    ranking = compact.get('ranking')
    if not ranking or not Path(ranking).is_absolute():
        raise ValueError('compact 开启时请选择 ranking 文件的本地绝对路径')
    path = Path(ranking).resolve(strict=True)
    vocab = config.get('text_config', config).get('vocab_size')
    with path.open('rb') as stream:
        prefix = stream.read(12)
        if len(prefix) != 12 or prefix[:8] != b'SPLCHD02':
            raise ValueError(f'compact ranking 需要 SPLCHD02 格式：{path}')
        count = struct.unpack('<I', prefix[8:])[0]
        if type(vocab) is not int or count != vocab or path.stat().st_size != 12 + count * 4:
            raise ValueError(f'compact ranking 大小或词表不匹配（target={vocab}, ranking={count}）：{path}')
        data = stream.read()
    values = struct.unpack(f'<{count}I', data)
    if len(set(values)) != count or any(value >= count for value in values):
        raise ValueError(f'compact ranking 不是完整词表排列：{path}')

def check_model(config, metadata, draft):
    # Reuse the selected engine's full configuration rules, not shape matching.
    with tempfile.TemporaryDirectory(prefix='.checking-', dir=root) as scratch:
        scratch = Path(scratch)
        target = scratch / 'config.json'
        target.write_bytes(encoded(config))
        arguments = [request['native'], 'model-check', 'gguf' if metadata is not None else 'mlx-affine', 'none', str(target)]
        if metadata is not None:
            path = scratch / 'gguf.json'
            path.write_bytes(encoded(metadata))
            arguments.append(str(path))
        if draft is not None: arguments.append(str(draft / 'config.json'))
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise ValueError(f'Splash 原生兼容性检查失败（drafter: {draft or "关闭"}）：{result.stderr.strip() or result.stdout.strip()}')
        family = json.loads(result.stdout)['family']
    # model-check identifies the family before the loader enforces its required draft.
    if draft is None and family not in {'Qwen3.5-4B', 'Kev-4B', 'Kev-0.8B', 'D3-lite', 'D3-mini', 'Julia-1', 'Laya'}:
        raise ValueError(f'{family} 需要匹配的 drafter；请选择本地目录并启用 drafter')
    return family

def select_draft():
    policy = request.get('drafter')
    previous = request.get('previous')
    old = {}
    if policy is None and previous and (Path(previous) / 'model.json').is_file():
        try:
            old = read_json(Path(previous) / 'model.json')
        except (ValueError, OSError):
            pass  # An obsolete directory is only a hint, never a dependency.
    recorded = (old.get('sources') or {}).get('draft')
    if policy is None and recorded:
        raise ValueError(f'旧 drafter 绑定待修复：{recorded.get("repo", "未知目录")}；请选择本地目录，或在支持的模型上关闭 drafter')
    policy = policy or dict(enabled=False, path=None)
    chosen = None
    selected_files = {}
    draft_type = None
    if policy['enabled']:
        location = policy.get('path')
        if not location or not Path(location).is_absolute():
            raise ValueError('已启用 drafter，请选择本地绝对目录')
        try:
            chosen = Path(location).resolve(strict=True)
            if not stable(chosen): raise ValueError('drafter 不能保存在临时 worktree 中')
            draft = read_json(chosen / 'config.json')
            draft_type = ', '.join(draft.get('architectures', []))
            found = draft_files(chosen)
            selected_files = {name: path.resolve(strict=True) for name, path in found.items()}
        except (ValueError, OSError, TypeError, KeyError) as error:
            raise ValueError(f'drafter 文件检查失败：{location}：{error}') from error
    return policy, chosen, draft_type, selected_files

def prepare_public(targets):
    from install.local import prepare_local_model

    _, chosen, _, selected_files = select_draft()
    before = {str(path): identity(path) for path in set(targets) | set(selected_files.values())}
    target = targets[0] if all(path.suffix == '.gguf' for path in targets) else targets[0].parent
    if target.is_dir() and any(path.parent != target for path in targets):
        raise ValueError('Selected MLX shards must share one model directory')
    directory = Path(prepare_local_model(
        target, draft=chosen, language_only=True, models_dir=root)).resolve(strict=True)
    if not directory.is_relative_to(root.resolve()):
        raise ValueError('Splash public preparation returned a directory outside GMD ownership')
    record = read_json(directory / 'model.json')
    entries = record['files']
    actual_targets = {(directory / name).resolve(strict=True) for name in entries
                      if name.startswith('target/') and name.endswith(('.gguf', '.safetensors'))}
    if actual_targets != set(targets):
        raise ValueError('Splash public preparation target differs from the selected model')
    actual_draft = {name: (directory / name).resolve(strict=True)
                    for name in entries if name.startswith('draft/')}
    # The public installer resolves an index into weight shards; the index is
    # an input to validate/protect, not a file the native assembly loads.
    expected_draft = {name: path for name, path in selected_files.items()
                      if name != 'draft/model.safetensors.index.json'}
    if actual_draft != expected_draft:
        raise ValueError('Splash public preparation drafter differs from the explicit selection; '
                         'no cached or implicit drafter is accepted')
    if record.get('vision_format') != 'none':
        raise ValueError('Splash public preparation must serve text only')
    check_compact(read_json(directory / 'config.json'), chosen)
    if before != {path: identity(Path(path)) for path in before}:
        raise ValueError('Model files changed during public preparation')
    return directory

def prepare():
    targets = [Path(path).resolve(strict=True) for path in request['files']]
    if not targets or any(not stable(path) for path in targets):
        raise ValueError('Selected model must be stored outside temporary worktrees')
    if (engine / 'install' / 'local.py').is_file():
        return prepare_public(targets)
    if request.get('requires_public_preparation'):
        raise ValueError('当前 Splash 模型目录接口需要 install.local.prepare_local_model；请修复引擎安装')
    files = {'target/' + path.name: path for path in targets}
    if len(files) != len(targets):
        raise ValueError('Duplicate model shard names')
    generated = {}
    adapters = {}
    adapters['native'] = hashlib.sha256(Path(request['native']).read_bytes()).hexdigest()
    metadata = None
    gguf_target = all(path.suffix == '.gguf' for path in targets)
    if gguf_target:
        from install import gguf
        adapters['gguf'] = hashlib.sha256(Path(gguf.__file__).read_bytes()).hexdigest()
        generated.update(gguf.derived_files(targets[0]))
        metadata = gguf.scalar_metadata(gguf.Metadata(targets[0]))
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

    policy, chosen, draft_type, selected_files = select_draft()
    files.update(selected_files)
    check_compact(config, chosen)
    family = check_model(config, metadata, chosen)

    inputs = dict(version=2, model=request['model'], adapter=adapters, drafter=policy,
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
                      family=family,
                      gmd_drafter=dict(enabled=chosen is not None, directory=str(chosen) if chosen else None, type=draft_type),
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
