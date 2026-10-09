import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'chat_protocol.dart';
import 'engine_runtime.dart';
import 'jev_debug.dart';

class LlmPlaygroundResult {
  const LlmPlaygroundResult({
    required this.request,
    required this.rawResponse,
    required this.elapsed,
    this.statusCode,
    this.requestBody,
    this.result,
    this.error,
    this.partialText = '',
    this.cancelled = false,
    this.timedOut = false,
    this.timeout = const Duration(seconds: 120),
  });
  final Map<String, Object?>? request;
  final String rawResponse;
  final Duration elapsed;
  final int? statusCode;
  final String? requestBody;
  final TextResult? result;
  final String? error;
  final String partialText;
  final bool cancelled;
  final bool timedOut;
  final Duration timeout;
  bool get completed => result != null && error == null;
  bool get interrupted =>
      !completed &&
      !cancelled &&
      !timedOut &&
      error != null &&
      statusCode == 200 &&
      request?['stream'] == true;
  String get text => result?.text ?? partialText;
  String? get finishReason => result?.finishReason;
  Map<String, Object?>? get usage => result?.usage;

  Map<String, Object?> get _evidence {
    Object? response;
    try {
      response = jsonDecode(rawResponse);
    } on FormatException {
      response = null;
    }
    return {
      'request': request,
      'request_body': requestBody,
      'dispatched': requestBody != null,
      'http_status': statusCode,
      'response': response,
      'raw_response': rawResponse,
      'text': text,
      'usage': usage,
      'finish_reason': finishReason,
      'completed': completed,
      'cancelled': cancelled,
      'timed_out': timedOut,
      'interrupted': interrupted,
      'timeout_us': timeout.inMicroseconds,
      'elapsed_us': elapsed.inMicroseconds,
      'error': error,
    };
  }

  Map<String, Object?> toJson() =>
      sealDebugJson(_evidence, projection: JevDebugProjection.llmEvidence);
}

/// Ordinary public HTTP client. It owns no model or server inference handles.
class LlmPlayground {
  LlmPlayground({required this.baseUrl});
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
      final request = await client.getUrl(_endpoint('/v1/models'));
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}: $raw');
      }
      final value = jsonDecode(raw);
      if (value is! Map || value['data'] is! List) {
        throw const FormatException('公开模型发现响应无效');
      }
      final ids = <String>[];
      for (final entry in value['data'] as List) {
        if (entry is! Map || entry['id'] is! String) {
          throw const FormatException('公开模型发现条目无效');
        }
        // Current public JEV entries carry source; chat entries do not.
        if (!entry.containsKey('source')) ids.add(entry['id'] as String);
      }
      return List.unmodifiable(ids);
    }

    try {
      if (timeout <= Duration.zero) throw const FormatException('客户端期限必须大于零');
      if (cancellation?.isCancelled ?? false) {
        throw const HttpException('公开模型发现已取消');
      }
      deadline = Timer(timeout, () {
        timedOut = true;
        disconnect();
      });
      return await Future.any<List<String>>([
        receive(),
        stopped.future.then<List<String>>((_) => throw const _LlmCancelled()),
      ]);
    } catch (error) {
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

  Future<void> exportTo(
    File destination, {
    required String document,
    LlmPlaygroundResult? result,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!destination.isAbsolute) throw ArgumentError('导出需要完整绝对路径');
    final safe = sealDebugJson({
      'input': document,
      'result': result?._evidence,
    }, projection: JevDebugProjection.llmEvidence);
    final evidence = safe['result'] as Map<String, Object?>?;
    final record = {
      'input_json': safe['input'],
      'request': evidence?['request'],
      'channel': 'http',
      'timeout_us': (result?.timeout ?? timeout).inMicroseconds,
      'result': evidence,
    };
    final serialized = const JsonEncoder.withIndent('  ').convert(record);
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

  Future<LlmPlaygroundResult> run(
    String document, {
    void Function(LlmPlaygroundResult progress)? onProgress,
    DecisionCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final watch = Stopwatch()..start();
    final client = HttpClient();
    Map<String, Object?>? requestBody;
    String? sentBody;
    int? status;
    final raw = StringBuffer();
    final text = StringBuffer();
    TextResult? result;
    String? error;
    var settled = false;
    var cancelled = false;
    var timedOut = false;
    Timer? timer;
    final expired = Completer<void>();
    final unlisten = cancellation?.listen(() => client.close(force: true));
    Future<void> receive() async {
      final value = jsonDecode(document);
      if (value is! Map) throw const FormatException('请求需要是 JSON 对象');
      final parsedBody = freezeDebugJson(
        Map<String, Object?>.from(value),
      ) as Map<String, Object?>;
      requestBody = parsedBody;
      final request = await client.postUrl(_endpoint('/v1/chat/completions'));
      if (settled) return;
      request.headers.contentType = ContentType.json;
      request.write(document);
      sentBody = document;
      final response = await request.close();
      status = response.statusCode;
      final model = parsedBody['model'];
      final body = utf8.decoder.bind(response).map((chunk) {
        if (!settled) raw.write(chunk);
        return chunk;
      });
      if (status != 200) {
        await body.drain<void>();
        throw HttpException('HTTP $status');
      }
      if (model is! String) throw const FormatException('model 需要是字符串');
      if (parsedBody['stream'] == true) {
        final decoder = TextStreamDecoder(expectedModel: model);
        final data = <String>[];
        void dispatch() {
          if (settled) return;
          if (data.isEmpty) return;
          final event = decoder.add(data.join('\n'));
          data.clear();
          if (event != null) {
            text.write(event.delta);
            onProgress?.call(
              LlmPlaygroundResult(
                request: requestBody,
                rawResponse: raw.toString(),
                elapsed: watch.elapsed,
                statusCode: status,
                requestBody: sentBody,
                partialText: text.toString(),
                timeout: timeout,
              ),
            );
          }
        }

        await for (final line in body.transform(const LineSplitter())) {
          if (line.isEmpty) {
            dispatch();
          } else if (line.startsWith('data:')) {
            var value = line.substring(5);
            if (value.startsWith(' ')) value = value.substring(1);
            data.add(value);
          }
        }
        dispatch();
        final complete = decoder.finish();
        if (!settled) result = complete;
      } else {
        await body.drain<void>();
        final complete = TextResult.parse(raw.toString(), expectedModel: model);
        if (!settled) result = complete;
      }
    }

    try {
      if (timeout <= Duration.zero) throw const FormatException('客户端期限必须大于零');
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
            (_) => throw const _LlmCancelled(),
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
      unlisten?.call();
      client.close(force: true);
      watch.stop();
    }
    return LlmPlaygroundResult(
      request: requestBody,
      rawResponse: raw.toString(),
      elapsed: watch.elapsed,
      statusCode: status,
      requestBody: sentBody,
      result: result,
      error: error,
      partialText: text.toString(),
      cancelled: cancelled,
      timedOut: timedOut,
      timeout: timeout,
    );
  }
}

class _LlmCancelled implements Exception {
  const _LlmCancelled();
}
