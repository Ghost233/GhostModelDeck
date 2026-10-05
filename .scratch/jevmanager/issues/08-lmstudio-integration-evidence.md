# 核实 LM Studio 下载及共享模型目录与引擎集成

ID: 08
Title: 核实 LM Studio 下载及共享模型目录与引擎集成
Parent: [JevManager：现成决策模型桌面管理与 MCP 委员会路线图](../map.md)
Type: research
Label: wayfinder:research
Mode: AFK
Status: resolved
Assignee: Ghost233
Executor: model_runtime_research
Blocked by: none

## Question

用户所见的 LM Studio 下载代理是什么，是否有可由本项目使用的公开下载路径？对于用户指定、可能与 LM Studio 共用的目录，官方资料说明了哪些目录布局、完整性和模型发现方式？怎样依据文件元数据而非文件名判断模型资产、架构、决策头及兼容引擎？

调查复用 LM Studio 的运行能力有哪些公开 API/CLI 或 runtime 管理入口；区分调用 LM Studio 管理的服务器、使用其 SDK 管理模型、直接调用其内部引擎。与独立下载固定版本官方 llama.cpp 对比，查明版本、许可证、API 和能力探测边界。不要把“LM Studio 支持 GGUF”推导为“其捆绑引擎支持特定决策模型或 /v1/systemone”。

## Answer

[LM Studio 下载、共享目录与引擎集成证据](../../../docs/research/lmstudio-integration-evidence.md) 已确认官方的模型下载、目录设置、模型清单与 runtime 管理接口。官方发布说明确有 HF proxy；公开日志中的代理路径经固定清单及 README 小文件请求验证，README 校验和与直连一致。该观察不等于长期稳定的第三方接口契约，大权重与断点续传尚未测试。

共享目录可以按用户选择建立清单，不需要默认迁移文件。正确识别应检查真实格式、architecture、decision metadata、head 和必要文件，并区分已识别、完整、兼容与实际就绪。LM Studio 清单可用于对账，不能证明 decision 支持；此次没有找到它公开支持 `/v1/systemone` 的文档。复用其运行能力应走公开接口，独立主线 llama.cpp 则需固定版本和本机验收。

研究已解除下载与引擎集成的事实阻塞。选择下载路径、共享目录写入规则及首版引擎仍由后续 HITL 工单确定。没有扫描用户目录、下载权重或运行服务。

## Comments

- 用户要求支持可配置模型路径与 LM Studio 目录共用、本地识别、本地引擎管理；具体引擎未定。
- 用户已回复：没有名称或 URL，只是在很多软件中见过这一下载选项。由研究查明公开证据，不再要求用户提供未知地址，也不虚构默认镜像地址。
- 由同一模型研究代理顺序复用，先完成“核实现成模型资产与可运行引擎”再处理本项，避免重复下载与兼容性调查。
- 研究报告归属：`docs/research/lmstudio-integration-evidence.md`。不扫描用户模型目录、不下载、不启动或更改 LM Studio，也不修改其设置。
- 2026-10-04：研究完成，区分公开管理接口、已观测代理小文件通路与尚未验收能力。无需用户再提供未知代理地址。
