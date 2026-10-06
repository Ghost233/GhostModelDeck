import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/omlx_engine.dart';

import 'fixtures/qwen2_mlx_layout.dart';

ProcessResult _fakeResult(int exitCode, String stdout, {String stderr = ''}) =>
    ProcessResult(4242, exitCode, stdout, stderr);

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Tests re-arm these completers; a second signal must never throw inside
/// the fake service (a StateError there would silently empty a 200 response).
void _signal(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

/// Same bundle-validation answers as the installer suite, except that chmod
/// runs for real so the pool's 0700/0600 credential files can be asserted.
class _PoolBundleIO implements OmlxProcessIO {
  _PoolBundleIO(this.bundle);
  final Directory bundle;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    if (executable == '/bin/chmod') return Process.run(executable, arguments);
    if (executable == '/usr/bin/id') return _fakeResult(0, '501\n');
    if (executable == '/usr/bin/stat') {
      if (arguments.last.startsWith('/Users/cryingneko')) {
        return _fakeResult(1, '', stderr: 'No such file or directory');
      }
      return _fakeResult(
        0,
        List.filled(arguments.length - 2, '501:20:0700:Directory').join('\n'),
      );
    }
    if (executable == '/bin/ls') {
      return _fakeResult(
        0,
        List.filled(
          arguments.length - 1,
          'drwx------  owner group path',
        ).join('\n'),
      );
    }
    if (executable == '/usr/bin/codesign' && arguments.first == '--verify') {
      return _fakeResult(0, '');
    }
    if (executable == '/usr/sbin/spctl') {
      return _fakeResult(0, '', stderr: 'accepted');
    }
    if (executable == '/usr/bin/codesign') {
      return _fakeResult(
        0,
        '',
        stderr: 'Identifier=app.omlx\nTeamIdentifier=PSK5Q5T46L\n',
      );
    }
    if (executable == '/usr/bin/plutil') {
      return _fakeResult(
        0,
        jsonEncode({
          'CFBundleIdentifier': 'app.omlx',
          'CFBundleShortVersionString': '0.7.0',
          'CFBundleVersion': '2987',
        }),
      );
    }
    if (executable.endsWith('/omlx-cli')) return _fakeResult(0, '0.7.0\n');
    if (executable.endsWith('/python3')) {
      final script = arguments.last;
      if (!script.contains('omlx.__version__')) {
        return _fakeResult(
          1,
          '',
          stderr: 'importlib.metadata.PackageNotFoundError',
        );
      }
      return _fakeResult(
        0,
        jsonEncode({
          'python': '3.11.10',
          'architecture': 'arm64',
          'prefix': '${bundle.path}/Contents/Resources/Python/cpython-3.11',
          'paths': [bundle.path, OmlxEngine.builderPath, workingDirectory],
          'origins': ['${bundle.path}/Contents/Resources/omlx/__init__.py'],
          'versions': {
            'omlx': '0.7.0',
            'mlx': '0.32.2',
            'mlx-lm': '0.31.4.dev132+g94cdcae13',
            'fastapi': '0.142.2',
            'transformers': '5.17.0',
          },
          'gpu': [
            [19.0, 22.0],
            [43.0, 50.0],
          ],
        }),
      );
    }
    throw StateError('Unexpected process: $executable $arguments');
  }

  @override
  Future<void> download(Uri url, File destination) =>
      throw UnimplementedError('downloads are not exercised here');
}

class _RecordedRequest {
  const _RecordedRequest(
    this.method,
    this.path,
    this.body,
    this.authorization,
    this.cookie,
  );
  final String method;
  final String path;
  final String? body;
  final String? authorization;
  final String? cookie;
}

class _ServerModel {
  _ServerModel(this.id, this.path);
  final String id;
  final String path;
  bool loaded = false;
  bool pinned = false;
}

/// A boundary double for the oMLX service: a real HTTP server speaking the
/// pinned v0.7.0 contract and adopting the pool-written credentials from the
/// settings.json it finds at the --base-path, with no pool business rules.
class _FakeServer {
  _FakeServer({
    required this.modelRoot,
    required this.apiKey,
    required this.signingSecret,
    this.keepaliveMode = 'chunk',
    this._preloaded = const {},
  });

  final String modelRoot;
  final String apiKey;
  final String signingSecret;

  /// Real 0.7.0 default is 'chunk' (settings.py:198); 'off' disables the
  /// keepalive frames whose model is the literal string 'keepalive'.
  final String keepaliveMode;
  final Set<String> _preloaded;
  final String cookieValue = _token('session');
  final Map<String, _ServerModel> models = {};
  final List<_RecordedRequest> requests = [];
  int port = 0;
  int loginCount = 0;
  bool fallbackDisabled = false;
  bool fallbackLies = false;
  bool leakSecretsInErrors = false;
  bool omitProfileRows = false;
  final Map<String, int> loadFailures = {};
  final Map<String, int> unloadFailures = {};
  final Set<String> chatRefusals = {};
  final Set<String> statusLoadingForever = {};
  final Set<String> statusNeverLoaded = {};
  String streamMode = 'ok'; // ok | missingUsage | missingDone | held
  Completer<void>? chatGate;
  Completer<void> chatStarted = Completer<void>();
  Completer<void>? streamGate;
  Completer<void> streamStarted = Completer<void>();
  Completer<void>? unloadGate;
  Completer<void> unloadStarted = Completer<void>();
  HttpServer? _http;

  static String _token(String prefix) {
    final random = Random.secure();
    final value = List.generate(
      24,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$prefix-$value';
  }

  Future<void> start(int requestedPort) async {
    await for (final entity in Directory(modelRoot).list()) {
      if (entity is Directory) {
        final id = _baseName(entity.path);
        models[id] = _ServerModel(id, entity.path)
          ..loaded = _preloaded.contains(id)
          ..pinned = _preloaded.contains(id);
      }
    }
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, requestedPort);
    port = _http!.port;
    _http!.listen(_handle);
  }

  Future<void> close() async {
    await _http?.close(force: true);
  }

