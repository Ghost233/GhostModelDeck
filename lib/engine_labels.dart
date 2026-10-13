import 'engine_catalog.dart';
import 'engine_runtime.dart';

String engineDisplayName(EngineRegistration entry) {
  final family = switch (entry.family) {
    EngineFamily.llamaCpp => 'llama.cpp',
    EngineFamily.omlx => 'oMLX',
    EngineFamily.splash => 'Splash',
  };
  final release = entry.release?.artifactTag ?? entry.release?.tag;
  return '$family${release == null
      ? ''
      : entry.id == EngineCatalog.officialId
      ? ' · JEV $release'
      : ' · $release'}';
}

String engineSourceLabel(EngineRegistration entry) {
  final source = entry.sourceBuild?['source'] as String?;
  if (source != null) return repositoryDisplayLabel(source);
  if (entry.source == EngineSource.linked) return entry.path ?? '来源未知';
  if (entry.release != null) {
    return repositoryDisplayLabel(entry.release!.url.toString());
  }
  return entry.family == EngineFamily.omlx ? 'jundot/omlx' : 'incoai/splash';
}

String repositoryDisplayLabel(String source) {
  if (source.startsWith('/')) return source;
  final ssh = RegExp(r'^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$')
      .firstMatch(source);
  if (ssh != null) return ssh[1]!;
  final uri = Uri.tryParse(source);
  if (uri?.host == 'github.com' && uri!.pathSegments.length >= 2) {
    return '${uri.pathSegments[0]}/${uri.pathSegments[1].replaceFirst(RegExp(r'\.git$'), '')}';
  }
  return source;
}

String engineVersionLabel(String? version) {
  if (version == null) return '版本未知';
  final lines = version.split('\n');
  final first = lines
      .firstWhere(
        (line) => line.trimLeft().startsWith('version:'),
        orElse: () => lines.first,
      )
      .replaceFirst(RegExp(r'^\s*version:\s*'), '');
  final commit = RegExp(r'commit ([a-f0-9]+)').firstMatch(first);
  return commit == null ? first : '${first.split(' (').first} · ${commit[1]}';
}
