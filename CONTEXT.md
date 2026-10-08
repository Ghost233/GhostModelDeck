# Ghost Model Deck

Ghost Model Deck 是统一管理现成模型及多种推理引擎的桌面应用。JEV 委员会是其中一种专用能力，不能代表全部模型的用途。

> 本文件记录新项目的领域词汇，不表示对应能力已经实现。JevManager 的原始术语保存在 [来源快照](docs/migration/jevmanager-source/CONTEXT.md)。

## 语言

**模型能力（Model Capability）**：模型与推理引擎组合能够提供的用途，例如标准 LLM、JEV 决策、OCR、图像生成或视频生成。能力名称与引擎名称是不同概念。

**标准 LLM 能力（Standard LLM Capability）**：由语言模型生成文本回答的能力。它不自动包含 JEV 决策所需的结构化候选项概率。

**JEV 决策能力（JEV Decision Capability）**：对上下文和明确候选项提供结构化判断、供委员会咨询使用的专用能力。是否具有真实概率取决于具体模型资产和推理引擎。

**决策模型（Decision Model）**：对给定上下文和明确候选项提供结构化判断的现成模型。它是否能提供原始概率，需要具体权重与引擎的证据。

**模型资产（Model Artifact）**：一个模型的具体发布版本及其权重、分词器、决策头等必要文件。相同模型名称的不同资产不必具有相同兼容性。

**模型包（Model Package）**：用户选择、下载和管理的一个模型及其完整配套资产集合。单个权重文件或分片只是包的组成部分。

**模型变体（Model Variant）**：同一模型包下的格式或量化版本。选择一个变体不表示选择该仓库的所有精度版本。

**推理引擎（Inference Engine）**：能够加载特定模型资产并提供相应模型能力的运行程序。同一个引擎可以承载不同能力，并非所有引擎都支持所有模型。

**引擎安装（Engine Installation）**：本机登记的一份具体版本推理引擎及其必要运行环境。它可以由 GhostModelDeck 安装，也可以关联本机已有安装。

**引擎服务（Engine Service）**：一次实际运行的推理引擎，可承载一个或多个模型推理实例。其生命周期独立于模型文件与引擎安装。

**启动器服务（Launcher Service）**：由 MacLauncher 统一管理的一组 GhostModelDeck 业务资源。其稳定身份不随具体模型或引擎进程的启停改变。

**启动模型集合（Startup Model Set）**：用户在 GhostModelDeck 中明确选定的一组模型运行组合，用于推理服务的显式启动。

**模型安装（Model Installation）**：本机已下载并具有完整性记录的一组模型资产。

**模型库目录（Model Library Directory）**：用户指定、独立于应用的本地模型资产存放位置。它可以由 GhostModelDeck 独用，也可以与 LM Studio 等应用共用；应用的替换不改变其中模型文件的位置或所有权。

**HF 模型搜索（HF Model Search）**：用户按关键词或仓库定位 Hugging Face 上可下载模型资产的入口。搜索结果不是本机可运行或决策兼容的证明。

**本地发现资产（Discovered Artifact）**：在用户指定模型库中识别出的既有模型文件或文件组。被发现不等于资产完整、兼容或推理就绪。

**推理实例（Inference Instance）**：一个已选模型安装在引擎服务中的运行组合，其可用模型能力需要分别验证。模型已安装不代表推理实例已就绪。

**公开模型标识（Public Model ID）**：客户端用于选择已登记模型运行组合或委员会模型的稳定标识。它与引擎原生模型名称、模型文件路径分别表达不同身份。

**调用模型名（API Model Name）**：客户端用来选择委员会模型或原生 JEV 模型的唯一名称，标识所请求的决策来源，是 JEV 调用使用的公开模型标识。

**本地 API 入口（Local API Entry）**：客户端访问 GhostModelDeck 模型能力的统一服务入口。它将公开模型标识映射到本应用管理的实际推理实例或委员会来源。

**受管实例（Managed Instance）**：由 GhostModelDeck 创建并负责其启动与停止的推理实例。

**接入实例（Attached Instance）**：由其他应用或用户预先创建、GhostModelDeck 连接使用的推理实例。连接使用不改变其生命周期归属。

**委员会（Council）**：对同一决策请求提供多份意见的一组席位。

**席位（Seat）**：委员会中的一个意见来源。同底座模型的多个席位不自动等于相互独立的意见。

**决策请求（Decision Request）**：提交给原生 JEV 模型或委员会的上下文、问题和候选项。

**委员会咨询结果（Council Consultation）**：各席位的判断及其聚合和分歧信息，供主模型作最终判断。

**综合评分（Aggregate Score）**：多个有效席位对同一候选项给出的概率经委员会规则综合后得到的评分。它不表示该候选的真实正确率。

**席位分歧（Seat Disagreement）**：有效席位在首选候选项上的差异。它不等同于模型独立性或评分校准质量。

**主模型（Main Model）**：提出决策咨询并结合委员会综合结果作最终判断的大模型。
_同义称呼_：大模型。

**MCP 接入（MCP Connection）**：主模型客户端通过 MCP 调用 GhostModelDeck JEV 决策能力的连接关系，决策来源可以是原生模型或委员会。

**推理测试场（Inference Playground）**：应用内用于提交推理输入并检查模型或委员会输出的交互区域。
_同义称呼_：测试场。

**虚拟 JEV 引擎（Virtual JEV Engine）**：把委员会作为一个决策来源向客户端呈现的模型能力，使用 JEV 兼容结果表达委员会的综合判断。

**协议转换器（Protocol Converter）**：将引擎推理结果或委员会综合结果表达为客户端所需协议的应用能力。

**JEV 判断题型（JEV Primitive）**：JEV 咨询的三种问题形式：choice 对明确候选项作选择，score 对有序级别作评分，noul 对明确的真假含义作判断。

**推理调试结果（Inference Debug Result）**：用于核对一次推理调用的实际输入、原始响应及委员会判断依据的诊断信息。

**委员会模型（Council Model）**：客户端按模型标识调用的 JEV 决策来源，其判断由对应的委员会配置组织席位产生。
_同义称呼_：虚拟 JEV 模型。

**委员会配置（Council Profile）**：用户保存的一组席位选择与咨询设置，决定对应委员会模型如何组织判断。

**原生 JEV 模型（Native JEV Model）**：由一个实际 JEV 决策模型提供判断的决策来源；单独调用时使用该模型的结果。

**引擎默认启动配置（Engine Launch Defaults）**：用户为特定引擎保存的默认启动选项。

**模型启动覆盖（Model Launch Overrides）**：用户为特定模型变体与具体引擎组合指定的启动选项，覆盖对应引擎的默认启动配置。

**启动参数文本（Launch Argument Text）**：用户直接填写的引擎启动选项文本；与参数表单中的同名选项冲突时，以文本为准。

**最终启动参数（Effective Launch Arguments）**：本次启动在应用用户配置与软件管理字段后实际采用的启动选项。

**未关联启动配置（Unlinked Launch Configuration）**：原引擎解除关联后仍保留的启动配置，可由用户在重新关联时选择恢复。
