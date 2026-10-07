import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'council.dart';
import 'decision_protocol.dart';
import 'engine_catalog.dart';
import 'engine_runtime.dart';
import 'llama_engine.dart';
import 'model_library.dart';

enum JevModelSource { council, native }

class JevRequestException extends DecisionProtocolException {
  const JevRequestException(this.statusCode, this.code, super.message);
  final int statusCode;
  final String code;
  Map<String, Object> toJson() => {
    'error': {'code': code, 'message': message},
  };
}

/// Stable identity of a local model/engine combination, never a runtime alias.
class JevModelBinding {
  const JevModelBinding({required this.artifactId, required this.engineId});
  final String artifactId;
  final String engineId;
  String get id => '$engineId/$artifactId';
  Map<String, Object> toJson() => {
    'artifact_id': artifactId,
    'engine_id': engineId,
  };
}

class JevModelDefinition {
  JevModelDefinition.council({
    required this.name,
    required List<JevModelBinding> seats,
    required this.timeout,
  }) : source = JevModelSource.council,
       bindings = List.unmodifiable(seats) {
    _validate();
  }
  JevModelDefinition.native({
    required this.name,
    required JevModelBinding binding,
  }) : source = JevModelSource.native,
       bindings = List.unmodifiable([binding]),
       timeout = const Duration(seconds: 10) {
    _validate();
  }
  final String name;
  final JevModelSource source;
  final List<JevModelBinding> bindings;
  final Duration timeout;
  void _validate() {
    if (name.trim().isEmpty || name != name.trim()) {
      throw const DecisionProtocolException('调用名必须是非空且无首尾空白的名称');
    }
    if (bindings.isEmpty ||
        bindings.map((b) => b.id).toSet().length != bindings.length) {
      throw const DecisionProtocolException('需要至少一个席位，且同一模型与引擎不能重复占席');
    }
    if (timeout <= Duration.zero) {
      throw const DecisionProtocolException('整轮超时预算必须大于零');
    }
  }

  Map<String, Object> toJson() => {
    'name': name,
    'source': source.name,
    'bindings': [for (final b in bindings) b.toJson()],
    'timeout_us': timeout.inMicroseconds,
  };
}

class JevModelAvailability {
  const JevModelAvailability(
    this.definition,
    this.reason, {
    required this.available,
  });
  final JevModelDefinition definition;
  final String? reason;
  final bool available;
  Map<String, Object> toJson() => {
    'id': definition.name,
    'source': definition.source.name,
  };
}

/// Filesystem boundary for reading and atomically replacing the registry.
abstract interface class JevRegistryIO {
  Future<String?> read(File file);
  Future<void> write(File file, String contents);
}

class NativeJevRegistryIO implements JevRegistryIO {
  @override
  Future<String?> read(File file) async =>
      await file.exists() ? await file.readAsString() : null;

  @override
  Future<void> write(File file, String contents) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
  }
}

/// One named-model registry for desktop, HTTP and MCP on the same running graph.
class JevModels {
  JevModels({
    required this.controller,
    this.registryFile,
    JevRegistryIO? registryIO,
  }) : registryIO = registryIO ?? NativeJevRegistryIO() {
    _subscription = controller.catalog.changes.listen((_) => _publish());
  }
  final CouncilController controller;
  final File? registryFile;
  final JevRegistryIO registryIO;
  final _changes = StreamController<void>.broadcast();
  late final StreamSubscription<EngineCatalogState> _subscription;
  List<JevModelDefinition> _definitions = const [];
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _operations = Future.value();
  bool _sealed = false;
  ({Object error, StackTrace stack})? _storageFailure;
  Future<void>? _shutdown;
  Future<void>? _close;
  Stream<void> get changes => _changes.stream;
  List<JevModelDefinition> get definitions => _definitions;

  List<JevModelBinding> get availableBindings => List.unmodifiable([
    for (final engine in controller.catalog.state.entries)
      if (engine.family == EngineFamily.llamaCpp &&
          controller.catalog.providerFor(engine.id).release.supportsSystemone)
        for (final asset in controller.catalog.library.state.artifacts)
          if (asset.kind == AssetKind.decision)
            JevModelBinding(artifactId: asset.id, engineId: engine.id),
  ]);

  String bindingLabel(JevModelBinding binding) {
    final asset = controller.catalog.library.state.artifacts
        .where((a) => a.id == binding.artifactId)
        .firstOrNull;
    final engine = controller.catalog.state.entries
        .where((e) => e.id == binding.engineId)
        .firstOrNull;
    return '${asset?.name ?? binding.artifactId} · ${engine?.name ?? binding.engineId}';
  }

