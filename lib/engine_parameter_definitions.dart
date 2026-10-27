import 'dart:convert';

import 'engine_parameter_recognition.dart';
import 'engine_runtime.dart';
import 'launch_argument_text.dart';

enum ParameterKind {
  integer,
  decimal,
  choice,
  flag,
  toggle,
  text,
  secret,
  file,
  directory,
  list,
  tuple,
  quantity,
  duration,
}

class EngineParameterDefinition {
  const EngineParameterDefinition(
    this.name,
    this.label,
    this.group,
    this.kind, {
    this.choices = const [],
    this.valueHints = const [],
    this.initial = '',
    this.help = '',
    this.negativeFlag,
    this.managed = false,
    this.advanced = false,
  });
  final String name;
  final String label;
  final String group;
  final ParameterKind kind;
  final List<String> choices;
  final List<String> valueHints;
  final String initial;
  final String help;
  final String? negativeFlag;
  final bool managed;
  final bool advanced;

  List<String> arguments(String value) {
    if (managed || value.isEmpty) return const [];
    if (kind == ParameterKind.flag) {
      if (value != 'true' && value != 'false') {
        throw FormatException('$label 需要是开启或关闭');
      }
      return value == 'true'
          ? [name]
          : negativeFlag == null
          ? const []
          : [negativeFlag!];
    }
    if (kind == ParameterKind.tuple) {
      final entries = tupleValues(value);
      if (entries.length != valueHints.length) {
        throw FormatException('$label 需要 ${valueHints.length} 个值');
      }
      return [name, ...entries];
    }
    if (kind == ParameterKind.list) {
      final entries = jsonDecode(value);
      if (entries is! List || entries.any((v) => v is! String)) {
        throw FormatException('$label 需要是字符串列表');
      }
      return [
        for (final entry in entries) ...[name, entry as String],
      ];
    }
    return [name, value];
  }

  List<String> tupleValues(String value) {
    if (value.startsWith('[')) {
      final entries = jsonDecode(value);
      if (entries is! List || entries.any((entry) => entry is! String)) {
        throw FormatException('$label 需要是字符串值');
      }
      return entries.cast<String>();
    }
    return parseLaunchArgumentText(value).map((token) => token.value).toList();
  }
}

/// Labels and types for managed desktop engines. Extra observed help is included
/// as parameter items, so a known option never requires typing its CLI spelling.
class EngineParameterDefinitions {
  static const groupLabels = {
    'resources': '上下文与内存',
    'compute': '计算与设备',
    'cache': '缓存与磁盘',
    'draft': '草稿模型',
    'lookup': '推测与采样优化',
    'limits': '服务请求限制',
    'thinking': '服务思考默认值',
    'network': '访问与 Web',
    'encoder': '决策编码器',
    'samplingDefaults': '服务启动采样默认值',
    'extra': '其他引擎参数',
    'managed': '软件管理字段',
  };

