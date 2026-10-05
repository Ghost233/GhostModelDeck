import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'decision_gguf.dart';
import 'engine_archive.dart';

/// Only the native process and its external HTTP interface are substituted.
class CouncilRuntime {
  CouncilRuntime._(this.root, this.library, this.engine, this.catalog, this.io);
  final Directory root;
  final ModelLibrary library;
  final LlamaEngine engine;
  final EngineCatalog catalog;
  final CouncilRuntimeIO io;

  static Future<CouncilRuntime> create({
    int modelCount = 2,
    CouncilRuntimeIO? processIO,
  }) async {
    final root = await Directory.systemTemp.createTemp('jev-council-');
    final models = Directory('${root.path}/models');
    await models.create();
    final first = modelCount == 0 ? null : await writeDecisionKev(models);
    if (modelCount > 1) {
      final other = File('${models.path}/author/Other/Other-Q8_0.gguf');
      await other.parent.create(recursive: true);
      await first!.copy(other.path);
    }
    if (modelCount > 2) {
      final third = File('${models.path}/author/Third/Third-Q8_0.gguf');
      await third.parent.create(recursive: true);
      await first!.copy(third.path);
    }
    final library = ModelLibrary();
    final assets = await library.scan(models, verifyFiles: true);
    final use = ModelUseRegistry(library);
    final io = processIO ?? CouncilRuntimeIO();
    final bytes = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(bytes);
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      useRegistry: use,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
      ),
      loadTimeout: const Duration(seconds: 3),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      useRegistry: use,
      registryFile: File('${root.path}/private/engines.json'),
      io: io,
    );
    await catalog.installOfficial(verifiedArchive: archive);
    for (final asset in assets) {
      await engine.start(asset.id);
    }
    return CouncilRuntime._(root, library, engine, catalog, io);
  }

  Future<void> close() async {
    io.release?.completeIfPending();
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class CouncilRuntimeIO implements EngineProcessIO {
  final requests = <Map<String, dynamic>>[];
  Future<String> Function(Map<String, dynamic> request, String response)?
  respond;
  int killedChildren = 0;
  int consultationStatus = 200;
  final _servers = <String, HttpServer>{};
  Future<void> closeEndpoint(String instanceId) =>
      _servers[instanceId]!.close(force: true);
  Completer<void>? bothArrived;
  Completer<void>? release;

  void holdConsultation() {
    requests.clear();
    bothArrived = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
        '',
      );
    }
    final result = await Process.run(executable, arguments);
    return EngineCommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    final child = _RuntimeChild(server, () => killedChildren++);
    _servers[arg('--alias')] = server;
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': arg('--alias'),
            'model_path': arg('--model'),
          }),
        );
      } else {
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        final options = body['questions']['council_choice']['criteria'] as Map;
        final consultation = options.containsKey('accept');
        if (consultation) {
          requests.add(body);
          if (requests.length == 2) bothArrived?.completeIfPending();
          await release?.future;
        }
        final prefersAccept = !arg('--model').contains('/Other/');
        var raw = jsonEncode({
          'model': arg('--alias'),
          'answers': {
            'council_choice': {
              'type': 'choice',
              'choice': consultation
                  ? (prefersAccept ? 'accept' : 'reject')
                  : options.keys.last,
              'probabilities': consultation
                  ? {
                      'accept': prefersAccept ? 0.75 : 0.25,
                      'reject': prefersAccept ? 0.25 : 0.75,
                    }
                  : {options.keys.first: 0.25, options.keys.last: 0.75},
            },
          },
          'usage': {'input_tokens': 10, 'output_tokens': 0},
        });
        if (consultation && respond != null) raw = await respond!(body, raw);
        if (consultation) request.response.statusCode = consultationStatus;
        request.response.write(raw);
      }
      await request.response.close();
    });
    return child;
  }
}

class _RuntimeChild implements EngineChild {
  _RuntimeChild(this.server, this.onKill) : _pid = server.port;
  final HttpServer server;
  final void Function() onKill;
  final int _pid;
  final stopped = Completer<int>();
  @override
  int get pid => _pid;
  @override
  Future<int> get exitCode => stopped.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    onKill();
    server.close(force: true).then((_) {
      if (!stopped.isCompleted) stopped.complete(0);
    });
    return true;
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}
