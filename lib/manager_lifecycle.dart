import 'council.dart';
import 'council_mcp.dart';
import 'engine_catalog.dart';
import 'model_downloader.dart';

enum ManagerLifecycleState { running, stopping, stopped, failed }

class ManagerLifecycle {
  ManagerLifecycle({
    required this.council,
    required this.mcp,
    required this.engines,
    required this.downloader,
  });
  final CouncilController council;
  final CouncilMcpServer mcp;
  final EngineCatalog engines;
  final ModelDownloader downloader;
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
    final downloads = downloader.close();
    downloads.ignore();
    return _shutdown = _finish(downloads);
  }

  Future<void> _finish(Future<void> downloads) async {
    final failures = <String>[];
    for (final step in [
      ('MCP', mcp.stop),
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