  static const splash = <EngineParameterDefinition>[
    EngineParameterDefinition(
      '--max-context',
      '最大上下文',
      'resources',
      ParameterKind.quantity,
      initial: 'auto',
      help: 'auto 或正整数，可选 K；实际容量由引擎核对。',
    ),
    EngineParameterDefinition(
      '--max-memory',
      '最大内存',
      'resources',
      ParameterKind.quantity,
      initial: 'auto',
      help: '自动或容量；只能降低原生自动预算。',
    ),
    EngineParameterDefinition(
      '--expert-memory',
      'MoE 专家缓存预算',
      'resources',
      ParameterKind.quantity,
      initial: 'auto',
      help: 'auto、off（加载全部专家）或指定容量；开启自动调节时须为 auto 或继承默认。',
    ),
    EngineParameterDefinition(
      '--moe-memory-pressure',
      'MoE 内存自动调节',
      'resources',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'off',
      help: '按系统内存压力调整本实例的 MoE 缓存；须使用自动专家预算。默认关闭，下次启动生效。需要支持此参数的 Splash 版本。',
    ),
    EngineParameterDefinition(
      '--host-memory-reserve',
      'MoE 系统内存预留',
      'resources',
      ParameterKind.quantity,
      initial: 'auto',
      help: 'auto 或指定容量；指定容量时须开启 MoE 内存自动调节。',
    ),
    EngineParameterDefinition(
      '--kv-format',
      'KV 缓存格式',
      'resources',
      ParameterKind.choice,
      choices: ['int8', 'bf16', 'q4h', 'q4_0', 'q4_0_unrotated'],
      initial: 'int8',
    ),
    EngineParameterDefinition(
      '--state-format',
      '循环状态格式',
      'resources',
      ParameterKind.choice,
      choices: ['fp32', 'bf16'],
      initial: 'fp32',
    ),
    EngineParameterDefinition(
      '--idle-release',
      '空闲释放时长',
      'resources',
      ParameterKind.duration,
      initial: '10m',
      help: 'off 或正时长；支持 s、m、h。',
    ),
    EngineParameterDefinition(
      '--max-cache-disk',
      '磁盘缓存容量',
      'cache',
      ParameterKind.quantity,
      initial: 'auto',
      help: 'auto、0（关闭）或容量。',
    ),
    EngineParameterDefinition(
      '--max-cache-disk-writes',
      '每日缓存写入预算',
      'cache',
      ParameterKind.quantity,
      initial: '0',
      help: '0 表示不限；其余为每日容量。',
    ),
    EngineParameterDefinition(
      '--persistent-cache',
      '持久缓存',
      'cache',
      ParameterKind.flag,
      initial: 'false',
    ),
    EngineParameterDefinition(
      '--cache-dir',
      '持久缓存目录',
      'managed',
      ParameterKind.directory,
      managed: true,
      help: '启用持久缓存后由 GMD 分配实例缓存目录。',
    ),
    EngineParameterDefinition(
      '--queue-size',
      '请求队列大小',
      'limits',
      ParameterKind.integer,
      initial: '32',
    ),
    EngineParameterDefinition(
      '--max-request-size',
      '请求体上限',
      'limits',
      ParameterKind.quantity,
      initial: '128M',
    ),
    EngineParameterDefinition(
      '--max-image-pixels',
      '单图最大像素',
      'limits',
      ParameterKind.integer,
      initial: '4194304',
      help: '65536–4194304。',
    ),
    EngineParameterDefinition(
      '--request-timeout',
      '服务请求时限',
      'limits',
      ParameterKind.duration,
      help: '留空使用原生默认预算。',
    ),
    EngineParameterDefinition(
      '--decode-share',
      '解码调度份额',
      'limits',
      ParameterKind.decimal,
      initial: '0.5',
    ),
    EngineParameterDefinition(
      '--disable-ane',
      '使用 Neural Engine',
      'compute',
      ParameterKind.flag,
      initial: 'false',
    ),
    EngineParameterDefinition(
      '--ane-ffn-share',
      'ANE FFN 分担比例',
      'compute',
      ParameterKind.text,
      initial: 'auto',
      choices: ['auto', '0', '0.25', '0.5', '0.75', '1'],
      help: 'auto、0（关闭）或 0–1。',
    ),
    EngineParameterDefinition(
      '--ane-ffn-minimum-rows',
      'ANE 最小提交行数',
      'compute',
      ParameterKind.integer,
      help: '实际最大值取决于当前原生编译；同时设置 FFN 分担比例。',
    ),
    EngineParameterDefinition(
      '--experimental-quantized-ffn',
      '实验性量化 FFN（不保留全量 FP16 缓存）',
      'compute',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'off',
      help: '默认关闭，重启后生效。仅普通生成的 Qwen3.5-4B 支持，可使用 Standard DFlash 或不使用草稿。27B、MoE、Kev、D3、ModernBERT 不支持，具体兼容性由 Splash 报错。',
    ),
    EngineParameterDefinition(
      '--ane-power-recovery',
      'ANE 功耗恢复',
      'compute',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'off',
      advanced: true,
    ),
    EngineParameterDefinition(
      '--ane-power-reference',
      '功耗参考',
      'compute',
      ParameterKind.text,
      choices: ['off', 'auto'],
      initial: 'off',
      advanced: true,
      help: 'off、auto 或正瓦数。',
    ),
    EngineParameterDefinition(
      '--ane-recovery-idle-watts',
      '空闲恢复功耗（W）',
      'compute',
      ParameterKind.decimal,
      initial: '0.05',
      advanced: true,
    ),
    EngineParameterDefinition(
      '--ane-recovery-max-power-percent',
      '恢复功耗百分比',
      'compute',
      ParameterKind.decimal,
      advanced: true,
      help: '0–100；设置后使用有效功耗参考并覆盖绝对阈值。',
    ),
    EngineParameterDefinition(
      '--allow-idle-sleep',
      '允许空闲睡眠',
      'compute',
      ParameterKind.flag,
      initial: 'false',
      advanced: true,
    ),
    EngineParameterDefinition(
      '--prompt-lookup',
      '提示查找',
      'lookup',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'off',
      help: '重启后生效；实际使用需要原生草稿验证路径，配置开启不代表匹配命中。',
    ),
    EngineParameterDefinition(
      '--prompt-lookup-min-match',
      '最小提示匹配长度',
      'lookup',
      ParameterKind.choice,
      choices: ['2', '3', '4'],
      initial: '2',
      help: '只在提示查找启用时使用；关闭后保留所选匹配长度。',
    ),
    EngineParameterDefinition(
      '--fast-topk',
      'Fast Top K',
      'lookup',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'off',
      help: '重启后生效；仅采样 lane、Top K 1～32 且 Min P 0 可使用，实际命中以原生计数为准。',
    ),
    EngineParameterDefinition(
      '--compact-draft-head',
      'compact draft head',
      'draft',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'off',
      advanced: true,
      help: '默认关闭；继承不写入覆盖值。仅在草稿开启时应用，原生验证通过后仍按请求条件使用。',
    ),
    EngineParameterDefinition(
      '--compact-draft-ranking',
      'ranking 文件',
      'draft',
      ParameterKind.file,
      advanced: true,
      help: '开启 compact 时选择 SPLCHD02 文件。检查精确大小、词表与完整排列；关闭后保留路径但不读取。',
    ),
    EngineParameterDefinition(
      '--compact-draft-capacity',
      'compact 词表容量',
      'draft',
      ParameterKind.integer,
      initial: '98304',
      advanced: true,
      help: '512～98,304，且为 256 的倍数；留空继承。实际容量以对应运行实例的原生状态为准。',
    ),
    EngineParameterDefinition(
      '--allowed-host',
      '附加允许主机',
      'network',
      ParameterKind.list,
    ),
    EngineParameterDefinition(
      '--allowed-origin',
      '允许来源',
      'network',
      ParameterKind.list,
    ),
    EngineParameterDefinition(
      '--api-key',
      '引擎 API 密钥',
      'network',
      ParameterKind.secret,
    ),
    EngineParameterDefinition(
      '--no-webui',
      '内置 Web UI',
      'network',
      ParameterKind.flag,
      initial: 'false',
    ),
    EngineParameterDefinition(
      '--default-reasoning-effort',
      '服务默认思考强度',
      'thinking',
      ParameterKind.choice,
      choices: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
      help: '下次启动生效；留空使用当前引擎默认来源，实例请求可单独覆盖。',
    ),
    EngineParameterDefinition(
      '--thinking-token-budget',
      '服务默认思考预算',
      'thinking',
      ParameterKind.integer,
      help: '下次启动生效；只接受非负整数，留空使用原生默认来源。请求字段另支持 -1 明确不限。',
    ),
    EngineParameterDefinition(
      '--thinking-end-text',
      '思考结束文字',
      'thinking',
      ParameterKind.text,
      help: '原生要求分词后为 1–64 token。',
    ),
    EngineParameterDefinition(
      '--encoder-submit-batch-size',
      '编码器提交批次',
      'encoder',
      ParameterKind.choice,
      choices: ['1', '2', '4'],
      initial: '4',
    ),
    EngineParameterDefinition(
      '--encoder-option-queries',
      '编码器选项查询',
      'encoder',
      ParameterKind.toggle,
      choices: ['on', 'off'],
      initial: 'on',
      help: '按当前决策编码器的实际能力应用。',
    ),
    EngineParameterDefinition(
      '--host',
      '私有监听地址',
      'managed',
      ParameterKind.text,
      managed: true,
    ),
    EngineParameterDefinition(
      '--port',
      '私有监听端口',
      'managed',
      ParameterKind.integer,
      managed: true,
    ),
    EngineParameterDefinition(
      '--served-model-name',
      '服务模型标识',
      'managed',
      ParameterKind.text,
      managed: true,
    ),
    EngineParameterDefinition(
      '--announce-served-name',
      '响应模型身份',
      'managed',
      ParameterKind.flag,
      managed: true,
    ),
    EngineParameterDefinition(
      '--model',
      '目标模型身份',
      'managed',
      ParameterKind.text,
      managed: true,
    ),
    EngineParameterDefinition(
      '--tokenizer',
      '分词器目录',
      'managed',
      ParameterKind.directory,
      managed: true,
    ),
    EngineParameterDefinition(
      '--binary',
      '原生程序',
      'managed',
      ParameterKind.file,
      managed: true,
    ),
  ];

