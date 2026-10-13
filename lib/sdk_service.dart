import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'council_mcp.dart';
import 'engine_catalog.dart';
import 'engine_runtime.dart';
import 'model_library.dart';
import 'public_gateway.dart';
import 'launch_instances.dart';

/// An explicitly selected saved instance; never an implicit model/engine pair.
class StartupModelEntry {
  const StartupModelEntry({required this.instanceId});
  final String instanceId;
  Map<String, Object?> toJson() => {'instance': instanceId};
}

class StartupModelSet {
  StartupModelSet({required this.file});
  factory StartupModelSet.user() => StartupModelSet(
    file: File(
      '${_home()}/Library/Application Support/GhostModelDeck/startup-models.json',
    ),
  );
  static const int schema = 1;
  final File file;
  List<StartupModelEntry> _entries = const [];
  bool _loaded = false;
  Future<void> _operations = Future.value();
  List<StartupModelEntry> get entries => List.unmodifiable(_entries);
  bool contains(String id) => _entries.any((entry) => entry.instanceId == id);
  Future<void> _serial(Future<void> Function() action) {
    final operation = _operations.then((_) => action());
    _operations = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> load() => _serial(_load);
  Future<void> _load() async {
    if (_loaded) return;
    if (!await file.exists()) {
      _loaded = true;
      return;
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map || value['schema'] != schema) {
      throw const FormatException('启动模型集合配置版本不受支持');
    }
    if (value['entries'] is! List) {
      throw const FormatException('启动模型集合配置缺少 entries');
    }
    final parsed = <StartupModelEntry>[];
    for (final entry in value['entries'] as List) {
      if (entry is! Map ||
          entry['instance'] is! String ||
          (entry['instance'] as String).trim().isEmpty) {
        throw const FormatException('启动集合条目需要非空实例身份');
      }
      parsed.add(StartupModelEntry(instanceId: entry['instance'] as String));
    }
    if (parsed.map((entry) => entry.instanceId).toSet().length !=
        parsed.length) {
      throw const FormatException('启动集合实例重复');
    }
    _entries = List.unmodifiable(parsed);
    _loaded = true;
  }

  Future<void> add(String id) => _serial(() async {
    await _load();
    if (id.trim().isEmpty) throw ArgumentError('实例身份不能为空');
    if (!contains(id)) {
      await _write([..._entries, StartupModelEntry(instanceId: id)]);
    }
  });
  Future<void> remove(String id) => _serial(() async {
    await _load();
    if (contains(id)) {
      await _write(_entries.where((entry) => entry.instanceId != id).toList());
    }
  });
  Future<void> _write(List<StartupModelEntry> next) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': schema,
        'entries': next.map((entry) => entry.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
    _entries = List.unmodifiable(next);
  }

  static String _home() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) throw StateError('无法读取用户目录');
    return home;
  }
}

enum LauncherServiceState { stopped, starting, running, stopping, failed }

/// MacLauncher 推理服务（service id `inference`）：经官方 maclauncher_sdk 把
/// 整体推理业务图（公开 LLM API + JEV MCP + 受管引擎）暴露给启动器。
///
/// 固定语义（docs/research/maclauncher-sdk-contract.md 与 docs/spec.md
/// 「SDK 与窗口生命周期」）：
/// - onStart 打开公开 API 与 MCP（已在运行则幂等复用），并显式加载启动模型
///   集合；确认只代表受理，空集合/缺资产/部分失败经 onStatus 与日志真实
///   报告；重复 start 复用匹配运行实例，不创建副本。
/// - onRecycle 先关新入场（封公开 API 并取消在途 Chat/SSE）→ 卸载全部受管
///   模型并停受管进程 → 停 MCP 与公开 API；应用、SDK 连接、启动配置与模型
///   文件全部保留，可再启动；失败聚合抛出，不假报停止。
/// - SDK dispose、断连与启动器崩溃从不回收业务；只有明确退出（
///   ManagerLifecycle.shutdown）才收尾 SDK 连接。
/// - onStatus 返回真实状态与真实 UTC observedAt；onLogs 返回应用事件真实
///   批次（旧→新、遵守 limit、截断真实标记），未知字段不伪造。
class LauncherInferenceService {
  LauncherInferenceService({
    required this.library,
    required this.engines,
    required this.gateway,
    required this.mcp,
    required this.startupSet,
    required this.instances,
    this.onOpenWindow,
    this.onSetEntryManaged,
    this.onVersionStatus,
    String? socketPath,
  }) : _socketPath = socketPath ?? MacLauncherSdk.defaultSocketPath();

