import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'embedding_protocol.dart';
import 'engine_runtime.dart';
import 'jev_debug.dart';

class EmbeddingPlaygroundResult {
  const EmbeddingPlaygroundResult({
    required this.request,
    required this.rawResponse,
    required this.elapsed,
    required this.timeout,
    this.requestBody,
    this.statusCode,
    this.result,
    this.error,
    this.cancelled = false,
    this.timedOut = false,
  });
  final Map<String, Object?>? request;
  final String? requestBody;
  final String rawResponse;
  final Duration elapsed;
  final Duration timeout;
  final int? statusCode;
  final EmbeddingResult? result;
  final String? error;
  final bool cancelled;
  final bool timedOut;
  bool get completed => result != null && error == null;

  Map<String, Object?> toJson() {
    Object? response;
    try {
      response = jsonDecode(rawResponse);
    } on FormatException {
      response = null;
    }
    final safe = sealDebugJson({
      'request': request,
      'request_body': requestBody,
      'raw_response': rawResponse,
      'response': response,
      'dispatched': requestBody != null,
      'http_status': statusCode,
      'completed': completed,
      'cancelled': cancelled,
      'timed_out': timedOut,
      'elapsed_us': elapsed.inMicroseconds,
      'timeout_us': timeout.inMicroseconds,
      'usage': result?.usage,
      'error': error,
    }, projection: JevDebugProjection.embeddingEvidence);
    return safe;
  }
}

/// A public HTTP client; it never obtains a model's internal runtime handle.
class EmbeddingPlayground {
  EmbeddingPlayground({required this.baseUrl});
  final Uri? Function() baseUrl;

  Uri _endpoint(String path) {
    final base = baseUrl();
    if (base == null) throw const HttpException('公开 HTTP 服务未运行');
    return base.resolve(path);
  }

  Future<List<String>> discover({
    DecisionCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final client = HttpClient();
    final stopped = Completer<void>();
    var timedOut = false;
    Timer? deadline;
    void disconnect() {
      client.close(force: true);
      if (!stopped.isCompleted) stopped.complete();
    }

    final remove = cancellation?.listen(disconnect);
    Future<List<String>> receive() async {
      final request = await client.getUrl(_endpoint('/api/v1/models'));
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}: $raw');
      }
      final value = jsonDecode(raw);
      if (value is! Map || value['models'] is! List) {
        throw const FormatException('公开模型容量响应无效');
      }
      final ids = <String>[];
      for (final row in value['models'] as List) {
        if (row is! Map || row['type'] != 'embedding') continue;
        final key = row['key'];
        final instances = row['loaded_instances'];
        if (key is! String || key.isEmpty || instances is! List) {
          throw const FormatException('公开嵌入模型发现条目无效');
        }
        if (instances.any(
          (instance) => instance is Map && instance['id'] == key,
        )) {
          if (!ids.contains(key)) ids.add(key);
        }
      }
      return List.unmodifiable(ids);
    }

    try {
      if (timeout <= Duration.zero) throw const FormatException('客户端期限必须大于零');
      if (cancellation?.isCancelled ?? false) throw const _EmbeddingCancelled();
      deadline = Timer(timeout, () {
        timedOut = true;
        disconnect();
      });
      return await Future.any<List<String>>([
        receive(),
        stopped.future.then<List<String>>(
          (_) => throw const _EmbeddingCancelled(),
        ),
      ]);
    } catch (_) {
      if (timedOut) throw TimeoutException('公开模型发现超时', timeout);
      if (cancellation?.isCancelled ?? false) {
        throw const HttpException('公开模型发现已取消');
      }
      rethrow;
    } finally {
      deadline?.cancel();
      remove?.call();
      client.close(force: true);
    }
  }

  Future<EmbeddingPlaygroundResult> run(
    String document, {
    DecisionCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final watch = Stopwatch()..start();
    final client = HttpClient();
    Map<String, Object?>? request;
    String? sentBody;
    int? status;
    final raw = StringBuffer();
    EmbeddingResult? result;
    String? error;
    var settled = false;
    var timedOut = false;
    var cancelled = false;
    Timer? timer;
    final expired = Completer<void>();
    final remove = cancellation?.listen(() => client.close(force: true));
    Future<void> receive() async {
      final value = jsonDecode(document);
      if (value is! Map) throw const FormatException('请求需要是 JSON 对象');
      request = freezeDebugJson(
        Map<String, Object?>.from(value),
      ) as Map<String, Object?>;
      final parsed = EmbeddingRequest.fromJson(request!);
      final outgoing = await client.postUrl(_endpoint('/v1/embeddings'));
      if (settled) return;
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(document);
      sentBody = document;
      final response = await outgoing.close();
      if (settled) return;
      status = response.statusCode;
      await for (final chunk in utf8.decoder.bind(response)) {
        if (settled) return;
        raw.write(chunk);
      }
      if (status != 200) throw HttpException('HTTP $status');
      final complete = EmbeddingResult.parse(raw.toString(), request: parsed);
      if (!settled) result = complete;
    }

    try {
      if (timeout <= Duration.zero) throw const FormatException('客户端期限必须大于零');
      if (cancellation?.isCancelled ?? false) throw const _EmbeddingCancelled();
      timer = Timer(timeout, () {
        timedOut = true;
        client.close(force: true);
        expired.completeError(TimeoutException('客户端期限已到', timeout));
      });
      await Future.any<void>([
        receive(),
        expired.future,
        if (cancellation != null)
          cancellation.whenCancelled.then<void>(
            (_) => throw const _EmbeddingCancelled(),
          ),
      ]);
    } catch (failure) {
      cancelled = !timedOut && (cancellation?.isCancelled ?? false);
      error = timedOut
          ? '客户端请求超时'
          : cancelled
          ? '本次请求已取消'
          : failure.toString();
      result = null;
    } finally {
      settled = true;
      timer?.cancel();
      remove?.call();
      client.close(force: true);
      watch.stop();
    }
    return EmbeddingPlaygroundResult(
      request: request,
      requestBody: sentBody,
      rawResponse: raw.toString(),
      elapsed: watch.elapsed,
      timeout: timeout,
      statusCode: status,
      result: result,
      error: error,
      cancelled: cancelled,
      timedOut: timedOut,
    );
  }

  Future<void> exportTo(
    File destination, {
    required String document,
    EmbeddingPlaygroundResult? result,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!destination.isAbsolute) throw ArgumentError('导出需要完整绝对路径');
    final safe = sealDebugJson({
      'input': document,
      'result': result?.toJson(),
    }, projection: JevDebugProjection.embeddingEvidence);
    final serialized = const JsonEncoder.withIndent('  ').convert({
      'input_json': safe['input'],
      'result': safe['result'],
      'channel': 'http',
      'timeout_us': (result?.timeout ?? timeout).inMicroseconds,
    });
    await destination.create(exclusive: true);
    try {
      await destination.writeAsString(serialized);
    } catch (error) {
      try {
        await destination.delete();
      } catch (cleanupError) {
        throw FileSystemException(
          '导出失败：$error；清理失败：$cleanupError',
          destination.path,
        );
      }
      rethrow;
    }
  }
}

class _EmbeddingCancelled implements Exception {
  const _EmbeddingCancelled();
}
