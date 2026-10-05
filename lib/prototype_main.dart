// Disposable Flutter prototype: three desktop layouts in one native window.
// All model, engine, download and MCP actions below are in-memory examples.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'GhostModelDeck Prototype',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff006d63)),
      scaffoldBackgroundColor: const Color(0xfff5f7fa),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    ),
    home: const JevPrototype(),
  ),
);

class DemoModel {
  DemoModel(
    this.name,
    this.description,
    this.size, {
    this.installed = false,
    this.hasHead = true,
    this.decision = true,
    this.selected = false,
    this.engine = 'LM Studio',
  });
  final String name, description, size;
  bool installed, hasHead, decision, selected, running = false;
  String engine;
  double progress = 0;
  bool get complete => installed && hasHead && decision;
  String get status => running
      ? '示例就绪'
      : progress > 0 && progress < 1
      ? '模拟下载中'
      : !installed
      ? '待下载'
      : !decision
      ? '普通聊天模型'
      : !hasHead
      ? '缺少决策头'
      : '文件齐全 · 引擎未就绪';
}

class JevPrototype extends StatefulWidget {
  const JevPrototype({super.key});
  @override
  State<JevPrototype> createState() => _JevPrototypeState();
}

class _JevPrototypeState extends State<JevPrototype> {
  final semantics = WidgetsBinding.instance.ensureSemantics();
  int variant = 0, page = 0;
  String source = 'Hugging Face 直连', scenario = '全部成功';
  bool mcp = false, consulting = false;
  bool lmLinked = false, llamaInstalled = false, specialInstalled = false;
  Map<String, dynamic>? result;
  VoidCallback? refreshDialog;
  void Function(int)? navigateDialog;
  final path = TextEditingController(text: '~/.lmstudio/models');
  final stateText = TextEditingController(
    text: '规则：重复扣款由账单团队处理，配送查询由物流团队处理，退换由售后处理。\n用户请求：同一订单被扣款两次，请处理重复扣款。',
  );
  final models = [
    DemoModel('Kev-0.8B', '候选目录 · Qwen 系决策模型', '812 MB', selected: true),
    DemoModel(
      'Laya Multilingual',
      '本地发现示例 · 缺文件情境',
      '678 MB',
      installed: true,
      hasHead: false,
      selected: true,
      engine: '专用引擎',
    ),
    DemoModel('JevK5-4B', '候选目录 · 需要兼容适配', '4.48 GB', engine: '专用引擎'),
    DemoModel(
      '通用 Qwen 聊天模型',
      '本地发现示例 · 非决策资产',
      '示例文件',
      installed: true,
      decision: false,
    ),
  ];
  static const pages = ['模型库', '下载目录', '引擎管理', '委员会', 'MCP 接入'];
  static const icons = [
    Icons.inventory_2_outlined,
    Icons.download_outlined,
    Icons.memory_outlined,
    Icons.groups_outlined,
    Icons.hub_outlined,
  ];
  static const variants = ['A · 侧栏管理台', 'B · 流程工作台', 'C · 委员会优先'];
  List<DemoModel> get seats => models.where((m) => m.selected).toList();
  int get readyCount => seats.where((m) => m.running).length;

  @override
  void dispose() {
    semantics.dispose();
    path.dispose();
    stateText.dispose();
    super.dispose();
  }

  void update(VoidCallback change) {
    setState(change);
    refreshDialog?.call();
  }

  void navigate(int index) {
    update(() => page = index);
    navigateDialog?.call(index);
  }

