import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'decidebench.dart';
import 'engine_runtime.dart' show DecisionCancellation;

class BenchmarkResourceFile {
  const BenchmarkResourceFile(this.path, this.bytes, this.sha256);
  final String path;
  final int bytes;
  final String sha256;
  Uri get url => Uri.https(
    'raw.githubusercontent.com',
    '/choyiny/decidebench/${BenchmarkResources.pin}/$path',
  );
}

class BenchmarkResourceProgress {
  const BenchmarkResourceProgress({
    required this.completedFiles,
    required this.totalFiles,
    required this.verifiedBytes,
    required this.totalBytes,
    required this.currentPath,
    this.downloadedBytes = 0,
  });
  final int completedFiles;
  final int totalFiles;
  final int verifiedBytes;
  final int totalBytes;
  final String currentPath;
  final int downloadedBytes;
}

class BenchmarkResourceCancelled implements Exception {
  const BenchmarkResourceCancelled();
  @override
  String toString() => 'Benchmark resource preparation cancelled';
}

enum BenchmarkResourceStatus { idle, preparing, ready, cancelled, failed }

class BenchmarkResources {
  BenchmarkResources(this.cacheRoot, {HttpClient Function()? createHttpClient})
    : _createHttpClient = createHttpClient ?? HttpClient.new;
  final Directory cacheRoot;
  final HttpClient Function() _createHttpClient;
  BenchmarkResourceStatus get status => _status;
  String? get lastError => _lastError;
  BenchmarkResourceStatus _status = BenchmarkResourceStatus.idle;
  String? _lastError;
  bool get preparing => _prepareDone != null;
  BenchmarkResourceProgress? get progress => _progress;
  Stream<BenchmarkResourceProgress?> get changes => _changes.stream;
  void cancelPreparation() => _activeCancellation?.cancel();

