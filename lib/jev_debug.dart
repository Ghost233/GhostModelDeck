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

enum _JevProjection {
  none,
  questions,
  question,
  answers,
  answer,
  aggregates,
  aggregate,
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
    if (key == 'model' && parent[key] is String) return true;
    if (parent['questions'] is Map &&
        parent.containsKey('state') &&
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

  static bool _identifiers(_JevProjection context) => const {
    _JevProjection.questions,
    _JevProjection.answers,
    _JevProjection.aggregates,
  }.contains(context);

  static _JevProjection _childContext(
    Map parent,
    String key,
    _JevProjection context,
  ) {
    if (context == _JevProjection.questions) return _JevProjection.question;
    if (context == _JevProjection.answers) return _JevProjection.answer;
    if (context == _JevProjection.aggregates) return _JevProjection.aggregate;
    if (key == 'questions' &&
        parent[key] is Map &&
        parent.containsKey('state')) {
      return _JevProjection.questions;
    }
    if (key == 'answers' &&
        parent[key] is Map &&
        (parent['model'] is String || parent['seat_id'] is String)) {
      return _JevProjection.answers;
    }
    if (key == 'aggregates' &&
        parent[key] is Map &&
        parent['request'] is Map &&
        parent['seats'] is List) {
      return _JevProjection.aggregates;
    }
    return _JevProjection.none;
  }

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
          collect(parsed);
          // A complete JSON document has structural context. Regex scanning its
          // original bytes would mistake identifiers/descriptions for headers.
          return;
        }
      } on FormatException {
        // Malformed raw JSON and error text remain credential-bearing evidence.
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
