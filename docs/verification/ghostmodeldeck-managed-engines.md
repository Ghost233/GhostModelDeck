# GhostModelDeck #15 — 受管引擎增量验证

## 范围与状态

本记录是 **里程碑 1 的可继续切片**，不是 #15、A04/A07/A08 的完整通过报告。起点为 main `344adf0`（包含 #14 `7701500`）。没有改冻结 #13 hash 清单、既有权重、个人配置、其他仓库或 Harness；没有接管外部运行服务。

### 本切片业务行为

- 原 `LlamaEngine.start(artifactId)` 仍显式启动一个模型对应一个 owned 子进程；新增接受扫描分类为 `AssetKind.chat` 的完整、全内容核验 GGUF，并保留 Kev/Laya 路径。
- 不改 #14 的扫描闭包、`LibraryArtifact`、quantization 或模板判定。启动前仍通过同一 `ModelLibrary.verify` 重验资产类型、文件大小、hash、闭包与已验证来源。
- 实例通过 `/props` 实际 alias/path 绑定后才执行能力探测：普通模型通过绑定 alias 的 `/v1/chat/completions` 非流式请求；Kev/Laya 仍通过原 `/v1/systemone` typed choice。
- `LlamaCapability.textGeneration` / `choiceProbability` 是该实例成功请求所得的不同能力，不来自健康检查、文件名或模型 metadata。`lastTextResult` / `lastResult` 保留对应真实 HTTP 原文。
- `TextRequest` 限定非流式、单轮文本；`TextResult` 验证实际 model、单个 assistant 文本、完成状态与正数实际生成 token 用量。不制造概率、confidence 或校准字段。
- `generateText(instanceId, request, timeout:, cancellation:)` 只调用已验证文本能力的指定实际实例，不隐式启动/切换模型。它复用原 HTTP 请求、身份绑定、取消与资源保护实现，而非第二套运行管理。
- `decide` 加入已验证 choice 能力门禁。`CouncilController.availableSeats` 同样要求 `choiceProbability`；即使普通实例 ready，也不能加入概率席。
- 本切片没有修改原 DecisionResult 的合法候选精确覆盖、有限 [0,1]、归一化误差 0.0001、model、usage.output_tokens=0 或等权成功席规则。

## 确定性接缝与红绿证据

只替换已约定的外部 `EngineProcessIO` / `EngineChild`，并在真实 loopback HTTP 上返回固定报文；没有 mock 内部扫描、验证、资源算法、Council 筛选或私有方法。GGUF 是结构可验证的公开 fixture，**不是可用于 native 推理的真实权重**。

| 切片 | 红灯 | 绿灯 |
| --- | --- | --- |
| 完整普通 GGUF 显式启动 | 原实现拒绝 chat：`请选择完整且已核验的 Kev 或 Laya GGUF 模型变体`；exit 1；`.tooling/container-tests/run-GcKk3q` | engine+council 20 tests 通过；exit 0；`.tooling/container-tests/run-3gNY9I` |
| ready 普通模型不得成为概率席 | 移除能力筛选时公开 Council 接口返回 CouncilSeat，`Expected: empty / Actual: [Instance of 'CouncilSeat']`；exit 1；`.tooling/container-tests/run-Qqq2oG` | 恢复最小能力筛选后同一公开行为通过；exit 0；`.tooling/container-tests/run-UbJ7f1` |

追加公开负例：健康服务的 foreign model、零生成 token、typed probability 报文均不能作为文本启动探测通过；失败退出 owned 子进程，能力集合为空，权重保留并释放删除保护。显式文本调用及 stopped 后拒绝调用有外部请求计数证据。

### GUI 生产路径（主线程恢复后已取得绿灯）

