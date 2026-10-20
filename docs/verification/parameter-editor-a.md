# A 方案参数编辑交付验证

<!-- parameter-editor-audit-status -->

**交付进行中。** 13 个切片的实现和局部验收已整合，最终生产构建及原生界面复查通过，完整宿主门禁 1144 项全部通过。独立审查、阶段合入和总 PR 尚未完成。

2026-10-20。依据为[原规格](../requirements/parameter-editor-spec.md)、[13 项拆解](../requirements/parameter-editor-delivery-plan.md)、[llama.cpp 范围调整](../requirements/parameter-editor-llama-adjustment.md)、[ADR 0009](../adr/0009-explicit-drafter-configuration.md) 和 [ADR 0010](../adr/0010-instance-generation-defaults.md)。原规格保留创建时的状态文字；当前完成状态以本文和工单为准。

## 候选与执行入口

总交付基准为 `6c96dcf31021e8a5207ad352b01d7d038df2b83b`。阶段候选进入 `dev`，总 PR 指向 `main`，本轮只推进到 ready。未设置硬性 token 或时间预算。

实现者分别负责加载、生成和认证，整合者串行接收冻结增量。最终测试副本排除用户原有 `.gitignore`、`lib/model_library.dart` 和 `test/model_library_test.dart` 三处改动；原工作区保留这些改动。排除原测试块留下的相邻空白仅在副本由固定 Dart 格式化。

原始记录位于主工作区 `.scratch/parameter-editor-delivery/`。恢复入口为 `current.json`，完整门禁队列为 `final-gate-queue.json`。原始日志和输入身份保存在 `final-host-gates/`；工作树清理前复制并校验，不依赖临时句柄恢复。

## 已实现的公开行为

- 实例编辑与引擎启动默认值复用 A 分组侧栏；生成默认值与公开 HTTP 测试场复用生成字段。开关、枚举、数值、步进、适用滑块、单位、路径、列表和 JSON 对象采用对应控件，高级组也可直接编辑。
- 加载配置、生成默认值和显式草稿分别保存。生成参数在准入时按单次显式值、实例默认值、当前原生默认值取值；后续修改不改变已准入请求。加载配置在下一次成功启动后生效。
- 继承、明确关闭和显式数值分别表达。关闭过滤及惩罚使用引擎中性值；关闭输出上限时不补入 32 或 4096。seed 保留精确整数，Splash 支持 uint64 高半区，llama.cpp 保留自身 uint32 范围。
- 停止字符串逐项编辑；结构化输出保留 Schema 和附加属性。模板对象编辑保留已有键，思考预算遵循各引擎语义。Splash 请求优先级、时限和缓存隔离进入公开请求。
- 调优文本继续优先，软件管理的模型、监听资源和草稿来源受控。Splash 独有长前缀只在所选安装的帮助明确识别时解析；歧义、未知和其他引擎不猜测。
- 当前状态属于实际运行实例。保存新来源、失效来源或另一引擎配置不会改写旧实例的来源、容量、认证及停止入口。

## 宿主门禁与构建

固定环境为 macOS arm64、Flutter 3.47.6（`5fc346839b5d0eef006ed8404392afb4dfae428d`）、Dart 3.13.5。Python 为 3.12.14，摘要 `494f72dd95d0dc196169c5821219fc6cfa9c1ef582332b95b53874b10acea6e0`。固定字体、依赖锁和实际命令由宿主入口记录。系统另一路 Flutter 已更新为 3.47.7，本轮使用项目 `.tooling/flutter-3.47.6`，未修改系统 SDK。

执行入口：

```sh
export GMD_FLUTTER_SDK=/Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/flutter-3.47.6
export GMD_TEST_PYTHON=/Users/ghost233/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
export JEV_LAYOUT_FONT=/Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/check-fonts/NotoSansCJK-Regular.ttc
./scripts/test-host.sh prepare
./scripts/test-host.sh check
```

在线准备已完成，依赖锁未变。最终测试副本需要的五套固定题源已按提交和实际数据复制，保留 Git link 的原提交，没有初始化嵌套仓库。Jevman 固定 Node 24.21.0 归档、二进制、许可及 arm64 均核验。准备证据为 `benchmark-materialization.json` 和门禁队列记录。

