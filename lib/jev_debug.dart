import 'dart:convert';

/// Owned by one decision call. Sealing prevents cleanup and late IO from writing.
class DecisionIOTrace {
  final _watch = Stopwatch()..start();
  Map<String, Object?>? _request;
  String? _requestBody;
  String? _rawResponse;
  int? _httpStatus;
  bool _sealed = false;

  void sent(String body) {
    if (_sealed) return;
    _requestBody = body;
    _request = Map<String, Object?>.from(jsonDecode(body) as Map);
  }

  void received(String raw, int status) {
    if (_sealed) return;
    _rawResponse = raw;
    _httpStatus = status;
  }

  void seal() {
    _sealed = true;
    _watch.stop();
  }

  Map<String, Object?> toJson() => freezeDebugJson({
    'dispatched': _requestBody != null,
    'request': _request,
    'request_body': _requestBody,
    'raw_response': _rawResponse,
    'http_status': _httpStatus,
    'elapsed_us': _watch.elapsedMicroseconds,
  }) as Map<String, Object?>;
}

/// Deep JSON snapshot; neither returned debug nor its nested objects are mutable.
Object? freezeDebugJson(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: freezeDebugJson(entry.value),
  }),
  List() => List<Object?>.unmodifiable(value.map(freezeDebugJson)),
  _ => value,
};

/// Caller-owned business root; unknown nested JSON cannot establish a role.
enum JevDebugProjection {
  generic,
  request,
  response,
  debug,
  playgroundResult,
  discovery,
  llmRequest,
  llmResponse,
  llmEvidence,
  benchmarkRun,
}

/// Redacts display copies only; actual engine input remains intact.
Map<String, Object?> sealDebugJson(
  Map<String, Object?> value, {
  JevDebugProjection projection = JevDebugProjection.generic,
}) {
  final context = switch (projection) {
    JevDebugProjection.generic => _JevProjection.none,
    JevDebugProjection.request => _JevProjection.request,
    JevDebugProjection.response => _JevProjection.response,
    JevDebugProjection.debug => _JevProjection.debug,
    JevDebugProjection.playgroundResult => _JevProjection.playgroundResult,
    JevDebugProjection.discovery => _JevProjection.discovery,
    JevDebugProjection.llmRequest => _JevProjection.llmRequest,
    JevDebugProjection.llmResponse => _JevProjection.llmResponse,
    JevDebugProjection.llmEvidence => _JevProjection.llmEvidence,
    JevDebugProjection.benchmarkRun => _JevProjection.benchmarkRun,
  };
  final redactor = _CredentialRedactor()..collect(value, context: context);
  return freezeDebugJson(redactor.redact(value, context: context))
      as Map<String, Object?>;
}

enum _JevProjection {
  none,
  request,
  response,
  debug,
  playgroundResult,
  configuration,
  discovery,
  nativeDiscovery,
  modelDiscovery,
  io,
  council,
  councilSeat,
  questions,
  question,
  answers,
  answer,
  aggregates,
  aggregate,
  llmRequest,
  llmResponse,
  llmEvidence,
  llmMessage,
  llmChoice,
  llmDelta,
  benchmarkRun,
  benchmarkItem,
  benchmarkResult,
  benchmarkIdentity,
}

class _CredentialRedactor {
  final _secrets = <String>{};
  static bool _credential(String key) => const {
    'apikey',
    'xapikey',
    'authorization',
    'cookie',
    'setcookie',
  }.contains(key.toLowerCase().replaceAll(RegExp('[-_]'), ''));
  static final _fields = RegExp(
    r'''\b(authorization|cookie|set-cookie|api[_-]?key|x-api-key)\b["']?\s*[:=]\s*(?:"((?:\\.|[^"\\])*)"|'([^']*)'|([^\r\n,}]+))''',
    caseSensitive: false,
  );