  List<JevModelAvailability> get configuredModels => List.unmodifiable([
    for (final definition in _definitions) _availability(definition),
  ]);
  List<JevModelAvailability> get callableModels =>
      List.unmodifiable(configuredModels.where((m) => m.available));

  String? bindingReason(JevModelBinding binding) {
    try {
      _resolve(binding);
      return null;
    } on JevRequestException catch (error) {
      return error.message;
    }
  }

  JevModelAvailability _availability(JevModelDefinition definition) {
    final reasons = <String>[];
    var ready = 0;
    for (final binding in definition.bindings) {
      final reason = bindingReason(binding);
      if (reason == null) {
        ready++;
      } else {
        reasons.add('${bindingLabel(binding)}：$reason');
      }
    }
    return JevModelAvailability(
      definition,
      reasons.isEmpty ? null : reasons.join('；'),
      available: ready > 0,
    );
  }

  CouncilSeat _resolve(JevModelBinding binding) {
    final engine = controller.catalog.state.entries
        .where(
          (e) => e.id == binding.engineId && e.family == EngineFamily.llamaCpp,
        )
        .firstOrNull;
    if (engine == null) {
      throw const JevRequestException(503, 'model_not_ready', '引擎未登记');
    }
    final ready = controller.catalog
        .providerFor(engine.id)
        .state
        .instances
        .where(
          (instance) =>
              instance.asset.id == binding.artifactId &&
              instance.status == LlamaInstanceStatus.ready &&
              instance.acceptingRequests &&
              instance.hasLiveProcess &&
              instance.capabilities.contains(LlamaCapability.choiceProbability),
        )
        .toList();
    if (ready.isEmpty) {
      throw const JevRequestException(
        503,
        'model_not_ready',
        '没有就绪的 JEV 实例；配置不会自动加载模型',
      );
    }
    if (ready.length != 1) {
      throw const JevRequestException(
        409,
        'route_conflict',
        '绑定歧义：存在多个就绪 JEV 实例',
      );
    }
    return CouncilSeat(engine: engine, instance: ready.single);
  }

  Future<void> load() {
    if (_sealed || controller.isShuttingDown) {
      return Future.error(StateError('应用正在退出'));
    }
    return _restore();
  }

  Future<void> _restore() {
    if (_loaded) return Future.value();
    return _loading ??= _load()
        .then<void>(
          (_) {
            _storageFailure = null;
          },
          onError: (Object error, StackTrace stack) {
            _storageFailure = (error: error, stack: stack);
            Error.throwWithStackTrace(error, stack);
          },
        )
        .whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final file = registryFile;
    final contents = file == null ? null : await registryIO.read(file);
    if (contents == null) {
      _loaded = true;
      return;
    }
    try {
      final value = jsonDecode(contents);
      if (value is! Map || value['schema'] != 1 || value['models'] is! List) {
        throw const FormatException('登记格式无效');
      }
      final models = <JevModelDefinition>[];
      for (final entry in value['models'] as List) {
        if (entry is! Map ||
            entry['name'] is! String ||
            entry['bindings'] is! List ||
            entry['timeout_us'] is! int) {
          throw const FormatException('配置格式无效');
        }
        final bindings = <JevModelBinding>[];
        for (final binding in entry['bindings'] as List) {
          if (binding is! Map ||
              binding['artifact_id'] is! String ||
              binding['engine_id'] is! String) {
            throw const FormatException('绑定格式无效');
          }
          bindings.add(
            JevModelBinding(
              artifactId: binding['artifact_id'] as String,
              engineId: binding['engine_id'] as String,
            ),
          );
        }
        models.add(switch (entry['source']) {
          'council' => JevModelDefinition.council(
            name: entry['name'] as String,
            seats: bindings,
            timeout: Duration(microseconds: entry['timeout_us'] as int),
          ),
          'native'
              when bindings.length == 1 && entry['timeout_us'] == 10000000 =>
            JevModelDefinition.native(
              name: entry['name'] as String,
              binding: bindings.single,
            ),
          _ => throw const FormatException('模型来源无效'),
        });
      }
      if (models.map((m) => m.name).toSet().length != models.length) {
        throw const FormatException('调用名重复');
      }
      _definitions = List.unmodifiable(models);
      _loaded = true;
      _publish();
    } on FormatException catch (error) {
      throw DecisionProtocolException('JEV 模型登记文件无效：${error.message}');
    }
  }

