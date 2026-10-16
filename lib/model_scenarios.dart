import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'launch_instances.dart';
import 'public_model_names.dart';

/// A user description and a separately named route to a saved instance.
class ModelScenario {
  const ModelScenario({
    required this.displayName,
    this.modelName = '',
    this.enabled = true,
    this.instanceId,
    this.councilId,
  });

  final String displayName;
  final String modelName;
  final bool enabled;
  final String? instanceId;
  final String? councilId;

  Map<String, Object?> toJson() => {
    'display_name': displayName,
    'model': modelName,
    'enabled': enabled,
    'instance_id': instanceId,
    'council_id': councilId,
  };

  factory ModelScenario.fromJson(Object? value) {
    if (value is! Map ||
        value['display_name'] is! String ||
        value['model'] is! String ||
        value['enabled'] is! bool ||
        value['instance_id'] != null && value['instance_id'] is! String ||
        value['council_id'] != null && value['council_id'] is! String) {
      throw const FormatException('场景配置格式无效');
    }
    return ModelScenario(
      displayName: value['display_name'],
      modelName: value['model'],
      enabled: value['enabled'],
      instanceId: value['instance_id'],
      councilId: value['council_id'],
    );
  }
}

/// Four fixed, initially unconfigured slots used for default MCP discovery.
class ModelScenarios {
  ModelScenarios({
    this.file,
    required this.names,
    this.instances,
    this.councilExists,
    this.isModelLocked,
  });

  final File? file;
  final PublicModelNames names;
  final LaunchInstances? instances;
  final bool Function(String id)? councilExists;
  final bool Function(String model)? isModelLocked;
  List<ModelScenario> _entries = const [
    ModelScenario(displayName: '短上下文'),
    ModelScenario(displayName: '长上下文'),
    ModelScenario(displayName: '短上下文＋视觉'),
    ModelScenario(displayName: '长上下文＋视觉'),
  ];
  List<ModelScenario> get entries => List.unmodifiable(_entries);
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  bool _loaded = false;
  bool _closed = false;
  Future<void>? _loading;
  Future<void> _operations = Future.value();
  int _pendingWrites = 0;
  bool get isSaving => _pendingWrites > 0;

  Future<void> load() {
    if (_closed) return Future.error(StateError('场景配置已关闭'));
    if (_loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    await instances?.load();
    final source = file;
    if (source != null && await source.exists()) {
      final value = jsonDecode(await source.readAsString());
      if (value is! Map ||
          value['schema'] != 1 ||
          value['scenarios'] is! List) {
        throw const FormatException('场景登记格式无效');
      }
      final entries = (value['scenarios'] as List)
          .map(ModelScenario.fromJson)
          .toList();
      _validate(entries);
      names.claimAll({
        for (var i = 0; i < entries.length; i++)
          if (entries[i].modelName.isNotEmpty)
            'scenario:$i': entries[i].modelName,
      });
      _entries = List.unmodifiable(entries);
    }
    _loaded = true;
  }

  void _validate(List<ModelScenario> entries) {
    if (entries.length != 4) throw const FormatException('必须保留四个场景');
    final configuredNames = <String>{};
    for (final entry in entries) {
      if (entry.instanceId != null && entry.councilId != null) {
        throw const FormatException('场景只能选择实例或委员会之一');
      }
      if (entry.displayName.trim().isEmpty ||
          entry.modelName.isNotEmpty &&
              (!PublicModelNames.isValid(entry.modelName) ||
                  !configuredNames.add(entry.modelName))) {
        throw const FormatException('场景名称为空或模型名字无效／重复');
      }
    }
  }

  Future<void> save(int slot, ModelScenario scenario) {
    if (_closed) return Future.error(StateError('场景配置已关闭'));
    _pendingWrites++;
    final operation = _operations
        .then((_) async {
          await load();
          if (slot < 0 || slot >= 4) throw RangeError.index(slot, _entries);
          final previous = _entries[slot];
          final routeChanged =
              previous.modelName != scenario.modelName ||
              previous.instanceId != scenario.instanceId ||
              previous.councilId != scenario.councilId ||
              previous.enabled != scenario.enabled;
          if (routeChanged && isModelLocked?.call(previous.modelName) == true) {
            throw StateError('模型正在参与评测，场景绑定与调用名已锁定');
          }
          if (scenario.instanceId != null &&
              scenario.instanceId != previous.instanceId &&
              instances?.find(scenario.instanceId!) == null) {
            throw ArgumentError('请选择已保存实例');
          }
          if (scenario.councilId != null &&
              scenario.councilId != previous.councilId &&
              councilExists?.call(scenario.councilId!) != true) {
            throw ArgumentError('请选择已保存委员会');
          }
          final next = [..._entries]..[slot] = scenario;
          _validate(next);
          final owner = 'scenario:$slot';
          if (scenario.modelName.isNotEmpty) {
            names.claim(owner, scenario.modelName);
          }
          try {
            final destination = file;
            if (destination != null) {
              await destination.parent.create(recursive: true);
              final temporary = File('${destination.path}.tmp');
              await temporary.writeAsString(
                jsonEncode({
                  'schema': 1,
                  'scenarios': [for (final entry in next) entry.toJson()],
                }),
                flush: true,
              );
              await temporary.rename(destination.path);
            }
          } catch (_) {
            if (previous.modelName != scenario.modelName) {
              names.release(owner, scenario.modelName);
            }
            rethrow;
          }
          if (previous.modelName != scenario.modelName) {
            names.release(owner, previous.modelName);
          }
          _entries = List.unmodifiable(next);
          if (!_changes.isClosed) _changes.add(null);
        })
        .whenComplete(() => _pendingWrites--);
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operations;
    await _loading;
    for (var i = 0; i < _entries.length; i++) {
      names.release('scenario:$i', _entries[i].modelName);
    }
    await _changes.close();
  }
}