  Iterable<_RecordedRequest> requestsTo(String path) =>
      requests.where((r) => r.path == path);

  bool _bearerOk(_RecordedRequest r) => r.authorization == 'Bearer $apiKey';
  bool _adminOk(_RecordedRequest r) => (r.cookie ?? '')
      .split(';')
      .any((part) => part.trim() == 'omlx_admin_session=$cookieValue');

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final recorded = _RecordedRequest(
      request.method,
      request.uri.path,
      body.isEmpty ? null : body,
      request.headers.value('authorization'),
      request.headers.value('cookie'),
    );
    requests.add(recorded);
    final segments = request.uri.pathSegments;
    try {
      if (segments.length == 1 && segments[0] == 'health') {
        await _json(request, 200, {'status': 'healthy'});
        return;
      }
      if (segments.length == 3 &&
          segments[0] == 'admin' &&
          segments[1] == 'api' &&
          segments[2] == 'login' &&
          request.method == 'POST') {
        loginCount++;
        final payload = jsonDecode(body);
        if (payload is Map &&
            payload['api_key'] == apiKey &&
            payload['remember'] == false) {
          request.response.headers.add(
            'set-cookie',
            'omlx_admin_session=$cookieValue; HttpOnly; SameSite=lax',
          );
          await _json(request, 200, {'success': true});
        } else {
          await _json(request, 401, {'error': 'invalid credentials'});
        }
        return;
      }
      if (segments.length == 3 &&
          segments[0] == 'admin' &&
          segments[1] == 'api' &&
          segments[2] == 'global-settings') {
        if (!_adminOk(recorded)) {
          await _json(request, 401, {'error': 'unauthorized'});
          return;
        }
        if (request.method == 'GET') {
          // Real 0.7.0 shape: nested readback plus raw secrets. The pool may
          // project model_fallback in memory but must never leak this body.
          await _json(request, 200, {
            'model': {
              'model_fallback': fallbackLies ? true : !fallbackDisabled,
            },
            'auth': {
              'api_key': apiKey,
              'secret_key': signingSecret,
              'sub_keys': [],
            },
          });
          return;
        }
        if (request.method == 'POST') {
          final payload = jsonDecode(body);
          if (payload is Map && payload['model_fallback'] == false) {
            fallbackDisabled = true;
            // Real packaged 0.7.0 response: no settings echo (issue #22).
            await _json(request, 200, {
              'success': true,
              'runtime_applied': ['model_fallback'],
            });
          } else {
            await _json(request, 400, {'error': 'unsupported change'});
          }
          return;
        }
      }
      if (segments.length == 5 &&
          segments[0] == 'admin' &&
          segments[1] == 'api' &&
          segments[2] == 'models' &&
          segments[4] == 'settings' &&
          request.method == 'PUT') {
        if (!_adminOk(recorded)) {
          await _json(request, 401, {'error': 'unauthorized'});
          return;
        }
        final model = models[segments[3]];
        if (model == null) {
          await _json(request, 404, {'error': 'unknown model'});
          return;
        }
        final payload = jsonDecode(body);
        if (payload is Map && payload['is_pinned'] is bool) {
          model.pinned = payload['is_pinned'] as bool;
          await _json(request, 200, {
            'success': true,
            'model_id': model.id,
            'settings': {'is_pinned': model.pinned},
          });
        } else {
          await _json(request, 400, {'error': 'unsupported settings'});
        }
        return;
      }
      if (segments.length == 3 &&
          segments[0] == 'v1' &&
          segments[1] == 'models' &&
          segments[2] == 'status' &&
          request.method == 'GET') {
        if (!_bearerOk(recorded)) {
          await _json(request, 401, {'error': 'unauthorized'});
          return;
        }
        final rows = <Map<String, Object?>>[];
        for (final model in models.values) {
          rows.add(_row(model));
          if (!omitProfileRows) {
            rows.add({
              ..._row(model),
              'id': '${model.id}-profile',
              'source_model_id': model.id,
              'pinned': false,
            });
          }
        }
        await _json(request, 200, {
          'final_ceiling': 1073741824,
          'current_model_memory': 0,
          'model_count': models.length,
          'loaded_count': models.values.where((m) => m.loaded).length,
          'load_seconds_per_gb_estimate': 1.0,
          'load_time_observations': 0,
          'models': rows,
        });
        return;
      }
      if (segments.length == 4 &&
          segments[0] == 'v1' &&
          segments[1] == 'models' &&
          segments[3] == 'load' &&
          request.method == 'POST') {
        if (!_bearerOk(recorded) && !_adminOk(recorded)) {
          await _json(request, 401, {'error': 'unauthorized'});
          return;
        }
        final model = models[segments[2]];
        if (model == null) {
          await _json(request, 404, {'error': 'unknown model'});
          return;
        }
        final failures = loadFailures[model.id] ?? 0;
        if (failures > 0) {
          loadFailures[model.id] = failures - 1;
          await _json(request, 500, {
            'error': leakSecretsInErrors
                ? 'load failed, retry with $apiKey'
                : 'load failed',
          });
          return;
        }
        model.loaded = true;
        await _json(request, 200, {
          'status': 'ok',
          'model_id': model.id,
          'message': 'Loaded ${model.id}',
        });
        return;
      }
      if (segments.length == 4 &&
          segments[0] == 'v1' &&
          segments[1] == 'models' &&
          segments[3] == 'unload' &&
          request.method == 'POST') {
        if (!_bearerOk(recorded)) {
          await _json(request, 401, {'error': 'unauthorized'});
          return;
        }
        final model = models[segments[2]];
        if (model == null) {
          await _json(request, 404, {'error': 'unknown model'});
          return;
        }
        final gate = unloadGate;
        if (gate != null && !gate.isCompleted) {
          _signal(unloadStarted);
          await gate.future;
        }
        final failures = unloadFailures[model.id] ?? 0;
        if (failures > 0) {
          unloadFailures[model.id] = failures - 1;
          await _json(request, 500, {'error': 'unload failed'});
          return;
        }
        if (!model.loaded) {
          await _json(request, 400, {'error': 'model is not loaded'});
          return;
        }
        model.loaded = false;
        await _json(request, 200, {'status': 'ok', 'model_id': model.id});
        return;
      }
      if (segments.length == 3 &&
          segments[0] == 'v1' &&
          segments[1] == 'chat' &&
          segments[2] == 'completions' &&
          request.method == 'POST') {
        if (!_bearerOk(recorded)) {
          await _json(request, 401, {'error': 'unauthorized'});
          return;
        }
        final payload = jsonDecode(body);
        final model = payload is Map ? payload['model'] as String? : null;
        if (model == null || chatRefusals.contains(model)) {
          await _json(request, 400, {'error': 'chat refused'});
          return;
        }
        if (payload is Map && payload['stream'] == true) {
          await _stream(request, model);
          return;
        }
        _signal(chatStarted);
        final gate = chatGate;
        if (gate != null && !gate.isCompleted) await gate.future;
        await _json(request, 200, {
          'id': 'cmpl-1',
          'model': model,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'reply-$model'},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 3,
            'completion_tokens': 1,
            'total_tokens': 4,
          },
        });
        return;
      }
      await _json(request, 404, {'error': 'not found'});
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {
        /* Client aborted mid-flight. */
      }
    }
  }

  Map<String, Object?> _row(_ServerModel model) => {
    'id': model.id,
    'model_path': model.path,
    'loaded': statusNeverLoaded.contains(model.id) ? false : model.loaded,
    'is_loading': statusLoadingForever.contains(model.id),
    'loading_started_at': null,
    'estimated_size': 1,
    'resident_estimated_size': 1,
    'distributed': false,
    'cluster': <Object?>[],
    'actual_size': null,
    'pinned': model.pinned,
    'engine_type': 'mlx',
    'model_type': 'text',
    'config_model_type': 'qwen2',
    'realtime_stt': false,
    'model_context_length': 4096,
    'is_helper': false,
    'thinking_default': false,
    'preserve_thinking_default': false,
    'source_type': 'local',
    'source_repo_id': null,
    'last_access': null,
    'max_context_window': 4096,
    'max_tokens': 4096,
    'is_favorite': false,
    'is_hidden': false,
  };

  Future<void> _stream(HttpRequest request, String model) async {
    _signal(streamStarted);
    final response = request.response;
    response.statusCode = 200;
    response.headers.contentType = ContentType('text', 'event-stream');
    void frame(Map<String, Object?> value) {
      response.write('data: ${jsonEncode(value)}\n\n');
    }

    try {
      // Real 0.7.0 behavior (server.py _chat_keepalive_chunk, 2521–2546):
      // with the default sse_keepalive_mode='chunk' every streaming chat
      // unconditionally begins with a keepalive frame whose model is the
      // literal string 'keepalive'.
      if (keepaliveMode == 'chunk') {
        frame({
          'id': 'c1',
          'model': 'keepalive',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': ''},
              'finish_reason': null,
            },
          ],
        });
      }
      frame({
        'id': 'c1',
        'model': model,
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant'},
          },
        ],
      });
      frame({
        'id': 'c1',
        'model': model,
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'Hello'},
          },
        ],
      });
      await response.flush();
      if (streamMode == 'held') {
        final gate = streamGate;
        await (gate?.future ??
            Future<void>.delayed(const Duration(minutes: 5)));
        frame({
          'id': 'c1',
          'model': model,
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'late'},
            },
          ],
        });
        await response.flush();
        await response.close();
        return;
      }
      frame({
        'id': 'c1',
        'model': model,
        'choices': [
          {
            'index': 0,
            'delta': {'content': ' there'},
          },
        ],
      });
      frame({
        'id': 'c1',
        'model': model,
        'choices': [
          {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
        ],
      });
      if (streamMode == 'missingUsage') {
        response.write('data: [DONE]\n\n');
        await response.close();
        return;
      }
      frame({
        'id': 'c1',
        'model': model,
        'choices': <Object?>[],
        'usage': {
          'prompt_tokens': 3,
          'completion_tokens': 2,
          'total_tokens': 5,
        },
      });
      if (streamMode != 'missingDone') response.write('data: [DONE]\n\n');
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {
        /* Client aborted mid-stream. */
      }
    }
  }
}

