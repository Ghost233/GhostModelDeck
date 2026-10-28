import 'dart:convert';
import 'dart:io';

import 'engine_runtime.dart';
import 'generation_seed.dart';

enum SplashOperationPath { chat, systemone }

enum SplashOperationKind { prefill, consume }

class SplashOperationSubmission {
  const SplashOperationSubmission(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// A private Splash control endpoint returned no trustworthy operation state.
class SplashOperationUnavailable implements Exception {
  const SplashOperationUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class SplashPrefillEndpointMissing extends SplashOperationUnavailable {
  const SplashPrefillEndpointMissing({this.instanceId, this.generation})
    : super('Splash 版本没有预填能力接口');
  final String? instanceId;
  final int? generation;
}

class SplashOperationIdentity {
  const SplashOperationIdentity(
    this.serviceInstance,
    this.runtimeGeneration, {
    this.capabilities = const SplashPrefillCapabilities.unavailable(),
  });
  final String serviceInstance;
  final int runtimeGeneration;
  final SplashPrefillCapabilities capabilities;

  bool supportsPrefill(SplashOperationPath path) =>
      capabilities.operationTracking &&
      (path == SplashOperationPath.chat
          ? capabilities.chatZeroBudget
          : capabilities.systemoneState);
}

class SplashPrefillCapabilities {
  const SplashPrefillCapabilities.unavailable()
    : declared = false,
      operationTracking = false,
      chatZeroBudget = false,
      systemoneState = false;
  const SplashPrefillCapabilities._(
    this.operationTracking,
    this.chatZeroBudget,
    this.systemoneState,
  ) : declared = true;
  final bool declared;
  final bool operationTracking, chatZeroBudget, systemoneState;

  static SplashPrefillCapabilities parse(Object? value) {
    if (value is! Map ||
        value['schema'] != 'splash-prefill/1' ||
        value['operation_tracking'] is! bool ||
        value['chat_zero_budget'] is! bool ||
        value['systemone_state'] is! bool) {
      return const SplashPrefillCapabilities.unavailable();
    }
    return SplashPrefillCapabilities._(
      value['operation_tracking'] as bool,
      value['chat_zero_budget'] as bool,
      value['systemone_state'] as bool,
    );
  }

  bool sameAs(SplashPrefillCapabilities other) =>
      declared == other.declared &&
      operationTracking == other.operationTracking &&
      chatZeroBudget == other.chatZeroBudget &&
      systemoneState == other.systemoneState;

  List<bool> get bindingValues => [
    declared,
    operationTracking,
    chatZeroBudget,
    systemoneState,
  ];
}

class SplashOperationChild {
  const SplashOperationChild({
    required this.state,
    required this.leaseReleased,
    this.questionId,
    this.nativeRequestId,
    this.runtimeGeneration,
    this.promptTokens,
    this.matchedPromptTokens,
    this.deduplicatedTokens,
    this.completionTokens,
  });
  final String state;
  final bool leaseReleased;
  final String? questionId;
  final int? nativeRequestId, runtimeGeneration, promptTokens;
  final int? matchedPromptTokens, deduplicatedTokens, completionTokens;
}

class SplashOperationSnapshot {
  SplashOperationSnapshot._({
    required this.operationId,
    required this.serviceInstance,
    required this.expectedRuntimeGeneration,
    required this.state,
    required this.terminal,
    required this.leaseReleased,
    required List<SplashOperationChild> children,
  }) : children = List.unmodifiable(children);
  final String operationId, serviceInstance;

  /// Submitted expectation; actual generations are reported per native child.
  final int expectedRuntimeGeneration;
  final String state;
  final bool terminal, leaseReleased;
  final List<SplashOperationChild> children;

  /// A completed handler alone does not establish a real prefill.
  SplashOperationChild requirePrefillEvidence() {
    final child = children.singleOrNull;
    if (state != 'completed' ||
        !terminal ||
        !leaseReleased ||
        child == null ||
        child.state != 'length' ||
        !child.leaseReleased ||
        child.questionId != null ||
        child.nativeRequestId == null ||
        child.runtimeGeneration != expectedRuntimeGeneration ||
        child.promptTokens == null ||
        child.promptTokens! < 1 ||
        child.completionTokens != 0) {
      throw const SplashOperationUnavailable('尚无真实零输出预填完成证据');
    }
    return child;
  }
}

/// Reads authenticated evidence from the already owned Splash service.
/// A missing, malformed or changed service is never treated as released.
class SplashOperationClient {
  SplashOperationClient({
    required this.endpoint,
    Map<String, String> headers = const {},
    this.timeout = const Duration(seconds: 5),
  }) : headers = Map.unmodifiable(headers);

  final Uri endpoint;
  final Map<String, String> headers;
  final Duration timeout;
  static final _id = RegExp(r'^[A-Za-z0-9._~-]{1,128}$');
  static final _token = RegExp(r'^[0-9a-fA-F]{64}$');

  /// The caller must bind the operation and own the runtime permit before
  /// submission. A response or transport error alone cannot prove release.
  Future<SplashOperationSubmission> submit({
    required SplashOperationPath path,
    required SplashOperationKind kind,
    required String operationId,
    required String token,
    required SplashOperationIdentity expected,
    required Map<String, Object?> body,
    DecisionCancellation? cancellation,
  }) async {
    if (!_id.hasMatch(operationId) ||
        !_token.hasMatch(token) ||
        !_id.hasMatch(expected.serviceInstance) ||
        expected.runtimeGeneration < 1 ||
        body['model'] is! String ||
        (body['model'] as String).isEmpty ||
        (body['stream'] != null && body['stream'] != false)) {
      throw const FormatException('原生请求绑定或正文无效');
    }
    if (path == SplashOperationPath.chat) {
      final max = body['max_tokens'];
      final completionMax = body['max_completion_tokens'];
      if ([
            max,
            completionMax,
          ].any((value) => value != null && (value is! int || value < 0)) ||
          body.containsKey('max_tokens') &&
              body.containsKey('max_completion_tokens') &&
              max != completionMax ||
          kind == SplashOperationKind.prefill &&
              (max != 0 && completionMax != 0 ||
                  max != null && max != 0 ||
                  completionMax != null && completionMax != 0) ||
          kind == SplashOperationKind.consume &&
              (max == 0 || completionMax == 0)) {
        throw const FormatException('原生请求类型与输出预算不符');
      }
    } else {
      final prefill = body['prefill_only'];
      final questions = body['questions'];
      if (prefill != null && prefill is! bool ||
          (prefill == true) != (kind == SplashOperationKind.prefill) ||
          prefill == true &&
              questions != null &&
              (questions is! Map || questions.isNotEmpty)) {
        throw const FormatException('原生请求类型与决策预填参数不符');
      }
    }
    final bytes = utf8.encode(encodeGenerationRequest(body));
    if (bytes.length > 1024 * 1024) throw const FormatException('原生请求超出字节上限');
    _checkEndpoint();
    final client = HttpClient()..connectionTimeout = timeout;
    final removeCancellation = cancellation?.listen(
      () => client.close(force: true),
    );
    try {
      if (cancellation?.isCancelled == true) {
        throw const SplashOperationUnavailable('Splash 提交结果未知；须查询原操作');
      }
      final request = await client
          .postUrl(
            endpoint.resolve(
              path == SplashOperationPath.chat
                  ? '/v1/chat/completions'
                  : '/v1/systemone',
            ),
          )
          .timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.contentType = ContentType.json;
      request.headers.set('X-Splash-Operation-ID', operationId);
      request.headers.set('X-Splash-Operation-Token', token);
      request.headers.set(
        'X-Splash-Service-Instance',
        expected.serviceInstance,
      );
      request.headers.set(
        'X-Splash-Runtime-Generation',
        expected.runtimeGeneration.toString(),
      );
      request.headers.set('X-Splash-Operation-Kind', kind.name);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(timeout);
      final result = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (result.length + chunk.length > 1024 * 1024) {
          throw const SplashOperationUnavailable('Splash 响应超出限制；终态未知');
        }
        result.addAll(chunk);
      }
      if (cancellation?.isCancelled == true) {
        throw const SplashOperationUnavailable('Splash 提交结果未知；须查询原操作');
      }
      return SplashOperationSubmission(
        response.statusCode,
        utf8.decode(result),
      );
    } on SplashOperationUnavailable {
      rethrow;
    } catch (_) {
      throw const SplashOperationUnavailable('Splash 提交结果未知；须查询原操作');
    } finally {
      removeCancellation?.call();
      client.close(force: true);
    }
  }

  Future<SplashOperationIdentity> identity({
    DecisionCancellation? cancellation,
  }) async {
    final value = await _request(
      'GET',
      '/v1/splash/runtime',
      cancellation: cancellation,
    );
    final instance = value['service_instance'];
    final generation = value['runtime_generation'];
    if (instance is! String ||
        !_id.hasMatch(instance) ||
        generation is! int ||
        generation < 1) {
      throw const SplashOperationUnavailable('Splash 运行身份尚未确认');
    }
    return SplashOperationIdentity(
      instance,
      generation,
      capabilities: SplashPrefillCapabilities.parse(
        value['prefill_capabilities'],
      ),
    );
  }

  Future<SplashOperationSnapshot> query({
    required String operationId,
    required String token,
    required SplashOperationIdentity expected,
    DecisionCancellation? cancellation,
  }) => _operation('GET', operationId, token, expected, cancellation);

  Future<SplashOperationSnapshot> cancel({
    required String operationId,
    required String token,
    required SplashOperationIdentity expected,
    DecisionCancellation? cancellation,
  }) => _operation('POST', operationId, token, expected, cancellation);

  /// The owner must first durably retain the result and terminal evidence.
  Future<void> acknowledge({
    required SplashOperationSnapshot snapshot,
    required String token,
  }) async {
    if (!snapshot.terminal ||
        !snapshot.leaseReleased ||
        !_id.hasMatch(snapshot.operationId) ||
        !_token.hasMatch(token)) {
      throw const SplashOperationUnavailable('原生终态未确认，不能回收操作记录');
    }
    final value = await _request(
      'DELETE',
      '/v1/splash/operations/${snapshot.operationId}',
      token: token,
    );
    if (value['acknowledged'] != true) {
      throw const SplashOperationUnavailable('Splash 操作回收结果未确认');
    }
  }

  Future<SplashOperationSnapshot> _operation(
    String method,
    String operationId,
    String token,
    SplashOperationIdentity expected,
    DecisionCancellation? cancellation,
  ) async {
    if (!_id.hasMatch(operationId) || !_token.hasMatch(token)) {
      throw const SplashOperationUnavailable('操作身份或凭证格式无效');
    }
    final path =
        '/v1/splash/operations/$operationId${method == 'POST' ? '/cancel' : ''}';
    final value = await _request(
      method,
      path,
      token: token,
      cancellation: cancellation,
    );
    if (value['operation_id'] != operationId ||
        value['service_instance'] != expected.serviceInstance ||
        value['state'] is! String ||
        value['terminal'] is! bool ||
        value['lease_released'] is! bool ||
        value['children'] is! List) {
      throw const SplashOperationUnavailable('Splash 操作状态或服务身份未确认');
    }
    final state = value['state'] as String;
    final terminal = value['terminal'] as bool;
    final released = value['lease_released'] as bool;
    if (!{
          'running',
          'cancel_requested',
          'completed',
          'cancelled',
          'failed',
          'unknown',
        }.contains(state) ||
        terminal != released ||
        terminal != {'completed', 'cancelled', 'failed'}.contains(state)) {
      throw const SplashOperationUnavailable('Splash 操作终态不一致');
    }
    final children = <SplashOperationChild>[];
    for (final item in value['children'] as List) {
      if (item is! Map ||
          item['state'] is! String ||
          item['question_id'] != null && item['question_id'] is! String ||
          item['lease_released'] != null && item['lease_released'] is! bool) {
        throw const SplashOperationUnavailable('Splash 原生子请求状态无效');
      }
      int? count(String key) {
        final number = item[key];
        if (number == null) return null;
        if (number is! int || number < 0) {
          throw const SplashOperationUnavailable('Splash 原生请求计数无效');
        }
        return number;
      }

      final generation = count('runtime_generation');
      final requestId = count('native_request_id');
      final promptTokens = count('prompt_tokens');
      final matchedTokens = count('matched_prompt_tokens');
      final childState = item['state'] as String;
      if (generation != null && generation != expected.runtimeGeneration ||
          generation == 0 ||
          requestId == 0 ||
          terminal && item['lease_released'] != true ||
          terminal &&
              childState != 'not_admitted' &&
              (requestId == null || generation == null) ||
          terminal &&
              !{
                'stop',
                'length',
                'cancelled',
                'failed',
                'not_admitted',
              }.contains(childState) ||
          matchedTokens != null &&
              promptTokens != null &&
              matchedTokens > promptTokens) {
        throw const SplashOperationUnavailable('Splash 原生代次或释放状态未确认');
      }
      children.add(
        SplashOperationChild(
          state: childState,
          leaseReleased: item['lease_released'] == true,
          questionId: item['question_id'] as String?,
          nativeRequestId: requestId,
          runtimeGeneration: generation,
          promptTokens: promptTokens,
          matchedPromptTokens: matchedTokens,
          deduplicatedTokens: count('deduplicated_tokens'),
          completionTokens: count('completion_tokens'),
        ),
      );
    }
    return SplashOperationSnapshot._(
      operationId: operationId,
      serviceInstance: expected.serviceInstance,
      expectedRuntimeGeneration: expected.runtimeGeneration,
      state: state,
      terminal: terminal,
      leaseReleased: released,
      children: children,
    );
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    String? token,
    DecisionCancellation? cancellation,
  }) async {
    _checkEndpoint();
    final client = HttpClient()..connectionTimeout = timeout;
    final removeCancellation = cancellation?.listen(
      () => client.close(force: true),
    );
    try {
      if (cancellation?.isCancelled == true) {
        throw const SplashOperationUnavailable('Splash 操作不可查询；终态与释放状态未知');
      }
      final request = await client
          .openUrl(method, endpoint.resolve(path))
          .timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (token != null) request.headers.set('X-Splash-Operation-Token', token);
      if (method != 'GET') request.contentLength = 0;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        if (method == 'GET' &&
            path == '/v1/splash/runtime' &&
            response.statusCode == 404) {
          throw const SplashPrefillEndpointMissing();
        }
        throw const SplashOperationUnavailable('Splash 操作不可查询；终态与释放状态未知');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const SplashOperationUnavailable('Splash 操作状态响应超出限制');
        }
        bytes.addAll(chunk);
      }
      if (cancellation?.isCancelled == true) {
        throw const SplashOperationUnavailable('Splash 操作不可查询；终态与释放状态未知');
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map) throw const FormatException('invalid response');
      return Map<String, Object?>.from(value);
    } on SplashOperationUnavailable {
      rethrow;
    } catch (_) {
      throw const SplashOperationUnavailable('Splash 操作不可查询；终态与释放状态未知');
    } finally {
      removeCancellation?.call();
      client.close(force: true);
    }
  }

  void _checkEndpoint() {
    if (!{'http', 'https'}.contains(endpoint.scheme) ||
        !{'127.0.0.1', 'localhost', '::1', '[::1]'}.contains(endpoint.host) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const SplashOperationUnavailable('Splash 地址不是本机服务');
    }
  }
}
