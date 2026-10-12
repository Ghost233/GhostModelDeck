/// Shared reservations for instance and committee public names.
class PublicModelNames {
  final _ownerByName = <String, String>{};

  static String normalize(String value) {
    final stem = value.replaceFirst(
      RegExp(r'\.(gguf|safetensors)$', caseSensitive: false),
      '',
    );
    final name = stem
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return name.isEmpty ? 'model' : name;
  }

  static bool isValid(String name) =>
      name == name.toLowerCase() &&
      RegExp(
        r'^[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*$',
        unicode: true,
      ).hasMatch(name);

  String suggest(String value, {String? owner}) {
    final base = normalize(value);
    var name = base;
    var suffix = 2;
    while (_ownerByName.containsKey(name) && _ownerByName[name] != owner) {
      name = '$base-${suffix++}';
    }
    return name;
  }

  void claim(String owner, String name) => claimAll({owner: name});

  void claimAll(Map<String, String> names) {
    final proposed = {..._ownerByName};
    for (final entry in names.entries) {
      if (!isValid(entry.value)) {
        throw FormatException('公开调用名格式无效：${entry.value}');
      }
      final existing = proposed[entry.value];
      if (existing != null && existing != entry.key) {
        throw StateError('调用名 ${entry.value} 已存在，建议 ${suggest(entry.value)}');
      }
      proposed[entry.value] = entry.key;
    }
    _ownerByName.addAll(proposed);
  }

  void release(String owner, String name) {
    if (_ownerByName[name] == owner) _ownerByName.remove(name);
  }
}
