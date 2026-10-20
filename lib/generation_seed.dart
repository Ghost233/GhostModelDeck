import 'dart:convert';

/// Only integers outside Dart's signed range need this immutable representation.
/// Private JSON stores decimal text; public/native JSON still uses an integer.
class ExactGenerationSeed {
  ExactGenerationSeed._(this.integer);
  final BigInt integer;
  @override
  String toString() => integer.toString();
  String toJson() => toString();
}

Object? parseGenerationSeed(String text) {
  if (text.length > 21 || !RegExp(r'^[+-]?\d+$').hasMatch(text)) return null;
  final integer = BigInt.tryParse(text);
  if (integer == null) return null;
  return int.tryParse(integer.toString()) ?? ExactGenerationSeed._(integer);
}

BigInt? generationSeedInteger(Object? value) => switch (value) {
  int() => BigInt.from(value),
  ExactGenerationSeed() => value.integer,
  _ => null,
};

/// Standard decoding validates all syntax before inspecting the top-level token.
Object? decodeGenerationRequest(String source) {
  final value = jsonDecode(source);
  if (value is! Map || !value.containsKey('seed')) return value;
  final span = _seedSpan(source);
  if (span == null) return value;
  final token = source.substring(span.$1, span.$2);
  if (RegExp(r'^-?(?:0|[1-9]\d*)$').hasMatch(token)) {
    final exact = parseGenerationSeed(token);
    if (exact != null) value['seed'] = exact;
  }
  return value;
}

String encodeGenerationRequest(
  Map<String, Object?> value, {
  bool pretty = false,
}) {
  final encoded =
      (pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder())
          .convert(value);
  final seed = value['seed'];
  if (seed is! ExactGenerationSeed) return encoded;
  final span = _seedSpan(encoded)!;
  return encoded.replaceRange(span.$1, span.$2, seed.toString());
}

// This is a locator over already validated JSON, not a second JSON parser.
// Strings and nested values are skipped; duplicate decoded names use the last.
(int, int)? _seedSpan(String source) {
  int whitespace(int cursor) {
    while (cursor < source.length &&
        [9, 10, 13, 32].contains(source.codeUnitAt(cursor))) {
      cursor++;
    }
    return cursor;
  }

  int stringEnd(int cursor) {
    cursor++;
    while (cursor < source.length) {
      final character = source.codeUnitAt(cursor++);
      if (character == 92) {
        cursor++;
      } else if (character == 34) {
        return cursor;
      }
    }
    throw const FormatException('JSON 字符串未结束');
  }

  int valueEnd(int cursor) {
    final first = source.codeUnitAt(cursor);
    if (first == 34) return stringEnd(cursor);
    if (first == 123 || first == 91) {
      var depth = 0;
      while (cursor < source.length) {
        final character = source.codeUnitAt(cursor);
        if (character == 34) {
          cursor = stringEnd(cursor);
          continue;
        }
        cursor++;
        if (character == 123 || character == 91) depth++;
        if (character == 125 || character == 93) {
          depth--;
          if (depth == 0) return cursor;
        }
      }
    }
    while (cursor < source.length &&
        ![9, 10, 13, 32, 44, 125, 93].contains(source.codeUnitAt(cursor))) {
      cursor++;
    }
    return cursor;
  }

  var cursor = whitespace(0);
  if (source.codeUnitAt(cursor) != 123) return null;
  cursor = whitespace(cursor + 1);
  (int, int)? result;
  while (source.codeUnitAt(cursor) != 125) {
    final endOfName = stringEnd(cursor);
    final name = jsonDecode(source.substring(cursor, endOfName));
    cursor = whitespace(endOfName);
    final start = whitespace(cursor + 1); // Colon, guaranteed by jsonDecode.
    final end = valueEnd(start);
    if (name == 'seed') result = (start, end);
    cursor = whitespace(end);
    if (source.codeUnitAt(cursor) == 125) break;
    cursor = whitespace(cursor + 1); // Comma, guaranteed by jsonDecode.
  }
  return result;
}