class _FakePoolChild implements OmlxPoolChild {
  _FakePoolChild(this.server);
  final _FakeServer server;
  static int _nextPid = 7000;
  @override
  final int pid = _nextPid++;
  final List<ProcessSignal> signals = [];
  final _exit = Completer<int>();
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  bool ignoreSigterm = false;
  bool neverDies = false;

  @override
  Future<int> get exitCode => _exit.future;
  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (neverDies) return;
    if (signal == ProcessSignal.sigterm && ignoreSigterm) return;
    die(1);
  }

  void die(int code) {
    if (_exit.isCompleted) return;
    unawaited(server.close());
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(code);
  }
}

/// Records spawn arguments and hands out fake children; no pooling logic.
class _FakePoolIO implements OmlxPoolIO {
  final List<String> executables = [];
  final List<List<String>> launches = [];
  final List<String?> workingDirectories = [];
  final List<Map<String, String>> environments = [];
  final List<_FakePoolChild> children = [];
  Set<String> preloaded = const {};
  void Function(_FakeServer server)? onServerCreated;

  _FakeServer get server => children.last.server;

  @override
  Future<OmlxPoolChild> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    executables.add(executable);
    launches.add(arguments);
    workingDirectories.add(workingDirectory);
    environments.add(environment);
    // The real service adopts credentials from the settings.json the pool
    // wrote into --base-path before spawning; the double does the same.
    final settings = jsonDecode(
      await File('$workingDirectory/settings.json').readAsString(),
    ) as Map<String, dynamic>;
    final auth = settings['auth'] as Map<String, dynamic>;
    final server = _FakeServer(
      modelRoot: arguments[arguments.indexOf('--model-dir') + 1],
      apiKey: auth['api_key'] as String,
      signingSecret: auth['secret_key'] as String,
      keepaliveMode:
          (settings['server'] as Map?)?['sse_keepalive_mode'] as String? ??
          'chunk',
      preloaded: preloaded,
    );
    onServerCreated?.call(server);
    await server.start(int.parse(arguments[arguments.indexOf('--port') + 1]));
    final child = _FakePoolChild(server);
    children.add(child);
    return child;
  }
}