最终两处修复完成后，`run-WYGh3e` 的 87 项定点及关联回归通过，包含此前 9 项失败、凭据的原始/类型化投影关联及两个温度界面入口。实际命令和包装退出均为 0，标准完成报告通过，758 个宿主输入保持不变，规范摘要为 `1197c99eaf61f1ee3bd1089ded748c46e539efa6b0d6ec2ac715ca4bedc39597`。随后唯一完整门禁 `run-NADIIq` 自然结束：1144 项全部通过，格式 234 文件无变化，静态分析无诊断，format/analyze/test/包装退出均为 0，标准完成报告通过。源码仍为同一规范摘要，`source_unchanged=true`。

正式入口构建命令为固定 SDK 的 `flutter build macos --release --no-pub --target=lib/main.dart`，设置 `FLUTTER_MACOS_ARM64_ONLY=true`。最终构建退出 0，主程序、`App.framework`、`FlutterMacOS.framework` 均仅为 arm64；全部声明资源与包内字节一致，构建期间输入未变。

157 个构建输入摘要为 `a63324b72bdbf1c5477da94fef970a64eb5cb4b52d98aff4672a6454dcf3ea01`。构建与测试副本逐文件一致，见 `production-build-final/final-worktree-equivalence.json`。产物保存于主工作区 `.tooling/parameter-editor-delivery/production-a63324b72bdb/Ghost Model Deck.app`，主程序摘要为 `7d2b38b555ca88abe8d3711bc04011165b750ec2804ef7fa39e97c1c420dae32`。

## 真实引擎验证

### Splash 草稿、compact 与预算

所选引擎为 `/Users/ghost233/Ghost233Code/GhostSplash`，原生二进制摘要为 `311ead4c092fb33eb0eb0fe1d6d91934ef8d1e43b45f31814f3049cad7b2148a`。以下资源都来自用户已有的 `/Users/ghost233/.lmstudio/models`。

| 目标 | 原始草稿 | 结果与证据 |
| --- | --- | --- |
| Qwen3.5-4B UD-Q4_K_XL GGUF | z-lab/Qwen3.5-4B-DFlash | 文件、原生配置及实际加载通过；草稿原生启用，JSON/SSE 200。`native-preflight/result.json`。 |
| Qwen3.8-27B-4bit 三片 safetensors | incoai/Qwen3.8-27B-DFlash2 | 原始分片引用及实际加载通过；JSON/SSE 200。`native-qwen38/result.json`。 |

准备过程在 GMD 自有不可变 assembly 中引用原始文件，不改写权重。公开扫描对 Qwen 条件生成架构的分类修复有独立红绿和 82 项关联回归；识别结果仍须经过实际原生加载确认。

真实 `qwen35-248320-dev-seed.splash` ranking 通过 `SPLCHD02` 格式、248320 词表、完整排列和原生验证，容量 32768；记录包含原生对照结果及正常完整 head 回退原因。短 JSON/SSE 成功，超限请求保留原生 413，uint64 最大值和 -1 seed 均被接受。证据为 `native-qwen35-compact-budgets-seed64/result.json`。不推导缺少原生信号的逐 token 颜色或命中。

提示查找和 Fast Top K 的原生配置已核对，提示查找因 `no complete earlier continuation` 正常回退，JSON/SSE 200。ANE 在该受控作业中明确关闭；不声称开启 ANE 或功耗恢复触发已实测。证据为 `native-qwen35-optimizations/result.json`。最初沙箱无法访问 Metal 的失败另存，宿主机运行成功才作为通过。

### llama.cpp

b11457 的普通 draft 明确选择同一 GGUF 同时作目标与草稿，原生就绪、状态及短 JSON/SSE 通过，见 `native-llama-draft-simple/result.json`。这只验证普通 draft 功能路径，不作性能或各模式兼容性结论。

普通 draft、EAGLE3、MTP、DFlash、DSpark 按所选官方 CLI 构造模式、资源和调优参数。用户已免除各模式真实兼容配对验收；原生 Ready 后不因 slots 缺失、未知草稿活动或原生回退额外拒绝。实际失败、取消及身份丢失继续按已有生命周期收尾。Splash 的严格草稿要求不受此调整影响。

### 认证与诊断

Splash 和 llama.cpp 各两个运行实例使用不同凭据。状态、发现、监控、JSON/SSE 正确凭据成功；缺失、错误、跨实例和待应用凭据返回 401。停止一个实例后同伴仍能服务，凭据文件在收尾后清除。证据为 `auth-native-report.md` 和 `auth-native/summary.json`。

