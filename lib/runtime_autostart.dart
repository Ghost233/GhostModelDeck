import 'engine_catalog.dart';
import 'launch_instances.dart';
import 'sdk_service.dart';

/// Applies explicit startup choices; never infers them from running processes.
class RuntimeAutostart {
  RuntimeAutostart({
    required this.instances,
    required this.settings,
    this.prepare,
  });
  final LaunchInstances instances;
  final StartupModelSet settings;
  final Future<void> Function()? prepare;
  final _failures = <String, String>{};
  Map<String, String> get failures => Map.unmodifiable(_failures);
  EngineCatalog get _catalog => instances.catalog;

  Future<void> initialize() async {
    await settings.load();
    if (settings.autoOpenEngines) await _catalog.setRuntimeEnabled(true);
  }

  Future<void> startSelected() async {
    final generation = _catalog.runtimeGeneration;
    bool current() =>
        _catalog.runtimeEnabled && generation == _catalog.runtimeGeneration;
    await settings.load();
    if (!current()) return;
    final selected = settings.entries;
    _failures.clear();
    if (selected.isEmpty) return;
    await prepare?.call();
    await instances.load();
    if (!current()) return;
    await Future.wait(
      selected.map((entry) async {
        if (!current()) return;
        try {
          await instances.start(entry.instanceId);
        } catch (error) {
          if (current()) _failures[entry.instanceId] = '$error';
        }
      }),
    );
  }
}
