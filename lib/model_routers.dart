import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'launch_instances.dart';

class ModelRouter {
  ModelRouter({
    required this.name,
    required Iterable<String> candidateIds,
    required this.currentInstanceId,
  }) : candidateIds = List.unmodifiable(candidateIds) {
    if (this.candidateIds.any((id) => id.isEmpty) ||
        this.candidateIds.toSet().length != this.candidateIds.length ||
        !this.candidateIds.contains(currentInstanceId)) {
      throw const FormatException('请选择候选实例和其中一个当前实例');
    }
  }

  final String name;
  final List<String> candidateIds;
  final String currentInstanceId;

  factory ModelRouter.fromJson(Object? value) {
    if (value
        case {
          'model': final String name,
          'candidate_ids': final List<Object?> candidates,
          'current_instance_id': final String current,
        }
        when candidates.every((id) => id is String)) {
      return ModelRouter(
        name: name,
        candidateIds: candidates.cast<String>(),
        currentInstanceId: current,
      );
    }
    throw const FormatException('模型路由配置格式无效');
  }

  Map<String, Object> toJson() => {
    'model': name,
    'candidate_ids': candidateIds,
    'current_instance_id': currentInstanceId,
  };
}

class ModelRouters {
  ModelRouters({required this.file, required this.instances, this.loadNames});

  final File file;
  final LaunchInstances instances;
  final Future<void> Function()? loadNames;
  final _entries = <String, ModelRouter>{};
  final _changes = StreamController<void>.broadcast();
  Future<void>? _loading;
  Future<void> _operations = Future.value();
  Future<void>? _closing;
  Object? _loadError;

  List<ModelRouter> get entries => List.unmodifiable(_entries.values);
  Stream<void> get changes => _changes.stream;
  Object? get loadError => _loadError;
  ModelRouter? find(String name) => _entries[name];

  Future<void> load() {
    if (_closing != null) return Future.error(StateError('模型路由已关闭'));
    return _loading ??= _load().then<void>(
      (_) {
        _loadError = null;
        _changes.add(null);
      },
      onError: (Object error, StackTrace stack) {
        _loading = null;
        _loadError = error;
        _changes.add(null);
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Future<void> _load() async {
    await instances.load();
    await loadNames?.call();
    if (!await file.exists()) return;
    final Object? value = jsonDecode(await file.readAsString());
    if (value case {'schema': 1, 'routers': final List<Object?> routers}) {
      final loaded = routers.map(ModelRouter.fromJson).toList();
      final byName = {for (final router in loaded) router.name: router};
      if (byName.length != loaded.length) {
        throw const FormatException('模型路由调用名重复');
      }
      instances.names.claimAll({
        for (final name in byName.keys) 'router:$name': name,
      }, allowUnderscore: true);
      _entries.addAll(byName);
      return;
    }
    throw const FormatException('模型路由登记格式无效');
  }

  Future<void> create(ModelRouter router) => _serial(() async {
    final name = router.name;
    if (_entries.containsKey(name)) throw StateError('调用名 $name 已存在');
    _validateCandidates(router);
    instances.names.claim('router:$name', name, allowUnderscore: true);
    try {
      await _persist({..._entries, name: router});
    } catch (_) {
      instances.names.release('router:$name', name);
      rethrow;
    }
  });

  Future<void> update(ModelRouter router) => _serial(() async {
    final previous = _require(router.name);
    _validateCandidates(router, previous: previous);
    await _persist({..._entries, router.name: router});
  });

  Future<void> select(String name, String instanceId) => _serial(() async {
    final previous = _require(name);
    if (instanceId == previous.currentInstanceId) return;
    final router = ModelRouter(
      name: name,
      candidateIds: previous.candidateIds,
      currentInstanceId: instanceId,
    );
    _validateCandidate(instanceId);
    await _persist({..._entries, name: router});
  });

  Future<void> delete(String name) => _serial(() async {
    _require(name);
    await _persist({..._entries}..remove(name));
    instances.names.release('router:$name', name);
  });

  ModelRouter _require(String name) =>
      find(name) ?? (throw StateError('模型路由 $name 不存在'));

  void _validateCandidates(ModelRouter router, {ModelRouter? previous}) {
    for (final id in router.candidateIds) {
      if (previous?.candidateIds.contains(id) != true ||
          id == router.currentInstanceId && id != previous?.currentInstanceId) {
        _validateCandidate(id);
      }
    }
  }

  void _validateCandidate(String id) {
    if (instances.find(id) == null) {
      throw ArgumentError('请选择已保存的实例');
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    if (_closing != null) return Future.error(StateError('模型路由已关闭'));
    final loaded = load();
    loaded.ignore();
    final operation = _operations.then((_) async {
      await loaded;
      await action();
    });
    _operations = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _persist(Map<String, ModelRouter> next) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'routers': next.values.map((router) => router.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
    _entries
      ..clear()
      ..addAll(next);
    _changes.add(null);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _operations;
    await _loading?.then<void>((_) {}, onError: (Object _) {});
    for (final name in _entries.keys) {
      instances.names.release('router:$name', name);
    }
    await _changes.close();
  }
}