Future<Directory> _bundle(Directory root) async {
  final app = await Directory('${root.path}/foreign.app').create();
  for (final relative in [
    'Contents/Info.plist',
    'Contents/MacOS/omlx-cli',
    'Contents/Resources/Python/cpython-3.11/bin/python3',
    'Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages/sitecustomize.py',
    'Contents/Resources/omlx/__init__.py',
  ]) {
    final file = File('${app.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString('fixture-only $relative');
  }
  return app;
}

Future<void> _writeModel(
  Directory parent,
  String name, {
  bool chat = true,
}) async {
  final dir = Directory('${parent.path}/$name');
  for (final entry in Qwen2MlxFixture().bytes().entries) {
    final file = File('${dir.path}/${entry.key}');
    await file.parent.create(recursive: true);
    if (entry.key == 'config.json' && !chat) {
      await file.writeAsString(
        jsonEncode({
          'model_type': 'qwen2',
          'architectures': ['Qwen2Model'],
        }),
      );
    } else {
      await file.writeAsBytes(entry.value, flush: true);
    }
  }
}

class _PoolFixture {
  _PoolFixture._();
  late Directory root;
  late Directory modelsRoot;
  late Directory installation;
  late ModelLibrary library;
  late ModelUseRegistry useRegistry;
  late _FakePoolIO poolIo;
  late OmlxEngine engine;
  late List<LibraryArtifact> artifacts;

  static Future<_PoolFixture> create() async {
    final f = _PoolFixture._();
    f.root = await Directory.systemTemp.createTemp('gmd-omlx-pool-');
    f.modelsRoot = await Directory('${f.root.path}/models').create();
    f.installation = Directory('${f.root.path}/owned');
    await _writeModel(f.modelsRoot, 'model-a');
    await _writeModel(f.modelsRoot, 'model-b');
    await _writeModel(f.modelsRoot, 'model-c', chat: false);
    f.library = ModelLibrary();
    f.artifacts = await f.library.scan(f.modelsRoot, verifyFiles: true);
    f.useRegistry = ModelUseRegistry(f.library);
    f.poolIo = _FakePoolIO();
    final version = await Directory('${f.installation.path}/0.7.0')
        .create(recursive: true);
    final app = await (await _bundle(f.root))
        .rename('${version.path}/oMLX.app');
    f.engine = OmlxEngine(
      installationDirectory: f.installation,
      io: _PoolBundleIO(app),
      library: f.library,
      poolIo: f.poolIo,
      useRegistry: f.useRegistry,
      poolLoadTimeout: const Duration(seconds: 10),
      poolStopTimeout: const Duration(milliseconds: 250),
    );
    final receipt = await f.engine.inspectLinked(app);
    await File('${version.path}/installation.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'receipt': {...receipt.toJson(), 'dmgSha256': OmlxEngine.dmgDigest},
      }),
    );
    await f.engine.refreshInstallation();
    assert(f.engine.state.status == OmlxInstallationStatus.installed);
    return f;
  }

  LibraryArtifact artifact(String name) => artifacts.singleWhere(
    (artifact) => artifact.files.every((file) => file.path.contains('/$name/')),
  );

  _FakeServer get server => poolIo.server;

  Future<void> dispose() async {
    engine.close();
    for (final child in poolIo.children) {
      child.ignoreSigterm = false;
      child.neverDies = false;
      child.kill(ProcessSignal.sigkill);
    }
    library.close();
    await root.delete(recursive: true);
  }
}

Matcher _requestKind(OmlxRequestKind kind) =>
    isA<OmlxRequestException>().having((e) => e.kind, 'kind', kind);

