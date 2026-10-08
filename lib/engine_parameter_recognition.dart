import 'engine_runtime.dart';

enum EngineHelpStatus { notRead, available, partial, unavailable }

class EngineParameterDescription {
  EngineParameterDescription({
    required List<String> names,
    this.valueHint = '',
    this.description = '',
  }) : names = List.unmodifiable(names);

  final List<String> names;
  final String valueHint;
  final String description;
}

/// Observations for one current executable version; never persisted as rules.
class EngineParameterRecognition {
  EngineParameterRecognition._({
    required this.family,
    required this.version,
    required this.executablePath,
    required this.contentFingerprint,
    required this.hasObservedHelp,
    required this.status,
    required Map<String, EngineParameterDescription> parameters,
    required Map<String, String> aliases,
    required List<String> notices,
  }) : parameters = Map.unmodifiable(parameters),
       _aliases = Map.unmodifiable(aliases),
       notices = List.unmodifiable(notices);

  final EngineFamily family;
  final String? version;
  final String? executablePath;
  final String? contentFingerprint;
  final bool hasObservedHelp;
  final EngineHelpStatus status;
  final Map<String, EngineParameterDescription> parameters;
  final Map<String, String> _aliases;
  final List<String> notices;

  static const _llamaAliases = {
    '-c': '--ctx-size',
    '-b': '--batch-size',
    '-ub': '--ubatch-size',
    '-np': '--parallel',
    '-ngl': '--n-gpu-layers',
    '--gpu-layers': '--n-gpu-layers',
    '-dev': '--device',
    '-m': '--model',
    '-a': '--alias',
  };
  static const _llamaDescriptions = {
    '--ctx-size': '上下文大小',
    '--batch-size': '批量大小',
    '--ubatch-size': '微批量大小',
    '--parallel': '并行数量',
    '--n-gpu-layers': 'GPU 层数',
    '--device': '设备',
    '--model': '软件管理的模型路径',
    '--alias': '软件管理的模型标识',
    '--host': '软件管理的监听地址',
    '--port': '软件管理的监听端口',
  };

  factory EngineParameterRecognition.builtIn({
    EngineFamily family = EngineFamily.llamaCpp,
    String? version,
    String? executablePath,
    String? contentFingerprint,
    String? notice,
  }) {
    final descriptions = family == EngineFamily.llamaCpp
        ? _llamaDescriptions
        : const {
            '--model-dir': '模型池目录',
            '--host': '监听地址',
            '--port': '监听端口',
            '--base-path': '私有数据目录',
            '--no-hf-cache': '关闭 HF 缓存发现',
            '--api-key': '软件管理的鉴权凭据',
            '--max-concurrent-requests': '最大并发请求数',
            '--memory-guard': '内存保护级别',
            '--hot-cache-max-size': '内存缓存上限',
          };
    final aliases = family == EngineFamily.llamaCpp
        ? _llamaAliases
        : const <String, String>{};
    final parameters = <String, EngineParameterDescription>{};
    for (final entry in descriptions.entries) {
      final description = EngineParameterDescription(
        names: [
          entry.key,
          ...aliases.keys.where((key) => aliases[key] == entry.key),
        ],
        description: entry.value,
      );
      for (final name in description.names) {
        parameters[name] = description;
      }
    }
    return EngineParameterRecognition._(
      family: family,
      version: version,
      executablePath: executablePath,
      contentFingerprint: contentFingerprint,
      hasObservedHelp: false,
      status: notice == null
          ? EngineHelpStatus.notRead
          : EngineHelpStatus.unavailable,
      parameters: parameters,
      aliases: aliases,
      notices: notice == null ? const [] : [notice],
    );
  }