  final _changes = StreamController<BenchmarkResourceProgress?>.broadcast(
    sync: true,
  );
  BenchmarkResourceProgress? _progress;
  Future<void>? _closeChanges;
  static const pin = '18e9c5eedd2855257ae534b5879ebba613479586';
  static const sourceUrl = 'https://github.com/choyiny/decidebench';
  static const files = <BenchmarkResourceFile>[
    BenchmarkResourceFile(
      'data/v1/action_review.jsonl',
      63222,
      'fa75566a6e93b39aa3859c296964fc455668bc2febcff988110a39308b5e8475',
    ),
    BenchmarkResourceFile(
      'data/v1/agent_routing.jsonl',
      58589,
      '654b78fd7f6068939b7894fc936c29ecba02ab89a5aefcf94abc0613710347fb',
    ),
    BenchmarkResourceFile(
      'data/v1/claim_support.jsonl',
      43992,
      '25dec854a70a96e61265c7aa333a7a159d6c2f4fdfbe91692cd7cf7a3491bc69',
    ),
    BenchmarkResourceFile(
      'data/v1/content_moderation.jsonl',
      56756,
      '1e241149ce61fbe2277a8abfd0288bb0608a01f52739d975f5b2a3b1646f0c79',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/REVIEW.md',
      1456,
      '7c7a6780d370699bd73203a5cafa46b331cd9bb41a149afcd2889b0e336bf70c',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/action_review.jsonl',
      7760,
      '94fd6ba9ccd043865887dda48d385faa14251a556284e6696699545f6ed36174',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/agent_routing.jsonl',
      28338,
      '871e819e5a6859a602727e29e860e4b646a80bead1fde2e8f543ff3e281e68b3',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/claim_support.jsonl',
      2787,
      '7d74dcabbb807d0e09fc044883610b148e73c89b7057a9b04285849275b08e8f',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/content_moderation.jsonl',
      18592,
      '9bd8e13ea39ad2fc0961ec788eb3cfe44703961446c7db16b4ec02df66f02d91',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/returns_policy.jsonl',
      102306,
      '81e6855c3d171ef9a636349d0889829e3e0683e98ce735affe0733862b214b60',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/review_sentiment.jsonl',
      5773,
      'be927f72ca394167ba5384942a7e76210940e23d149605ff7f09836972f0ac63',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/support_intent.jsonl',
      134304,
      '6c1378f657f9c182206dfedd9e79b54630e2b929a5e4411a89301ea07198299b',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/templates.json',
      138290,
      '5cc20be19604dd94fa50c73ae90568cbbaffb400df680d56afec71fab80f9dc3',
    ),
    BenchmarkResourceFile(
      'data/v1/examples/ticket_triage.jsonl',
      23174,
      'e453ac2a662af3755a4edb7160f26ad2305a166e490202496740b0c1aaf0c392',
    ),
    BenchmarkResourceFile(
      'data/v1/returns_policy.jsonl',
      58384,
      '140f04f09f73e6f92fc1de1ba6ecc379cc5579bf2244c6cde6cd989bd3f0ddc8',
    ),
    BenchmarkResourceFile(
      'data/v1/review_sentiment.jsonl',
      55067,
      'af2924d851d5e403e5e38aa67ee373b9710b36a478de946f5ec895ffe49b5b74',
    ),
    BenchmarkResourceFile(
      'data/v1/support_intent.jsonl',
      50251,
      'd4a424ebd9f9e3e909af76502be72fa4643043fb2c4e21b9f52108e9ec1edc09',
    ),
    BenchmarkResourceFile(
      'data/v1/ticket_triage.jsonl',
      56540,
      '68b84d75d7fe8b83f1d8367ec8d158ca28c5cb49a66740426904703a7351f1e5',
    ),
    BenchmarkResourceFile(
      'README.md',
      13792,
      'd5df830291d54a97afba6179c5f690a88500495c7a9320714c7f651692347906',
    ),
    BenchmarkResourceFile(
      'LICENSE',
      1069,
      'bd2dd822d7829522323f4afa190ad29238b91b5622873a274d7ab4a7932d64ac',
    ),
    BenchmarkResourceFile(
      'data/LICENSE',
      217,
      'f4d37fb206d3fa4eff2681db54c7b93c21f9a47d18a0f6f8a6fb5836a8d55b40',
    ),
    BenchmarkResourceFile(
      'CITATION.cff',
      441,
      '88c373a56647cafce62ddcca83f92d303cd74ddecb9065de9f741f838ee043ee',
    ),
  ];
  static Map<String, Object?> get identity => Map.unmodifiable({
    'id': 'decidebench',
    'pin': pin,
    'contentSha256': sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final file in files)
                {'path': file.path, 'bytes': file.bytes, 'sha256': file.sha256},
            ]),
          ),
        )
        .toString(),
    'questionCount': 400,
    'pairCount': 200,
    'exampleCount': 297,
    'templateCount': 63,
    'requestVersion': 'v1.1-jev-default-criteria-examples',
    'scoringVersion': 'v1.1-score.py',
    'source': sourceUrl,
    'codeLicense': 'MIT',
    'dataLicense': 'CC BY 4.0',
    'citation': 'Yong, Cho Yin (2026). DecideBench, version 1.1.',
  });

  Future<Directory> prepare(
    DecisionCancellation caller, {
    void Function(BenchmarkResourceProgress)? onProgress,
  }) => _runPreparation(
    caller,
    (token) => _prepare(token, onProgress: onProgress),
  );

  Future<DecideBenchSuite> prepareSuite(
    DecisionCancellation caller, {
    void Function(BenchmarkResourceProgress)? onProgress,
  }) => _runPreparation(caller, (token) async {
    final directory = await _prepare(token, onProgress: onProgress);
    _checkCancellation(token);
    return DecideBenchSuite.load(directory);
  });

  Future<T> _runPreparation<T>(
    DecisionCancellation caller,
    Future<T> Function(DecisionCancellation) operation,
  ) async {
    if (_closed) throw StateError('Benchmark resources are closed');
    if (_prepareDone != null) {
      throw StateError('Benchmark preparation is already running');
    }
    final token = DecisionCancellation();
    final removeCaller = caller.listen(token.cancel);
    final done = Completer<void>();
    _activeCancellation = token;
    _prepareDone = done;
    _status = BenchmarkResourceStatus.preparing;
    _lastError = null;
    _progress = null;
    _changes.add(null);
    try {
      final result = await operation(token);
      _checkCancellation(token);
      if (_closed) throw const BenchmarkResourceCancelled();
      _status = BenchmarkResourceStatus.ready;
      return result;
    } catch (error) {
      if (token.isCancelled) {
        _status = BenchmarkResourceStatus.cancelled;
        _lastError = null;
        throw const BenchmarkResourceCancelled();
      }
      _status = BenchmarkResourceStatus.failed;
      _lastError = error.toString();
      rethrow;
    } finally {
      removeCaller();
      _activeCancellation = null;
      _prepareDone = null;
      _progress = null;
      _changes.add(null);
      done.complete();
    }
  }

  Future<Directory> _prepare(
    DecisionCancellation token, {
    void Function(BenchmarkResourceProgress)? onProgress,
  }) async {
    _checkCancellation(token);
    final directory = Directory('${cacheRoot.path}/decidebench/$pin');
    HttpClient? client;
    HttpClientRequest? request;
    File? partial;
    var completed = 0;
    var verified = 0;
    final totalBytes = files.fold(0, (sum, resource) => sum + resource.bytes);
    final removeCancellation = token.listen(() {
      request?.abort(const BenchmarkResourceCancelled());
      client?.close(force: true);
    });
    void progress(String path, [int downloaded = 0]) {
      final value = BenchmarkResourceProgress(
        completedFiles: completed,
        totalFiles: files.length,
        verifiedBytes: verified,
        totalBytes: totalBytes,
        currentPath: path,
        downloadedBytes: downloaded,
      );
      _progress = value;
      _changes.add(value);
      onProgress?.call(value);
    }

    try {
      await directory.create(recursive: true);
      for (final resource in files) {
        _checkCancellation(token);
        final destination = File('${directory.path}/${resource.path}');
        progress(resource.path);
        if (!await _matches(destination, resource)) {
          _checkCancellation(token);
          client ??= _createHttpClient()
            ..connectionTimeout = const Duration(seconds: 30);
          request = await client.getUrl(resource.url);
          _checkCancellation(token);
          request.followRedirects = false;
          final response = await request.close();
          _checkCancellation(token);
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'Benchmark source HTTP ${response.statusCode}',
              uri: resource.url,
            );
          }
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in response) {
            _checkCancellation(token);
            buffer.add(chunk);
            if (buffer.length > resource.bytes) {
              throw FormatException(
                'Benchmark resource too large: ${resource.path}',
              );
            }
            progress(resource.path, buffer.length);
          }
          _checkCancellation(token);
          final bytes = buffer.takeBytes();
          if (bytes.length != resource.bytes ||
              sha256.convert(bytes).toString() != resource.sha256) {
            throw FormatException(
              'Benchmark resource mismatch: ${resource.path}',
            );
          }
          await destination.parent.create(recursive: true);
          partial = File('${destination.path}.part');
          await partial.writeAsBytes(bytes, flush: true);
          _checkCancellation(token);
          await partial.rename(destination.path);
          partial = null;
          request = null;
        }
        _checkCancellation(token);
        completed++;
        verified += resource.bytes;
        progress(resource.path);
      }
      _checkCancellation(token);
      return directory;
    } catch (_) {
      if (token.isCancelled) throw const BenchmarkResourceCancelled();
      rethrow;
    } finally {
      removeCancellation();
      client?.close(force: true);
      if (partial != null && await partial.exists()) await partial.delete();
    }
  }

  bool _closed = false;
  DecisionCancellation? _activeCancellation;
  Completer<void>? _prepareDone;

  Future<void> close() async {
    _closed = true;
    final done = _prepareDone;
    _activeCancellation?.cancel();
    if (done != null) await done.future;
    await (_closeChanges ??= _changes.close());
  }

  static void _checkCancellation(DecisionCancellation token) {
    if (token.isCancelled) throw const BenchmarkResourceCancelled();
  }

  static Future<bool> _matches(
    File file,
    BenchmarkResourceFile resource,
  ) async {
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    return bytes.length == resource.bytes &&
        sha256.convert(bytes).toString() == resource.sha256;
  }
}
