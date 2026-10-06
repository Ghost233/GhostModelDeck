import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_theme.dart';
import 'council.dart';
import 'council_page.dart';
import 'council_mcp.dart';
import 'download_panel.dart';
import 'download_preferences.dart';
import 'download_tasks_page.dart';
import 'engine_catalog.dart';
import 'engine_page.dart';
import 'omlx_engine.dart';
import 'hf_model_browser.dart';
import 'public_gateway.dart';
import 'library_directory_settings.dart';
import 'library_page.dart';
import 'llama_engine.dart';
import 'model_downloader.dart';
import 'model_library.dart';
import 'model_search_page.dart';
import 'mcp_page.dart';
import 'manager_lifecycle.dart';
import 'model_use_registry.dart';
import 'sdk_service.dart';
import 'settings_page.dart';
import 'software_update_pane.dart';
import 'update_checker.dart';
import 'update_download_service.dart';

void main() => runApp(const GhostModelDeckApp());

class GhostModelDeckApp extends StatelessWidget {
  const GhostModelDeckApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GhostModelDeck',
    debugShowCheckedModeBanner: false,
    theme: buildJevTheme(Brightness.light),
    darkTheme: buildJevTheme(Brightness.dark),
    home: const _ManagerShell(),
  );
}

class _ManagerShell extends StatefulWidget {
  const _ManagerShell();
  @override
  State<_ManagerShell> createState() => _ManagerShellState();
}

class _ManagerShellState extends State<_ManagerShell> {
  static const _native = MethodChannel('com.ghost233.ghostmodeldeck/native');
  final _settings = LibraryDirectorySettings.user();
  final _preferences = DownloadPreferences.user();
  final _downloader = ModelDownloader();
  final _library = ModelLibrary();
  late final HfModelBrowser _browser;
  late final DownloadTaskController _downloads;
  late final ModelUseRegistry _useRegistry;
  late final LlamaEngine _officialEngine;
  late final LlamaEngine _standardEngine;
  late final OmlxEngine _omlxEngine;
  late final EngineCatalog _engines;
  late final CouncilController _council;
  late final CouncilMcpServer _mcp;
  late final PublicModelRoutes _publicRoutes;
  late final PublicGatewayServer _publicGateway;
  final _startupSet = StartupModelSet.user();
  late final LauncherInferenceService _launcherService;
  late final ManagerLifecycle _lifecycle;
  String? _libraryPath;
  String? _settingsError;
  String? _appVersion;
  int _page = 0;
  final _openedPages = <int>{0};

  @override
  void initState() {
    super.initState();
    _browser = HfModelBrowser(
      cacheDirectory: Directory('${_settings.file.parent.path}/hf-cache'),
    );
    _downloads = DownloadTaskController(
      downloader: _downloader,
      preferences: _preferences,
    );
    _useRegistry = ModelUseRegistry(_library);
    _officialEngine = LlamaEngine(
      library: _library,
      installationDirectory: Directory(
        '${_settings.file.parent.path}/engines/llama.cpp',
      ),
      useRegistry: _useRegistry,
    );
    _standardEngine = LlamaEngine(
      library: _library,
      installationDirectory: _officialEngine.installationDirectory,
      useRegistry: _useRegistry,
      release: standardLlamaRelease,
      installationId: EngineCatalog.standardId,
    );
    _omlxEngine = OmlxEngine(
      installationDirectory: Directory(
        '${_settings.file.parent.path}/engines/omlx',
      ),
    );
    _engines = EngineCatalog(
      library: _library,
      officialEngine: _officialEngine,
      standardEngine: _standardEngine,
      omlxEngine: _omlxEngine,
      useRegistry: _useRegistry,
      registryFile: File('${_settings.file.parent.path}/engines.json'),
    );
    _council = CouncilController(catalog: _engines);
    _mcp = CouncilMcpServer(controller: _council);
    _publicRoutes = PublicModelRoutes(
      library: _library,
      runtimes: [_officialEngine, _standardEngine, _omlxEngine],
      registryFile: File('${_settings.file.parent.path}/public_models.json'),
    );
    _publicGateway = PublicGatewayServer(routes: _publicRoutes);
    _launcherService = LauncherInferenceService(
      library: _library,
      engines: _engines,
      gateway: _publicGateway,
      mcp: _mcp,
      startupSet: _startupSet,
      // 窗口激活最小原生 seam；原生窗口行为验证属 #19 范围。原生未实现时
      // MissingPluginException 真实上抛，不假装窗口已激活。
      onOpenWindow: () => _native.invokeMethod<void>('activateMainWindow'),
    );
    _lifecycle = ManagerLifecycle(
      council: _council,
      mcp: _mcp,
      engines: _engines,
      downloader: _downloader,
      gateway: _publicGateway,
      launcher: _launcherService,
    );
    _native.setMethodCallHandler((call) async {
      if (call.method != 'prepareToQuit') throw MissingPluginException();
      try {
        await _lifecycle.shutdown();
        return true;
      } catch (_) {
        throw PlatformException(
          code: 'shutdown_failed',
          message: '受管服务尚未完成收尾。',
        );
      }
    });
    unawaited(_mcp.start().catchError((Object _) {}));
    // 启动失败（含公开端口冲突）保留在网关状态机中显式呈现，不影响其余服务。
    unawaited(_publicGateway.start().catchError((Object _) {}));
    // SDK 连接立即返回，握手与重连在后台维持；启动器不在场不影响独立使用。
    _launcherService.connect();
    _loadSettings();
    _loadAppVersion();
  }

