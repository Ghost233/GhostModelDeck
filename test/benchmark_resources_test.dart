import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/engine_runtime.dart';

void main() {
  test(
    'prepare downloads the fixed complete original suite and rechecks cache',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-benchmark-resource-',
      );
      addTearDown(() => root.delete(recursive: true));
      final original = Directory('benchmarks/sources/decidebench');
      final responses = <Uri, List<int>>{
        for (final file in BenchmarkResources.files)
          file.url: await File('${original.path}/${file.path}').readAsBytes(),
      };
      final requested = <Uri>[];
      final clients = <_SourceClient>[];
      final resources = BenchmarkResources(
        root,
        createHttpClient: () {
          final client = _SourceClient(responses, requested);
          clients.add(client);
          return client;
        },
      );
      final progress = <BenchmarkResourceProgress>[];
      expect(resources.status, BenchmarkResourceStatus.idle);
      expect(resources.lastError, isNull);
      expect(BenchmarkResources.identity['questionCount'], 400);
      expect(BenchmarkResources.identity['dataLicense'], 'CC BY 4.0');
      final checked = await resources.prepare(
        DecisionCancellation(),
        onProgress: progress.add,
      );
      expect(requested, hasLength(22));
      expect(requested.every((url) => url.scheme == 'https'), isTrue);
      expect(
        requested.every((url) => url.path.contains(BenchmarkResources.pin)),
        isTrue,
      );
      final suite = await DecideBenchSuite.load(checked);
      expect(suite.items, hasLength(400));
      expect(suite.identity, BenchmarkResources.identity);
      expect(resources.status, BenchmarkResourceStatus.ready);
      expect(resources.lastError, isNull);
      expect(progress.last.completedFiles, 22);
      expect(progress.last.verifiedBytes, progress.last.totalBytes);
      expect(clients.every((client) => client.closed), isTrue);
      await resources.prepare(DecisionCancellation());
      expect(requested, hasLength(22));
      // Corruption must be detected even when a supported pin directory exists.
      await File('${checked.path}/data/v1/action_review.jsonl')
          .writeAsString('corrupt');
      await resources.prepare(DecisionCancellation());
      expect(requested, hasLength(23));
      expect((await DecideBenchSuite.load(checked)).items, hasLength(400));
    },
  );
  test('source failures never mark unverified files ready or retry', () async {
    final original = Directory('benchmarks/sources/decidebench');
    final responses = <Uri, List<int>>{
      for (final file in BenchmarkResources.files)
        file.url: await File('${original.path}/${file.path}').readAsBytes(),
    };
    for (final status in [HttpStatus.ok, HttpStatus.serviceUnavailable]) {
      final root = await Directory.systemTemp.createTemp(
        'gmd-resource-failure-',
      );
      addTearDown(() => root.delete(recursive: true));
      final requests = <Uri>[];
      final altered = {...responses};
      final first = BenchmarkResources.files.first;
      altered[first.url] = [...responses[first.url]!];
      altered[first.url]![0] ^= 1;
      final client = _SourceClient(altered, requests, status: status);
      final resources = BenchmarkResources(
        root,
        createHttpClient: () => client,
      );
      await expectLater(
        resources.prepare(DecisionCancellation()),
        status == HttpStatus.ok
            ? throwsA(isA<FormatException>())
            : throwsA(isA<HttpException>()),
      );
      expect(requests, hasLength(1));
      expect(client.closed, isTrue);
      expect(resources.status, BenchmarkResourceStatus.failed);
      expect(
        resources.lastError,
        contains(status == HttpStatus.ok ? 'mismatch' : 'HTTP 503'),
      );
      final cache = Directory(
        '${root.path}/decidebench/${BenchmarkResources.pin}',
      );
      expect(await File('${cache.path}/${first.path}').exists(), isFalse);
      expect(
        await cache
            .list(recursive: true)
            .where((file) => file is File)
            .toList(),
        isEmpty,
      );
    }
  });

  test(
    'ordinary cancellation wins before readiness including final progress',
    () async {
      final original = Directory('benchmarks/sources/decidebench');
      final responses = <Uri, List<int>>{
        for (final file in BenchmarkResources.files)
          file.url: await File('${original.path}/${file.path}').readAsBytes(),
      };
      for (final cancelAtCompletion in [false, true]) {
        final root = await Directory.systemTemp.createTemp(
          'gmd-resource-cancel-',
        );
        addTearDown(() => root.delete(recursive: true));
        final unrelated = File('${root.path}/unrelated.txt');
        await unrelated.writeAsString('retain');
        final requests = <Uri>[];
        final client = _SourceClient(responses, requests);
        final token = DecisionCancellation();
        final resources = BenchmarkResources(
          root,
          createHttpClient: () => client,
        );
        await expectLater(
          resources.prepare(
            token,
            onProgress: (value) {
              if (cancelAtCompletion
                  ? value.completedFiles == value.totalFiles
                  : value.downloadedBytes > 0) {
                token.cancel();
              }
            },
          ),
          throwsA(isA<BenchmarkResourceCancelled>()),
        );
        expect(client.closed, isTrue);
        expect(resources.status, BenchmarkResourceStatus.cancelled);
        expect(resources.lastError, isNull);
        expect(requests, hasLength(cancelAtCompletion ? 22 : 1));
        if (!cancelAtCompletion) expect(client.requests.single.aborted, isTrue);
        expect(await unrelated.readAsString(), 'retain');
        expect(
          await root
              .list(recursive: true)
              .where((file) => file.path.endsWith('.part'))
              .toList(),
          isEmpty,
        );
      }
    },
  );
  test(
    'application close cancels only owned preparation and awaits cleanup',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-resource-close-');
      addTearDown(() => root.delete(recursive: true));
      final file = BenchmarkResources.files.first;
      final responses = <Uri, List<int>>{
        file.url: await File('benchmarks/sources/decidebench/${file.path}')
            .readAsBytes(),
      };
      final started = Completer<void>();
      final client = _SourceClient(responses, [], started: started);
      final caller = DecisionCancellation();
      final unrelated = DecisionCancellation();
      final resources = BenchmarkResources(
        root,
        createHttpClient: () => client,
      );
      final preparing = resources.prepare(caller);
      final cancelled = expectLater(
        preparing,
        throwsA(isA<BenchmarkResourceCancelled>()),
      );
      try {
        await started.future;
        await resources.close();
        expect(client.closed, isTrue);
        expect(client.requests.single.aborted, isTrue);
        expect(caller.isCancelled, isFalse);
        expect(unrelated.isCancelled, isFalse);
        await cancelled;
        expect(
          await root
              .list(recursive: true)
              .where((entity) => entity is File)
              .toList(),
          isEmpty,
        );
        await resources.close();
        await expectLater(
          resources.prepare(DecisionCancellation()),
          throwsStateError,
        );
      } finally {
        // Failed red assertions still release the external network seam.
        caller.cancel();
        await cancelled;
      }
    },
  );
  test(
    'public suite preparation owns complete loading and quit cancellation',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-resource-suite-');
      addTearDown(() => root.delete(recursive: true));
      final responses = <Uri, List<int>>{
        for (final file in BenchmarkResources.files)
          file.url: await File('benchmarks/sources/decidebench/${file.path}')
              .readAsBytes(),
      };
      final requested = <Uri>[];
      final resources = BenchmarkResources(
        root,
        createHttpClient: () => _SourceClient(responses, requested),
      );
      final suite = await resources.prepareSuite(DecisionCancellation());
      expect(suite.items, hasLength(400));
      expect(suite.identity, BenchmarkResources.identity);
      expect(requested, hasLength(22));
      final caller = DecisionCancellation();
      final cancelled = resources.prepareSuite(
        caller,
        onProgress: (progress) {
          if (progress.completedFiles == progress.totalFiles) {
            scheduleMicrotask(() => unawaited(resources.close()));
          }
        },
      );
      await expectLater(cancelled, throwsA(isA<BenchmarkResourceCancelled>()));
      expect(caller.isCancelled, isFalse);
      await resources.close();
      await expectLater(
        resources.prepareSuite(DecisionCancellation()),
        throwsStateError,
      );
    },
  );
}