完整门禁发现提前清洗调试 I/O 导致合法业务字段改变、跨副本凭据关联丢失。修复保留 trace 私有原始输入，在最终类型化展示边界投影并脱敏；运行实例凭据在准入时绑定。原始 9 个失败断言保留，新增复合凭据、实际 owner key 和晚到 I/O 边界，当前集成回归通过。真实协议、认证头及日志保护的未变路径复用上述原生证据；修复后的完整门禁已通过。

## 原生桌面验证

使用真实 Swift MethodChannel 和生产公开控制器/Widget 组合，配置文件显式注入任务目录，HOME 不变。验收窗口与已安装应用隔离。

- 原生目录/GGUF/ranking 选择、格式过滤、取消、清除后放弃、保存重开均已操作。900 × 560 深色 150% 可滚动、搜索和使用固定操作栏；浅色 100% 也已核对。
- 原生界面保存输出上限 8，省略字段的 JSON/SSE 实际生成 8 个 token；运行中改为 4 后，下一请求生成 4 个。明确关闭后同一进程生成 21 个，单次显式 4 仍优先。
- 待应用上下文 auto 保持当前容量 2048。保存错误草稿目录不准备或重启旧实例，旧进程仍服务且能停止；下一启动显示所选目录缺 config.json 的错误和完整日志。原生选择器修复来源后启动成功，实际容量才变为 262144。
- 从原生界面运行 llama.cpp 显式短测试，HTTP 200 后测试实例自动停止。继承模型思考时的初次 32-token 短测返回 502，单独保留为失败；显式关闭思考后才通过。

实际记录见 `native-window/final-native-*.json`、`final-native-result.json` 和 `preflight-final-check.json`。原生进程已停止，9 份正式配置和原始权重元数据未变。

原生窗口曾复现 Slider 使 AX 树冻结的 SDK 问题，与 [Flutter #190357](https://github.com/flutter/flutter/issues/190357) 对应。为原 Slider 增加局部 `Overlay.wrap` 后，完整弹窗、键盘输入、拖动和 AX 更新恢复；保留原有语义且未修改 SDK。

最后一次原生复查使用最终修复源码重新构建：未指定温度显示继承且没有虚构滑块位置；实际键盘输入 0 后，数值和 Slider 0% 同步，AX 持续更新。取消后保存值仍为 1.0，正常退出后 PID 消失、生命周期 stopped、live_instances 为空，正式配置保持原摘要、大小及修改时间。见 `native-window/postfix-build/result.json`、`postfix-native-result.json`。LaunchServices 未提供退出码，记录使用正常退出与进程消失证据，不虚构退出 0。

## 失败历史与证据边界

| 记录 | 结果及处理 |
| --- | --- |
| 旧候选 `run-izMTMd` | 1080 项通过，仅为修复前历史，不代替当前门禁。 |
| `run-Int25e` | 副本排除用户补丁留下格式差异，按固定 formatter 修正副本。 |
| `run-HAI1JC`、`run-wG3WUW` | 缺固定题源和 Node，保留环境失败。准备完成后原失败 `run-ASJRul` 和关联 24 项 `run-DI8p6C` 通过。 |
| `run-dIlp4S` | 自然结束，1131 通过、9 失败；归为调试投影产品回归，统一修复后重新验证。 |

测试替身、文件检查、原生配置检查、真实模型和原生桌面分别计入各自范围。成功结果只在相关输入、环境和外部条件未变时复用。原生后端决定实际兼容性；没有覆盖的性能、ANE 开启效果和逐 token 命中不作推断。

## 原型与交付边界

[完整 A/B/C 原型](https://github.com/Ghost233/GhostModelDeck/tree/codex/prototype-parameter-editor-a) 保留在归档提交 `ab22a624243e552b8bcf37f694402de07ad5a23b`。主工作区 `.tooling/parameter-editor-prototype/archive/` 留有原预览来源。

父项为 [A 方案：实例参数控件、生成默认值与显式草稿模型](https://github.com/Ghost233/GhostModelDeck/issues/118)。父规格正文保持原样，子项按本轮验收范围结项。当前尚未提交或关闭工单；阶段和总审查仍待执行。
