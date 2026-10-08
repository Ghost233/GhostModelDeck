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

/// Redacts display copies only; actual engine input and standard answers remain intact.
Map<String, Object?> sealDebugJson(Map<String, Object?> value) {
  final redactor = _CredentialRedactor()..collect(value);
  return freezeDebugJson(redactor.redact(value)) as Map<String, Object?>;
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
  static bool _taskData(Map parent, String key) {
    if (key == 'model' && parent[key] is String) return true;
    if (parent['questions'] is Map &&
        parent.containsKey('state') &&
        const {'state', 'images'}.contains(key)) {
      return true;
    }
    if (const {'choice', 'score', 'noul'}.contains(parent['type']) &&
        const {
          'instructions',
          'criteria',
          'choice',
          'score',
          'noul',
          'probabilities',
          'legend',
          'votes',
          'top_choices',
          'aggregate_scores',
        }.contains(key)) {
      return true;
    }
    if (key == 'name' &&
        parent['bindings'] is List &&
        const {'native', 'council'}.contains(parent['source'])) {
      return true;
    }
    if (parent['request'] is Map &&
        parent['seats'] is List &&
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

  static bool _identifiers(Map parent, String key) =>
      (key == 'questions' &&
          parent[key] is Map &&
          parent.containsKey('state')) ||
      (key == 'answers' &&
          parent[key] is Map &&
          (parent['model'] is String || parent['seat_id'] is String)) ||
      (key == 'aggregates' &&
          parent[key] is Map &&
          parent['request'] is Map &&
          parent['seats'] is List);

  static bool _textEvidence(String key) => const {
    'rawresponse',
    'requestbody',
    'rawheaders',
    'headers',
    'error',
    'message',
    'diagnostic',
  }.contains(key.toLowerCase().replaceAll(RegExp('[-_]'), ''));

  void collect(
    Object? value, {
    bool taskData = false,
    bool identifiers = false,
    bool textEvidence = false,
  }) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key as String;
        final opaque = taskData || !identifiers && _taskData(value, key);
        if (!opaque &&
            !identifiers &&
            _credential(key) &&
            entry.value is String) {
          _remember(entry.value as String);
        }
        collect(
          entry.value,
          taskData: opaque,
          identifiers: !opaque && !identifiers && _identifiers(value, key),
          textEvidence: textEvidence || _textEvidence(key),
        );
      }
    } else if (value is List) {
      for (final entry in value) {
        collect(
          entry,
          taskData: taskData,
          identifiers: identifiers,
          textEvidence: textEvidence,
        );
      }
    } else if (value is String && !taskData) {
      try {
        final parsed = jsonDecode(value);
        if (parsed is Map || parsed is List) {
          collect(parsed, textEvidence: textEvidence);
          // A complete JSON document has structural context. Regex scanning its
          // original bytes would mistake identifiers/descriptions for headers.
          return;
        }
      } on FormatException {
        // Malformed raw JSON and error text remain credential-bearing evidence.
      }
      if (!textEvidence) return;
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
    bool identifiers = false,
  }) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key as String:
              !taskData &&
                  !identifiers &&
                  !_taskData(value, entry.key as String) &&
                  _credential(entry.key as String)
              ? '[redacted]'
              : redact(
                  entry.value,
                  taskData:
                      taskData ||
                      !identifiers && _taskData(value, entry.key as String),
                  identifiers:
                      !taskData &&
                      !identifiers &&
                      _identifiers(value, entry.key as String),
                ),
      };
    }
    if (value is List) {
      return [
        for (final entry in value)
          redact(entry, taskData: taskData, identifiers: identifiers),
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