class _SourceClient extends Fake implements HttpClient {
  _SourceClient(
    this.responses,
    this.requested, {
    this.status = HttpStatus.ok,
    this.started,
  });
  final Map<Uri, List<int>> responses;
  final List<Uri> requested;
  final int status;
  final Completer<void>? started;
  final requests = <_SourceRequest>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    final request = _SourceRequest(responses[url]!, status, started);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
    for (final request in requests) {
      request.abort();
    }
  }
}

class _SourceRequest extends Fake implements HttpClientRequest {
  _SourceRequest(this.bytes, this.status, this.started);
  final List<int> bytes;
  final int status;
  final Completer<void>? started;
  _StalledSourceResponse? stalled;
  bool aborted = false;
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async {
    final signal = started;
    if (signal == null) return _SourceResponse(bytes, status);
    return stalled = _StalledSourceResponse(signal);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    stalled?.abort();
  }
}

class _SourceResponse extends Stream<List<int>> implements HttpClientResponse {
  _SourceResponse(List<int> bytes, this.statusCode)
    : _body = Stream.value(bytes);
  final Stream<List<int>> _body;
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StalledSourceResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _StalledSourceResponse(Completer<void> started) {
    body = StreamController<List<int>>(onListen: () => started.complete());
  }
  late final StreamController<List<int>> body;
  bool aborted = false;
  void abort() {
    if (aborted) return;
    aborted = true;
    body.addError(const SocketException('request aborted'));
    unawaited(body.close());
  }

  @override
  int get statusCode => HttpStatus.ok;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
