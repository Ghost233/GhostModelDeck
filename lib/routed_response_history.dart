import 'dart:convert';

/// Retains complete Responses input items and output for a public model name.
/// The next request can reconstruct its input on whichever instance is selected.
class RoutedResponseHistory {
  static const _maxEntries = 256;
  static const _maxBytes = 16 * 1024 * 1024;
  static const _maxHistoryBytes = 1024 * 1024;
  final _entries = <(String, String), List<int>>{};
  int _bytes = 0;

  List<Object?>? find(String model, String id) {
    final key = (model, id);
    final history = _entries.remove(key);
    if (history == null) return null;
    _entries[key] = history;
    return (jsonDecode(utf8.decode(history)) as List).cast<Object?>();
  }

  void remember(String model, Object? input, Map<String, Object?> response) {
    final id = response['id'];
    final output = response['output'];
    if (id is! String ||
        output is! List ||
        response['store'] == false ||
        response['status'] == 'failed' ||
        (input is! String && input is! List)) {
      return;
    }
    final bytes = utf8.encode(jsonEncode([...inputItems(input), ...output]));
    if (bytes.length > _maxHistoryBytes) return;
    final key = (model, id);
    _bytes -= _entries.remove(key)?.length ?? 0;
    _entries[key] = bytes;
    _bytes += bytes.length;
    while (_entries.length > _maxEntries || _bytes > _maxBytes) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
  }

  static List<Object?> inputItems(Object? input) => switch (input) {
    String text => [
      {'type': 'message', 'role': 'user', 'content': text},
    ],
    List items => items.cast<Object?>(),
    _ => throw const FormatException('input 需要是字符串或数组'),
  };

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