  void _remember(String value) {
    if (value.isEmpty) return;
    _secrets.add(value);
    final bearer = RegExp(
      r'^Bearer\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(value);
    if (bearer != null) _secrets.add(bearer.group(1)!);
    for (final cookie in value.split(';')) {
      final separator = cookie.indexOf('=');
      if (separator >= 0 && separator + 1 < cookie.length) {
        _secrets.add(cookie.substring(separator + 1).trim());
      }
    }
  }

  // Identifier dictionaries and task descriptions are opaque JEV data, not
  // credential configuration. Known secrets are still removed from their values.
  static bool _taskData(Map parent, String key, _JevProjection context) {
    if (const {
          _JevProjection.request,
          _JevProjection.response,
          _JevProjection.debug,
          _JevProjection.llmRequest,
          _JevProjection.llmResponse,
          _JevProjection.benchmarkRun,
          _JevProjection.benchmarkIdentity,
        }.contains(context) &&
        key == 'model' &&
        parent[key] is String) {
      return true;
    }
    if (context == _JevProjection.benchmarkItem &&
        const {
          'id',
          'pair_id',
          'gold',
          'prediction',
          'category',
          'difficulty',
        }.contains(key) &&
        parent[key] is String) {
      return true;
    }
    if (key == 'content' &&
        parent[key] is String &&
        (context == _JevProjection.llmMessage &&
                const {
                  'system',
                  'user',
                  'assistant',
                }.contains(parent['role']) ||
            context == _JevProjection.llmDelta)) {
      return true;
    }
    if (context == _JevProjection.llmEvidence &&
        key == 'text' &&
        parent[key] is String) {
      return true;
    }
    if (context == _JevProjection.request &&
        const {'state', 'images'}.contains(key)) {
      return true;
    }
    if (context == _JevProjection.question &&
        const {'choice', 'score', 'noul'}.contains(parent['type']) &&
        const {'instructions', 'criteria'}.contains(key)) {
      return true;
    }
    if (context == _JevProjection.answer ||
        context == _JevProjection.aggregate) {
      final fields = switch (parent['type']) {
        'choice' => const {'choice', 'probabilities'},
        'score' => const {'score', 'probabilities', 'legend'},
        'noul' => const {'noul'},
        _ => const <String>{},
      };
      if (fields.contains(key)) return true;
      if (context == _JevProjection.aggregate &&
          parent['type'] == 'choice' &&
          const {'votes', 'top_choices'}.contains(key)) {
        return true;
      }
    }
    if (context == _JevProjection.configuration &&
        (key == 'name' ||
            key == 'fixed_call_names' &&
                parent[key] is List &&
                (parent[key] as List).every((name) => name is String))) {
      return true;
    }
    if (context == _JevProjection.nativeDiscovery &&
        key == 'model' &&
        parent[key] is String) {
      return true;
    }
    if (context == _JevProjection.modelDiscovery &&
        key == 'id' &&
        parent[key] is String) {
      return true;
    }
    if (context == _JevProjection.council &&
        const {
          'aggregate_scores',
          'votes',
          'top_choices',
          'disagreement',
        }.contains(key)) {
      return true;
    }
    return false;
  }

  static bool _identifiers(_JevProjection context) => const {
    _JevProjection.questions,
    _JevProjection.answers,
    _JevProjection.aggregates,
  }.contains(context);

  static _JevProjection _childContext(
    Map parent,
    String key,
    _JevProjection context,
  ) => switch (context) {
    _JevProjection.benchmarkRun => switch (key) {
      'items' => _JevProjection.benchmarkItem,
      'identity' => _JevProjection.benchmarkIdentity,
      _ => _JevProjection.none,
    },
    _JevProjection.benchmarkIdentity =>
      key == 'configuration'
          ? _JevProjection.configuration
          : _JevProjection.none,
    _JevProjection.benchmarkItem => switch (key) {
      'request' || 'request_json' => _JevProjection.request,
      'result' => _JevProjection.benchmarkResult,
      _ => _JevProjection.none,
    },
    _JevProjection.benchmarkResult => switch (key) {
      'request' || 'request_json' => _JevProjection.request,
      'output' =>
        parent['status'] == 'success'
            ? _JevProjection.response
            : _JevProjection.none,
      'debug' => _JevProjection.debug,
      'raw_response' =>
        parent['status'] == 'success' && parent['output'] is Map
            ? _JevProjection.response
            : _JevProjection.none,
      _ => _JevProjection.none,
    },
    _JevProjection.llmEvidence => switch (key) {
      'input' || 'request' || 'request_body' => _JevProjection.llmRequest,
      'response' || 'raw_response' => _JevProjection.llmResponse,
      'result' => _JevProjection.llmEvidence,
      _ => _JevProjection.none,
    },
    _JevProjection.llmRequest =>
      key == 'messages' ? _JevProjection.llmMessage : _JevProjection.none,
    _JevProjection.llmResponse =>
      key == 'choices' && parent['model'] is String
          ? _JevProjection.llmChoice
          : _JevProjection.none,
    _JevProjection.llmChoice => switch (key) {
      'message' => _JevProjection.llmMessage,
      'delta' => _JevProjection.llmDelta,
      _ => _JevProjection.none,
    },
    _JevProjection.discovery => switch (key) {
      'instances' => _JevProjection.nativeDiscovery,
      'data' => _JevProjection.modelDiscovery,
      _ => _JevProjection.none,
    },
    _JevProjection.playgroundResult => switch (key) {
      'output' => _JevProjection.response,
      'debug' => _JevProjection.debug,
      _ => _JevProjection.none,
    },
    _JevProjection.debug => switch (key) {
      'configuration' => _JevProjection.configuration,
      'input' => _JevProjection.request,
      'native' || 'seats' => _JevProjection.io,
      'council' => _JevProjection.council,
      'converted_result' => _JevProjection.response,
      _ => _JevProjection.none,
    },
    _JevProjection.io => switch (key) {
      'request' || 'request_body' => _JevProjection.request,
      'result' => _JevProjection.response,
      'raw_response' =>
        parent['result'] != null
            ? _JevProjection.response
            : _JevProjection.none,
      _ => _JevProjection.none,
    },
    _JevProjection.council => switch (key) {
      'request' => _JevProjection.request,
      'seats' => _JevProjection.councilSeat,
      'aggregates' => _JevProjection.aggregates,
      _ => _JevProjection.none,
    },
    _JevProjection.councilSeat => switch (key) {
      'answers' => _JevProjection.answers,
      'raw_response' =>
        parent['answers'] != null
            ? _JevProjection.response
            : _JevProjection.none,
      _ => _JevProjection.none,
    },
    _JevProjection.request =>
      key == 'questions' ? _JevProjection.questions : _JevProjection.none,
    _JevProjection.response =>
      key == 'answers' ? _JevProjection.answers : _JevProjection.none,
    _JevProjection.questions => _JevProjection.question,
    _JevProjection.answers => _JevProjection.answer,
    _JevProjection.aggregates => _JevProjection.aggregate,
    _ => _JevProjection.none,
  };

  void collect(
    Object? value, {
    bool taskData = false,
    _JevProjection context = _JevProjection.none,
  }) {
    if (value is Map) {
      final identifiers = _identifiers(context);
      for (final entry in value.entries) {
        final key = entry.key as String;
        final opaque =
            taskData || !identifiers && _taskData(value, key, context);
        if (!opaque &&
            !identifiers &&
            _credential(key) &&
            entry.value is String) {
          _remember(entry.value as String);
        }
        collect(
          entry.value,
          taskData: opaque,
          context: _childContext(value, key, context),
        );
      }
    } else if (value is List) {
      for (final entry in value) {
        collect(entry, taskData: taskData, context: context);
      }
    } else if (value is String && !taskData) {
      try {
        final parsed = jsonDecode(value);
        if (parsed is Map || parsed is List) {
          collect(parsed, context: context);
          // A complete JSON document has structural context. Regex scanning its
          // original bytes would mistake identifiers/descriptions for headers.
          return;
        }
      } on FormatException {
        // Malformed raw JSON and error text remain credential-bearing evidence.
      }
      if (context == _JevProjection.llmResponse &&
          const LineSplitter()
              .convert(value)
              .any((line) => line.startsWith('data:'))) {
        // Observe each SSE payload with its response role. Unknown frames and
        // comments remain generic evidence; raw bytes are never reconstructed.
        final data = <String>[];
        void dispatch() {
          if (data.isEmpty) return;
          final payload = data.join('\n');
          data.clear();
          if (payload != '[DONE]') collect(payload, context: context);
        }

        for (final line in const LineSplitter().convert(value)) {
          if (line.isEmpty) {
            dispatch();
          } else if (line.startsWith('data:')) {
            final content = line.substring(5);
            data.add(content.startsWith(' ') ? content.substring(1) : content);
          } else {
            collect(line);
          }
        }
        dispatch();
        return;
      }
      for (final match in _fields.allMatches(value)) {
        var secret = match.group(2) ?? match.group(3) ?? match.group(4)!;
        if (match.group(2) != null) {
          try {
            secret = jsonDecode('"$secret"') as String;
          } on FormatException {
            /* Use the observed literal. */
          }
        }
        _remember(secret.trim());
      }
    }
  }

  Object? redact(
    Object? value, {
    bool taskData = false,
    _JevProjection context = _JevProjection.none,
  }) {
    if (value is Map) {
      final identifiers = _identifiers(context);
      return {
        for (final entry in value.entries)
          entry.key as String:
              !taskData &&
                  !identifiers &&
                  !_taskData(value, entry.key as String, context) &&
                  _credential(entry.key as String)
              ? '[redacted]'
              : redact(
                  entry.value,
                  taskData:
                      taskData ||
                      !identifiers &&
                          _taskData(value, entry.key as String, context),
                  context: _childContext(value, entry.key as String, context),
                ),
      };
    }
    if (value is List) {
      return [
        for (final entry in value)
          redact(entry, taskData: taskData, context: context),
      ];
    }
    if (value is String) {
      var result = value;
      final secrets = _secrets.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final secret in secrets) {
        result = result.replaceAll(secret, '[redacted]');
        final encoded = jsonEncode(secret);
        result = result.replaceAll(
          encoded.substring(1, encoded.length - 1),
          '[redacted]',
        );
      }
      return result;
    }
    return value;
  }
}
