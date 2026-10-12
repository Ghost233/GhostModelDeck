import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_theme.dart';
import 'benchmark_game_work.dart';
import 'benchmark_page.dart';
import 'benchmark_resources.dart';
import 'benchmark_run_store.dart';
import 'benchmark_runner.dart';
import 'council.dart';
import 'council_page.dart';
import 'jev_playground_page.dart';
import 'jev_playground.dart';
import 'llm_playground_page.dart';
import 'council_mcp.dart';
import 'download_panel.dart';
import 'application_configuration.dart';
import 'download_preferences.dart';
import 'download_tasks_page.dart';
import 'engine_catalog.dart';
import 'launch_instances.dart';
import 'instances_page.dart';
import 'engine_page.dart';
import 'engine_source_build.dart';
import 'embedding_page.dart';
import 'omlx_engine.dart';
import 'hf_model_browser.dart';
import 'public_gateway.dart';
import 'public_model_names.dart';
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
import 'startlux_readout.dart';
import 'startlux_runtime.dart';
import 'software_update_pane.dart';
import 'update_checker.dart';
import 'update_download_service.dart';
import 'version_status_bridge.dart';

void main() => runApp(const GhostModelDeckApp());

class GhostModelDeckApp extends StatelessWidget {
  const GhostModelDeckApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ghost Model Deck',
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

class _ManagerShellState extends State<_ManagerShell>
    with TickerProviderStateMixin {
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
  late final LlamaEngine _embeddingEngine;
  late final StartluxRuntime _startluxRuntime;
  StartluxReadoutFactory? _startluxReadoutFactory;
  Future<void> _startluxPreparation = Future.value();
  late final OmlxEngine _omlxEngine;
  late final EngineCatalog _engines;
  late final LaunchInstances _instances;
  final _publicNames = PublicModelNames();
  String? _instanceArtifact;
  late final CouncilController _council;
  late final CouncilMcpServer _mcp;
  late final PublicModelRoutes _publicRoutes;
  late final PublicGatewayServer _publicGateway;
  late final BenchmarkResources _benchmarkResources;
  late final BenchmarkGameWork _benchmarkGameWork;
  late final BenchmarkRunner _benchmarks;
  final _startupSet = StartupModelSet.user();
  late final LauncherInferenceService _launcherService;
  late final ManagerLifecycle _lifecycle;
  late final VersionStatusBridge _versionStatusBridge;
  String? _libraryPath;
  List<String> _libraryPaths = [];
  String? _settingsError;
  String? _appVersion;
  int _page = 0;
  int _enginePage = 0;
  int _playgroundPage = 8;
  int _jevPage = 7;
  late final TabController _workspaceTabs;
  late final TabController _capabilityTabs;
  final _openedPages = <int>{0};

  @override
  void initState() {
    super.initState();
    _workspaceTabs = TabController(length: 2, vsync: this);
    _capabilityTabs = TabController(length: 3, vsync: this);
    _browser = HfModelBrowser(
      cacheDirectory: Directory('${_settings.file.parent.path}/hf-cache'),
    );
    _downloads = DownloadTaskController(
      downloader: _downloader,
      preferences: _preferences,
    );
    _useRegistry = ModelUseRegistry(_library);
    _startluxRuntime = StartluxRuntime(
      Directory('${_settings.file.parent.path}/startlux-runtime'),
      assets: _loadStartluxAsset,
    );
    _officialEngine = LlamaEngine(
      library: _library,
      installationDirectory: Directory(
        '${_settings.file.parent.path}/engines/llama.cpp',
      ),
      useRegistry: _useRegistry,
      startStartluxReadout: _startStartluxReadout,
    );
    _standardEngine = LlamaEngine(
      library: _library,
      installationDirectory: _officialEngine.installationDirectory,
      useRegistry: _useRegistry,
      release: standardLlamaRelease,
      installationId: EngineCatalog.standardId,
      startStartluxReadout: _startStartluxReadout,
    );
    _embeddingEngine = LlamaEngine(
      library: _library,
      installationDirectory: _officialEngine.installationDirectory,
      useRegistry: _useRegistry,
      release: embeddingLlamaRelease,
      installationId: EngineCatalog.embeddingId,
      startStartluxReadout: _startStartluxReadout,
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
      embeddingEngine: _embeddingEngine,
      omlxEngine: _omlxEngine,
      useRegistry: _useRegistry,
      registryFile: File('${_settings.file.parent.path}/engines.json'),
      startStartluxReadout: _startStartluxReadout,
      sourceBuilder: EngineSourceBuilder(
        Directory('${_settings.file.parent.path}/engines/source'),
      ),
    );
    _instances = LaunchInstances(
      catalog: _engines,
      file: File('${_settings.file.parent.path}/launch-instances.json'),
      names: _publicNames,
    );
    _council = CouncilController(
      catalog: _engines,
      modelRegistryFile: File('${_settings.file.parent.path}/jev_models.json'),
      publicNames: _publicNames,
      launchInstances: _instances,
    );
    _mcp = CouncilMcpServer(controller: _council);
    _publicRoutes = PublicModelRoutes(
      library: _library,
      instances: _instances,
      runtimes: [
        _officialEngine,
        _standardEngine,
        _embeddingEngine,
        _omlxEngine,
      ],
      runtimeSources: () => _engines.runtimes.toList(),
      registryFile: File('${_settings.file.parent.path}/public_models.json'),
    );
    _publicGateway = PublicGatewayServer(
      routes: _publicRoutes,
      jevModels: _council.models,
    );
    _benchmarkResources = BenchmarkResources(
      Directory('${_settings.file.parent.path}/benchmark-cache'),
    );
    _benchmarkGameWork = BenchmarkGameWork(
      Directory('${_settings.file.parent.path}/benchmark-game-cache'),
    );
    _benchmarks = BenchmarkRunner(
      client: JevPlayground(gateway: _publicGateway, mcp: _mcp),
      store: BenchmarkRunStore(
        directory: Directory('${_settings.file.parent.path}/benchmark-runs'),
      ),
      models: _council.models,
    );
    // #28 版本状况桥：与设置页共用 UpdateChecker 查询；当前版本读取包信息
    // 缓存值，未就绪时桥如实按查询失败回报。
    _versionStatusBridge = VersionStatusBridge(
      currentVersion: () => _appVersion,
      checkForUpdates: (version) =>
          UpdateChecker(currentVersion: version).check(),
    );
    _launcherService = LauncherInferenceService(
      library: _library,
      engines: _engines,
      gateway: _publicGateway,
      mcp: _mcp,
      startupSet: _startupSet,
      instances: _instances,
      // 窗口激活最小原生 seam；原生窗口行为验证属 #19 范围。原生未实现时
      // MissingPluginException 真实上抛，不假装窗口已激活。
      onOpenWindow: () => _native.invokeMethod<void>('activateMainWindow'),
      onSetEntryManaged: (managed) async =>
          await _native.invokeMethod<bool>('setEntryManaged', managed) ?? false,
      onVersionStatus: _versionStatusBridge.query,
    );
    _lifecycle = ManagerLifecycle(
      instances: _instances,
      council: _council,
      mcp: _mcp,
      engines: _engines,
      downloader: _downloader,
      gateway: _publicGateway,
      launcher: _launcherService,
      benchmarks: _benchmarks,
      benchmarkResources: _benchmarkResources,
      benchmarkGameWork: _benchmarkGameWork,
    );
    _native.setMethodCallHandler((call) async {
      if (call.method != 'prepareToQuit') throw MissingPluginException();
      _startluxRuntime.cancelPreparation();
      final failures = <String>[];
      try {
        await _lifecycle.shutdown();
      } catch (error) {
        failures.add('服务收尾：$error');
      }
      try {
        await _startluxRuntime.close();
      } catch (error) {
        failures.add('StartLux 运行时收尾：$error');
      }
      if (failures.isNotEmpty) {
        throw PlatformException(
          code: 'shutdown_failed',
          message: failures.join('; '),
        );
      }
      return true;
    });
    unawaited(_loadSettings());
    _loadAppVersion();
  }

  Future<StartluxReadout?> _startStartluxReadout(
    LibraryArtifact asset,
    Uri nativeEndpoint,
    String alias,
    int generation,
    DecisionCancellation cancellation,
  ) async {
    if (!asset.hasStartluxReadout) return null;
    // Several engine installations share one preparation owner. The caller
    // retains the real failure; the tail only admits the next preparation.
    final preparation = _startluxPreparation.then(
      (_) => _startluxRuntime.prepare(cancellation),
    );
    _startluxPreparation = preparation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final runtime = await preparation;
    var factory = _startluxReadoutFactory;
    if (factory == null || factory.runtime.fingerprint != runtime.fingerprint) {
      factory = StartluxReadoutFactory(
        runtime,
        cacheRoot: Directory('${_settings.file.parent.path}/startlux-readout'),
        assets: _loadStartluxAsset,
      );
      _startluxReadoutFactory = factory;
    }
    return factory.start(
      nativeEndpoint: nativeEndpoint,
      alias: alias,
      generation: generation,
      cancellation: cancellation,
    );
  }

  Future<Uint8List> _loadStartluxAsset(String name) async {
    final data = await rootBundle.load(name);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
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
      await ApplicationConfiguration(directory: _settings.file.parent)
          .prepare();
      final directories = await _settings.loadDirectories();
      final path = directories.downloadPath;
      await _preferences.load();
      await _startupSet.load();
      await _instances.load();
      if (!mounted) return;
      unawaited(_mcp.start().catchError((Object _) {}));
      // Public and SDK discovery must not read the previous configuration.
      unawaited(_publicGateway.start().catchError((Object _) {}));
      _launcherService.connect();
      if (mounted) {
        setState(() {
          _libraryPath = path;
          _libraryPaths = directories.libraryPaths;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _settingsError = '设置读取失败：$error');
    }
  }

  Future<String?> _pickDirectory() =>
      _native.invokeMethod<String>('pickLibraryDirectory');
  Future<String?> _pickEngineDirectory() =>
      _native.invokeMethod<String>('pickEngineDirectory');
  Future<String> _saveDirectory(String path) async {
    final directories = await _settings.saveDirectories(
      ModelDirectories(
        downloadPath: path,
        libraryPaths: [..._libraryPaths, path],
      ),
    );
    final saved = directories.downloadPath;
    if (mounted) {
      setState(() {
        _libraryPath = saved;
        _libraryPaths = directories.libraryPaths;
        _settingsError = null;
      });
    }
    return saved;
  }

  Future<void> _saveLibraryPaths(List<String> paths) async {
    final directories = await _settings.saveDirectories(
      ModelDirectories(downloadPath: _libraryPath!, libraryPaths: paths),
    );
    if (mounted) setState(() => _libraryPaths = directories.libraryPaths);
  }

  void _navigate(int page) => setState(() {
    _page = page;
    _openedPages.add(page);
    if ((page <= 6 || page == 11) && page != 4) {
      _enginePage = page;
      _workspaceTabs.index = 0;
    } else if (page >= 7) {
      _playgroundPage = page;
      _capabilityTabs.index = switch (page) {
        8 => 0,
        10 => 2,
        _ => 1,
      };
      if (page == 7 || page == 9) _jevPage = page;
    }
  });

  void _selectWorkspace(int index) => setState(() {
    _page = index == 0 ? _enginePage : _playgroundPage;
    _openedPages.add(_page);
  });

  void _selectCapability(int index) => setState(() {
    _playgroundPage = switch (index) {
      0 => 8,
      1 => _jevPage,
      _ => 10,
    };
    _page = _playgroundPage;
    _openedPages.add(_page);
  });

  @override
  void dispose() {
    _capabilityTabs.dispose();
    _workspaceTabs.dispose();
    _native.setMethodCallHandler(null);
    // 只关闭 SDK 通信，不回收业务；明确退出的完整收尾走 ManagerLifecycle。
    unawaited(_launcherService.dispose().catchError((Object _) {}));
    _browser.close();
    unawaited(_benchmarks.close().catchError((Object _) {}));
    unawaited(_benchmarks.store.close().catchError((Object _) {}));
    unawaited(_benchmarkResources.close().catchError((Object _) {}));
    unawaited(_benchmarkGameWork.close().catchError((Object _) {}));
    unawaited(
      _startluxRuntime.close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            context: ErrorDescription('收尾 StartLux 运行时准备'),
          ),
        );
      }),
    );
    // Explicit native shutdown awaits the original failure via ManagerLifecycle.
    unawaited(_downloader.close().catchError((Object _) {}));
    _mcp.close();
    _publicGateway.close();
    _publicRoutes.close();
    unawaited(_instances.close().catchError((Object _) {}));
    unawaited(_council.close().catchError((Object _) {}));
    _engines.close();
    _officialEngine.close();
    _standardEngine.close();
    _embeddingEngine.close();
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
                      onPressed: _loadSettings,
                      child: const Text('重试'),
                    ),
                  ],
                ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TabBar(
              key: const Key('workspace-tabs'),
              controller: _workspaceTabs,
              onTap: _selectWorkspace,
              tabs: const [
                Tab(text: '引擎'),
                Tab(text: '测试场'),
              ],
            ),
            if (_workspaceTabs.index == 1)
              TabBar.secondary(
                key: const Key('playground-capability-tabs'),
                controller: _capabilityTabs,
                onTap: _selectCapability,
                tabs: const [
                  Tab(text: '通用 LLM'),
                  Tab(text: 'JEV'),
                  Tab(text: '嵌入'),
                ],
              ),
            Expanded(
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
                                  message: 'Ghost Model Deck',
                                  child: Text(
                                    'Ghost Model Deck',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
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
                              if (_workspaceTabs.index == 0) ...[
                                _groupLabel('模型'),
                                _navigation('发现模型', Icons.search_rounded, 0),
                                _navigation('模型库', Icons.folder_outlined, 2),
                                _navigation('下载', Icons.download_outlined, 1),
                                _groupLabel('服务'),
                                _navigation('引擎管理', Icons.memory_outlined, 3),
                                _navigation('实例', Icons.layers_outlined, 11),
                                _navigation('委员会配置', Icons.groups_outlined, 5),
                                _navigation('MCP', Icons.cable_outlined, 6),
                              ] else ...[
                                _groupLabel('测试'),
                                _navigation(
                                  '基础测试',
                                  Icons.science_outlined,
                                  switch (_capabilityTabs.index) {
                                    0 => 8,
                                    1 => 7,
                                    _ => 10,
                                  },
                                ),
                                if (_capabilityTabs.index == 1)
                                  _navigation(
                                    '基准评测',
                                    Icons.assessment_outlined,
                                    9,
                                  ),
                              ],
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
                            DownloadTasksPage(
                              downloads: _downloads,
                              engines: _engines,
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(2))
                            LibraryPage(
                              library: _library,
                              libraryPath: path,
                              libraryPaths: _libraryPaths,
                              engines: _engines,
                              publicRoutes: _publicRoutes,
                              publicGateway: _publicGateway,
                              onCreateInstance: (artifact) {
                                _instanceArtifact = artifact;
                                _navigate(11);
                              },
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(3))
                            EnginePage(
                              catalog: _engines,
                              pickEngineDirectory: _pickEngineDirectory,
                              onDownloadStarted: () => _navigate(1),
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(4))
                            SettingsPage(
                              preferences: _preferences,
                              libraryPath: path,
                              onLibraryPathChanged: _saveDirectory,
                              libraryPaths: _libraryPaths,
                              onLibraryPathsChanged: _saveLibraryPaths,
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
                          if (_openedPages.contains(7))
                            JevPlaygroundPage(
                              gateway: _publicGateway,
                              mcp: _mcp,
                              active: _workspaceTabs.index == 1 && _page == 7,
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(8))
                            LlmPlaygroundPage(
                              gateway: _publicGateway,
                              active: _workspaceTabs.index == 1 && _page == 8,
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(9))
                            BenchmarkPage(
                              resources: _benchmarkResources,
                              runner: _benchmarks,
                              gameWork: _benchmarkGameWork,
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(10))
                            EmbeddingPage(
                              gateway: _publicGateway,
                              active: _workspaceTabs.index == 1 && _page == 10,
                            )
                          else
                            const SizedBox.shrink(),
                          if (_openedPages.contains(11))
                            InstancesPage(
                              instances: _instances,
                              startupSet: _startupSet,
                              initialArtifactId: _instanceArtifact,
                              onInitialArtifactHandled: () {
                                setState(() => _instanceArtifact = null);
                              },
                              prepare: () async {
                                await _engines.refresh();
                                if (!_library.state.scanning &&
                                    _library.state.rootPaths.isEmpty) {
                                  await _library.scanDirectories(
                                    _libraryPaths.map(Directory.new).toList(),
                                  );
                                }
                              },
                            )
                          else
                            const SizedBox.shrink(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