  factory EngineParameterRecognition.fromHelp(
    String help, {
    required String version,
    String? executablePath,
    String? contentFingerprint,
    EngineFamily family = EngineFamily.llamaCpp,
    EngineParameterRecognition? previous,
  }) {
    final builtIn = EngineParameterRecognition.builtIn(
      family: family,
      version: version,
      executablePath: executablePath,
      contentFingerprint: contentFingerprint,
    );
    final retained =
        previous != null &&
            previous.hasObservedHelp &&
            contentFingerprint != null &&
            previous.family == family &&
            previous.executablePath == executablePath &&
            previous.contentFingerprint == contentFingerprint
        ? previous
        : null;
    final parameters = {...builtIn.parameters, ...?retained?.parameters};
    final aliases = {...?retained?._aliases, ...builtIn._aliases};
    final rows = <EngineParameterDescription>[];
    List<String>? names;
    var valueHint = '';
    final description = <String>[];
    var unsupported = false;
    void finish() {
      if (names != null) {
        rows.add(
          EngineParameterDescription(
            names: names!,
            valueHint: valueHint,
            description: description.join(' '),
          ),
        );
      }
      names = null;
      valueHint = '';
      description.clear();
    }

    for (final line in help.split('\n')) {
      final match = _optionRow.firstMatch(line);
      if (match != null) {
        finish();
        names = _name
            .allMatches(match.group(1)!)
            .map((item) => item.group(0)!)
            .toList();
        final tail = line.substring(match.end);
        if (tail.trim().isNotEmpty) {
          if (RegExp(r'^\s{2,}').hasMatch(tail)) {
            description.add(tail.trim());
          } else {
            final fields = tail.trim().split(RegExp(r'\s{2,}'));
            valueHint = fields.first;
            if (_name.hasMatch(valueHint)) {
              unsupported = true;
              names = null;
              valueHint = '';
              continue;
            }
            description.addAll(fields.skip(1));
          }
        }
      } else if (names != null && RegExp(r'^\s{4,}\S').hasMatch(line)) {
        description.add(line.trim());
      } else {
        if (line.trimLeft().startsWith('-') && !line.startsWith('-----')) {
          unsupported = true;
        }
        finish();
      }
    }
    finish();
    final observedNames = <String>{};
    for (final row in rows) {
      observedNames.addAll(row.names);
      for (final name in row.names) {
        parameters[name] = row;
      }
      // Help lists positive and negative switches together. They are not aliases.
      if (row.names.any(
        (name) => name.startsWith('--no-') || name.startsWith('-no-'),
      )) {
        continue;
      }
      final known = row.names
          .map((name) => aliases[name] ?? name)
          .where(
            (name) =>
                builtIn.parameters.containsKey(name) ||
                (retained?.parameters.containsKey(name) ?? false),
          )
          .toSet();
      if (known.length > 1) {
        unsupported = true;
        continue;
      }
      final canonical =
          known.singleOrNull ??
          row.names.firstWhere(
            (name) => name.startsWith('--'),
            orElse: () => row.names.first,
          );
      for (final name in row.names) {
        if (!builtIn.parameters.containsKey(name)) aliases[name] = canonical;
      }
    }
    final missing =
        (family == EngineFamily.llamaCpp
                ? _llamaDescriptions.keys
                : builtIn.parameters.keys)
            .where((name) => !observedNames.contains(name))
            .toList();
    final notices = <String>[];
    final status = rows.isEmpty
        ? EngineHelpStatus.unavailable
        : unsupported || missing.isNotEmpty
        ? EngineHelpStatus.partial
        : EngineHelpStatus.available;
    if (rows.isEmpty) {
      notices.add('当前版本帮助信息无法解析，继续使用已有识别规则。');
    } else if (status == EngineHelpStatus.partial) {
      notices.add('当前版本帮助信息只能部分识别，未识别内容保留并交由引擎判断。');
    }
    if (missing.isNotEmpty) {
      notices.add('当前帮助未列出 ${missing.join('、')}；保留内置规则与原配置，请核对版本差异。');
    }
    if (retained != null && status != EngineHelpStatus.available) {
      notices.add('沿用同一引擎内容上次读取的可用帮助规则，不自动改写配置。');
    }
    return EngineParameterRecognition._(
      family: family,
      version: version,
      executablePath: executablePath,
      contentFingerprint: contentFingerprint,
      hasObservedHelp: rows.isNotEmpty || retained != null,
      status: status,
      parameters: parameters,
      aliases: aliases,
      notices: notices,
    );
  }

  static final _optionRow = RegExp(
    r'^\s{0,2}(-{1,2}[A-Za-z][A-Za-z0-9_-]*(?:,\s*-{1,2}[A-Za-z][A-Za-z0-9_-]*)*)',
  );
  static final _name = RegExp(r'-{1,2}[A-Za-z][A-Za-z0-9_-]*');

  String canonicalName(String name) => _aliases[name] ?? name;
  bool recognizes(String name) => parameters.containsKey(name);
  EngineParameterDescription? descriptionFor(String name) => parameters[name];

  EngineParameterRecognition withReadFailure({
    required String version,
    required String notice,
  }) => EngineParameterRecognition._(
    family: family,
    version: version,
    executablePath: executablePath,
    contentFingerprint: contentFingerprint,
    hasObservedHelp: hasObservedHelp,
    status: EngineHelpStatus.unavailable,
    parameters: parameters,
    aliases: _aliases,
    notices: [
      ...{...notices, notice},
    ],
  );
}