  static const String projectId = 'com.ghost233.ghostmodeldeck';

  /// 运行时发现自报显示名（#30）：未关联时启动器以此建待批准卡片。
  static const String projectName = 'Ghost Model Deck';

  static const String serviceId = 'inference';
  static const String serviceName = '推理服务';

  /// 应用事件日志缓冲上限；超出丢弃最旧条目，onLogs 截断标记随之真实成立。
  static const int logCapacity = 1000;

  final ModelLibrary library;
  final EngineCatalog engines;
  final PublicGatewayServer gateway;
  final CouncilMcpServer mcp;
  final StartupModelSet startupSet;
  final LaunchInstances instances;

  /// 窗口激活最小 seam：由应用壳注入（原生 MethodChannel）；原生窗口行为
  /// 验证属 #19 范围。未配置时 openWindow 请求真实失败，不假装成功。
  final Future<void> Function()? onOpenWindow;

  /// 暂时隐藏菜单栏入口；false 归还应用自身显示控制，不改变业务或 Dock。
  final Future<bool> Function(bool managed)? onSetEntryManaged;

  /// 版本状况查询 seam（#28）：由应用壳注入 VersionStatusBridge.query。
  /// 未配置时不声明该能力；若启动器仍查询，SDK 自动应答「不支持更新」。
  /// 回调抛异常由 SDK 兜底为 failure，桥本身也不抛。
  final Future<VersionStatus> Function()? onVersionStatus;

  final String _socketPath;
  final _logBuffer = <LogEntry>[];
  LauncherServiceState _state = LauncherServiceState.stopped;
  String? _instanceId;
  String? _lastError;
  MacLauncherSdk? _sdk;
  final _subscriptions = <StreamSubscription<void>>[];
  bool _disposed = false;

  /// 待批准期间（#30）：启动器以 pending-approval 拒绝握手是批准前的正常
  /// 状态，SDK 每 5 秒自动重试。此期间只公告一次，不反复刷连接日志；
  /// 批准成功（connected）或被以其他原因拒绝时退出该期间。
  bool _pendingApproval = false;

  LauncherServiceState get state => _state;

  /// 本次运行的实例身份（应用生成，非 PID/会话名）；停止后为 null。
  String? get instanceId => _instanceId;
  String? get lastError => _lastError;

  /// 连接启动器：立即返回，握手、心跳与重连由官方 SDK 在后台维持。重复
  /// 调用幂等；SDK 失联或重连不触碰业务。
  void connect() {
    if (_disposed) throw StateError('推理服务已收尾');
    if (_sdk != null) return;
    final sdk = MacLauncherSdk.connect(
      projectId: projectId,
      projectName: projectName,
      // 运行时发现入口自报（#30）：打包运行时上报自身 .app（DMG 安装后解析
      // 为 /Applications/Ghost Model Deck.app）；开发期非 bundle 运行退回上报
      // 当前可执行文件。入口存在性由启动器在批准时校验。
      entry: SdkEntry.currentAppBundle() ?? SdkEntry.currentExecutable(),
      socketPath: _socketPath,
      services: {
        serviceId: ServiceCallbacks(
          name: serviceName,
          onStart: _start,
          onRecycle: _recycle,
          onStatus: _status,
          onLogs: _logs,
        ),
      },
      app: AppCallbacks(
        onOpenWindow: _openWindow,
        onSetEntryManaged: onSetEntryManaged,
        onVersionStatus: onVersionStatus,
      ),
    );
    _sdk = sdk;
    _subscriptions.add(
      sdk.states.listen((status) {
        // 断连/重连只记录真实连接事件，从不回收或复制业务。
        if (status.state == SdkConnectionState.rejected &&
            status.reason == kRejectReasonPendingApproval) {
          // 待批准不是错误：公告一次后静默，SDK 自动重试到用户批准。
          if (!_pendingApproval) {
            _pendingApproval = true;
            _log('启动器待批准：请在启动器管理窗口批准 $projectName 的关联，批准后自动连接');
          }
          return;
        }
        if (_pendingApproval) {
          // 待批准期间的 connecting/disconnected 是重试噪音，不刷日志。
          if (status.state == SdkConnectionState.connected ||
              status.state == SdkConnectionState.rejected) {
            _pendingApproval = false;
          } else {
            return;
          }
        }
        _log(
          '启动器连接：${status.state.name}'
          '${status.reason == null ? '' : '（${status.reason}）'}',
        );
      }),
    );
    _subscriptions.add(
      gateway.changes.listen((state) => _log('公开 API：${state.name}')),
    );
    _subscriptions.add(
      mcp.changes.listen((state) => _log('JEV MCP：${state.status.name}')),
    );
  }

