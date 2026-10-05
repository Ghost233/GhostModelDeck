# JevManager

JevManager 是管理现成决策模型并向主模型提供委员会咨询的桌面应用。此处的 JevManager 指本项目，不指 TypeSafe 的 Jev 产品，也不表示本项目训练了自己的模型。

## 语言

**决策模型（Decision Model）**：对给定上下文和明确候选项提供结构化判断的现成模型。它是否能提供原始概率，需要具体权重与引擎的证据。

**模型资产（Model Artifact）**：一个模型的具体发布版本及其权重、分词器、决策头等必要文件。相同模型名称的不同资产不必具有相同兼容性。

**推理引擎（Inference Engine）**：能够加载特定模型资产并计算决策结果的运行程序。

**模型安装（Model Installation）**：本机已下载并具有完整性记录的一组模型资产。

**模型库目录（Model Library Directory）**：用户指定的本地模型资产存放位置。它可以由 JevManager 独用，也可以与 LM Studio 等应用共用；目录中的文件不因此自动归 JevManager 管理。

**HF 模型搜索（HF Model Search）**：用户按关键词或仓库定位 Hugging Face 上可下载模型资产的入口。搜索结果不是本机可运行或决策兼容的证明。

**本地发现资产（Discovered Artifact）**：在用户指定模型库中识别出的既有模型文件或文件组。被发现不等于资产完整、兼容或推理就绪。

**推理实例（Inference Instance）**：一个已选模型安装与其引擎的运行组合。模型已安装不代表推理实例已就绪。

**受管实例（Managed Instance）**：由 JevManager 创建并负责其启动与停止的推理实例。

**接入实例（Attached Instance）**：由其他应用或用户预先创建、JevManager 连接使用的推理实例。连接使用不改变其生命周期归属。

**委员会（Council）**：对同一决策请求提供多份意见的一组席位。

**席位（Seat）**：委员会中的一个意见来源。同底座模型的多个席位不自动等于相互独立的意见。

**决策请求（Decision Request）**：提交给委员会的上下文、问题和候选项。

**委员会咨询结果（Council Consultation）**：各席位的判断及其聚合和分歧信息，供主模型作最终判断。

**综合评分（Aggregate Score）**：多个有效席位对同一候选项给出的概率经委员会规则综合后得到的评分。它不表示该候选的真实正确率。

**席位分歧（Seat Disagreement）**：有效席位在首选候选项上的差异。它不等同于模型独立性或评分校准质量。

**主模型（Main Model）**：提出决策咨询并结合委员会综合结果作最终判断的大模型。
_同义称呼_：大模型。

**MCP 接入（MCP Connection）**：主模型客户端通过 MCP 调用 JevManager 咨询能力的连接关系。
