import 'council.dart';
import 'council_mcp.dart';
import 'engine_catalog.dart';
import 'model_downloader.dart';
import 'public_gateway.dart';

enum ManagerLifecycleState { running, stopping, stopped, failed }

class ManagerLifecycle {
  ManagerLifecycle({
    required this.council,
    required this.mcp,
    required this.engines,
    required this.downloader,
    this.gateway,
  });
  final CouncilController council;
  final CouncilMcpServer mcp;
  final EngineCatalog engines;
  final ModelDownloader downloader;
  final PublicGatewayServer? gateway;
  ManagerLifecycleState state = ManagerLifecycleState.running;
  String? error;
  Future<void>? _shutdown;

  /// A terminal attempt for this graph: repeated calls share its success or
  /// failure. A failed result never grants the native shell permission to exit.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    state = ManagerLifecycleState.stopping;
    council.beginShutdown();
    engines.beginShutdown();
    // 公开 API 先于引擎排空封入场并取消在途请求，不复制引擎许可逻辑。
    gateway?.beginShutdown();
    final downloads = downloader.close();
    downloads.ignore();
    return _shutdown = _finish(downloads);
  }

  Future<void> _finish(Future<void> downloads) async {
    final failures = <String>[];
    for (final step in [
      ('MCP', mcp.stop),
      ('公开 API', () => gateway?.stop() ?? Future<void>.value()),
      ('委员会', council.shutdown),
      ('引擎', engines.shutdown),
      ('下载', () => downloads),
    ]) {
      try {
        await step.$2();
      } catch (failure) {
        failures.add('${step.$1}：$failure');
      }
    }
    if (failures.isNotEmpty) {
      state = ManagerLifecycleState.failed;
      error = failures.join('; ');
      throw StateError('退出收尾未完成：$error');
    }
    state = ManagerLifecycleState.stopped;
  }
}