  /// 应用内展示的当前版本必须来自包信息（Info.plist），不硬编码。
  /// 测试环境无插件实现时降级为 null，更新面板显示「不可用」。
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {}
  }

  SoftwareUpdateConfig? _softwareUpdateConfig() {
    final version = _appVersion;
    if (version == null) return null;
    return SoftwareUpdateConfig(
      currentVersion: version,
      checkForUpdates: () => UpdateChecker(currentVersion: version).check(),
      downloadUpdate: (update, {onProgress, confirmBeforeInstall}) {
        final sha256 = update.sha256;
        if (sha256 == null) {
          return Future.value(const UpdateDownloadFailed('发布缺少校验摘要，无法安全下载'));
        }
        return UpdateDownloadService().downloadUpdate(
          source: update.downloadUrl,
          version: update.version,
          expectedSha256: sha256,
          expectedSizeBytes: update.sizeBytes,
          onProgress: onProgress,
          confirmBeforeInstall: confirmBeforeInstall,
        );
      },
    );
  }

  Future<void> _loadSettings() async {
    try {
      final path = await _settings.load();
      await _preferences.load();
      await _startupSet.load();
      if (mounted) setState(() => _libraryPath = path);
    } catch (_) {
      if (mounted) setState(() => _settingsError = '设置读取失败');
    }
  }

  Future<String?> _pickDirectory() =>
      _native.invokeMethod<String>('pickLibraryDirectory');
  Future<String?> _pickEngineDirectory() =>
      _native.invokeMethod<String>('pickEngineDirectory');
  Future<String> _saveDirectory(String path) async {
    final saved = await _settings.save(path);
    if (mounted) {
      setState(() {
        _libraryPath = saved;
        _settingsError = null;
      });
    }
    return saved;
  }

  void _navigate(int page) => setState(() {
    _page = page;
    _openedPages.add(page);
  });

  @override
  void dispose() {
    _native.setMethodCallHandler(null);
    // 只关闭 SDK 通信，不回收业务；明确退出的完整收尾走 ManagerLifecycle。
    unawaited(_launcherService.dispose().catchError((Object _) {}));
    _browser.close();
    // Explicit native shutdown awaits the original failure via ManagerLifecycle.
    unawaited(_downloader.close().catchError((Object _) {}));
    _mcp.close();
    _publicGateway.close();
    _publicRoutes.close();
    _council.close();
    _engines.close();
    _officialEngine.close();
    _standardEngine.close();
    _library.close();
    _preferences.dispose();
    super.dispose();
  }

  Widget _navigation(String label, IconData icon, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _page == index;
    return Padding(
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
          onTap: () => _navigate(index),
        ),
      ),
    );
  }

  Widget _groupLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 22, 12, 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final path = _libraryPath;
    final scheme = Theme.of(context).colorScheme;
    if (path == null) {
      return Scaffold(
        body: Center(
          child: _settingsError == null
              ? const CircularProgressIndicator(strokeWidth: 2)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_settingsError!),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () async {
                        final selected = await _pickDirectory();
                        if (selected != null) await _saveDirectory(selected);
                      },
                      child: const Text('选择模型目录'),
                    ),
                  ],
                ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Container(
              width: 188,
              color: scheme.surfaceContainerLow,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 26, 12, 12),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.hub_outlined,
                            color: scheme.onPrimary,
                            size: 17,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Tooltip(
                            message: 'GhostModelDeck',
                            child: Text(
                              'GhostModelDeck',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _groupLabel('模型'),
                        _navigation('发现模型', Icons.search_rounded, 0),
                        _navigation('模型库', Icons.folder_outlined, 2),
                        _navigation('下载任务', Icons.download_outlined, 1),
                        _groupLabel('服务'),
                        _navigation('委员会', Icons.groups_outlined, 5),
                        _navigation('MCP', Icons.cable_outlined, 6),
                        _navigation('引擎管理', Icons.memory_outlined, 3),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Divider(color: scheme.outlineVariant),
                  ),
                  _navigation('设置', Icons.tune_rounded, 4),
                  const SizedBox(height: 18),
                ],
              ),
            ),
            VerticalDivider(width: 1, color: scheme.outlineVariant),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 30, 32, 28),
                child: IndexedStack(
                  index: _page,
                  children: [
                    ModelSearchPage(
                      browser: _browser,
                      downloads: _downloads,
                      libraryPath: path,
                      onDownloadStarted: () => _navigate(1),
                    ),
                    if (_openedPages.contains(1))
                      DownloadTasksPage(downloads: _downloads)
                    else
                      const SizedBox.shrink(),
                    if (_openedPages.contains(2))
                      LibraryPage(
                        library: _library,
                        libraryPath: path,
                        engines: _engines,
                        publicRoutes: _publicRoutes,
                        publicGateway: _publicGateway,
                        startupSet: _startupSet,
                      )
                    else
                      const SizedBox.shrink(),
                    if (_openedPages.contains(3))
                      EnginePage(
                        catalog: _engines,
                        pickEngineDirectory: _pickEngineDirectory,
                      )
                    else
                      const SizedBox.shrink(),
                    if (_openedPages.contains(4))
                      SettingsPage(
                        preferences: _preferences,
                        libraryPath: path,
                        onLibraryPathChanged: _saveDirectory,
                        pickLibraryDirectory: _pickDirectory,
                        softwareUpdate: _softwareUpdateConfig(),
                      )
                    else
                      const SizedBox.shrink(),
                    if (_openedPages.contains(5))
                      CouncilPage(
                        controller: _council,
                        onOpenLibrary: () => _navigate(2),
                      )
                    else
                      const SizedBox.shrink(),
                    if (_openedPages.contains(6))
                      McpPage(server: _mcp)
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
