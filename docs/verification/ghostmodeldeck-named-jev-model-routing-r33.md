# #33 命名 JEV 模型路由与标准结果验证

日期：2026-10-08。来源：[工单 #33](https://github.com/Ghost233/GhostModelDeck/issues/33)、[已确认规格](../requirements/protocol-converters-and-playground.md)、[ADR 0002](../adr/0002-named-council-model-routing.md)。实施基线为 `888b41490ccc303dee62fbadea564c4ffd1aed60`，分支为 `codex/jev-model-routing`。本记录只对应 #33 的命名配置、既有三题型正常调用和标准结果；#34 的完整原生结构化 JSON/扩展字段以及 #35 的完整测试场、debug、取消交互继续由后续切片完成。

## 实施与接缝

`CouncilController.models` 维护唯一命名登记与配置持久化；软件页面、HTTP 和 MCP 访问同一登记、同一 `EngineCatalog` 和受管实例。配置保存资产 ID 与引擎 ID，不保存随机实例 alias，也不调用模型启动/加载。调用入场后使用不可变配置及已解析实例快照；编辑、重命名、删除不会重写已开始的调用。

原生路由使用既有 `LlamaEngine.decideBatch` 的 Ready、能力、身份/代次、活动许可与取消边界。解析后的 `choice`、`score`、`noul`、概率、legend、confidence 和实际 usage 保留，只映射公开 model。委员会路由复用 `CouncilController.consultBatch`，整席完整校验、等权平均、至少一席完整成功；零成功产生业务错误且无 answers。

正常结果顶层严格为 `model/answers/usage`。委员会 choice 只对完全相等的最高概率按候选 ID 排序；近似相等保留真正最高项。choice/score confidence 从最终分布按固定原生算法计算，noul 保持 scalar。算法依据为 [固定原生 formatter](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L665-L765)，测试期望来自独立已知向量，不调用生产计算函数生成期望。

HTTP 为 `POST /v1/systemone`。MCP 为 `decide_jev`、`decide_jev_batch`，另提供 `list_jev_models`；旧工具名称没有平行注册。HTTP/MCP 必填 model，共用 typed 输入与业务错误数据。Codex 示例超时取 `max(20, ceil(最大已保存预算秒数)+10)`，60.1 秒配置生成 71 秒，删除后回落至 20 秒；只生成示例文本，没有修改用户客户端文件。

测试从已确认的公开业务入口、实际生产 Widget 和本机真实 HTTP/MCP 驱动；仅外部原生进程/HTTP 与测试临时文件位于替身边界。没有 mock 委员会、转换器、模型登记或资源管理业务，没有测试私有计算函数。

## #33 十六条验收对应证据

| 条目 | 实施与验证 |
| --- | --- |
| 1. HTTP/MCP 必填 model、同一来源、双载荷一致 | `jev_protocol_test.dart` 真实三名称混合调用，缺少/未知 model，MCP 文本 JSON 与 structuredContent 相等；`council_mcp_test.dart` 新工具发现和单题。 |
| 2. 多配置 CRUD、独立超时、持久恢复 | `jev_models_test.dart` 离线创建 quick/hard、不同成员/预算、重新构造控制器加载文件、重命名与删除；生命周期回归覆盖退出等待写入、删除、恢复与持久化失败传播；`jev_model_page_test.dart` 实际对话框创建/编辑/删除，以及成员被移除后的编辑拒绝和明确删席保存。生产没有预设 quick/hard 或难度策略。 |
| 3. 原生固定名、全局唯一、无特殊默认 | 跨来源同名拒绝，不覆盖已有配置；未登记 gmd-council 报不存在，用户显式创建同名普通委员会后可调用。 |
| 4. 离线绑定不加载、稳定资产/引擎身份 | 停止全部受管实例后保存配置，恢复时无 live process；显示未就绪原因；显式重新启动后 alias 改变，原固定名继续可用。 |
| 5. 可用状态与发现、唯一绑定、逐批能力 | 部分不可用配置显示原因；歧义原生从发现移除；`jev_protocol_test.dart` Score probe 未成功的 Ready 原生仍可被发现，但混合请求被拒绝，Choice-only 可用。 |
| 6. 标准顶层与三题型字段、默认不泄漏 | HTTP/MCP 与页面断言顶层仅 model/answers/usage，答案包含标准字段，noul 无伪造概率/legend/confidence。 |
| 7. 原生保真与唯一受管入口 | 原生混合 wire 例核对原 choice、校验容差内的原 score、confidence、legend、noul 与 input_tokens=27；仅选定实例收到调用，许可回收。 |
| 8. 多/单/零成功 | 全成功、部分整席失败、仅一席有效、零成功均由公开入口驱动；MCP 零成功 isError，返回 error 而非补造 answers。 |
| 9. confidence、ordinal score、scalar noul | 独立八组 Score 向量含 `[0.4,0.4,0.1,0.1]→0.1`；两席综合 `[0.45,0.45,0.1]→score0.65/confidence0.025`；相反 Choice 综合 confidence0，Noul 均值0.5。 |
| 10. 精确并列、成功席位用量 | 单席和多席精确并列选择 a；`2^-41` 概率差仍选择 z；实际成功用量7+13=20，失败不计入，八题同一席报告27不乘题数。 |
| 11. 整席退出、不修概率 | 任一题缺失、概率不归一化、confidence 缺失或 noul 增加非法字段均使整席退出；保留另一完整席位原分布及实际用量。 |
| 12. 不可用/歧义/能力失败与原生明确错误 | 原生 not_ready、route_conflict、capability_mismatch；委员会其他有效席位仍可返回。能力不匹配的真实 HTTP/MCP 核对原生409且零上游推理、委员会成功用量10。 |
| 13. 软件选择来源与正常结果 | 页面实际配置与来源选择，正常标准 JSON 展示；CJK 400/647/880 宽度、2倍字号覆盖三题型。完整委员会结构只在本次 debug 参数为 true 时出现在扩展中，默认结果无这些结构。 |
| 14. 入场快照 | 两席请求执行期间重命名、改成员与预算：原名/两成员/3秒快照仍完成，新名使用一成员/1秒；删除期间已开始请求继续完成，新调用拒绝旧名。 |
| 15. 新连接配置与非法配置拒绝 | 生成文本包含两个新决策工具与模型发现；超时示例随最长保存预算变化。名称冲突、未知绑定、重复席位、非正预算、缺少/未知 model 明确拒绝且有效配置保留。 |
| 16. 公开运行图、实际界面、真实协议及门禁 | 见上述生产 Widget、真实 HTTP/MCP、受管入口用例及下方最终门禁；只替换外部 I/O。 |

## 红 → 绿与原始失败

证据目录均位于该 worktree 的 `.tooling/container-tests/`，每目录保存源码归档、作业、原始日志与真实 exit。下列编号是已执行的代表性切片；红均为真实失败，绿均为 exit0。

| 切片 | 红目录 / 原始失败 | 绿目录 |
| --- | --- | --- |
| 离线命名配置持久化 | `run-pGbtGp`，命名 API 尚不存在 | `run-g4cfzh` |
| 原生字段与用量保真 | `run-xZpfxD`，decide 入口不存在 | `run-U0Vrtv` |
| 委员会标准结果与综合 | `run-XtGAPu`，无标准委员会调用 | `run-XF1Ugc` |
| 真实 HTTP/MCP | `run-stf4Ei`，无 JEV gateway 接入 | `run-1gV2AK` |
| 软件命名配置 | `run-pMtSYY`，生产页面没有创建模型控件 | `run-lweYHt` |
| 部分可用原因与重启恢复 | `run-LbUdmq`，部分配置原因丢失 | `run-ZSyt1F` |
| 委员会退出撤回输出 | `run-NBy5NI`，已退出仍发布一席成功 | `run-Hha2ow` |
| 生成连接示例预算 | `run-4PQeL3`，仍固定20秒 | `run-Gyaac7` |
| 原生退出撤回输出 | `run-Km2Zin`，已退出仍发布原生成功 | `run-6SFc3J` |

能力不匹配真实协议用例为 `run-smrtok` exit0。受影响模块首轮 `run-ilzXTF` 为54通过/1失败：旧整图期望遗漏新增 confidence，原始失败保留，定向修复 `run-0TPDXr` exit0。更新后的完整受影响模块 `run-03ZdQs` 为104通过、exit0。

页面测试驱动曾因 Flutter 默认拦截网络、选到对话框外控件或未滚动到按钮失败；已改用仓库既有真实网络边界与确定性公开状态等待。`run-eLGur8` 被主动终止且未完成，不能视为成功；最终页面绿为 `run-lweYHt`，随后包括在104项模块验证中。宿主曾报告临时文件 ENOSPC；修改未写入，复查有充足空间且写入探针和重试成功，没有清理用户文件或替换运行时。

正式门禁首轮格式 `run-OoAOQv` exit1（新增页面测试1文件未格式化），分析 `run-myNLGe` exit1（30条 if 缺少块诊断）。这些失败均不计通过；修复仅限本次新增结构与格式。最终结果见下节。

完整测试首轮 `run-ULdqC7` 为449通过/4失败、exit1；四项均为旧桌面布局驱动寻找已替换的“综合评分”，首个原始错误为 `desktop_layout_test.dart:358` 的 No element，没有溢出诊断。保留原900×560、dark/light及1.0/1.5字号、边界可见性与截图断言，改为实际选择命名配置并提交后检查标准结果。定向首项 `run-hcdx4r` exit0，随后同文件完整矩阵 `run-4mkEfE` 为34通过、exit0。

## 首轮候选本地门禁（历史）

固定 Flutter 提交 `5fc346839b5d0eef006ed8404392afb4dfae428d` / Dart3.13.5，Socktainer 容器 `ghostmodeldeck-checks-r33b`，按锁文件联网 pub get。容器独占、检查串行，无离线模式和远端 CI。

以下为首轮候选 `21f8cfb3c156b4753a6b5baec0d3cec8fe1c6817` 的历史正式门禁，不能代替审查修复后输入的检查。命令均从指定容器主进程 runner 执行，退出码从保存的 exit 文件核对：

| 命令（均带 `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`） | 证据目录 | 实际结果 |
| --- | --- | --- |
| `./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | `run-3PcQ04` | 79 files、0 changed、exit0 |
| `./scripts/test-container.sh analyze` | `run-wJem0f` | No issues found、exit0 |
| `./scripts/test-container.sh test` | `run-1UInQs` | 453 tests passed、0 failed、exit0 |

首轮87个检查输入的内容指纹为 `35f35f3df840ce677faa8ec4c3c5f89e335f2b3e0d70220b836fa701290bdda1`。该历史指纹使用逐行路径/哈希编码；当前输入的逐文件 SHA256 和编码见 [输入清单](ghostmodeldeck-named-jev-model-routing-r33-source.json)。范围包含 lib/test/benchmarks 与 pubspec/lockfile/analysis_options，和 runner 的输入范围一致。

最新集成分支 `codex/jev-protocol-playground` 与当前基线均为 `888b41490ccc303dee62fbadea564c4ffd1aed60`；执行正常 merge 返回 Already up to date，无源码差异。首轮门禁及合并结果保留为历史证据；审查修复后的当前门禁见下方记录。GitHub/远端业务由主线程后续阶段执行，本工作树仅产生本地提交。


## 首轮双轴审查修复

审查基于首轮候选 `21f8cfb3c156b4753a6b5baec0d3cec8fe1c6817`。Standards 轴原顺序为原生取消窗口、持久化退出排空两项 P2；Spec 轴原顺序为不可用绑定编辑丢失、重复的原生取消窗口两项 P2，共三个独立缺陷。[审查与复盘记录](ghostmodeldeck-r33-review-and-retro.md) 保留两个轴的原顺序和脚本故障证据。

| 缺陷 | 首个原始错误与修复 | 真实定向与模块结果 |
| --- | --- | --- |
| 原生通知事件取消后仍返回正常结果 | 公开 `engine.changes` 首次发布 `lastBatchResult` 时取消 token，`run-H5VFhz` exit1 仍返回 answers。仅加 await 后检查的 `run-s3LhuV` 仍 exit1；让已排队结果通知先送达，再复核 token 和退出状态。 | `run-yAGgMM` exit0；原生、协议和 MCP 相关文件 `run-zZ4P15` 28项通过、exit0。 |
| 配置持久化未纳入退出排空 | 仅在真实文件 I/O 边界延迟写入，`run-OBQITw` exit1 显示写入未完成时 shutdown 已完成。登记关闭新准入，等待已接纳写入/删除/恢复，持久化错误向 shutdown/close 传播。 | 原失败用例 `run-cqaDFs` exit0；`run-YlPp6G` 4项生命周期用例通过、exit0。 |
| 编辑不可用成员时静默丢失绑定 | 真实模型库移除 B 后，`run-pmAmye` exit1 显示只有1项，期望保留2项。编辑器持有已有绑定快照，显示不可用项；改名/预算必须先明确移除该项，否则拒绝保存并保留磁盘原配置。 | 首次绿尝试 `run-kV6ytr` exit1 为测试查找器误选后台标签，限定对话框后 `run-hB0n0w` exit0；页面文件 `run-gVRNE7` 2项通过。异步清理适配后 `run-CeaNGC` 2项通过、exit0。 |

`CouncilController.close` 返回的 Future 已在需要完成清理的生产 benchmark、桌面/SDK fixture 和 Widget 清理入口等待；`addTearDown` 直接接收 Future 回调。Widget I/O 使用既有 `tester.runAsync`。页面 dispose 保留显式 `unawaited` 与错误处理，正式退出仍由 `ManagerLifecycle` 等待 shutdown 并报告持久化错误。

最小受影响模块命令为 `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh test --no-pub test/jev_registry_lifecycle_test.dart test/jev_models_test.dart test/jev_protocol_test.dart test/jev_model_page_test.dart test/council_page_test.dart test/manager_lifecycle_test.dart test/mcp_page_test.dart`，`run-Jgu8VU` 39项通过、exit0。此处 `--no-pub` 前 runner 已执行联网 pub get。后续页面清理输入变化由 `run-CeaNGC` 再次覆盖，旧绿没有复用为新输入的检查。

复盘的两个脚本 P2 由主线程修复：作业上传先核对内容哈希再发布，桌面启动保护识别已安装的运行实例。`bash -n`、`git diff --check` 与真实外部 I/O 故障/保护干跑结果见上述复盘记录；故障用例中的预期 exit1 不算产品门禁通过。

## 审查修复后的本地门禁

主线程通过新 runner 的格式干跑 `run-JKH7mI` 为80文件/0改动、exit0；随后正式 analyze `run-VweOGF` exit1，在 `lib/jev_models.dart:230` 首报多行 if 缺少块，共3项同类诊断。逐项加块后源码指纹变化，旧格式绿只作为历史证据；当前格式/分析/全套测试重新覆盖同一最终输入。

同一固定工具链、锁文件和独占容器通过新 runner 串行执行正式命令，均由归档的原始 exit 文件核对：

| 命令（均带 `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`） | 证据目录 | 实际结果 |
| --- | --- | --- |
| `./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | `run-rnOkh6` | 80 files、0 changed、exit0 |
| `./scripts/test-container.sh analyze` | `run-9e2het` | No issues found、exit0 |
| `./scripts/test-container.sh test` | `run-hS6CRq` | 459 tests passed、0 failed、exit0 |

三次门禁归档的88个输入逐文件 SHA256 与当前内容完全相等，按 sorted compact JSON 的路径→SHA256 映射编码，内容指纹为 `c681cd6f2c6ca44de0f9014790479ec848c78322dd90acdffe8eaa592ace6d4e`。详细输入、真实命令、结果、归档哈希、工具链、复盘脚本哈希及历史候选记录见 [输入与检查清单](ghostmodeldeck-named-jev-model-routing-r33-source.json)。最终门禁后只更新本阶段文档，没有改 lib/test/benchmarks 或检查脚本输入。

当前复盘脚本 SHA256 仍与主线程交付完全相等：`test-container.sh` 为 `2287146911a50228bf0d7f4036dac5945096c8d4cbd9fc287be1026ad5d9ce34`，`run-desktop.sh` 为 `bb368ffb477a027fe248b5d41e24a994f0be18c60227761c1ec7bdf845c8a0e6`。本地 `bash -n scripts/test-container.sh scripts/run-desktop.sh` 和 `git diff --check` 再次 exit0；复盘的原始外部 I/O 故障证据保留在主工作区 `.tooling/verification/stage33-retro/`。

最新本地集成分支仍为 `888b41490ccc303dee62fbadea564c4ffd1aed60`，正常 merge 再次返回 Already up to date。三个已确认产品 P2 与两个复盘脚本 P2 已闭合，本地无未闭合失败、有效长作业或远端补验缺口。完整 stage diff 将交回主线程复审；本分支仅本地提交，不推送或创建 PR。


## 验证范围

以上证据验证生产业务、标准转换、持久化、生产 Widget 布局与本机协议往返。原生进程/引擎 wire 位于已确认的外部 I/O 替身边界，不能代替 Mac 真模型推理、概率质量、真实客户端和完整 Release 验收。没有修改版本号、tag、Release 或已确认规格，也没有实施普通 Chat 输出转换、llama/oMLX/SSE 专项能力或后续完整原生 JSON 与完整测试场交互。

## bootstrap 清理修复后的最终工程门禁

二次 Standards 复审发现 bootstrap 发布失败遗留本次新建等待容器的 P2，按 E04 完成清理及原始失败传播。真实红、同类真实绿、既有容器保留、清理失败独立报告的证据和环境故障记录见 [阶段复盘](ghostmodeldeck-r33-review-and-retro.md)。本轮只修改 `scripts/test-container.sh` 与验证文档，没有修改 lib/test/benchmarks 或 `run-desktop.sh`。

最终 runner SHA-256 为 `38092ead45f6164bb26d52ad6bbfe47de86a1b014034192e428f24f7bba27f6f`。在独占的 `ghostmodeldeck-checks-r33b` 中逐个作业重跑以下完整门禁；每次均先联网 pub get，宿主 runner 与容器 job 的真实退出码均为 0。

| 命令 | 证据目录 | 结果 |
| --- | --- | --- |
| `./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | `run-8Tibw3` | 80 files、0 changed、exit0 |
| `./scripts/test-container.sh analyze` | `run-Wet3Bh` | No issues found、exit0 |
| `./scripts/test-container.sh test` | `run-LE7NLG` | 459 tests passed、0 failed、exit0 |

三次归档的 88 个输入逐文件 SHA-256 与当前工作树及既有清单完全相等，内容指纹仍为 `c681cd6f2c6ca44de0f9014790479ec848c78322dd90acdffe8eaa592ace6d4e`；最终脚本变化由本轮三项门禁重新覆盖。归档哈希、日志哈希、作业哈希和 runner 哈希见 [输入与检查清单](ghostmodeldeck-named-jev-model-routing-r33-source.json)，上一轮 `run-rnOkh6` / `run-9e2het` / `run-hS6CRq` 已保留为修复前历史。本轮故障探针均为检查脚本公开 I/O 与资源生命周期证据，不能替代真实模型和客户端验收。
