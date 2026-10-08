class LaunchArgumentTextException implements Exception {
  const LaunchArgumentTextException(this.position, this.message);
  final int position;
  final String message;

  @override
  String toString() => '参数文本第 $position 位：$message，启动前请修正。';
}

class LaunchArgumentToken {
  const LaunchArgumentToken(this.value, {required this.hasLiteralPrefix});
  final String value;

  /// Quoting/escaping at the start distinguishes a value after a known option
  /// from the next independent, unquoted option. It does not rewrite the value.
  final bool hasLiteralPrefix;
}

List<String> splitLaunchArgumentText(String source) =>
    parseLaunchArgumentText(source).map((token) => token.value).toList();

/// Parses argument boundaries and their source. It never expands variables or
/// executes shell syntax; callers give the values directly to the chosen engine.
List<LaunchArgumentToken> parseLaunchArgumentText(String source) {
  final nul = source.indexOf('\u0000');
  if (nul >= 0) {
    throw LaunchArgumentTextException(nul + 1, '参数不能包含 NUL 字符');
  }
  final arguments = <LaunchArgumentToken>[];
  var token = StringBuffer();
  var active = false;
  var literalPrefix = false;
  String? quote;
  var quoteStart = 0;
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    if (quote == "'") {
      if (character == quote) {
        quote = null;
      } else {
        token.write(character);
      }
      continue;
    }
    if (quote == '"') {
      if (character == quote) {
        quote = null;
      } else if (character == r'\' && index + 1 < source.length) {
        final next = source[index + 1];
        if ([r'\', '"', r'$', String.fromCharCode(96), '\n'].contains(next)) {
          index++;
          if (next != '\n') token.write(next);
        } else {
          token.write(character);
        }
      } else {
        token.write(character);
      }
      continue;
    }
    if (RegExp(r'\s').hasMatch(character)) {
      if (active) {
        arguments.add(
          LaunchArgumentToken(
            token.toString(),
            hasLiteralPrefix: literalPrefix,
          ),
        );
      }
      token = StringBuffer();
      active = false;
      literalPrefix = false;
    } else if (character == "'" || character == '"') {
      if (!active) literalPrefix = true;
      quote = character;
      quoteStart = index;
      active = true;
    } else if (character == r'\') {
      if (index + 1 == source.length) {
        throw LaunchArgumentTextException(index + 1, '反斜杠后缺少字符');
      }
      final next = source[++index];
      if (next != '\n') {
        if (!active) literalPrefix = true;
        token.write(next);
        active = true;
      }
    } else {
      token.write(character);
      active = true;
    }
  }
  if (quote != null) {
    throw LaunchArgumentTextException(quoteStart + 1, '引号未闭合');
  }
  if (active) {
    arguments.add(
      LaunchArgumentToken(token.toString(), hasLiteralPrefix: literalPrefix),
    );
  }
  return arguments;
}