  void notice(String text) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
  );

  Future<void> download(DemoModel model) async {
    if (model.progress > 0 && model.progress < 1) return;
    for (final step in [0.2, 0.55, 0.85, 1.0]) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      update(() {
        model.progress = step;
        if (step == 1) {
          model.installed = true;
          model.hasHead = true;
        }
      });
    }
    notice('示例文件已齐全；还需选择兼容引擎并启动。未下载真实权重。');
  }

  void start(DemoModel model) {
    if (!model.complete) {
      notice('此示例资产不完整或不是决策模型。');
      return;
    }
    if (model.engine == 'LM Studio') {
      if (!lmLinked) {
        notice('先模拟关联 LM Studio，再检查此模型的能力。');
        return;
      }
      notice('模拟诊断：此组合尚无可用决策接口，请选择兼容的补充引擎。');
      return;
    }
    if (model.engine == 'llama.cpp' && !llamaInstalled ||
        model.engine == '专用引擎' && !specialInstalled) {
      notice('先安装所选示例引擎，再启动模型。');
      return;
    }
    update(() => model.running = true);
    notice('${model.name} 示例就绪；没有启动真实引擎。');
  }

  Future<void> remove(DemoModel model) async {
    if (model.running) {
      notice('先停止使用该模型，再删除。');
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型 · 原型操作'),
        content: Text(
          '${model.name}\n所选文件：${model.size}\n\n只移除内存中的示例，不删除本机任何文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除示例'),
          ),
        ],
      ),
    );
    if (yes == true) {
      update(() {
        model.installed = false;
        model.progress = 0;
      });
    }
  }

  Future<void> consult() async {
    update(() {
      consulting = true;
      result = null;
    });
    final selected = List<DemoModel>.of(seats);
    final responses = await Future.wait(
      selected.asMap().entries.map((entry) async {
        final i = entry.key;
        final model = entry.value;
        if (!model.running) {
          return <String, dynamic>{'seat': model.name, 'status': 'unavailable'};
        }
        await Future<void>.delayed(Duration(milliseconds: 900 + i * 450));
        if (scenario == '全部失败' || (scenario == '一席超时' && i == 1)) {
          return <String, dynamic>{'seat': model.name, 'status': 'timeout'};
        }
        final p = i.isEven ? [0.7, 0.2, 0.1] : [0.2, 0.6, 0.2];
        return <String, dynamic>{
          'seat': model.name,
          'status': 'ok',
          'engine': model.engine,
          'choice': i.isEven ? 'billing' : 'shipping',
          'probabilities': {'billing': p[0], 'shipping': p[1], 'returns': p[2]},
        };
      }),
    );
    if (!mounted) return;
    final good = responses.where((r) => r['status'] == 'ok').toList();
    final scores = <String, double>{};
    final votes = {'billing': 0, 'shipping': 0, 'returns': 0};
    for (final r in good) {
      votes[r['choice'] as String] = votes[r['choice']]! + 1;
    }
    if (good.length >= 2) {
      for (final id in votes.keys) {
        scores[id] =
            good
                .map((r) => (r['probabilities'][id] as num).toDouble())
                .reduce((a, b) => a + b) /
            good.length;
      }
    }
    update(() {
      consulting = false;
      result = {
        'demo': true,
        'status': good.isEmpty
            ? 'failed'
            : good.length == selected.length
            ? 'ok'
            : 'partial',
        'mode': good.length >= 2
            ? 'ensemble'
            : good.length == 1
            ? 'single_model'
            : 'none',
        'requestedSeatCount': selected.length,
        'successfulSeatCount': good.length,
        'seats': responses,
        'aggregate': scores.isEmpty
            ? null
            : {'method': 'equal_weight_mean', 'scores': scores},
        'disagreement': good.length < 2
            ? null
            : {
                'voteCounts': votes,
                'voteDisagreement':
                    1 -
                    votes.values.reduce((a, b) => a > b ? a : b) / good.length,
              },
      };
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        update(() => variant = (variant + 2) % 3);
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        update(() => variant = (variant + 1) % 3);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Scaffold(
      body: Column(
        children: [
          Container(
            color: const Color(0xffe8f0ef),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: const Row(
              children: [
                Icon(Icons.science_outlined, size: 18),
                SizedBox(width: 9),
                Expanded(child: Text('桌面界面原型 · 模型、下载、引擎与 MCP 均为内存示例')),
                Text('不连接真实服务', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: switch (variant) {
              0 => managerLayout(),
              1 => workflowLayout(),
              _ => councilLayout(),
            },
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一个方案',
                  onPressed: () => update(() => variant = (variant + 2) % 3),
                  icon: const Icon(Icons.chevron_left),
                ),
                ...List.generate(
                  3,
                  (i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: ChoiceChip(
                      label: Text(variants[i]),
                      selected: variant == i,
                      onSelected: (_) => update(() => variant = i),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一个方案',
                  onPressed: () => update(() => variant = (variant + 1) % 3),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget managerLayout() => Row(
    children: [
      Container(
        width: 220,
        color: const Color(0xff14252b),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 32, 20, 32),
              child: Text(
                'GhostModelDeck',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ...List.generate(
              pages.length,
              (i) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  selected: page == i,
                  selectedTileColor: const Color(0xff26434a),
                  leading: Icon(
                    icons[i],
                    color: page == i ? const Color(0xff9ce4d6) : Colors.white60,
                  ),
                  title: Text(
                    pages[i],
                    style: TextStyle(
                      color: page == i ? Colors.white : Colors.white70,
                    ),
                  ),
                  onTap: () => update(() => page = i),
                ),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'macOS · Flutter\n关窗继续 / 明确退出停止\n示例席位就绪 $readyCount/${seats.length}',
                style: const TextStyle(
                  color: Colors.white60,
                  height: 1.8,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading(pages[page], '模型管理支撑并发委员会，综合结果交给大模型。'),
              const SizedBox(height: 22),
              section(page),
            ],
          ),
        ),
      ),
    ],
  );

  Widget workflowLayout() => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('搭建你的模型委员会', '沿着下载 → 识别 → 启动 → 并发咨询 → MCP 的路径验证。'),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: List.generate(
            pages.length,
            (i) => ActionChip(
              avatar: CircleAvatar(
                radius: 12,
                child: Text('${i + 1}', style: const TextStyle(fontSize: 11)),
              ),
              label: Text(pages[i]),
              backgroundColor: page == i
                  ? const Color(0xffc4e9df)
                  : Colors.white,
              onPressed: () => update(() => page = i),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 250,
              child: panel('本步目标', [
                Text(
                  [
                    '确认来源和资产类型，发现本地已存在的模型。',
                    '选择共享模型目录和下载源，再补齐必要文件。',
                    '优先 LM Studio，检查决策能力，必要时补兼容引擎。',
                    '至少两个就绪席位并发判断，保留原始意见与综合结果。',
                    '大模型通过本机 HTTP MCP 获得委员会意见。',
                  ][page],
                ),
                const SizedBox(height: 24),
                Text(
                  '当前页：${pages[page]}\n就绪席位：$readyCount/${seats.length}\nMCP 示例状态：${mcp ? "开启" : "关闭"}',
                  style: const TextStyle(height: 1.8),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => update(() => page = (page + 1) % 5),
                  child: const Text('下一步'),
                ),
              ]),
            ),
            const SizedBox(width: 24),
            Expanded(child: section(page)),
          ],
        ),
      ],
    ),
  );

  Widget councilLayout() => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        heading('委员会工作区', '先看决策与分歧，模型和服务管理集中在两侧。'),
        const SizedBox(height: 20),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 230,
                child: SingleChildScrollView(
                  child: panel('席位与模型', [
                    ...models
                        .where((m) => m.decision)
                        .map(
                          (m) => CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: m.selected,
                            title: Text(
                              m.name,
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: Text(
                              m.status,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onChanged: consulting
                                ? null
                                : (v) => update(() => m.selected = v ?? false),
                          ),
                        ),
                    const Divider(),
                    TextButton.icon(
                      onPressed: () => openSection(0),
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('模型与下载'),
                    ),
                    TextButton.icon(
                      onPressed: () => openSection(2),
                      icon: const Icon(Icons.memory_outlined),
                      label: const Text('引擎与就绪'),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: councilSection(showSeats: false),
                ),
              ),
              const SizedBox(width: 18),
              SizedBox(
                width: 240,
                child: SingleChildScrollView(
                  child: panel('服务与结果状态', [
                    badge(mcp ? 'MCP 示例开启' : 'MCP 示例关闭', mcp),
                    const SizedBox(height: 16),
                    const Text(
                      '本机 HTTP\n整轮预算 10 秒\n等权综合\n支持部分结果',
                      style: TextStyle(height: 1.9),
                    ),
                    const Divider(height: 32),
                    Text(
                      result == null
                          ? '尚未发起示例咨询'
                          : '状态：${result!["status"]}\n模式：${result!["mode"]}\n成功：${result!["successfulSeatCount"]}/${result!["requestedSeatCount"]}',
                      style: const TextStyle(height: 1.8),
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      onPressed: () => openSection(4),
                      child: const Text('MCP 接入配置'),
                    ),
                    TextButton(
                      onPressed: () => openSection(1),
                      child: const Text('模型存放路径'),
                    ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> openSection(int index) async {
    var activeIndex = index;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, dialogUpdate) {
          refreshDialog = () {
            if (context.mounted) dialogUpdate(() {});
          };
          navigateDialog = (i) {
            if (context.mounted) dialogUpdate(() => activeIndex = i);
          };
          return Dialog(
            child: SizedBox(
              width: 940,
              height: 630,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pages[activeIndex],
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    section(activeIndex),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    refreshDialog = null;
    navigateDialog = null;
  }

  Widget heading(String title, String subtitle) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              style: const TextStyle(color: Color(0xff66757e), fontSize: 13),
            ),
          ],
        ),
      ),
      badge('界面原型', false),
    ],
  );

  Widget panel(String title, List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xffe0e6ea)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    ),
  );

  Widget badge(String label, bool good) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: good ? const Color(0xffddf3e9) : const Color(0xffedf0f3),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        color: good ? const Color(0xff24634d) : const Color(0xff52636d),
      ),
    ),
  );

  Widget section(int index) => switch (index) {
    0 => librarySection(),
    1 => downloadSection(),
    2 => enginesSection(),
    3 => councilSection(),
    _ => mcpSection(),
  };

  Widget librarySection() => Column(
    children: [
      panel('候选目录与本地发现', [
        const Text(
          '模型名称与文件后缀不足以证明兼容；资产完整、引擎兼容和实际就绪分开展示。',
          style: TextStyle(color: Color(0xff66757e)),
        ),
        const SizedBox(height: 16),
        ...models.map(
          (m) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xffedf3f1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    m.decision
                        ? Icons.psychology_outlined
                        : Icons.chat_bubble_outline,
                    color: const Color(0xff237b6c),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${m.description} · ${m.size}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff66757e),
                        ),
                      ),
                      const SizedBox(height: 7),
                      badge(m.status, m.running),
                      if (m.progress > 0 && m.progress < 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(value: m.progress),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (m.decision && (!m.installed || !m.hasHead))
                  OutlinedButton(
                    onPressed: () => download(m),
                    child: Text(m.installed ? '补齐示例文件' : '模拟下载'),
                  ),
                if (m.installed)
                  IconButton(
                    tooltip: '手动删除示例',
                    onPressed: () => remove(m),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
          ),
        ),
        const Divider(),
        Wrap(
          spacing: 12,
          children: [
            TextButton.icon(
              onPressed: () => notice('模拟扫描完成；未读取本机模型目录。'),
              icon: const Icon(Icons.refresh),
              label: const Text('模拟扫描'),
            ),
            TextButton.icon(
              onPressed: () => navigate(1),
              icon: const Icon(Icons.folder_open),
              label: const Text('设置模型库'),
            ),
            TextButton.icon(
              onPressed: () => navigate(2),
              icon: const Icon(Icons.memory_outlined),
              label: const Text('配置引擎'),
            ),
          ],
        ),
      ]),
    ],
  );

  Widget downloadSection() => panel('下载与共享模型库', [
    TextField(
      controller: path,
      decoration: const InputDecoration(
        labelText: '模型存放路径',
        helperText: '可与 LM Studio 共用；此原型仅在内存中修改路径',
      ),
    ),
    const SizedBox(height: 22),
    DropdownButtonFormField<String>(
      initialValue: source,
      decoration: const InputDecoration(labelText: '下载来源'),
      items: [
        'Hugging Face 直连',
        'LM Studio 代理',
      ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
      onChanged: (s) => update(() => source = s!),
    ),
    const SizedBox(height: 22),
    const Text('安装状态', style: TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    const Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Chip(label: Text('下载临时文件')),
        Chip(label: Text('检查必要文件')),
        Chip(label: Text('校验版本与哈希')),
        Chip(label: Text('资产完整')),
      ],
    ),
    const SizedBox(height: 16),
    const Text(
      '已有共享资产也可以手动删除；下载不自动覆盖既有文件。续传和来源能力在真实下载器接入时验收。',
      style: TextStyle(color: Color(0xff66757e), height: 1.8),
    ),
    const SizedBox(height: 24),
    FilledButton.icon(
      onPressed: () {
        notice('示例路径与来源已应用；未写入文件。');
        navigate(0);
      },
      icon: const Icon(Icons.check),
      label: const Text('应用示例设置'),
    ),
  ]);

  Widget enginesSection() => panel('引擎与实例', [
    Row(
      children: [
        badge('LM Studio 优先', true),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            '先验证具体资产的决策能力；必要时使用兼容引擎。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
    const SizedBox(height: 16),
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        OutlinedButton.icon(
          onPressed: () => update(() => lmLinked = true),
          icon: const Icon(Icons.link),
          label: Text(lmLinked ? 'LM Studio 示例已关联' : '模拟关联 LM Studio'),
        ),
        OutlinedButton.icon(
          onPressed: () => update(() => llamaInstalled = true),
          icon: const Icon(Icons.download_outlined),
          label: Text(llamaInstalled ? 'llama.cpp 示例已安装' : '模拟下载 llama.cpp'),
        ),
        OutlinedButton.icon(
          onPressed: () => update(() => specialInstalled = true),
          icon: const Icon(Icons.extension_outlined),
          label: Text(specialInstalled ? '专用引擎示例已关联' : '模拟关联专用引擎'),
        ),
      ],
    ),
    const SizedBox(height: 12),
    const Text(
      '引擎版本将在真实接入时检测。此处用 LM Studio 未支持情境演示补充引擎路径，不代表本机诊断结论。',
      style: TextStyle(color: Color(0xff66757e), fontSize: 12, height: 1.6),
    ),
    const SizedBox(height: 10),
    ...models
        .where((m) => m.decision)
        .map(
          (m) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    badge(m.status, m.running),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: m.engine,
                        decoration: const InputDecoration(
                          labelText: '提供方 · 示例',
                        ),
                        items: ['LM Studio', 'llama.cpp', '专用引擎']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (s) => update(() {
                          m.engine = s!;
                          m.running = false;
                        }),
                      ),
                    ),
                    const SizedBox(width: 14),
                    FilledButton.tonal(
                      onPressed: m.complete
                          ? () => m.running
                                ? update(() => m.running = false)
                                : start(m)
                          : null,
                      child: Text(m.running ? '停止示例' : '检查并启动示例'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    const Divider(height: 28),
    const Text(
      '明确退出时仅收尾 GhostModelDeck 创建的受管实例；不关闭 LM Studio 本身或原有实例。',
      style: TextStyle(color: Color(0xff66757e), height: 1.7),
    ),
  ]);

  Widget councilSection({bool showSeats = true}) => Column(
    children: [
      if (showSeats) ...[
        panel('选择委员会席位', [
          Wrap(
            spacing: 12,
            children: models
                .where((m) => m.decision)
                .map(
                  (m) => FilterChip(
                    label: Text('${m.name} · ${m.running ? "示例就绪" : "未就绪"}'),
                    selected: m.selected,
                    onSelected: consulting
                        ? null
                        : (v) => update(() => m.selected = v),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 12),
          Text('选中 ${seats.length} 席 · 就绪 $readyCount 席 · 先跑通两个不同模型'),
        ]),
        const SizedBox(height: 18),
      ],
      panel('发起一次决策咨询', [
        TextField(
          controller: stateText,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '上下文 state · 示例不影响固定演示概率',
          ),
        ),
        const SizedBox(height: 14),
        const Wrap(
          spacing: 8,
          children: [
            Chip(label: Text('billing · 账单团队')),
            Chip(label: Text('shipping · 物流团队')),
            Chip(label: Text('returns · 售后团队')),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: scenario,
                decoration: const InputDecoration(labelText: '演示情境'),
                items: ['全部成功', '一席超时', '全部失败']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: consulting
                    ? null
                    : (s) => update(() => scenario = s!),
              ),
            ),
            const SizedBox(width: 14),
            FilledButton.icon(
              onPressed: !consulting && readyCount >= 2 ? consult : null,
              icon: const Icon(Icons.bolt),
              label: Text(consulting ? '示例并发中…' : '演示并发咨询'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '等权综合 · 整轮预算 10 秒 · 部分结果可返回。故障演示会加速，不实际等待 10 秒。',
          style: TextStyle(color: Color(0xff66757e), fontSize: 12),
        ),
        if (readyCount < 2)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
              onPressed: () =>
                  variant == 2 ? openSection(2) : update(() => page = 2),
              child: const Text('先完成文件并启动至少两个示例实例'),
            ),
          ),
        if (consulting)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
      ]),
      if (result != null) ...[const SizedBox(height: 18), resultSection()],
    ],
  );

  Widget resultSection() {
    final scores = result!['aggregate']?['scores'] as Map<String, double>?;
    return panel('综合结果 · 演示数据', [
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          badge('状态 ${result!["status"]}', result!['status'] == 'ok'),
          badge('模式 ${result!["mode"]}', result!['mode'] == 'ensemble'),
          badge(
            '${result!["successfulSeatCount"]}/${result!["requestedSeatCount"]} 席成功',
            result!['successfulSeatCount'] > 0,
          ),
        ],
      ),
      const SizedBox(height: 18),
      if (scores != null)
        ...scores.entries.map(
          (e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 95, child: Text(e.key)),
                Expanded(
                  child: LinearProgressIndicator(
                    value: e.value,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Text(e.value.toStringAsFixed(2)),
              ],
            ),
          ),
        )
      else
        Text(
          result!['mode'] == 'single_model'
              ? '仅一席成功，保留其结果；没有委员会综合评分。'
              : '全部席位失败，没有综合建议。',
        ),
      const SizedBox(height: 14),
      const Text(
        '综合评分不是正确率；各模型原始结果、投票及分歧一起交给大模型。',
        style: TextStyle(color: Color(0xff66757e), fontSize: 12),
      ),
      const SizedBox(height: 14),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('查看原始席位与 MCP 结果示例'),
        children: [
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(result),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    ]);
  }

  Widget mcpSection() => panel('大模型接入委员会', [
    Row(
      children: [
        Expanded(
          child: Text(
            'MCP 示例状态：${mcp ? "已开启" : "未开启"}',
            style: const TextStyle(fontSize: 18),
          ),
        ),
        Switch(value: mcp, onChanged: (v) => update(() => mcp = v)),
      ],
    ),
    const SizedBox(height: 10),
    const Text('本机 Streamable HTTP · 一个入口共用常驻席位'),
    const SizedBox(height: 18),
    const SelectableText(
      'http://127.0.0.1:<port>/mcp\nconsult_jev_council(state, options)',
      style: TextStyle(fontFamily: 'monospace', height: 1.8),
    ),
    const SizedBox(height: 18),
    const Text(
      '示例配置，<port> 待真实服务绑定后替换。当前没有监听端口，也没有修改 Codex 设置。',
      style: TextStyle(color: Color(0xff66757e), height: 1.7),
    ),
    const SizedBox(height: 20),
    const SelectableText(
      '[mcp_servers.jev_council]\nurl = "http://127.0.0.1:<port>/mcp"',
      style: TextStyle(fontFamily: 'monospace', height: 1.7),
    ),
    const SizedBox(height: 20),
    OutlinedButton.icon(
      onPressed: () async {
        await Clipboard.setData(
          const ClipboardData(
            text: '[mcp_servers.jev_council]\nurl = "http://127.0.0.1:<port>/mcp"',
          ),
        );
        notice('已复制示例配置；需要替换真实端口后才能连接。');
      },
      icon: const Icon(Icons.copy_outlined),
      label: const Text('复制示例配置'),
    ),
    const Divider(height: 34),
    const Text(
      '关窗口继续 · 明确退出停止受管实例与 MCP\n返回每席意见、综合评分、分歧及失败情况。',
      style: TextStyle(height: 1.9),
    ),
  ]);
}