  Future<Map<String, Object?>> decide(
    String name,
    DecisionBatchRequest request, {
    DecisionCancellation? cancellation,
    bool debug = false,
  }) async {
    await load();
    if (controller.isShuttingDown) {
      throw const JevRequestException(503, 'service_stopping', '应用正在退出');
    }
    final definition = _definitions.where((m) => m.name == name).firstOrNull;
    if (definition == null) {
      throw const JevRequestException(404, 'model_not_found', '调用模型名不存在');
    }
    if (definition.source == JevModelSource.council) {
      final seats = <CouncilSeat>[];
      final unavailable = <Map<String, Object>>[];
      for (final binding in definition.bindings) {
        try {
          seats.add(_resolve(binding));
        } on JevRequestException catch (error) {
          unavailable.add({
            'binding': binding.toJson(),
            'error': error.toJson()['error']!,
          });
        }
      }
      final result = await controller.consultBatch(
        request,
        timeout: definition.timeout,
        cancellation: cancellation,
        seats: seats,
      );
      if (cancellation?.isCancelled == true) {
        throw const JevRequestException(409, 'cancelled', '本次决策已取消');
      }
      if (controller.isShuttingDown) {
        throw const JevRequestException(503, 'service_stopping', '应用正在退出');
      }
      if (result.status == CouncilStatus.failed) {
        throw const JevRequestException(502, 'no_successful_seats', '没有完整成功席位');
      }
      return {
        ...result.standardResult(definition.name),
        if (debug)
          'debug': {
            'source': 'council',
            'configuration': definition.toJson(),
            'unavailable_seats': unavailable,
            'council': result.toJson(),
          },
      };
    }
    final seat = _resolve(definition.bindings.single);
    if (request.questions.values.any(
      (q) =>
          !seat.instance.capabilities.contains(capabilityForPrimitive(q.type)),
    )) {
      throw const JevRequestException(
        409,
        'capability_mismatch',
        '所选原生实例没有本次请求需要的题型能力',
      );
    }
    try {
      final result = await controller.catalog
          .providerFor(seat.engine.id)
          .decideBatch(
            seat.instance.id,
            request,
            timeout: definition.timeout,
            cancellation: cancellation,
          );
      // Deliver the engine's queued result notification before committing output.
      await Future<void>.value();
      if (cancellation?.isCancelled == true) {
        throw const JevRequestException(409, 'cancelled', '本次决策已取消');
      }
      if (controller.isShuttingDown) {
        throw const JevRequestException(503, 'service_stopping', '应用正在退出');
      }
      return {
        ...result.toJson(publicModel: definition.name),
        if (debug)
          'debug': {
            'source': 'native',
            'configuration': definition.toJson(),
            'instance_id': seat.instance.id,
            'request': request.toSystemone(model: seat.instance.id),
            'raw_response': jsonDecode(result.rawResponse),
            'elapsed_us': result.elapsed.inMicroseconds,
          },
      };
    } on LlamaRequestException catch (error) {
      throw JevRequestException(
        switch (error.kind) {
          DecisionFailureKind.timedOut => 504,
          DecisionFailureKind.cancelled => 409,
          DecisionFailureKind.notReady => 503,
          _ => 502,
        },
        switch (error.kind) {
          DecisionFailureKind.timedOut => 'timed_out',
          DecisionFailureKind.cancelled => 'cancelled',
          DecisionFailureKind.notReady => 'model_not_ready',
          DecisionFailureKind.invalidResponse => 'invalid_response',
          _ => 'engine_error',
        },
        error.message,
      );
    } on LlamaEngineException catch (error) {
      throw JevRequestException(502, 'engine_error', error.message);
    } on FormatException {
      throw const JevRequestException(502, 'invalid_response', '引擎响应不是有效 JSON');
    }
  }

  Future<void> save(JevModelDefinition definition, {String? replacing}) =>
      _serial(() async {
        await _restore();
        if (replacing != null &&
            !_definitions.any((m) => m.name == replacing)) {
          throw const DecisionProtocolException('待编辑的模型配置不存在');
        }
        if (_definitions.any(
          (m) => m.name == definition.name && m.name != replacing,
        )) {
          throw const DecisionProtocolException('调用名已存在，委员会与原生模型必须使用唯一名称');
        }
        final registered = availableBindings.map((b) => b.id).toSet();
        if (definition.bindings.any((b) => !registered.contains(b.id))) {
          throw const DecisionProtocolException('席位必须绑定已登记的本机 JEV 模型与兼容引擎');
        }
        await _store([
          for (final m in _definitions)
            if (m.name != replacing) m,
          definition,
        ]);
      });

  Future<void> delete(String name) => _serial(() async {
    await _restore();
    if (!_definitions.any((m) => m.name == name)) {
      throw const DecisionProtocolException('模型配置不存在');
    }
    await _store([
      for (final m in _definitions)
        if (m.name != name) m,
    ]);
  });

  Future<void> _store(List<JevModelDefinition> models) async {
    final file = registryFile;
    if (file != null) {
      try {
        await registryIO.write(
          file,
          jsonEncode({
            'schema': 1,
            'models': [for (final m in models) m.toJson()],
          }),
        );
        _storageFailure = null;
      } catch (error, stack) {
        _storageFailure = (error: error, stack: stack);
        rethrow;
      }
    }
    _definitions = List.unmodifiable(models);
    _publish();
  }