  /// 只交还入口并关闭通信（固定 SDK 语义：dispose 从不触发业务回收）。
  /// 幂等；明确退出路径由 ManagerLifecycle 在业务收尾后调用。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _sdk?.dispose();
  }

  Future<void> _start() async {
    if (_disposed) throw StateError('推理服务已收尾');
    if (_state == LauncherServiceState.starting ||
        _state == LauncherServiceState.stopping) {
      // SDK 按服务的 busy 门闩通常已拦下并发变更；这是防御性兜底。
      throw StateError('推理服务正在变更：${_state.name}');
    }
    final first = _state != LauncherServiceState.running;
    if (first) {
      _state = LauncherServiceState.starting;
      _instanceId = _newInstanceId();
      _lastError = null;
      _log('推理服务启动受理，实例 $_instanceId');
    } else {
      _log('推理服务重复启动受理，复用实例 $_instanceId');
    }
    try {
      // 配置损坏在此真实失败，不静默按空集合启动。
      await startupSet.load();
      await _ensureGateway();
      await _ensureMcp();
      await _loadStartupSet();
      _state = LauncherServiceState.running;
    } catch (error) {
      _state = LauncherServiceState.failed;
      _lastError = '$error';
      _log('推理服务启动失败：$error');
      rethrow;
    }
  }

  Future<void> _recycle() async {
    if (_state == LauncherServiceState.stopped) {
      _log('推理服务回收受理：已停止，幂等完成');
      return;
    }
    if (_state == LauncherServiceState.starting ||
        _state == LauncherServiceState.stopping) {
      throw StateError('推理服务正在变更：${_state.name}');
    }
    _state = LauncherServiceState.stopping;
    instances.cancelPendingStarts();
    _log('推理服务回收受理：封入场→排空→卸载受管模型→停服务，实例 $_instanceId');
    final failures = <String>[];
    // 1) 先关新入场：封公开 API 并取消在途 Chat/SSE，解除引擎排空等待。
    try {
      gateway.beginShutdown();
    } catch (error) {
      failures.add('公开 API 入场关闭：$error');
    }
    // 2) 卸载全部受管模型并停受管进程；准入闩与迟到登记由 catalog 保证。
    try {
      await engines.stopManaged();
    } catch (error) {
      failures.add('受管引擎回收：$error');
    }
    // 3) 停 JEV MCP：取消在途咨询、关监听并排空。
    try {
      await mcp.stop();
    } catch (error) {
      failures.add('JEV MCP 停止：$error');
    }
    // 4) 停公开 API：关监听并排空剩余在途。
    try {
      await gateway.stop();
    } catch (error) {
      failures.add('公开 API 停止：$error');
    }
    if (failures.isNotEmpty) {
      _state = LauncherServiceState.failed;
      _lastError = failures.join('；');
      _log('推理服务回收未完成：$_lastError');
      throw StateError('推理服务回收未完成：$_lastError');
    }
    // 保留应用、SDK 连接、启动配置与模型文件；实例身份随本次运行结束。
    _state = LauncherServiceState.stopped;
    _instanceId = null;
    _lastError = null;
    _log('推理服务已回收：应用、连接、配置与模型文件保留，可再启动');
  }

  Future<ServiceStatus> _status() async {
    final observedAt = DateTime.now().toUtc();
    bool? ready;
    String? message;
    if (_state == LauncherServiceState.running) {
      final problems = <String>[];
      if (gateway.state != PublicGatewayState.running) {
        problems.add('公开 API 未运行（${gateway.state.name}）');
      }
      if (mcp.state.status != CouncilMcpStatus.running) {
        problems.add('JEV MCP 未运行（${mcp.state.status.name}）');
      }
      final entries = startupSet.entries;
      if (entries.isEmpty) {
        problems.add('启动模型集合为空：接口可用但未加载模型');
      } else {
        for (final entry in entries) {
          final instance = _matchingInstance(entry);
          if (instance == null) {
            problems.add('模型未运行：${entry.instanceId}');
          } else if (instance.status != RuntimeInstanceStatus.ready) {
            problems.add('模型未就绪：${entry.instanceId}（${instance.status.name}）');
          }
        }
      }
      // 有接口无可用模型不能宣称推理就绪。
      ready = problems.isEmpty;
      if (!ready) message = problems.join('；');
    } else if (_state == LauncherServiceState.failed) {
      message = _lastError;
    }
    return ServiceStatus(
      state: switch (_state) {
        LauncherServiceState.stopped => ServiceState.stopped,
        LauncherServiceState.starting => ServiceState.starting,
        LauncherServiceState.running => ServiceState.running,
        LauncherServiceState.stopping => ServiceState.stopping,
        LauncherServiceState.failed => ServiceState.failed,
      },
      instanceId: _instanceId,
      ready: ready,
      observedAt: observedAt,
      message: message,
    );
  }

  Future<LogBatch> _logs(LogQuery query) async {
    final all = _logBuffer;
    final limit = query.limit;
    final start = all.length > limit ? all.length - limit : 0;
    return LogBatch(
      entries: List.unmodifiable(all.sublist(start)),
      instanceId: _instanceId,
      truncated: start > 0,
      observedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> _openWindow() async {
    final seam = onOpenWindow;
    if (seam == null) throw StateError('窗口激活 seam 未配置');
    _log('启动器请求激活主窗口');
    await seam();
  }

  /// 公开 API 只允许从 stopped 启动；启动/停止中的实例等待其落定后复用，
  /// failed 状态保留既有错误真实抛出，不做端口漂移。
  Future<void> _ensureGateway() async {
    while (gateway.state == PublicGatewayState.starting ||
        gateway.state == PublicGatewayState.stopping) {
      final settled = Completer<void>();
      late final StreamSubscription<PublicGatewayState> subscription;
      subscription = gateway.changes.listen((_) {
        if (!settled.isCompleted) settled.complete();
      });
      final current = gateway.state;
      if (current == PublicGatewayState.starting ||
          current == PublicGatewayState.stopping) {
        await settled.future;
      }
      await subscription.cancel();
    }
    if (gateway.state == PublicGatewayState.running) return;
    await gateway.start();
  }

  /// MCP start 经其内部串行队列幂等复用：已在运行直接返回，失败后真实重试。
  Future<void> _ensureMcp() => mcp.start();

  /// 显式加载启动模型集合：匹配（同引擎、同资产、存活）的运行实例幂等
  /// 复用，不创建副本；缺资产与单项失败记录日志并继续，由 onStatus 真实
  /// 报告未就绪。
  Future<void> _loadStartupSet() async {
    await instances.load();
    await Future.wait(
      startupSet.entries.map((entry) async {
        try {
          if (instances.find(entry.instanceId) == null) {
            _log('启动集合模型缺失：${entry.instanceId}');
            return;
          }
          if (_matchingInstance(entry) != null) {
            _log('启动集合复用运行实例：${entry.instanceId}');
            return;
          }
          final started = await instances.start(entry.instanceId);
          _log('启动集合加载模型：${entry.instanceId}（实例 ${started.id}）');
        } catch (error) {
          _log('启动集合加载失败：${entry.instanceId}：$error');
        }
      }),
    );
  }

  RuntimeInstance? _matchingInstance(StartupModelEntry entry) => instances
      .runsFor(entry.instanceId)
      .where(
        (instance) =>
            !instance.temporaryTest &&
            instance.hasLiveProcess &&
            (instance.status == RuntimeInstanceStatus.starting ||
                instance.status == RuntimeInstanceStatus.ready),
      )
      .firstOrNull;

  void _log(String text) {
    _logBuffer.add(
      LogEntry(
        text: text,
        timestamp: DateTime.now().toUtc(),
        stream: LogStream.app,
      ),
    );
    if (_logBuffer.length > logCapacity) {
      _logBuffer.removeRange(0, _logBuffer.length - logCapacity);
    }
  }

  static String _newInstanceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    final suffix = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'run-'
        '${DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(16)}'
        '-$suffix';
  }
}
