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
| 2. 多配置 CRUD、独立超时、持久恢复 | `jev_models_test.dart` 离线创建 quick/hard、不同成员/预算、重新构造控制器加载文件、重命名与删除；`jev_model_page_test.dart` 实际对话框创建/编辑/删除。生产没有预设 quick/hard 或难度策略。 |
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

## 最终本地门禁

固定 Flutter 提交 `5fc346839b5d0eef006ed8404392afb4dfae428d` / Dart3.13.5，Socktainer 容器 `ghostmodeldeck-checks-r33b`，按锁文件联网 pub get。容器独占、检查串行，无离线模式和远端 CI。

最终正式命令与结果如下，均从指定容器主进程 runner 执行，退出码从保存的 exit 文件核对：

| 命令（均带 `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`） | 证据目录 | 实际结果 |
| --- | --- | --- |
| `./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | `run-3PcQ04` | 79 files、0 changed、exit0 |
| `./scripts/test-container.sh analyze` | `run-wJem0f` | No issues found、exit0 |
| `./scripts/test-container.sh test` | `run-1UInQs` | 453 tests passed、0 failed、exit0 |

最终87个检查输入的内容指纹为 `35f35f3df840ce677faa8ec4c3c5f89e335f2b3e0d70220b836fa701290bdda1`，每个文件的 SHA256 见 [输入清单](ghostmodeldeck-named-jev-model-routing-r33-source.json)。包含 lib/test/benchmarks 与 pubspec/lockfile/analysis_options，和 runner 的输入范围一致。门禁完成后逐文件核对指纹没有变化；后续只填写本文的结果记录。

最新集成分支 `codex/jev-protocol-playground` 与当前基线均为 `888b41490ccc303dee62fbadea564c4ffd1aed60`；执行正常 merge 返回 Already up to date，无源码差异。保留上述真实失败历史，无未闭合本地失败、未完成测试或远端补验需求。GitHub/远端业务由主线程后续阶段执行，本工作树仅产生本地提交。


## 验证范围

以上证据验证生产业务、标准转换、持久化、生产 Widget 布局与本机协议往返。原生进程/引擎 wire 位于已确认的外部 I/O 替身边界，不能代替 Mac 真模型推理、概率质量、真实客户端和完整 Release 验收。没有修改版本号、tag、Release 或已确认规格，也没有实施普通 Chat 输出转换、llama/oMLX/SSE 专项能力或后续完整原生 JSON 与完整测试场交互。
