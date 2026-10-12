import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'decision_gguf.dart';
import 'engine_archive.dart';

/// Production model library, engine and public gateway. Only engine IO differs.
class EmbeddingTestRuntime {
  EmbeddingTestRuntime._(
    this.root,
    this.library,
    this.asset,
    this.io,
    this.engine,
    this.catalog,
    this.routes,
    this.gateway,
  );
  final Directory root;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final EmbeddingTestIO io;
  final LlamaEngine engine;
  final EngineCatalog catalog;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  String get publicId => routes.publicIdFor(asset.id);

  static Future<EmbeddingTestRuntime> create({
    EmbeddingTestIO? processIO,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-embedding-playground-',
    );
    final models = Directory('${root.path}/models');
    await writeEmbeddingGguf(models);
    final library = ModelLibrary();
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final bytes = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(bytes);
    final io = processIO ?? EmbeddingTestIO();
    final use = ModelUseRegistry(library);
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
    final routes = PublicModelRoutes(library: library, runtimes: [engine]);
    await routes.enable(asset.id);
    await engine.start(asset.id);
    final gateway = PublicGatewayServer(
      routes: routes,
      port: 0,
      heartbeatInterval: const Duration(milliseconds: 20),
    );
    await gateway.start();
    io.bodies.clear();
    return EmbeddingTestRuntime._(
      root,
      library,
      asset,
      io,
      engine,
      catalog,
      routes,
      gateway,
    );
  }

  Future<void> close() async {
    if (io.release != null && !io.release!.isCompleted) io.release!.complete();
    await gateway.stop();
    gateway.close();
    routes.close();
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    for (final child in io.children) {
      await child.server.close(force: true);
    }
    await root.delete(recursive: true);
  }
}

class EmbeddingTestIO implements EngineProcessIO {
  final bodies = <Map<String, Object?>>[];
  final children = <EmbeddingTestChild>[];
  int status = 200;
  String? responseModel;
  String? responseBody;
  List<List<num>> vectors = [
    [3, 0],
    [0, 4],
  ];
  Map<String, Object?> usage = {'prompt_tokens': 8, 'total_tokens': 8};
  int? contextPerSlot = 4096;
  int slotCount = 1;
  String? propsAlias;
  Completer<void>? held;
  Completer<void>? release;
  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    final child = EmbeddingTestChild(server);
    children.add(child);
    server.listen((request) async {
      try {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/health') {
          request.response.write('{"status":"ok"}');
        } else if (request.uri.path == '/props') {
          request.response.write(
            jsonEncode({
              'model_alias': propsAlias ?? arg('--alias'),
              'model_path': arg('--model'),
              'total_slots': slotCount,
              'default_generation_settings': {
                if (contextPerSlot != null) 'n_ctx': contextPerSlot,
              },
            }),
          );
        } else if (request.uri.path == '/v1/embeddings') {
          final body = Map<String, Object?>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          bodies.add(body);
          if (release != null &&
              (body['input'] == 'hold' ||
                  body['input'] is List &&
                      (body['input'] as List).contains('hold'))) {
            if (held != null && !held!.isCompleted) held!.complete();
            await release!.future;
          }
          request.response.statusCode = status;
          final input = body['input'];
          final count = input is List ? input.length : 1;
          request.response.write(
            responseBody ??
                (status != 200
                    ? 'upstream refused'
                    : jsonEncode({
                        'object': 'list',
                        'model': responseModel ?? arg('--alias'),
                        'data': [
                          for (var index = 0; index < count; index++)
                            {
                              'object': 'embedding',
                              'index': index,
                              'embedding': vectors[index % vectors.length],
                            },
                        ],
                        'usage': usage,
                      })),
          );
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      } on HttpException {
        /* An ordinary caller may disconnect. */
      }
    });
    return child;
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
}

class EmbeddingTestChild implements EngineChild {
  EmbeddingTestChild(this.server) : pid = server.port;
  final HttpServer server;
  final exited = Completer<int>();
  @override
  final int pid;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    unawaited(
      server.close(force: true).then((_) {
        if (!exited.isCompleted) exited.complete(0);
      }),
    );
    return true;
  }
}