void main() {
  test(
    'pool refuses work before verified installation or without a library',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-omlx-pool-cold-');
      addTearDown(() => root.delete(recursive: true));
      final cold = OmlxEngine(
        installationDirectory: Directory('${root.path}/a'),
      );
      addTearDown(cold.close);
      expect(cold.runtimeInstances, isEmpty);
      await expectLater(
        cold.startRuntime('anything'),
        throwsA(isA<OmlxException>()),
      );
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final headless = OmlxEngine(
        installationDirectory: fixture.installation,
        io: _PoolBundleIO(fixture.engine.bundle),
      );
      addTearDown(headless.close);
      await expectLater(
        headless.startRuntime('anything'),
        throwsA(isA<OmlxException>()),
      );
    },
  );

  test(
    'two verified chat models share exactly one owned pool process',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      final b = fixture.artifact('model-b');

      final instanceA = await fixture.engine.startRuntime(a.id);
      final instanceB = await fixture.engine.startRuntime(b.id);

      expect(fixture.poolIo.launches, hasLength(1));
      expect(instanceA.status, RuntimeInstanceStatus.ready);
      expect(instanceB.status, RuntimeInstanceStatus.ready);
      expect(instanceA.capabilities, {RuntimeCapability.textGeneration});
      expect(instanceA.artifactId, a.id);
      expect(instanceB.artifactId, b.id);
      expect(instanceA.acceptingRequests, isTrue);
      expect(instanceA.hasLiveProcess, isTrue);
      expect(instanceA.error, isNull);
      expect(instanceA.generation, instanceB.generation);
      expect(
        fixture.engine.runtimeInstances.map((i) => i.id),
        containsAll([instanceA.id, instanceB.id]),
      );

      final args = fixture.poolIo.launches.single;
      expect(args.first, 'serve');
      expect(args, contains('--no-hf-cache'));
      expect(args[args.indexOf('--host') + 1], '127.0.0.1');
      expect(
        args[args.indexOf('--model-dir') + 1],
        await fixture.modelsRoot.resolveSymbolicLinks(),
      );
      expect(
        args[args.indexOf('--base-path') + 1],
        fixture.poolIo.workingDirectories.single,
      );
      for (final forbidden in [
        '--pin',
        '--loaded-only',
        '--no-auto-load',
        '--fallback',
        '--api-key',
      ]) {
        expect(args, isNot(contains(forbidden)));
      }
      expect(
        fixture.poolIo.executables.single,
        '${fixture.engine.bundle.path}/Contents/MacOS/omlx-cli',
      );

      final replyA = await fixture.engine.generateText(
        instanceA.id,
        TextRequest(prompt: 'Ping', maxTokens: 8),
      );
      expect(replyA.text, 'reply-model-a');
      expect(replyA.model, 'model-a');
      expect(replyA.finishReason, 'stop');
      expect(replyA.outputTokens, 1);
      final replyB = await fixture.engine.generateText(
        instanceB.id,
        TextRequest(prompt: 'Ping', maxTokens: 8),
      );
      expect(replyB.text, 'reply-model-b');
      // Exactly one native service served both instances.
      expect(fixture.poolIo.launches, hasLength(1));
      expect(fixture.poolIo.children.single.signals, isEmpty);

      await fixture.engine.stopManaged();
      expect(fixture.poolIo.children.single.signals, [ProcessSignal.sigterm]);
    },
  );

  test(
    'pool credentials: bearer for /v1, cookie for /admin, single login, '
    'private settings file, and fresh credentials per pool generation',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      await fixture.engine.startRuntime(a.id);

      final base = Directory(fixture.poolIo.workingDirectories.single!);
      expect(_baseName(base.path), startsWith('.pool-'));
      expect(
        base.parent.path,
        await fixture.installation.resolveSymbolicLinks(),
      );
      expect((await base.stat()).mode & 0x3f, 0, reason: 'base must be 0700');
      final settingsFile = File('${base.path}/settings.json');
      expect(
        (await settingsFile.stat()).mode & 0x3f,
        0,
        reason: 'settings.json must be 0600',
      );
      final settings =
          jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
      expect(settings['version'], '1.0');
      final serverSection = settings['server'] as Map<String, dynamic>;
      expect(serverSection['host'], '127.0.0.1');
      expect(
        serverSection['port'],
        int.parse(
          fixture.poolIo.launches.single[fixture.poolIo.launches.single.indexOf(
                '--port',
              ) +
              1],
        ),
      );
      final modelSection = settings['model'] as Map<String, dynamic>;
      expect(modelSection['model_dirs'], [
        await fixture.modelsRoot.resolveSymbolicLinks(),
      ]);
      expect(modelSection['model_fallback'], isFalse);
      final auth = settings['auth'] as Map<String, dynamic>;
      expect(auth['skip_api_key_verification'], isFalse);
      expect(auth['allow_unauthenticated_inference'], isFalse);
      expect(auth['sub_keys'], isEmpty);
      final apiKey = auth['api_key'] as String;
      final signingSecret = auth['secret_key'] as String;
      expect(apiKey.length, greaterThanOrEqualTo(32));
      expect(signingSecret.length, greaterThanOrEqualTo(32));
      expect(apiKey, isNot(signingSecret));
      // The service adopted the pool-written credentials.
      expect(apiKey, fixture.server.apiKey);

      // Credentials never travel through argv or the child environment.
      expect(fixture.poolIo.launches.single.join(''), isNot(contains(apiKey)));
      expect(
        jsonEncode(fixture.poolIo.environments.single),
        isNot(contains(apiKey)),
      );
      expect(
        jsonEncode(fixture.poolIo.environments.single),
        isNot(contains(signingSecret)),
      );
      expect(
        fixture.poolIo.environments.single.keys.any(
          (key) =>
              key.startsWith('DYLD') ||
              key.startsWith('OMLX') ||
              key == 'PYTHONPATH' ||
              key == 'PYTHONHOME',
        ),
        isFalse,
      );

      // Every recorded request carried the protocol-correct credential.
      expect(fixture.server.loginCount, 1);
      for (final recorded in fixture.server.requests) {
        if (recorded.path.startsWith('/v1/')) {
          expect(
            recorded.authorization,
            'Bearer $apiKey',
            reason: recorded.path,
          );
        }
        if (recorded.path.startsWith('/admin/api/') &&
            recorded.path != '/admin/api/login') {
          expect(
            recorded.cookie,
            contains('omlx_admin_session='),
            reason: recorded.path,
          );
          expect(recorded.cookie, isNot(contains(apiKey)));
        }
        if (recorded.path == '/admin/api/login') {
          expect(jsonDecode(recorded.body!), {
            'api_key': apiKey,
            'remember': false,
          });
        }
      }

      // A raw client without credentials is rejected by the service itself.
      final raw = HttpClient();
      addTearDown(() => raw.close(force: true));
      Future<int> status(String path, {Map<String, String>? headers}) async {
        final request = await raw.openUrl(
          'GET',
          Uri.parse('http://127.0.0.1:${fixture.server.port}$path'),
        );
        headers?.forEach(request.headers.add);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await status('/v1/models/status'), 401);
      expect(
        await status(
          '/v1/models/status',
          headers: {'authorization': 'Bearer wrong'},
        ),
        401,
      );
      final login = await raw.postUrl(
        Uri.parse('http://127.0.0.1:${fixture.server.port}/admin/api/login'),
      );
      login.write(jsonEncode({'api_key': 'wrong', 'remember': false}));
      final loginResponse = await login.close();
      await loginResponse.drain<void>();
      expect(loginResponse.statusCode, 401);
      expect(
        await status('/admin/api/global-settings'),
        401,
        reason: 'admin endpoints require the session cookie',
      );

      // A new pool generation rotates credentials and owns a new base.
      await fixture.engine.stopManaged();
      expect(await base.exists(), isFalse, reason: 'base is retired with pool');
      final second = await fixture.engine.startRuntime(a.id);
      expect(second.status, RuntimeInstanceStatus.ready);
      expect(fixture.poolIo.launches, hasLength(2));
      final secondSettings = jsonDecode(
        await File('${fixture.poolIo.workingDirectories.last}/settings.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final secondAuth = secondSettings['auth'] as Map<String, dynamic>;
      expect(secondAuth['api_key'], isNot(apiKey));
      expect(secondAuth['secret_key'], isNot(signingSecret));
      // SSE keepalive must be disabled: the real 'chunk' default emits frames
      // whose model is 'keepalive', breaking decoder binding (issue #23).
      expect(
        (secondSettings['server']
            as Map<String, dynamic>)['sse_keepalive_mode'],
        'off',
      );
      expect(fixture.server.loginCount, 1);
    },
  );

  test(
    'server-side secrets never leak into exceptions or projections',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      final b = fixture.artifact('model-b');
      await fixture.engine.startRuntime(a.id);
      final server = fixture.server;

      server.leakSecretsInErrors = true;
      server.loadFailures['model-b'] = 1;
      await expectLater(
        fixture.engine.startRuntime(b.id),
        throwsA(isA<OmlxException>()),
      );
      final failed = fixture.engine.runtimeInstances.singleWhere(
        (run) => run.artifactId == b.id,
      );
      expect(failed.status, RuntimeInstanceStatus.failed);
      expect(failed.error, isNotNull);
      expect(failed.error, isNot(contains(server.apiKey)));
      expect(failed.error, isNot(contains(server.signingSecret)));
      expect(failed.error, isNot(contains(server.cookieValue)));
      // Whitelist projection: the raw settings document is fetched once for
      // the fallback readback, but its decoy secrets never reach error text.
      expect(
        server.requests.where(
          (r) => r.method == 'GET' && r.path == '/admin/api/global-settings',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'unloaded, loading, failed or non-chat models never become ready',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      final b = fixture.artifact('model-b');
      final c = fixture.artifact('model-c');

      // Non-chat assets are rejected before any native pool exists.
      await expectLater(
        fixture.engine.startRuntime(c.id),
        throwsA(isA<OmlxException>()),
      );
      expect(
        fixture.poolIo.launches,
        isEmpty,
        reason: 'no pool for rejected kinds',
      );

      await fixture.engine.startRuntime(a.id);
      final server = fixture.server;

      // A failing physical load leaves the instance failed, never ready.
      server.loadFailures['model-b'] = 1;
      await expectLater(
        fixture.engine.startRuntime(b.id),
        throwsA(isA<OmlxException>()),
      );
      expect(server.models['model-b']!.loaded, isFalse);
      final failedRun = fixture.engine.runtimeInstances.singleWhere(
        (run) => run.artifactId == b.id,
      );
      expect(failedRun.status, RuntimeInstanceStatus.failed);
      expect(failedRun.capabilities, isEmpty);
      expect(failedRun.acceptingRequests, isFalse);
      await expectLater(
        fixture.engine.generateText(failedRun.id, TextRequest(prompt: 'x')),
        throwsA(_requestKind(OmlxRequestKind.notReady)),
      );

      // The transient load failure can be retried for the same artifact.
      final retried = await fixture.engine.startRuntime(b.id);
      expect(retried.status, RuntimeInstanceStatus.ready);
      await fixture.engine.stop(retried.id);

      // A load that reports ok but never reaches a loaded row is rejected.
      server.statusNeverLoaded.add('model-b');
      await expectLater(
        fixture.engine.startRuntime(b.id),
        throwsA(isA<OmlxException>()),
      );
      server.statusNeverLoaded.remove('model-b');

      // A row stuck in is_loading likewise never becomes ready.
      server.statusLoadingForever.add('model-b');
      await expectLater(
        fixture.engine.startRuntime(b.id),
        throwsA(isA<OmlxException>()),
      );
      server.statusLoadingForever.remove('model-b');

      // Probe refusal keeps the instance out of ready and rolls back the load.
      server.chatRefusals.add('model-b');
      await expectLater(
        fixture.engine.startRuntime(b.id),
        throwsA(isA<OmlxException>()),
      );
      expect(server.models['model-b']!.loaded, isFalse);
      expect(
        fixture.engine.runtimeInstances
            .where((run) => run.status == RuntimeInstanceStatus.ready)
            .map((run) => run.artifactId),
        [a.id],
        reason: 'only the originally enabled model stays ready',
      );
    },
  );

  test(
    'enablement sends pin-only settings and enforces fallback false readback',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      await fixture.engine.startRuntime(a.id);
      final server = fixture.server;

      final pinRequests = server
          .requestsTo('/admin/api/models/model-a/settings')
          .toList();
      expect(pinRequests, hasLength(1));
      final pinBody =
          jsonDecode(pinRequests.single.body!) as Map<String, dynamic>;
      expect(pinBody.keys, ['is_pinned']);
      expect(pinBody['is_pinned'], isTrue);

      final fallbackPosts = server
          .requestsTo('/admin/api/global-settings')
          .where((r) => r.method == 'POST')
          .toList();
      expect(fallbackPosts, hasLength(1));
      expect(jsonDecode(fallbackPosts.single.body!), {'model_fallback': false});
      expect(server.fallbackDisabled, isTrue);

      // A service that lies in the nested readback fails the whole pool start.
      await fixture.engine.stopManaged();
      fixture.poolIo.onServerCreated = (server) => server.fallbackLies = true;
      await expectLater(
        fixture.engine.startRuntime(a.id),
        throwsA(
          isA<OmlxException>().having(
            (e) => e.toString(),
            'message',
            contains('fallback'),
          ),
        ),
      );
      fixture.poolIo.onServerCreated = null;
    },
  );

  test('stale preloaded pins from a previous service state are reconciled at pool start', () async {
    final fixture = await _PoolFixture.create();
    addTearDown(fixture.dispose);
    final a = fixture.artifact('model-a');
    fixture.poolIo.preloaded = {'model-b'};
    await fixture.engine.startRuntime(a.id);
    final server = fixture.server;
    // The resurrected pin/load was unwound before any enablement work.
    final unpin = server
        .requestsTo('/admin/api/models/model-b/settings')
        .single;
    expect(jsonDecode(unpin.body!), {'is_pinned': false});
    final unload = server.requestsTo('/v1/models/model-b/unload').single;
    final pinA = server.requestsTo('/admin/api/models/model-a/settings').single;
    expect(
      server.requests.indexOf(unload),
      lessThan(server.requests.indexOf(pinA)),
    );
    expect(server.models['model-b']!.pinned, isFalse);
    expect(server.models['model-b']!.loaded, isFalse);
  });

  test('profile rows and unknown ids never yield a ready instance', () async {
    final fixture = await _PoolFixture.create();
    addTearDown(fixture.dispose);
    final a = fixture.artifact('model-a');
    final instance = await fixture.engine.startRuntime(a.id);
    expect(instance.status, RuntimeInstanceStatus.ready);
    // The fake service always mirrors model-a as a profile row; enablement
    // succeeded, so the pool matched the physical row exactly.
    await expectLater(
      fixture.engine.generateText(
        'model-a-profile',
        TextRequest(prompt: 'Ping'),
      ),
      throwsA(_requestKind(OmlxRequestKind.notReady)),
    );
    await expectLater(
      fixture.engine.generateText('model-a', TextRequest(prompt: 'Ping')),
      throwsA(_requestKind(OmlxRequestKind.notReady)),
    );
    await expectLater(
      fixture.engine.startRuntime('not-an-artifact'),
      throwsA(isA<OmlxException>()),
    );
  });

  test('stop(A) seals admission, cancels in-flight work, unloads only A and keeps B ready', () async {
    final fixture = await _PoolFixture.create();
    addTearDown(fixture.dispose);
    final a = fixture.artifact('model-a');
    final b = fixture.artifact('model-b');
    final instanceA = await fixture.engine.startRuntime(a.id);
    final instanceB = await fixture.engine.startRuntime(b.id);
    final server = fixture.server;

    server.chatGate = Completer<void>();
    server.chatStarted = Completer<void>();
    final pending = expectLater(
      fixture.engine.generateText(
        instanceA.id,
        TextRequest(prompt: 'Hold me', maxTokens: 8),
      ),
      throwsA(_requestKind(OmlxRequestKind.cancelled)),
    );
    await server.chatStarted.future;
    // stop() seals admission synchronously; late work is rejected at once.
    final stopping = fixture.engine.stop(instanceA.id);
    final sealed = expectLater(
      fixture.engine.generateText(
        instanceA.id,
        TextRequest(prompt: 'Too late'),
      ),
      throwsA(_requestKind(OmlxRequestKind.notReady)),
    );
    await stopping;
    await pending;
    await sealed;
    server.chatGate!.complete();

    final stoppedA = fixture.engine.runtimeInstances.singleWhere(
      (run) => run.id == instanceA.id,
    );
    expect(stoppedA.status, RuntimeInstanceStatus.stopped);
    expect(stoppedA.capabilities, isEmpty);
    expect(stoppedA.acceptingRequests, isFalse);
    expect(stoppedA.activeRequests, 0);
    expect(server.models['model-a']!.loaded, isFalse);
    expect(server.requestsTo('/v1/models/model-a/unload'), hasLength(1));
    expect(server.requestsTo('/v1/models/model-b/unload'), isEmpty);

    // B was never touched; the shared service keeps running.
    final replyB = await fixture.engine.generateText(
      instanceB.id,
      TextRequest(prompt: 'Ping', maxTokens: 8),
    );
    expect(replyB.text, 'reply-model-b');
    expect(fixture.poolIo.children.single.signals, isEmpty);

    // A stopped instance can be re-enabled from the same verified artifact.
    final reenabled = await fixture.engine.startRuntime(a.id);
    expect(reenabled.status, RuntimeInstanceStatus.ready);
  });

  test(
    'natural service exit revokes every ready instance and rejects late work',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      final b = fixture.artifact('model-b');
      final instanceA = await fixture.engine.startRuntime(a.id);
      final instanceB = await fixture.engine.startRuntime(b.id);
      final generation = instanceA.generation;

      fixture.poolIo.children.single.die(1);
      await pumpEventQueue();

      for (final id in [instanceA.id, instanceB.id]) {
        final run = fixture.engine.runtimeInstances.singleWhere(
          (r) => r.id == id,
        );
        expect(run.status, RuntimeInstanceStatus.failed);
        expect(run.acceptingRequests, isFalse);
        expect(run.capabilities, isEmpty);
        await expectLater(
          fixture.engine.generateText(id, TextRequest(prompt: 'late')),
          throwsA(_requestKind(OmlxRequestKind.notReady)),
        );
      }

      // A fresh enablement owns a new process generation.
      final revived = await fixture.engine.startRuntime(b.id);
      expect(fixture.poolIo.launches, hasLength(2));
      expect(revived.generation, greaterThan(generation));
      final reply = await fixture.engine.generateText(
        revived.id,
        TextRequest(prompt: 'Ping', maxTokens: 8),
      );
      expect(reply.text, 'reply-model-b');
    },
  );

  test(
    'failed unload keeps a failed-live residual that stop can retry',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      final instanceA = await fixture.engine.startRuntime(a.id);
      final server = fixture.server;

      server.unloadFailures['model-a'] = 1;
      await expectLater(
        fixture.engine.stop(instanceA.id),
        throwsA(isA<OmlxException>()),
      );
      final residual = fixture.engine.runtimeInstances.singleWhere(
        (run) => run.id == instanceA.id,
      );
      expect(residual.status, RuntimeInstanceStatus.failed);
      expect(residual.hasLiveProcess, isTrue);
      expect(residual.acceptingRequests, isFalse);
      expect(residual.capabilities, isEmpty);
      expect(residual.error, contains('卸载'));
      expect(server.models['model-a']!.loaded, isTrue);

      // Retrying stop unloads the residual and settles the instance.
      await fixture.engine.stop(instanceA.id);
      expect(server.models['model-a']!.loaded, isFalse);
      final settled = fixture.engine.runtimeInstances.singleWhere(
        (run) => run.id == instanceA.id,
      );
      expect(settled.status, RuntimeInstanceStatus.stopped);
      expect(settled.hasLiveProcess, isFalse);
    },
  );

  test('stopManaged escalates to sigkill, retires base, and a failed recycle is retryable', () async {
    final fixture = await _PoolFixture.create();
    addTearDown(fixture.dispose);
    final a = fixture.artifact('model-a');
    await fixture.engine.startRuntime(a.id);
    final child = fixture.poolIo.children.single;
    final base = fixture.poolIo.workingDirectories.single!;

    // SIGTERM is ignored; the pool escalates and still settles.
    child.ignoreSigterm = true;
    await fixture.engine.stopManaged();
    expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    expect(
      fixture.engine.runtimeInstances.every(
        (run) => run.status == RuntimeInstanceStatus.stopped,
      ),
      isTrue,
    );
    expect(await Directory(base).exists(), isFalse);

    // A process that never dies blocks the recycle but keeps evidence.
    await fixture.engine.startRuntime(a.id);
    final stuck = fixture.poolIo.children.last;
    stuck.neverDies = true;
    await expectLater(
      fixture.engine.stopManaged(),
      throwsA(isA<OmlxException>()),
    );
    expect(stuck.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    final failed = fixture.engine.runtimeInstances.single;
    expect(failed.status, RuntimeInstanceStatus.failed);
    expect(failed.hasLiveProcess, isTrue);

    // The same stopManaged retries the failed recycle and recovers.
    stuck.neverDies = false;
    await fixture.engine.stopManaged();
    expect(
      fixture.engine.runtimeInstances.single.status,
      RuntimeInstanceStatus.stopped,
    );

    // A third generation starts cleanly after the successful retry.
    final again = await fixture.engine.startRuntime(a.id);
    expect(again.status, RuntimeInstanceStatus.ready);
    expect(fixture.poolIo.launches, hasLength(3));
  });

  test('streaming delivers real deltas, finish and usage; cancellation aborts without a fabricated terminal', () async {
    final fixture = await _PoolFixture.create();
    addTearDown(fixture.dispose);
    final a = fixture.artifact('model-a');
    final instance = await fixture.engine.startRuntime(a.id);
    final server = fixture.server;

    final events = await fixture.engine
        .streamText(instance.id, TextRequest(prompt: 'Hi', maxTokens: 8))
        .toList();
    final deltas = events.where((e) => e.result == null).map((e) => e.delta);
    expect(deltas.join(), 'Hello there');
    final complete = events.last;
    expect(complete.result, isNotNull);
    expect(complete.result!.text, 'Hello there');
    expect(complete.result!.finishReason, 'stop');
    expect(complete.result!.outputTokens, 2);
    expect(complete.result!.model, 'model-a');

    // Mid-stream cancellation aborts; no terminal event is fabricated.
    server.streamMode = 'held';
    server.streamGate = Completer<void>();
    server.streamStarted = Completer<void>();
    final cancellation = DecisionCancellation();
    final collected = <TextStreamEvent>[];
    final done = fixture.engine
        .streamText(
          instance.id,
          TextRequest(prompt: 'Hi', maxTokens: 8),
          cancellation: cancellation,
        )
        .listen(collected.add)
        .asFuture<void>();
    await server.streamStarted.future;
    cancellation.cancel();
    await expectLater(done, throwsA(_requestKind(OmlxRequestKind.cancelled)));
    expect(collected.where((e) => e.result != null), isEmpty);
    expect(collected.map((e) => e.delta).join(), isNot(contains('late')));
    server.streamGate!.complete();
    server.streamMode = 'ok';

    // Missing usage frames fail the stream instead of faking accounting.
    server.streamMode = 'missingUsage';
    await expectLater(
      fixture.engine
          .streamText(instance.id, TextRequest(prompt: 'Hi', maxTokens: 8))
          .toList(),
      throwsA(_requestKind(OmlxRequestKind.invalidResponse)),
    );

    // A truncated stream without [DONE] is invalid, never a clean finish.
    server.streamMode = 'missingDone';
    await expectLater(
      fixture.engine
          .streamText(instance.id, TextRequest(prompt: 'Hi', maxTokens: 8))
          .toList(),
      throwsA(_requestKind(OmlxRequestKind.invalidResponse)),
    );
  });

  test(
    'catalog runtimeFor returns the owned pool; recycle seals late enrollment',
    () async {
      final fixture = await _PoolFixture.create();
      addTearDown(fixture.dispose);
      final a = fixture.artifact('model-a');
      final b = fixture.artifact('model-b');
      final cpp = LlamaEngine(
        library: fixture.library,
        installationDirectory: Directory('${fixture.root.path}/cpp'),
      );
      addTearDown(cpp.close);
      final catalog = EngineCatalog(
        library: fixture.library,
        officialEngine: cpp,
        useRegistry: fixture.useRegistry,
        registryFile: File('${fixture.root.path}/engines.json'),
        omlxEngine: fixture.engine,
      );
      addTearDown(catalog.close);

      final runtime = catalog.runtimeFor(EngineCatalog.omlxId);
      expect(runtime, same(fixture.engine));

      // holdStartAdmission seals enrollment until released.
      final hold = fixture.engine.holdStartAdmission();
      await expectLater(
        fixture.engine.startRuntime(a.id),
        throwsA(isA<OmlxException>()),
      );
      hold();
      final instance = await fixture.engine.startRuntime(a.id);
      expect(instance.status, RuntimeInstanceStatus.ready);

      // During a catalog-managed recycle, late enrollment is rejected.
      final server = fixture.server;
      server.unloadGate = Completer<void>();
      server.unloadStarted = Completer<void>();
      final stopping = catalog.stopManaged();
      await server.unloadStarted.future;
      await expectLater(
        fixture.engine.startRuntime(b.id),
        throwsA(
          isA<OmlxException>().having(
            (e) => e.toString(),
            'message',
            contains('回收'),
          ),
        ),
      );
      server.unloadGate!.complete();
      await stopping;

      // After the recycle, enrollment resumes against a fresh pool.
      final resumed = await fixture.engine.startRuntime(b.id);
      expect(resumed.status, RuntimeInstanceStatus.ready);
      expect(fixture.poolIo.launches, hasLength(2));
    },
  );
}
