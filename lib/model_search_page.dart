import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'download_panel.dart';
import 'hf_model_browser.dart';
import 'model_package.dart';

class ModelSearchPage extends StatefulWidget {
  const ModelSearchPage({
    super.key,
    required this.browser,
    required this.downloads,
    required this.libraryPath,
    this.onDownloadStarted,
    this.onPackageSelected,
  });

  final HfModelBrowser browser;
  final DownloadTaskController downloads;
  final String libraryPath;
  final VoidCallback? onDownloadStarted;
  final ValueChanged<ModelPackageSelection?>? onPackageSelected;

  @override
  State<ModelSearchPage> createState() => _ModelSearchPageState();
}

class _ModelSearchPageState extends State<ModelSearchPage> {
  late final TextEditingController _query;
  late final TextEditingController _revision;
  late StreamSubscription<HfBrowserState> _subscription;
  late HfBrowserState _state;
  HfRepositoryFiles? _repository;
  List<ModelPackage> _packages = const [];
  ModelPackageSelection? _selection;

  @override
  void initState() {
    super.initState();
    _state = widget.browser.state;
    _query = TextEditingController(text: _state.query);
    _revision = TextEditingController(text: _state.requestedRevision);
    _readPackages(_state.repository);
    _subscription = widget.browser.changes.listen(_onState);
    _publishAfterFrame();
  }

