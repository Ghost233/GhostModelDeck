import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'model_library.dart';
import 'local_model_package.dart';
import 'engine_catalog.dart';
import 'llama_engine.dart';
import 'model_run_dialog.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.library,
    required this.libraryPath,
    this.engines,
  });

  final ModelLibrary library;
  final String libraryPath;
  final EngineCatalog? engines;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _selected = <String>{};
  final _variantIds = <String, String>{};
  final _expanded = <String>{};
  final _stopping = <String>{};
  final _filter = TextEditingController();
  LibraryState? _packageState;
  String? _packagePath;
  Future<LocalModelPackages>? _packageFuture;
  String? _operationError;
  bool _deleting = false;
  bool _verifying = false;
  bool _awaitingScan = false;
  int _scanGeneration = 0;
  StreamSubscription<EngineCatalogState>? _engineChanges;

  @override
  void initState() {
    super.initState();
    _engineChanges = widget.engines?.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _scan();
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engines != widget.engines) {
      _engineChanges?.cancel();
      _engineChanges = widget.engines?.changes.listen((_) {
        if (mounted) setState(() {});
      });
    }
    if (oldWidget.libraryPath != widget.libraryPath ||
        oldWidget.library != widget.library) {
      _selected.clear();
      _variantIds.clear();
      _expanded.clear();
      _scan();
    }
  }

  void _scan() {
    final path = widget.libraryPath;
    final library = widget.library;
    final generation = ++_scanGeneration;
    _operationError = null;
    _selected.clear();
    _awaitingScan = path.isNotEmpty;
    if (path.isNotEmpty) {
      library.scan(Directory(path)).then((_) {
        if (mounted &&
            generation == _scanGeneration &&
            widget.library == library &&
            widget.libraryPath == path) {
          setState(() {
            _awaitingScan = false;
            _packageState = null;
          });
        }
      });
    }
  }

  Future<void> _delete(List<String> artifactIds) async {
    setState(() {
      _deleting = true;
      _operationError = null;
    });
    try {
      final plan = await widget.library.prepareDeletion(artifactIds);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除所选模型'),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${plan.files.length} 个文件 · ${_size(plan.sizeBytes)}'),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      plan.files
                          .map(
                            (file) =>
                                '${file.path}  (${_size(file.sizeBytes)})',
                          )
                          .join('\n'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      await widget.library.delete(plan, confirmed: confirmed == true);
      if (mounted) _selected.clear();
    } on LibraryException catch (error) {
      if (mounted) _operationError = error.message;
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _verify(List<String> artifactIds) async {
    final path = widget.libraryPath;
    final library = widget.library;
    setState(() {
      _verifying = true;
      _operationError = null;
    });
    try {
      await library.verify(artifactIds);
    } on LibraryException catch (error) {
      if (mounted && widget.libraryPath == path && widget.library == library) {
        _operationError = error.message;
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  void dispose() {
    _engineChanges?.cancel();
    _filter.dispose();
    super.dispose();
  }

  Future<LocalModelPackages> _packagesFor(LibraryState state) {
    if (!identical(_packageState, state) ||
        _packagePath != widget.libraryPath) {
      _packageState = state;
      _packagePath = widget.libraryPath;
      _packageFuture =
          widget.libraryPath.isEmpty || _awaitingScan || state.scanning
          ? Future.value(
              LocalModelPackages(packages: [], residualArtifacts: []),
            )
          : LocalModelPackages.discover(
              Directory(state.rootPath ?? widget.libraryPath),
              state.artifacts,
            );
    }
    return _packageFuture!;
  }

  LocalModelVariant _variant(LocalModelPackage package) =>
      package.variants.firstWhere(
        (variant) => variant.id == _variantIds[package.id],
        orElse: () => package.variants.first,
      );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LibraryState>(
      stream: widget.library.changes,
      initialData: widget.library.state,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        return FutureBuilder<LocalModelPackages>(
          future: _packagesFor(state),
          builder: (context, grouped) {
            final busy = _deleting || _verifying;
            final scanning =
                widget.libraryPath.isNotEmpty &&
                (_awaitingScan ||
                    state.scanning ||
                    grouped.connectionState != ConnectionState.done);
            final catalog = scanning ? null : grouped.data;
            final all = catalog?.packages ?? <LocalModelPackage>[];
            final filter = _filter.text.trim().toLowerCase();
            final packages = all
                .where((package) => package.name.toLowerCase().contains(filter))
                .toList();
            final chosen = all
                .where((package) => _selected.contains(package.id))
                .toList();
            final verifyIds = chosen
                .expand((package) => _variant(package).artifactIds)
                .toSet()
                .toList();
            final deleteIds = chosen
                .expand((package) => package.artifactIds)
                .toSet()
                .toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '模型库',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '扫描',
                      onPressed: scanning || busy || widget.libraryPath.isEmpty
                          ? null
                          : () => setState(_scan),
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      onPressed: verifyIds.isEmpty || scanning || busy
                          ? null
                          : () => _verify(verifyIds),
                      icon: const Icon(Icons.fact_check_outlined, size: 18),
                      label: const Text('核验'),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      onPressed: deleteIds.isEmpty || scanning || busy
                          ? null
                          : () => _delete(deleteIds),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除模型'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if ((!_awaitingScan && state.error != null) ||
                    _operationError != null ||
                    grouped.hasError)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _operationError ??
                          state.error ??
                          grouped.error.toString(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _filter,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '筛选模型',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(width: 36),
                      Expanded(
                        child: Text(
                          '模型',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      SizedBox(
                        width: 120,
                        child: Text(
                          '变体',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      SizedBox(
                        width: 130,
                        child: Text(
                          '状态',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      SizedBox(
                        width: 80,
                        child: Text(
                          '大小',
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      SizedBox(width: 64),
                      SizedBox(width: 28),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: scanning
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : packages.isEmpty
                      ? const Center(child: Text('没有匹配的模型包'))
                      : ListView.separated(
                          itemCount: packages.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (context, index) {
                            final package = packages[index];
                            final variant = _variant(package);
                            return Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 36,
                                        child: Checkbox(
                                          value: _selected.contains(package.id),
                                          onChanged: busy
                                              ? null
                                              : (_) => _toggle(package.id),
                                        ),
                                      ),
                                      Expanded(
                                        child: Tooltip(
                                          message: package.directoryPath,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                package.name.split('/').last,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleSmall,
                                              ),
                                              if (package.name.contains(
                                                '/',
                                              )) ...[
                                                const SizedBox(height: 3),
                                                Text(
                                                  package.name.substring(
                                                    0,
                                                    package.name.lastIndexOf(
                                                      '/',
                                                    ),
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 120,
                                        child: package.variants.length == 1
                                            ? Text(
                                                variant.label,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall,
                                              )
                                            : DropdownButton<String>(
                                                value: variant.id,
                                                isExpanded: true,
                                                underline: const SizedBox(),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall,
                                                items: package.variants
                                                    .map(
                                                      (item) =>
                                                          DropdownMenuItem(
                                                            value: item.id,
                                                            child: Text(
                                                              item.label,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                          ),
                                                    )
                                                    .toList(),
                                                onChanged: busy
                                                    ? null
                                                    : (value) => setState(
                                                        () =>
                                                            _variantIds[package
                                                                    .id] =
                                                                value!,
                                                      ),
                                              ),
                                      ),
                                      SizedBox(
                                        width: 130,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: JevStatusChip(
                                            label: _variantStatus(variant),
                                            tone:
                                                variant.artifacts.any(
                                                  (asset) =>
                                                      asset.integrity ==
                                                      AssetIntegrity.corrupt,
                                                )
                                                ? JevStatusTone.error
                                                : JevStatusTone.neutral,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 80,
                                        child: Tooltip(
                                          message:
                                              '当前变体 ${_size(variant.sizeBytes)}',
                                          child: Text(
                                            _size(package.sizeBytes),
                                            textAlign: TextAlign.right,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 64,
                                        child: TextButton(
                                          onPressed:
                                              busy ||
                                                  widget.engines == null ||
                                                  !variant.artifacts.any(
                                                    (asset) =>
                                                        asset.kind ==
                                                            AssetKind
                                                                .decision &&
                                                        asset.integrity ==
                                                            AssetIntegrity
                                                                .complete,
                                                  )
                                              ? null
                                              : () => showModelRunDialog(
                                                  context,
                                                  catalog: widget.engines!,
                                                  library: widget.library,
                                                  modelPackage: package,
                                                  variant: variant,
                                                ),
                                          child: const Text('运行'),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 28,
                                        child: IconButton(
                                          tooltip: '文件详情',
                                          padding: EdgeInsets.zero,
                                          onPressed: () => setState(() {
                                            if (!_expanded.add(package.id)) {
                                              _expanded.remove(package.id);
                                            }
                                          }),
                                          icon: Icon(
                                            _expanded.contains(package.id)
                                                ? Icons.expand_less
                                                : Icons.expand_more,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                for (final run
                                    in widget.engines?.runsFor(
                                          variant.artifactIds,
                                        ) ??
                                        <EngineRun>[])
                                  _runRow(run, busy),
                                if (_expanded.contains(package.id))
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      44,
                                      4,
                                      12,
                                      12,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: SelectableText(
                                        package.details
                                            .map(_details)
                                            .join('\n\n'),
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                ),
                if (catalog != null && catalog.residualArtifacts.isNotEmpty)
                  ExpansionTile(
                    dense: true,
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '目录其他文件 (${catalog.residualArtifacts.length}) · 只读',
                      style: const TextStyle(fontSize: 12),
                    ),
                    children: [
                      SizedBox(
                        height: 140,
                        child: SingleChildScrollView(
                          child: SelectableText(
                            catalog.residualArtifacts
                                .map(_details)
                                .join('\n\n'),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '${packages.length} / ${all.length} 个模型包 · 已选 ${chosen.length} 个',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _toggle(String id) => setState(() {
    if (!_selected.add(id)) _selected.remove(id);
  });

  Widget _runRow(EngineRun run, bool busy) {
    final instance = run.instance;
    final stopKey = '${run.engine.id}:${instance.id}';
    final stopping = _stopping.contains(stopKey);
    final active =
        instance.status == LlamaInstanceStatus.ready ||
        instance.status == LlamaInstanceStatus.starting;
    final theme = Theme.of(context);
    final failure = instance.status == LlamaInstanceStatus.failed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 4, 32, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(run.engine.name, style: theme.textTheme.bodySmall),
              const SizedBox(width: 10),
              JevStatusChip(
                label: stopping
                    ? '停止中'
                    : switch (instance.status) {
                        LlamaInstanceStatus.starting => '启动中',
                        LlamaInstanceStatus.ready => '运行中',
                        LlamaInstanceStatus.stopped => '已停止',
                        LlamaInstanceStatus.failed => '失败',
                      },
                tone: stopping
                    ? JevStatusTone.neutral
                    : failure
                    ? JevStatusTone.error
                    : instance.status == LlamaInstanceStatus.ready
                    ? JevStatusTone.success
                    : JevStatusTone.neutral,
              ),
              const Spacer(),
              if (active)
                TextButton(
                  onPressed: busy || stopping
                      ? null
                      : () async {
                          setState(() {
                            _stopping.add(stopKey);
                            _operationError = null;
                          });
                          try {
                            await widget.engines!
                                .providerFor(run.engine.id)
                                .stop(instance.id);
                          } catch (error) {
                            if (mounted) {
                              setState(
                                () => _operationError = error.toString(),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _stopping.remove(stopKey));
                            }
                          }
                        },
                  child: Text(stopping ? '停止中' : '停止'),
                ),
            ],
          ),
          if (instance.error != null)
            Text(
              instance.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (instance.lastResult != null)
            ExpansionTile(
              dense: true,
              tilePadding: EdgeInsets.zero,
              title: Text(
                '结果 · ${instance.lastResult!.choice}',
                style: theme.textTheme.bodySmall,
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    instance.lastResult!.rawResponse,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _variantStatus(LocalModelVariant variant) {
  if (variant.artifacts.length == 1) return _status(variant.artifacts.single);
  if (variant.artifacts.any(
    (artifact) => artifact.integrity == AssetIntegrity.corrupt,
  )) {
    return '完整性不符';
  }
  return '未支持 · 包待确认';
}

String _status(LibraryArtifact artifact) {
  if (artifact.integrity == AssetIntegrity.corrupt) return '文件损坏';
  if (artifact.kind == AssetKind.adapter) return 'Adapter · 不完整';
  if (artifact.kind == AssetKind.encoder) return 'Encoder · 待配套';
  if (artifact.integrity == AssetIntegrity.incomplete) return '缺文件 / Metadata';
  if (artifact.kind == AssetKind.chat) {
    return artifact.integrity == AssetIntegrity.complete &&
            artifact.fingerprintsVerified
        ? '普通聊天模型'
        : '聊天 · 文件待核验';
  }
  if (artifact.kind == AssetKind.unknown) return '已发现 · 未知';
  return artifact.integrity == AssetIntegrity.complete
      ? artifact.fingerprintsVerified
            ? '完整 · 待能力验证'
            : '文件齐全 · 待核验'
      : '已发现 · 文件待核验';
}

String _details(LibraryArtifact artifact) => [
  if (artifact.repoId != null) '仓库  ${artifact.repoId}',
  if (artifact.revision != null) 'Revision  ${artifact.revision}',
  if (artifact.license != null) '许可证  ${artifact.license}',
  if (artifact.architecture != null) '架构  ${artifact.architecture}',
  if (artifact.decisionType != null) '决策类型  ${artifact.decisionType}',
  '来源  ${artifact.sourceVerified ? '上游校验通过' : '未验证'}',
  ...artifact.diagnostics,
  ...artifact.files.map(
    (file) => [
      file.path,
      if (file.sha256 != null)
        'SHA-256 本地全量内容  ${file.sha256}'
      else
        '基础清单 · ${file.sizeBytes} bytes · ${file.modifiedAtUtc?.toIso8601String() ?? '时间未知'}',
      if (file.sha256 == null && file.prefixSha256 != null)
        '前缀 ${file.prefixBytes} bytes SHA-256  ${file.prefixSha256}',
    ].join('\n'),
  ),
].join('\n');

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
