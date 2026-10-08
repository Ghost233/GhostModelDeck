import 'engine_catalog.dart';
import 'engine_runtime.dart';

String engineDisplayName(EngineRegistration entry) {
  if (entry.source == EngineSource.linked) {
    return entry.family == EngineFamily.omlx ? 'oMLX' : 'llama.cpp';
  }
  return entry.name;
}

String engineSourceLabel(EngineRegistration entry) {
  if (entry.source == EngineSource.managed) return 'Ghost Model Deck';
  if (entry.path?.contains('/.lmstudio/extensions/backends/') ?? false) {
    final runtime = RegExp(r'-(\d+\.\d+\.\d+)(?:/|$)').firstMatch(entry.path!);
    return 'LM Studio${runtime == null ? '' : ' ${runtime[1]}'}';
  }
  return '本地关联';
}

String engineVersionLabel(String? version) {
  if (version == null) return '版本未知';
  final first = version.split('\n').first.replaceFirst('version: ', '');
  final commit = RegExp(r'commit ([a-f0-9]+)').firstMatch(first);
  return commit == null ? first : '${first.split(' (').first} · ${commit[1]}';
}
