import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'model_library.dart';
import 'local_model_package.dart';
import 'engine_catalog.dart';
import 'engine_runtime.dart';
import 'engine_launch_editor.dart';
import 'llama_engine.dart';
import 'model_run_dialog.dart';
import 'public_gateway.dart';
import 'management_table.dart';

typedef _ModelRow = ({LocalModelPackage package, LocalModelVariant variant});

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.library,
    required this.libraryPath,
    this.libraryPaths,
    this.onCreateInstance,
    this.engines,
    this.publicRoutes,
    this.publicGateway,
  });

  final ModelLibrary library;
  final String libraryPath;
  final List<String>? libraryPaths;
  final void Function(String artifactId)? onCreateInstance;
  List<String> get roots => libraryPaths ?? [libraryPath];
  final EngineCatalog? engines;
  final PublicModelRoutes? publicRoutes;
  final PublicGatewayServer? publicGateway;

  /// 启动模型集合配置：用户把某个运行组合显式设为推理服务启动时加载。

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _selected = <String>{};
  final _stopping = <String>{};
  final _starting = <String>{};
  LibraryState? _packageState;
  String? _packagePath;
  Future<LocalModelPackages>? _packageFuture;
  String? _operationError;
  bool _deleting = false;
  bool _awaitingScan = false;
  int _scanGeneration = 0;
  StreamSubscription<EngineCatalogState>? _engineChanges;
  StreamSubscription<void>? _routeChanges;

  @override
  void initState() {
    super.initState();
    _engineChanges = widget.engines?.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _routeChanges = widget.publicRoutes?.changes.listen((_) {
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
    if (oldWidget.publicRoutes != widget.publicRoutes) {
      _routeChanges?.cancel();
      _routeChanges = widget.publicRoutes?.changes.listen((_) {
        if (mounted) setState(() {});
      });
    }
    if (oldWidget.roots.join('\n') != widget.roots.join('\n') ||
        oldWidget.library != widget.library) {
      _selected.clear();
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
      library.scanDirectories(widget.roots.map(Directory.new).toList()).then((
        _,
      ) {
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

  Future<void> _startModel(LocalModelVariant variant) async {
    final catalog = widget.engines;
    if (catalog == null || !_starting.add(variant.id)) return;
    setState(() => _operationError = null);
    try {
      await catalog.refresh();
      final asset = variant.artifacts
          .where(
            (a) => [
              AssetKind.chat,
              AssetKind.decision,
              AssetKind.embedding,
            ].contains(a.kind),
          )
          .single;
      final preferred = catalog.preferredEngineFor(asset.id);
      final entries = catalog.state.entries.where(
        (e) => e.status == LlamaInstallationStatus.installed,
      );
      final entry = preferred == null
          ? entries.firstOrNull
          : entries.where((e) => e.id == preferred).firstOrNull;
      if (entry == null) throw StateError('已保存的引擎不可用，请在参数中选择引擎');
      if (entry.family == EngineFamily.omlx) throw StateError('此引擎尚未接通模型运行');
      await catalog.runtimeFor(entry.id).startRuntime(asset.id);
    } catch (error) {
      if (mounted) setState(() => _operationError = error.toString());
    } finally {
      _starting.remove(variant.id);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _engineChanges?.cancel();
    _routeChanges?.cancel();
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
          : _discoverPackages(state);
    }
    return _packageFuture!;
  }

  Future<LocalModelPackages> _discoverPackages(LibraryState state) async {
    final packages = <LocalModelPackage>[];
    final roots = state.rootPaths.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final assigned = <String>{};
    for (final root in roots) {
      final assets = state.artifacts
          .where(
            (a) =>
                !assigned.contains(a.id) &&
                ['GGUF', 'Safetensors'].contains(a.format) &&
                a.files.any((f) => f.path.startsWith('$root/')),
          )
          .toList();
      assigned.addAll(assets.map((asset) => asset.id));
      final discovered = await LocalModelPackages.discover(
        Directory(root),
        assets,
      );
      packages.addAll(discovered.packages);
    }
    final unique = {for (final package in packages) package.id: package};
    return LocalModelPackages(
      packages: unique.values.toList(),
      residualArtifacts: [],
    );
  }

  List<String> _deletableIds(
    List<_ModelRow> rows,
    Iterable<_ModelRow> selected,
  ) {
    final chosen = selected.toList();
    final ids = chosen.map((row) => row.variant.id).toSet();
    final retained = rows
        .where((row) => !ids.contains(row.variant.id))
        .expand((row) => row.variant.artifactIds)
        .toSet();
    return chosen
        .expand((row) => row.variant.artifactIds)
        .where((id) => !retained.contains(id))
        .toSet()
        .toList();
  }

  Future<void> _revealModelDirectory(String path) async {
    try {
      await const MethodChannel('com.ghost233.ghostmodeldeck/native')
          .invokeMethod<void>('revealInFinder', {'path': path});
    } catch (error) {
      if (mounted) setState(() => _operationError = 'Finder 打开失败：$error');
    }
  }

  Future<void> _showModelDetails(_ModelRow row) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(row.package.name),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width,
        height: MediaQuery.sizeOf(context).height * .6,
        child: StreamBuilder<EngineCatalogState>(
          stream: widget.engines?.changes,
          initialData: widget.engines?.state,
          builder: (context, _) => StreamBuilder<void>(
            stream: widget.publicRoutes?.changes,
            builder: (context, _) => ListView(
              children: [
                Text('${row.variant.label} · ${_size(row.variant.sizeBytes)}'),
                const SizedBox(height: 12),
                for (final file in row.variant.files.take(20))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText(
                      '${file.path} · ${_size(file.sizeBytes)}',
                    ),
                  ),
                if (row.variant.files.length > 20)
                  Text('共 ${row.variant.files.length} 个文件；完整目录可在 Finder 查看。'),
                if (widget.onCreateInstance == null) ...[
                  for (final run
                      in widget.engines
                              ?.runsFor(row.variant.artifactIds)
                              .take(20) ??
                          <EngineRun>[])
                    _runRow(run, _deleting),
                  if (widget.publicRoutes != null &&
                      row.variant.artifacts.length == 1 &&
                      [
                        AssetKind.chat,
                        AssetKind.embedding,
                      ].contains(row.variant.artifacts.single.kind))
                    _publicApiRow(row.variant.artifacts.single),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _revealModelDirectory(row.package.directoryPath),
          child: const Text('在 Finder 中显示'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _tableActions(_ModelRow row, List<_ModelRow> all, bool busy) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TextButton(
        key: ValueKey('model-start:${row.variant.id}'),
        onPressed: busy
            ? null
            : widget.onCreateInstance != null
            ? () => widget.onCreateInstance!(row.variant.artifactIds.first)
            : widget.engines == null || _starting.contains(row.variant.id)
            ? null
            : () => _startModel(row.variant),
        child: Text(widget.onCreateInstance == null ? '运行' : '创建实例'),
      ),
      if (widget.onCreateInstance == null)
        IconButton(
          key: ValueKey('model-parameters:${row.variant.id}'),
          tooltip: '模型参数',
          icon: const Icon(Icons.tune, size: 18),
          onPressed: busy || widget.engines == null
              ? null
              : () => showModelRunDialog(
                  context,
                  catalog: widget.engines!,
                  library: widget.library,
                  modelPackage: row.package,
                  variant: row.variant,
                ),
        ),
      PopupMenuButton<String>(
        key: ValueKey('model-more:${row.variant.id}'),
        tooltip: '更多',
        enabled: !busy,
        onSelected: (action) async {
          if (action == 'details') {
            await _showModelDetails(row);
          } else if (action == 'folder') {
            await _revealModelDirectory(row.package.directoryPath);
          } else {
            await _delete(_deletableIds(all, [row]));
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'details', child: Text('文件详情')),
          PopupMenuItem(value: 'folder', child: Text('在 Finder 中显示')),
          PopupMenuItem(value: 'delete', child: Text('删除模型')),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => StreamBuilder<LibraryState>(
    stream: widget.library.changes,
    initialData: widget.library.state,
    builder: (context, snapshot) {
      final state = snapshot.data!;
      return FutureBuilder<LocalModelPackages>(
        future: _packagesFor(state),
        builder: (context, grouped) {
          final busy = _deleting;
          final scanning =
              widget.libraryPath.isNotEmpty &&
              (_awaitingScan ||
                  state.scanning ||
                  grouped.connectionState != ConnectionState.done);
          final rows = <_ModelRow>[
            for (final package
                in scanning
                    ? <LocalModelPackage>[]
                    : grouped.data?.packages ?? <LocalModelPackage>[])
              for (final variant in package.variants)
                (package: package, variant: variant),
          ];
          final chosen = rows
              .where((row) => _selected.contains(row.variant.id))
              .toList();
          final deleteIds = _deletableIds(rows, chosen);
          final error =
              _operationError ??
              state.error ??
              widget.publicRoutes?.error ??
              (grouped.hasError ? grouped.error.toString() : null);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('模型库', style: Theme.of(context).textTheme.headlineSmall),
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
                    onPressed: deleteIds.isEmpty || scanning || busy
                        ? null
                        : () => _delete(deleteIds),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除模型'),
                  ),
                ],
              ),
              if (error != null)
                Padding(
                  key: const Key('library-operation-error'),
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: scanning
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : ManagementTable<_ModelRow>(
                        id: 'models',
                        items: rows,
                        rowKey: (row) => row.variant.id,
                        searchText: (row) =>
                            '${row.package.name} ${row.variant.label} ${row.package.directoryPath} ${row.variant.files.map((file) => file.path).join(' ')}',
                        emptyLabel: '没有匹配的模型包',
                        columns: [
                          ManagementColumn(
                            label: '模型名',
                            minWidth: 230,
                            flex: 2,
                            compare: (a, b) =>
                                a.package.name.compareTo(b.package.name),
                            cell: (row) => Row(
                              children: [
                                Checkbox(
                                  value: _selected.contains(row.variant.id),
                                  onChanged: busy
                                      ? null
                                      : (_) => _toggle(row.variant.id),
                                ),
                                Expanded(
                                  child: Text(
                                    row.package.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ManagementColumn(
                            label: '格式',
                            minWidth: 110,
                            flex: 0,
                            compare: (a, b) => a.variant.artifacts.first.format
                                .compareTo(b.variant.artifacts.first.format),
                            cell: (row) => Text(
                              row.variant.artifacts
                                  .map((asset) => asset.format)
                                  .toSet()
                                  .join(' / '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ManagementColumn(
                            label: '量化',
                            minWidth: 110,
                            flex: 0,
                            compare: (a, b) =>
                                (a.variant.artifacts.first.quantization ?? '')
                                    .compareTo(
                                      b.variant.artifacts.first.quantization ??
                                          '',
                                    ),
                            cell: (row) => Text(
                              row.variant.artifacts.first.quantization ?? '—',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ManagementColumn(
                            label: '大小',
                            minWidth: 100,
                            flex: 0,
                            compare: (a, b) => a.variant.sizeBytes.compareTo(
                              b.variant.sizeBytes,
                            ),
                            cell: (row) => Text(_size(row.variant.sizeBytes)),
                          ),
                          ManagementColumn(
                            label: '所在目录',
                            minWidth: 230,
                            flex: 3,
                            compare: (a, b) => a.package.directoryPath
                                .compareTo(b.package.directoryPath),
                            cell: (row) => Tooltip(
                              message: row.package.directoryPath,
                              child: Text(
                                row.package.directoryPath,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          ManagementColumn(
                            label: '操作',
                            minWidth: 200,
                            flex: 0,
                            cell: (row) => _tableActions(row, rows, busy),
                          ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${rows.length} 个模型变体 · 已选 ${chosen.length} 个',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      );
    },
  );

  void _toggle(String id) => setState(() {
    if (!_selected.add(id)) _selected.remove(id);
  });

  /// Public API exposure is an explicit business operation: enable/disable
  /// and copy the connection info. Loading never happens implicitly.
  Widget _publicApiRow(LibraryArtifact artifact) {
    final routes = widget.publicRoutes!;
    final gateway = widget.publicGateway;
    final enabled = routes.isEnabled(artifact.id);
    final baseUrl = gateway?.baseUrl;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 32, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            enabled ? Icons.public : Icons.public_off,
            size: 15,
            color: enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          if (!enabled)
            TextButton(
              onPressed: () => _setPublic(artifact, true),
              child: const Text('启用公开 API'),
            )
          else ...[
            Expanded(
              child: SelectableText(
                [
                  '公开模型 ID  ${routes.publicIdFor(artifact.id)}',
                  if (baseUrl != null)
                    'Base URL  $baseUrl/v1'
                  else
                    '公开 API 未运行（${gateway?.state.name ?? '未知'}'
                        '${gateway?.error != null ? '：${gateway!.error}' : ''}）',
                ].join('\n'),
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: '复制公开模型 ID',
              iconSize: 16,
              padding: EdgeInsets.zero,
              onPressed: () =>
                  _copy('公开模型 ID', routes.publicIdFor(artifact.id)),
              icon: const Icon(Icons.copy_outlined),
            ),
            if (baseUrl != null)
              IconButton(
                tooltip: '复制 Base URL',
                iconSize: 16,
                padding: EdgeInsets.zero,
                onPressed: () => _copy('Base URL', '$baseUrl/v1'),
                icon: const Icon(Icons.link_outlined),
              ),
            TextButton(
              onPressed: () => _setPublic(artifact, false),
              child: const Text('停用'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _setPublic(LibraryArtifact artifact, bool enable) async {
    try {
      if (enable) {
        await widget.publicRoutes!.enable(artifact.id);
      } else {
        await widget.publicRoutes!.disable(artifact.id);
      }
      _operationError = null;
    } catch (error) {
      if (mounted) setState(() => _operationError = error.toString());
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已复制$label')));
    }
  }

  Widget _runRow(EngineRun run, bool busy) {
    final instance = run.instance;
    final legacy = run.engine.family == EngineFamily.llamaCpp
        ? widget.engines!
              .providerFor(run.engine.id)
              .state
              .instances
              .where((value) => value.id == instance.id)
              .firstOrNull
        : null;
    final stopKey = '${run.engine.id}:${instance.id}';
    final stopping =
        _stopping.contains(stopKey) ||
        instance.status == RuntimeInstanceStatus.stopping;
    final active =
        instance.status == RuntimeInstanceStatus.ready ||
        instance.status == RuntimeInstanceStatus.starting ||
        instance.status == RuntimeInstanceStatus.stopping ||
        (instance.status == RuntimeInstanceStatus.failed &&
            instance.hasLiveProcess);
    final theme = Theme.of(context);
    final failure = instance.status == RuntimeInstanceStatus.failed;
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
                        RuntimeInstanceStatus.starting => '启动中',
                        RuntimeInstanceStatus.ready => '运行中',
                        RuntimeInstanceStatus.stopping => '停止中',
                        RuntimeInstanceStatus.stopped => '已停止',
                        RuntimeInstanceStatus.failed => '失败',
                      },
                tone: stopping
                    ? JevStatusTone.neutral
                    : failure
                    ? JevStatusTone.error
                    : instance.status == RuntimeInstanceStatus.ready
                    ? JevStatusTone.success
                    : JevStatusTone.neutral,
              ),
              const Spacer(),
              if (legacy?.launchCommand != null)
                IconButton(
                  tooltip: '实际启动命令',
                  icon: const Icon(Icons.terminal, size: 18),
                  onPressed: () => _showLaunchCommand(legacy!),
                ),

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
                                .runtimeFor(run.engine.id)
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
          if (legacy?.lastResult != null)
            ExpansionTile(
              dense: true,
              tilePadding: EdgeInsets.zero,
              title: Text(
                '结果 · ${legacy!.lastResult!.choice}',
                style: theme.textTheme.bodySmall,
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    legacy.lastResult!.rawResponse,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _showLaunchCommand(LlamaInstance instance) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('实际启动命令'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: EngineLaunchCommandView(
            command: instance.launchCommand!,
            title: '本次实际启动命令',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
