# JevManager：现成决策模型桌面管理与 MCP 委员会路线图

ID: jevmanager-map
Label: wayfinder:map
Status: resolved
Owner: Ghost233

## Destination

为 JevManager 的完整首版形成可实施、可验收的规格与决策：多个 Jev 类决策模型对同一请求并发判断，汇总各模型意见、综合结果与分歧，通过 MCP 返回给大模型作最终判断；标准 Flutter 桌面应用负责模型下载、目录与识别、引擎及委员会管理。macOS 优先，首先接入 Codex。最终交付方向是可运行的整套产品；本轮地图的终点是清除构建前的关键不确定性。

## Notes

- 用户已确定：标准 Flutter 桌面应用；macOS 优先；Codex 为首个 MCP 客户端；首个用途是通用候选项决策。通用 Dart/widget 测试保持容器边界；Mac 推理、Flutter 专属构建及桌面/引擎/MCP 联调的明确例外见生命周期工单答案。
- 用户进一步明确核心要求：多个 Jev 类模型接收同一决策请求并发判断，JevManager 综合结果后经 MCP 返回给发起咨询的大模型。返回内容保留各席位意见及综合与分歧信息；具体规则见委员会工单答案。
- 用户新增首版要求：支持 LM Studio 下载代理选项；模型存放路径可设置，可与 LM Studio 目录共用；正确识别本地模型；本地引擎管理。相关开放决定在子工单推进，不在 Notes 复制决定详情。
- 使用 `wayfinder`、`grilling`、`domain-modeling`；研究工单使用 `research`；界面验证使用 `prototype`。
- 零训练，使用别人已发布的现成权重。下载、模型加载和推理测试必须分别验收。
- 用户粘贴对话中的模型名称、排名、内存及兼容性说法全部是待核实线索；模型卡自报与本机实测分开记录。
- 绘图会话已完成地图与 AFK 研究；后续按 frontier 推进，每个会话最多解决一项 HITL 决策，由用户参与确定，不把尚未回答的产品问题当作已决定。
- prototype 工单包含的一次性代码只用于形成界面/操作路径决定，不等于正式实现。用户反馈已记录、所有决策工单已解决，地图交接 to-spec；正式实现未开始。
- 交接产物为 [JevManager 首版规格](spec.md)，测试边界已由用户确认，to-spec 已完成。下一阶段进入 to-tickets，不复用决策工单作实现任务。
- 研究产物保存在当前 main 工作区的 `docs/research/`。用户 Git 规则优先于 skill 的一次性 research 分支建议，不创建额外分支或 worktree。
- 不下载大权重、不安装宿主项目依赖、不更改运行时和客户端设置、不提交或推送，除非后续执行范围要求这些行动。研究阶段不能声称服务已跑通。
- 本地 tracker 规则见 [Issue 跟踪器：本地 Markdown](../../docs/agents/issue-tracker.md)，领域语言见 [JevManager 术语表](../../CONTEXT.md)。

## Decisions so far

<!-- 每张已解决工单仅一行摘要和带名称的链接。 -->

- [核实 MCP 接入与决策接口契约](issues/02-mcp-contract-evidence.md) — Codex 接入入口与 MCP/SDK 版本边界已有一手证据，传输和产品契约仍待决定与实调验收。
- [核实现成模型资产与可运行引擎](issues/01-model-runtime-evidence.md) — 四个模型家族已有固定资产与引擎矩阵；GGUF 后缀不足以判定兼容，中文与委员会收益仍需实测。
- [核实 Flutter macOS 构建与引擎打包边界](issues/03-desktop-packaging-evidence.md) — 标准 Flutter 的 Mac 构建、helper 与共享目录访问约束已有证据；宿主验收范围和发行方式仍待决定。
- [核实 LM Studio 下载及共享模型目录与引擎集成](issues/08-lmstudio-integration-evidence.md) — 官方管理接口与代理小文件通路已查明；目录共享可行性与模型识别有依据，大文件下载和 decision 引擎能力仍待验收。
- [确定模型下载与安装规则](issues/04-download-install-policy.md) — 本应用自行下载，通过 HF 搜索/仓库选文件并保留本地扫描；共享已有资产可手动删除，下载成功与决策兼容性分开验收。
- [确定桌面与推理及 MCP 的生命周期](issues/05-desktop-lifecycle.md) — LM Studio 优先、必要时补兼容引擎；关窗继续、退出停止受管实例；本机 HTTP MCP 与非 App Sandbox `.app`，Mac 构建及联调例外已明确。
- [确定委员会语义与真实验收标准](issues/06-council-acceptance.md) — 可配置席位，先验证两席并发；等权综合保留原始意见与分歧，10 秒截止返回部分结果，先用中文合成案例验收。
- [验证桌面管理的完整操作路径](issues/07-desktop-flow-prototype.md) — 用户否决原三方案，确定 oMLX 式紧凑管理、HF 搜索选文件、无初始化教程及长说明；正式界面仍需按规格实现与验收。

## Not yet specified

构建前的产品决定已明确，没有剩余 frontier。模型/引擎真实性、中文表现、资源占用、下载来源和目录规模属于正式规格中的实施验证，未被宣称为已通过；验证失败时再开针对实际证据的决策工单。

## Out of scope

- 训练或微调模型、声称提供本项目自研权重。
- 在没有实测数据时承诺固定排行榜、三席独立性、约 5GB 内存或 20 分钟验收。
- 云端托管、团队多租户和远程访问；当前目标是本地应用。
- 委员会自行执行主模型选定的外部动作；首个用途是返回咨询意见。
- 首版公开分发、公证、App Store 沙盒与其他桌面平台；用户已选先交付本机 `.app`，见 [确定桌面与推理及 MCP 的生命周期](issues/05-desktop-lifecycle.md)。