  static const llama = <EngineParameterDefinition>[
    EngineParameterDefinition(
      '--reasoning',
      '服务模板思考模式',
      'thinking',
      ParameterKind.choice,
      choices: ['on', 'off', 'auto'],
      help: '下次启动生效；auto 按模板判断，请求模板开关可覆盖。',
    ),
    EngineParameterDefinition(
      '--reasoning-effort',
      '服务默认思考强度',
      'thinking',
      ParameterKind.choice,
      choices: [
        'default',
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ],
      help: '下次启动生效；default 保留模板默认。实际支持取决于模板。',
    ),
    EngineParameterDefinition(
      '--reasoning-budget',
      '服务默认思考预算',
      'thinking',
      ParameterKind.integer,
      help: '下次启动生效；-1 不限，0 立即结束思考，正整数限制 token。请求预算 -1 继承本服务预算。',
    ),
    EngineParameterDefinition(
      '--reasoning-preserve',
      '服务保留历史思考',
      'thinking',
      ParameterKind.flag,
      negativeFlag: '--no-reasoning-preserve',
      help: '下次启动生效；需要模板支持 preserve_reasoning 能力。',
    ),
    EngineParameterDefinition(
      '--ctx-size',
      '上下文大小',
      'resources',
      ParameterKind.integer,
      initial: '4096',
    ),
    EngineParameterDefinition(
      '--batch-size',
      '批量大小',
      'resources',
      ParameterKind.integer,
      initial: '4096',
    ),
    EngineParameterDefinition(
      '--ubatch-size',
      '微批量大小',
      'resources',
      ParameterKind.integer,
      initial: '4096',
    ),
    EngineParameterDefinition(
      '--parallel',
      '推理并发槽位',
      'resources',
      ParameterKind.integer,
      initial: '1',
    ),
    EngineParameterDefinition(
      '--n-gpu-layers',
      'GPU 层数',
      'resources',
      ParameterKind.text,
      choices: ['auto', 'all', '0'],
      initial: 'auto',
      help: '自动、全部或指定整数层数。',
    ),
    EngineParameterDefinition(
      '--device',
      '计算设备',
      'compute',
      ParameterKind.choice,
      choices: ['MTL0', 'none'],
      help: 'Metal MTL0 或 CPU；其他实际设备可从当前帮助中识别。',
    ),
    EngineParameterDefinition(
      '--threads',
      'CPU 生成线程',
      'compute',
      ParameterKind.integer,
    ),
    EngineParameterDefinition(
      '--threads-batch',
      'CPU 批处理线程',
      'compute',
      ParameterKind.integer,
    ),
    EngineParameterDefinition(
      '--flash-attn',
      'Flash Attention',
      'compute',
      ParameterKind.choice,
      choices: ['auto', 'on', 'off'],
    ),
    EngineParameterDefinition(
      '--cache-type-k',
      'K 缓存类型',
      'cache',
      ParameterKind.choice,
      choices: [
        'f32',
        'f16',
        'bf16',
        'q8_0',
        'q4_0',
        'q4_1',
        'iq4_nl',
        'q5_0',
        'q5_1',
      ],
    ),
    EngineParameterDefinition(
      '--cache-type-v',
      'V 缓存类型',
      'cache',
      ParameterKind.choice,
      choices: [
        'f32',
        'f16',
        'bf16',
        'q8_0',
        'q4_0',
        'q4_1',
        'iq4_nl',
        'q5_0',
        'q5_1',
      ],
    ),
    EngineParameterDefinition(
      '--mmap',
      '内存映射',
      'resources',
      ParameterKind.flag,
      negativeFlag: '--no-mmap',
    ),
    EngineParameterDefinition(
      '--mlock',
      '锁定权重内存',
      'resources',
      ParameterKind.flag,
    ),
    EngineParameterDefinition(
      '--context-shift',
      '原生上下文移位',
      'resources',
      ParameterKind.flag,
      negativeFlag: '--no-context-shift',
      help: '原生 token 移位；不等同于按完整消息裁剪。',
    ),
    EngineParameterDefinition(
      '--temp',
      '服务启动默认温度',
      'samplingDefaults',
      ParameterKind.decimal,
    ),
    EngineParameterDefinition(
      '--top-k',
      '服务启动默认 Top K',
      'samplingDefaults',
      ParameterKind.integer,
    ),
    EngineParameterDefinition(
      '--top-p',
      '服务启动默认 Top P',
      'samplingDefaults',
      ParameterKind.decimal,
    ),
    EngineParameterDefinition(
      '--min-p',
      '服务启动默认 Min P',
      'samplingDefaults',
      ParameterKind.decimal,
    ),
    EngineParameterDefinition(
      '--repeat-penalty',
      '服务启动默认重复惩罚',
      'samplingDefaults',
      ParameterKind.decimal,
    ),
    EngineParameterDefinition(
      '--presence-penalty',
      '服务启动默认存在惩罚',
      'samplingDefaults',
      ParameterKind.decimal,
    ),
    EngineParameterDefinition(
      '--frequency-penalty',
      '服务启动默认频率惩罚',
      'samplingDefaults',
      ParameterKind.decimal,
    ),
    EngineParameterDefinition(
      '--seed',
      '服务启动默认种子',
      'samplingDefaults',
      ParameterKind.integer,
    ),
    EngineParameterDefinition(
      '--predict',
      '服务启动默认生成上限',
      'samplingDefaults',
      ParameterKind.integer,
    ),
    EngineParameterDefinition(
      '--spec-draft-n-max',
      '最大草稿 token',
      'draft',
      ParameterKind.integer,
      initial: '3',
    ),
    EngineParameterDefinition(
      '--spec-draft-n-min',
      '最小草稿 token',
      'draft',
      ParameterKind.integer,
      initial: '0',
    ),
    EngineParameterDefinition(
      '--spec-draft-p-min',
      '草稿概率阈值',
      'draft',
      ParameterKind.decimal,
      initial: '0',
    ),
    EngineParameterDefinition(
      '--spec-draft-ngl',
      '草稿 GPU 层数',
      'draft',
      ParameterKind.text,
      choices: ['auto', 'all', '0'],
      initial: 'auto',
    ),
    EngineParameterDefinition(
      '--spec-draft-device',
      '草稿计算设备',
      'draft',
      ParameterKind.choice,
      choices: ['MTL0', 'none'],
      advanced: true,
      help: '未设置时跟随目标模型。',
    ),
    EngineParameterDefinition(
      '--spec-draft-threads',
      '草稿生成线程',
      'draft',
      ParameterKind.integer,
      advanced: true,
    ),
    EngineParameterDefinition(
      '--spec-draft-threads-batch',
      '草稿批处理线程',
      'draft',
      ParameterKind.integer,
      advanced: true,
    ),
    EngineParameterDefinition(
      '--spec-draft-type-k',
      '草稿 K 缓存类型',
      'draft',
      ParameterKind.choice,
      choices: [
        'f32',
        'f16',
        'bf16',
        'q8_0',
        'q4_0',
        'q4_1',
        'iq4_nl',
        'q5_0',
        'q5_1',
      ],
      advanced: true,
    ),
    EngineParameterDefinition(
      '--spec-draft-type-v',
      '草稿 V 缓存类型',
      'draft',
      ParameterKind.choice,
      choices: [
        'f32',
        'f16',
        'bf16',
        'q8_0',
        'q4_0',
        'q4_1',
        'iq4_nl',
        'q5_0',
        'q5_1',
      ],
      advanced: true,
    ),
    EngineParameterDefinition(
      '--spec-draft-sampling',
      '草稿采样方式',
      'draft',
      ParameterKind.choice,
      choices: ['greedy', 'probabilistic'],
      advanced: true,
      help: '由当前版本帮助核对支持情况。',
    ),
    EngineParameterDefinition(
      '--spec-draft-backend-sampling',
      '草稿后端采样',
      'draft',
      ParameterKind.flag,
      negativeFlag: '--no-spec-draft-backend-sampling',
      advanced: true,
    ),
    EngineParameterDefinition(
      '--model',
      '目标模型文件',
      'managed',
      ParameterKind.file,
      managed: true,
    ),
    EngineParameterDefinition(
      '--spec-draft-model',
      '草稿模型文件',
      'managed',
      ParameterKind.file,
      managed: true,
    ),
    EngineParameterDefinition(
      '--spec-type',
      'ngram 推测模式',
      'lookup',
      ParameterKind.choice,
      choices: [
        'none',
        'ngram-simple',
        'ngram-map-k',
        'ngram-map-k4v',
        'ngram-mod',
        'ngram-cache',
      ],
      initial: 'none',
      help: '草稿开启时本次不激活 ngram，保存的选择保留。',
    ),
    EngineParameterDefinition(
      '--spec-default',
      'ngram 快捷模式',
      'managed',
      ParameterKind.flag,
      managed: true,
      help: '通过 ngram 模式选择配置。',
    ),
    EngineParameterDefinition(
      '--alias',
      '模型标识',
      'managed',
      ParameterKind.text,
      managed: true,
    ),
    EngineParameterDefinition(
      '--host',
      '私有监听地址',
      'managed',
      ParameterKind.text,
      managed: true,
    ),
    EngineParameterDefinition(
      '--port',
      '私有监听端口',
      'managed',
      ParameterKind.integer,
      managed: true,
    ),
  ];

