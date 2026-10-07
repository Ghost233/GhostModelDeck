# Issue 跟踪器：GhostModelDeck

当前仓库的本地 Git remote 指向 `Ghost233/GhostModelDeck`。需要 GitHub 业务操作时使用该仓库，实际账户必须按根 AGENTS.md 核验为 Ghost233。首批文档复制没有迁移旧工单；新项目的 Wayfinder 决策、规格和实现工单已独立发布到本仓库。

## 迁移边界

- `Ghost233/JevManager` 的路线图、规格、实现工单和评论属于来源历史；复制本地文档不表示这些工单已迁入 GhostModelDeck。
- `.scratch/jevmanager/`、`.scratch/jevmanager-build/` 与 `.scratch/github-migration/` 保留旧项目规划及来源映射，不用其中旧状态选择新项目工作。
- 原跟踪器文档完整保存在 [来源快照](../migration/jevmanager-source/docs/agents/issue-tracker.md)。
- 新项目规格、地图、分类标签和依赖关系在开展对应工作时按实际仓库状态核验；不要把旧项目 issue 编号作为新仓库工单。

## 后续操作

运行认证 gh 命令前先切换到 Ghost233，再核验实际身份；业务命令明确使用 `--repo Ghost233/GhostModelDeck`，API 使用 `repos/Ghost233/GhostModelDeck/...`。身份与权限不符时停止该操作。

GitHub API 的瞬时错误（TLS handshake timeout、GraphQL 5xx/带错误码的临时失败）直接重试同一操作，通常立即成功；仅当重试仍失败且不是网络可达性问题时，才视为硬故障走诊断流程。

工程 skill 需要读取、创建或发布工单时按其流程执行，标签映射见 [分类标签](triage-labels.md)。已有旧项目链接用于来源引用；没有用户要求时不转移、关闭或重建旧工单。

撰写工单范围与验收标准时，引用仓库文件路径前核验其存在；意图新增文件须明确写「新增」。审查结项时逐条核对验收标准，未覆盖项按缺陷处理。

## Wayfinding operations / 寻路操作

当前地图：[GhostModelDeck：从 JevManager 扩展为多引擎模型管理器的首期决策地图](https://github.com/Ghost233/GhostModelDeck/issues/1)。它是新项目的规范决策入口；开放子工单和阻塞关系以 GitHub 实时状态为准。

实施交接：[GhostModelDeck 首期规格](https://github.com/Ghost233/GhostModelDeck/issues/12) 为规范规格及实现子项父项，[本地工单索引](../implementation-plan.md) 提供顺序。实现切片属于规格父项，不能混入 Wayfinder 决策子项。

- 地图是本仓库带 `wayfinder:map` 标签的单个 issue；子项使用 `wayfinder:research`、`wayfinder:prototype`、`wayfinder:grilling` 或 `wayfinder:task`。
- 使用原生 sub-issues 关联父地图：`POST repos/Ghost233/GhostModelDeck/issues/<map-number>/sub_issues`，`sub_issue_id` 为子项的 database id。
- 使用原生阻塞关系：`POST repos/Ghost233/GhostModelDeck/issues/<number>/dependencies/blocked_by`，`issue_id` 为阻塞项的 database id，不是 issue number 或 node id。
- 读取地图子项：`GET repos/Ghost233/GhostModelDeck/issues/<map-number>/sub_issues`；读取各开放子项的 `dependencies/blocked_by`。frontier 是开放、未分配且没有开放阻塞项的子项，按地图子项顺序选择。
- 开始解决前先分配给 Ghost233。HITL 工单等待开发者本人回答，代理不得代答；AFK 研究可独立进行。
- 答案写入解决评论，再关闭子项。地图的 `Decisions so far` 只追加一行摘要与名称链接，不复制完整结论；开放工单通过子项查询获得，不写入地图正文。
- 工单和地图在所有叙述中使用带链接的完整名称。并行工作时先重新读取最新状态，避免覆盖其他会话更新。
- 若原生关系确实不可用，才退回正文中的名称链接；不得因认证或网络失败把本地草稿当作已发布地图。
