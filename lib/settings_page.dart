import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'download_preferences.dart';
import 'model_downloader.dart';
import 'software_update_pane.dart';

/// 设置页（Q4E 双栏布局）：左侧分类导航，右侧内容面板。
/// 原有下载来源/模型库设置归入「常规」，新增「软件更新」。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    required this.libraryPath,
    required this.onLibraryPathChanged,
    required this.pickLibraryDirectory,
    this.softwareUpdate,
  });

  final DownloadPreferences preferences;
  final String libraryPath;
  final Future<String> Function(String) onLibraryPathChanged;
  final Future<String?> Function() pickLibraryDirectory;

  /// 软件更新面板依赖；为 null（如测试夹具未注入）时面板降级为只读。
  final SoftwareUpdateConfig? softwareUpdate;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _saving = false;
  String? _error;
  int _pane = 0;

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

  Widget _navItem(String label, IconData icon, int index, Key key_) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _pane == index;
    return Padding(
      key: key_,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: selected
            ? scheme.onSurface.withValues(alpha: .06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          selected: selected,
          dense: true,
          minTileHeight: 42,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          horizontalTitleGap: 11,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(
            icon,
            size: 18,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
          title: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          onTap: () => setState(() => _pane = index),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 168,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 12, 16),
                child: Text(
                  '设置',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              _navItem(
                '常规',
                Icons.tune_rounded,
                0,
                const ValueKey('settings-nav-general'),
              ),
              _navItem(
                '软件更新',
                Icons.system_update_alt_rounded,
                1,
                const ValueKey('settings-nav-update'),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        const SizedBox(width: 24),
        Expanded(
          child: _pane == 0
              ? _buildGeneralPane(context)
              : SoftwareUpdatePane(config: widget.softwareUpdate),
        ),
      ],
    );
  }

  /// 「常规」面板：原有设置内容，行为与结构保持不变。
  Widget _buildGeneralPane(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          children: [
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
