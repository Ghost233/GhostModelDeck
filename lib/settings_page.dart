import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'download_preferences.dart';
import 'model_downloader.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    required this.libraryPath,
    required this.onLibraryPathChanged,
    required this.pickLibraryDirectory,
  });

  final DownloadPreferences preferences;
  final String libraryPath;
  final Future<String> Function(String) onLibraryPathChanged;
  final Future<String?> Function() pickLibraryDirectory;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _saving = false;
  String? _error;

  Future<void> _saveSource(DownloadSource? source) async {
    if (source == null) return;
    await _save(() => widget.preferences.saveSource(source));
  }

  Future<void> _chooseDirectory() async {
    final path = await widget.pickLibraryDirectory();
    if (path == null || !mounted) return;
    await _save(() async {
      await widget.onLibraryPathChanged(path);
    });
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '设置无法保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          children: [
            const JevPageHeader(title: '设置'),
            Text('下载', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            JevSurface(
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_download_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text('默认下载来源', style: theme.textTheme.bodyMedium),
                  ),
                  SizedBox(
                    width: 190,
                    child: ListenableBuilder(
                      listenable: widget.preferences,
                      builder: (context, _) =>
                          DropdownButtonFormField<DownloadSource>(
                            key: ValueKey(widget.preferences.source),
                            initialValue: widget.preferences.source,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onChanged: _saving ? null : _saveSource,
                            items: const [
                              DropdownMenuItem(
                                value: DownloadSource.hf,
                                child: Text('HF 直连'),
                              ),
                              DropdownMenuItem(
                                value: DownloadSource.lmStudio,
                                child: Text('LM Studio 代理'),
                              ),
                            ],
                          ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text('模型库', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            JevSurface(
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('存放位置', style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 6),
                        Tooltip(
                          message: widget.libraryPath,
                          child: Text(
                            widget.libraryPath,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton(
                    onPressed: _saving ? null : _chooseDirectory,
                    child: const Text('选择目录'),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