  static const omlx = <EngineParameterDefinition>[
    EngineParameterDefinition(
      '--max-concurrent-requests',
      '最大并发请求数',
      'resources',
      ParameterKind.integer,
    ),
    EngineParameterDefinition(
      '--memory-guard',
      '内存保护级别',
      'resources',
      ParameterKind.choice,
      choices: ['off', 'safe', 'balanced', 'aggressive'],
    ),
    EngineParameterDefinition(
      '--hot-cache-max-size',
      '内存缓存上限',
      'cache',
      ParameterKind.quantity,
    ),
  ];

  static List<EngineParameterDefinition> known(EngineFamily family) =>
      switch (family) {
        EngineFamily.llamaCpp => llama,
        EngineFamily.splash => splash,
        EngineFamily.omlx => omlx,
      };

  static List<EngineParameterDefinition> forEngine(
    EngineFamily family, {
    EngineParameterRecognition? recognition,
  }) {
    final result = {for (final field in known(family)) field.name: field};
    if (recognition != null) {
      for (final entry in recognition.parameters.entries) {
        final name = recognition.canonicalName(entry.key);
        if (!name.startsWith('--') ||
            result.containsKey(name) ||
            _actions.contains(name) ||
            _modelSources.contains(name) ||
            entry.value.description.contains('argument has been removed') ||
            name == '--spec-draft-p-split') {
          continue;
        }
        final observed = entry.value;
        final hint = observed.valueHint;
        if (hint.isEmpty &&
            name.startsWith('--no-') &&
            observed.names.contains('--${name.substring(5)}')) {
          continue;
        }
        final choiceMatch = RegExp(
          r'^\{([^}]+)\}$|^\[([^\]]+\|[^\]]+)\]$|^<([^>]+\|[^>]+)>$',
        ).firstMatch(hint);
        final choiceText =
            choiceMatch?.group(1) ??
            choiceMatch?.group(2) ??
            choiceMatch?.group(3);
        final choices =
            choiceText
                ?.split(RegExp(r'[,|]'))
                .map((value) => value.trim())
                .toList() ??
            <String>[];
        if (choices.isEmpty && ['MODE', 'TYPE'].contains(hint)) {
          choices.addAll(
            RegExp(r'(?:^|\s)- ([a-z0-9_+.-]+):')
                .allMatches(observed.description)
                .map((match) => match[1]!)
                .toSet(),
          );
        }
        final negative = observed.names
            .where((s) => s.startsWith('--no-'))
            .firstOrNull;
        final valueHints =
            RegExp(r'^[A-Z][A-Z0-9_]*(?: [A-Z][A-Z0-9_]*)+$').hasMatch(hint)
            ? hint.split(' ')
            : <String>[];
        final kind = valueHints.isNotEmpty
            ? ParameterKind.tuple
            : name == '--api-key'
            ? ParameterKind.secret
            : choices.isNotEmpty
            ? ParameterKind.choice
            : hint.isEmpty
            ? ParameterKind.flag
            : RegExp(r'^(INT|COUNT|TOKENS)$').hasMatch(hint)
            ? ParameterKind.integer
            : RegExp(r'^(N|P|FLOAT|SCALE)$').hasMatch(hint)
            ? ParameterKind.decimal
            : hint.contains('FNAME') || hint == 'FILE'
            ? ParameterKind.file
            : ParameterKind.text;
        result[name] = EngineParameterDefinition(
          name,
          observed.description.split(RegExp(r'[\n(]')).first.trim().isEmpty
              ? name
              : observed.description.split(RegExp(r'[\n(]')).first.trim(),
          name.startsWith('--spec-draft-') ? 'draft' : 'extra',
          kind,
          choices: choices,
          valueHints: valueHints,
          negativeFlag: negative == name ? null : negative,
          help: hint == 'N'
              ? '${observed.description} 数值类型由当前引擎校验；帮助未注明整数限制。'
              : observed.description,
        );
      }
    }
    return result.values.toList();
  }

  static EngineParameterDefinition definition(
    String name,
    EngineFamily family, {
    EngineParameterRecognition? recognition,
  }) =>
      forEngine(
        family,
        recognition: recognition,
      ).where((d) => d.name == name).firstOrNull ??
      EngineParameterDefinition(name, name, 'extra', ParameterKind.text);

  static const _actions = {
    '--help',
    '--version',
    '--list-devices',
    '--completion-bash',
    '--completion-zsh',
    '--print-completion-bash',
  };
  static const _modelSources = {
    '--hf-repo',
    '--hf-file',
    '--hf-token',
    '--model-url',
    '--docker-repo',
    '--spec-draft-hf',
    '--fim-qwen-1.5b-default',
    '--fim-qwen-3b-default',
    '--fim-qwen-7b-default',
    '--fim-qwen-7b-spec',
    '--fim-qwen-14b-spec',
    '--fim-qwen-30b-default',
  };
}