  @override
  void didUpdateWidget(ModelSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.browser != widget.browser) {
      _subscription.cancel();
      _state = widget.browser.state;
      _query.text = _state.query;
      _revision.text = _state.requestedRevision;
      _readPackages(_state.repository);
      _subscription = widget.browser.changes.listen(_onState);
      _publishAfterFrame();
    }
  }

  void _publishAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPackageSelected?.call(_selection);
    });
  }

  void _onState(HfBrowserState state) {
    if (!mounted) return;
    final previous = _selection;
    setState(() {
      if (state.activeRepositoryId != _state.activeRepositoryId ||
          state.requestedRevision != _state.requestedRevision) {
        _revision.text = state.requestedRevision;
      }
      _state = state;
      _readPackages(state.repository);
    });
    if (!identical(previous, _selection)) {
      widget.onPackageSelected?.call(_selection);
    }
  }

  void _readPackages(HfRepositoryFiles? repository) {
    if (identical(_repository, repository)) return;
    _repository = repository;
    _packages = repository == null
        ? const []
        : ModelPackage.discover(repository);
    _selection = null;
    if (_packages.isEmpty) return;
    final model = _packages.firstWhere(
      (model) => model.variants.any((variant) => variant.canDownload),
      orElse: () => _packages.first,
    );
    _selection = _defaultVariant(model);
  }

  ModelPackageSelection? _defaultVariant(ModelPackage model) {
    if (model.variants.isEmpty) return null;
    final variant = model.variants.firstWhere(
      (variant) => variant.canDownload,
      orElse: () => model.variants.first,
    );
    return model.selectVariant(variant.id);
  }

  void _chooseModel(ModelPackage? model) {
    if (model == null) return;
    setState(() => _selection = _defaultVariant(model));
    widget.onPackageSelected?.call(_selection);
  }

  void _chooseVariant(String? id) {
    final selected = _selection;
    if (id == null || selected == null) return;
    setState(() => _selection = selected.modelPackage.selectVariant(id));
    widget.onPackageSelected?.call(_selection);
  }

  void _search() {
    _revision.text = 'main';
    widget.browser.search(_query.text);
  }

  void _selectRepository(String id) {
    _revision.text = 'main';
    widget.browser.selectRepository(id);
  }

  void _readRevision() {
    final id = _state.activeRepositoryId;
    if (id != null) {
      widget.browser.selectRepository(id, revision: _revision.text);
    }
  }

  void _showRevision() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        void read() {
          Navigator.of(dialogContext).pop();
          _readRevision();
        }

        return AlertDialog(
          title: const Text('版本'),
          content: SizedBox(
            width: 340,
            child: TextField(
              key: const ValueKey('model-revision-input'),
              controller: _revision,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Revision'),
              onSubmitted: (_) => read(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: read, child: const Text('读取')),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    _query.dispose();
    _revision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const JevPageHeader(title: '发现模型'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('model-search-input'),
                  controller: _query,
                  decoration: InputDecoration(
                    hintText: '在 Hugging Face 上搜索模型',
                    hintStyle:
                        Theme.of(context).inputDecorationTheme.hintStyle ??
                        TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: _search, child: const Text('搜索')),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child:
                _state.searchStatus == RequestStatus.idle &&
                    _state.activeRepositoryId == null
                ? Center(
                    child: Icon(
                      Icons.search_rounded,
                      size: 40,
                      color: Theme.of(context).colorScheme.onSurfaceVariant
                          .withValues(alpha: .3),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 292, child: _repositories()),
                      const SizedBox(width: 24),
                      Expanded(child: JevSurface(child: _model())),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _repositories() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('模型', style: Theme.of(context).textTheme.labelSmall),
              Text('下载量', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: switch (_state.searchStatus) {
            RequestStatus.idle => const SizedBox.shrink(),
            RequestStatus.loading => const _Loading(),
            RequestStatus.empty => const _Status('没有找到模型'),
            RequestStatus.failed => _Status(_state.searchError!),
            RequestStatus.ready => ListView.separated(
              itemCount: _state.repositories.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final repository = _state.repositories[index];
                return Material(
                  borderRadius: BorderRadius.circular(8),
                  color: _state.activeRepositoryId == repository.id
                      ? Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.05)
                      : Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _selectRepository(repository.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message: repository.id,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    repository.id.split('/').last,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontWeight:
                                              _state.activeRepositoryId ==
                                                  repository.id
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    repository.id.split('/').first,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(fontWeight: FontWeight.w400),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _count(repository.downloads),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          },
        ),
        if (_state.searchStatus == RequestStatus.ready)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_state.repositories.length} 个结果',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_state.searchOrigin == MetadataOrigin.cache)
                  _CacheBadge(_state.searchError),
              ],
            ),
          ),
      ],
    );
  }

  Widget _model() {
    if (_state.activeRepositoryId == null) {
      return Center(
        child: Text(
          '选择模型',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    final repository = _state.repository;
    final selection = _selection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: _state.activeRepositoryId!,
                child: Text(
                  _state.activeRepositoryId!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (_state.repositoryOrigin == MetadataOrigin.cache)
              _CacheBadge(_state.repositoryError),
            IconButton(
              tooltip: '版本',
              onPressed: _showRevision,
              icon: const Icon(Icons.history, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Expanded(
          child: switch (_state.repositoryStatus) {
            RequestStatus.loading => const _Loading(),
            RequestStatus.failed => _Status(_state.repositoryError!),
            RequestStatus.empty => const _Status('此版本没有模型包'),
            RequestStatus.idle => const SizedBox.shrink(),
            RequestStatus.ready =>
              selection == null
                  ? const _Status('没有可识别的模型包')
                  : ListView(
                      children: [
                        if (_packages.length > 1)
                          DropdownButtonFormField<ModelPackage>(
                            key: const ValueKey('model-package'),
                            initialValue: selection.modelPackage,
                            decoration: const InputDecoration(labelText: '模型'),
                            isExpanded: true,
                            onChanged: _chooseModel,
                            items: [
                              for (final model in _packages)
                                DropdownMenuItem(
                                  value: model,
                                  child: Text(
                                    model.label,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          )
                        else
                          Text(
                            selection.modelPackage.label,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontSize: 20),
                          ),
                        const SizedBox(height: 24),
                        DropdownButtonFormField<String>(
                          key: const ValueKey('model-variant'),
                          initialValue: selection.variant.id,
                          decoration: const InputDecoration(
                            labelText: '格式 / 量化',
                          ),
                          isExpanded: true,
                          onChanged: _chooseVariant,
                          items: [
                            for (final variant
                                in selection.modelPackage.variants)
                              DropdownMenuItem(
                                value: variant.id,
                                child: Text(
                                  '${variant.format} · ${variant.label}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _size(selection.variant.sizeBytes),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                        if (!selection.variant.canDownload) ...[
                          const SizedBox(height: 8),
                          Text(
                            selection.variant.unavailableReason ?? '暂不支持此变体',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        _details(repository!, selection),
                      ],
                    ),
          },
        ),
        DownloadPanel(
          downloads: widget.downloads,
          browser: widget.browser,
          modelPackage: selection?.modelPackage,
          variantId: selection?.variant.id,
          libraryPath: widget.libraryPath,
          onDownloadStarted: widget.onDownloadStarted,
        ),
      ],
    );
  }

  Widget _details(
    HfRepositoryFiles repository,
    ModelPackageSelection selection,
  ) {
    return ExpansionTile(
      key: ValueKey('details-${repository.revision}-${selection.variant.id}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text('详情', style: Theme.of(context).textTheme.bodySmall),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            repository.revision,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(fontWeight: FontWeight.w400),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            repository.summary.license ?? '许可证未提供',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 10),
        for (final file in selection.variant.files)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: [
                      file.path,
                      if (file.sha256 != null) 'SHA-256 ${file.sha256}',
                      if (file.blobId != null) 'Git blob ${file.blobId}',
                    ].join('\n'),
                    child: Text(
                      file.path,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _size(file.sizeBytes),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _size(int? bytes) {
  if (bytes == null) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

String _count(int? value) {
  if (value == null) return '—';
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '$value';
}

class _CacheBadge extends StatelessWidget {
  const _CacheBadge(this.error);

  final String? error;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: error ?? '缓存元数据',
    child: const Text('缓存', style: TextStyle(fontSize: 12)),
  );
}

class _Status extends StatelessWidget {
  const _Status(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 13),
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