公开 widget 测试复用原 LibraryPage → ModelRunDialog → EngineCatalog.providerFor → LlamaEngine.start 路径，参数化保留 decision 并新增 ordinary text。红灯 exit 1：普通资产的运行按钮被旧 decision-only 条件禁用，未出现引擎 dropdown，`Bad state: No element`；证据 `.tooling/container-tests/run-2Wbhb6`。最小修改只放开 LibraryPage 运行按钮和 ModelRunDialog 的 chat 资格，不改导航/主题。主线程按用户要求撤回离线模式、恢复可运行的专用容器后，使用原联网脚本重跑：decision 与 ordinary 两个真实生产路径 widget 用例均通过，exit 0，证据 `.tooling/container-tests/run-GfB1hi`。之前 `run-I6In7Y` 离线重跑只保留诊断用途，不替代联网检查。本项不是宿主原生人工 GUI 验收。

后续绿色任务在原脚本的 `flutter pub get` 卡于 `Downloading packages...` 超过 10 分钟，尚未执行任何测试。只读进程检查及同容器 pub.dev HEAD 超时证明包主机连接故障：`curl: (28) Operation timed out after 15003 milliseconds with 0 bytes received`。为释放唯一 jobslot，核对确切 cmdline 后仅 TERM 本次 owned Dart pub 子进程，原脚本返回 `Failed to update packages.`，exit 241，证据 `.tooling/container-tests/run-nJfP7o`。容器没有创建/删除/重启，网络/SDK/包配置没有更改。

### 检查状态

- 原脚本初步 format：exit 0，56 files / 0 changed，`.tooling/container-tests/run-BvHnxc`；**在最后 GUI 修改之前，不能作为最终全量格式证据**。
- M1 business/Council 绿灯见上表，20 tests；之后追加的文本拒绝 case 和 GUI 修改尚待最终运行。
- 最后修改后的本机固定 Dart `format --output=none --set-exit-if-changed lib test benchmarks`：exit 0，56 files / 0 changed；`git diff --check` 无错误。此本机证据不能冒充原脚本容器检查。
- 主线程完成本里程碑最终联网检查（无 offline/no-pub）：format56文件0改动 run-HgmhGR，analyze零诊断 run-4vRxlF，完整166项全部通过 run-xOjIpZ，均 exit0。此前因网络中止/离线诊断结果不替代本次正式检查。
- 使用恢复后的自有 `ghostmodeldeck-checks-r33b`，固定SDK和依赖未变；网络与独立容器停止/恢复边界见[诊断记录](ghostmodeldeck-network-recovery.md)。来源和其他服务未由本线程重启。
- 已有 fixture 绿/红任务执行 teardown，没有真实 llama 进程被本里程碑创建。这里只完成 M1 的受控 I/O 与 widget 验证；仍不是完整 #15 验收。

## 真实与未执行范围

**本切片没有下载、安装或 native 加载真实模型。没有把 fixture 或父线程已有 hash 预检宣称为新 native 验收。** 所有共享权重均未触及。

JEV official release 仍为 `b11381 / 836d57176dc699a726c55418e4f96b8ca628e1bf`。没有全局替换 release，没有宣称普通 `v0.5.0 / 7fe450e19305b828c199d602c23a8337aaa1f03b` 支持 systemone。本次 archive 安装 fixture 仍使用旧 release 协议；不是多版本管理已实现的证据。

后续仍需：

1. 每 run generation / 请求许可 / 取消排空 / 全体停止关闭入场 / 停止失败不能公开 Ready / peer 与权重保护的确定性调度。当前生命周期沿用原实现，不能宣称这些缺口已经修复。
2. 标准版真实安装版本与 commit 验证、准确多版本登记，以及 managed archive SHA 与 linked binary SHA 分开表达；安装、服务、运行身份明确分离。
3. score / noul 类型化能力请求与结果，按固定原始 schema 校验。`choiceProbability` 明确只代表 choice，不证明 score/noul。三题型/MCP一致性还须主线程 #19 补验。
4. 引擎内部流式复用与晚结果封口。没有提前实现 #17 的完整 HTTP 网关/SDK。
5. 固定普通 Qwen2.5-0.5B GGUF、现有 Kev/Laya 的公开扫描/完整来源重建、真实生产入口安装/加载/调用、Mac 构建，以及 PID/端口/权重完整收尾。现阶段不宣称 Ready 的完整 installation-version/run-generation 证据链。

工单由主线程继续处理和最终审查；本切片不自行关闭 #15。