  Future<void> _serial(Future<void> Function() action) {
    if (_sealed || controller.isShuttingDown) {
      return Future.error(StateError('应用正在退出'));
    }
    final future = _operations.then((_) => action());
    _operations = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> shutdown() {
    _sealed = true;
    return _shutdown ??= _drain();
  }

  Future<void> _drain() async {
    await _operations;
    await _loading;
    final failure = _storageFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }

  Future<void> close() => _close ??= _closeResources();

  Future<void> _closeResources() async {
    try {
      await shutdown();
    } finally {
      await _subscription.cancel();
      await _changes.close();
    }
  }
}

/// Current typed input boundary shared by HTTP, MCP and the desktop form.
/// JSON task contents are retained in the immutable production request.
class JevModelRequest {
  const JevModelRequest(this.model, this.request, this.debug);
  final String model;
  final DecisionBatchRequest request;
  final bool debug;

  static JevModelRequest parse(Object? value) {
    if (value is! Map) throw const DecisionProtocolException('请求需要是 JSON 对象');
    final model = value['model'];
    if (model is! String || model.trim().isEmpty) {
      throw const DecisionProtocolException('model 需要是非空字符串');
    }
    _fields(value, const {
      'model',
      'state',
      'questions',
      'stream',
      'debug',
      'images',
    });
    if (value['state'] == null || value['questions'] is! Map) {
      throw const DecisionProtocolException(
        'state 需要是非 null JSON，questions 需要是对象',
      );
    }
    if (value.containsKey('debug') && value['debug'] is! bool ||
        value.containsKey('stream') && value['stream'] is! bool) {
      throw const DecisionProtocolException('debug 与 stream 需要是布尔值');
    }
    final questions = <String, DecisionQuestion>{};
    for (final entry in (value['questions'] as Map).entries) {
      final question = entry.value;
      if (entry.key is! String ||
          question is! Map ||
          question['instructions'] == null) {
        throw const DecisionProtocolException(
          '题目需要非空 ID、题型与非 null instructions',
        );
      }
      _fields(question, const {'type', 'instructions', 'criteria'});
      final instructions = question['instructions'] as Object;
      final criteria = question['criteria'];
      questions[entry.key as String] = switch (question['type']) {
        'choice' => ChoiceQuestion(
          instructions: instructions,
          options: _descriptions(criteria),
        ),
        'score' when criteria is List => ScoreQuestion(
          instructions: instructions,
          levels: criteria.cast<Object?>(),
        ),
        'noul' => NoulQuestion.fromCriteria(
          instructions: instructions,
          criteria: criteria,
          hasCriteria: question.containsKey('criteria'),
        ),
        _ => throw const DecisionProtocolException('未知题型或 criteria 形状无效'),
      };
    }
    return JevModelRequest(
      model,
      DecisionBatchRequest(
        state: value['state'] as Object,
        questions: questions,
        stream: value['stream'] == true,
        extensions: {
          if (value.containsKey('images')) 'images': value['images'],
        },
      ),
      value['debug'] == true,
    );
  }

  static JevModelRequest single(Map<String, dynamic> value) {
    _fields(value, const {
      'model',
      'state',
      'options',
      'instructions',
      'debug',
    });
    final raw = value['options'];
    if (raw is! List) throw const DecisionProtocolException('options 需要是候选项数组');
    final options = <String, Object?>{};
    for (final option in raw) {
      if (option is! Map ||
          option['id'] is! String ||
          !option.containsKey('text') ||
          options.containsKey(option['id'])) {
        throw const DecisionProtocolException('候选 ID 必须是唯一字符串，text 必须存在');
      }
      _fields(option, const {'id', 'text'});
      options[option['id'] as String] = option['text'];
    }
    return parse({
      'model': value['model'],
      'state': value['state'],
      'debug': value.containsKey('debug') ? value['debug'] : false,
      'questions': {
        'council_choice': {
          'type': 'choice',
          'instructions': value.containsKey('instructions')
              ? value['instructions']
              : '根据上下文，从候选项中选择最合适的一项。',
          'criteria': options,
        },
      },
    });
  }
}

void _fields(Map value, Set<String> allowed) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw DecisionProtocolException('包含不支持的字段：$key');
    }
  }
}

Map<String, Object?> _descriptions(Object? value) {
  if (value is! Map || value.keys.any((k) => k is! String)) {
    throw const DecisionProtocolException(
      'choice criteria 需要是 ID 到 JSON 描述的对象',
    );
  }
  return Map<String, Object?>.from(value);
}
