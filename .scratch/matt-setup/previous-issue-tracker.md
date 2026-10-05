# Issue 跟踪器：本地 Markdown

仓库当前未配置外部 issue tracker，按 Wayfinder 默认使用本地 Markdown。以后可运行 `$setup-matt-pocock-skills` 选择 GitHub 等 tracker；切换时迁移现有地图，避免产生两个规范来源。

## Wayfinding operations / 寻路操作

- 地图：`.scratch/<effort>/map.md`，标签 `wayfinder:map`。
- 子工单：`.scratch/<effort>/issues/NN-<slug>.md`，有稳定 ID、Title、Parent、Type、Label、Mode、Status、Assignee、Executor 和 Blocked by。
- `Status: open` 表示未认领；开始处理前改为 `claimed` 并填写 Assignee 与 Executor；解决后为 `resolved`。HITL 必须由用户参与，不可替用户回答。
- 本地文件无原生依赖 API。`Blocked by` 记录子工单 ID；列出的工单全部 resolved 才能领取。
- frontier 是 open、所有阻塞已 resolved、Assignee 为空的子工单，按 ID 顺序选择。不要把开放工单复制到地图正文。
- 答案追加到工单的 `## Answer`；会话和来源指针放 `## Comments`。地图的 Decisions so far 只增加带名称链接的一行摘要。
- 改动前检查文件是否已被另一会话认领。研究报告保存到 `docs/research/`，工单只链接资产。
- 显示文件、工单和地图时用标题及其链接，不用裸 ID 作为名称。

## 规格与实现交接

- to-spec 的规范产物是 `.scratch/<effort>/spec.md`，使用 `ready-for-agent` 标签，不再重复分诊。
- 如该 skill 要求的测试边界尚待用户确认，规格状态为 `needs-test-boundary-confirmation`；确认后为 `ready-for-agent`。标签不授权跳过状态直接实施。
- 规格就绪后由 to-tickets 生成独立实现工单，再由 implement 按依赖领取；决策工单不作为实现工单复用。
- 本项实现工单位于 `.scratch/jevmanager-build/issues/`，从 01 编号，父规格保持 `.scratch/jevmanager/spec.md` 的唯一来源；`.scratch/jevmanager/issues/` 仅保留已完成的决策工单。
- 实现工单严格采用 to-tickets 的本地模板：标题、要构建什么、被什么阻塞、状态及验收复选项。只有阻塞项已完成的 ready-for-agent 工单属于 frontier。
