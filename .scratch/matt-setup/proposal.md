# Matt skills 仓库设置草稿

Status: applied
Choices: GitHub Issues / 默认五个分类标签 / 单上下文 / AGENTS.md / 仅 Ghost233

用户确认所有选项并指定 AGENTS.md 与 Ghost233 账户。草稿已展示，Agent skills 区块和三个配置文件已写入；保留之前本地 tracker 配置作为迁移来源。

## AGENTS.md 将补充的区块

```markdown
## Agent skills

### Issue 跟踪器

执行读写工单、规格或 Wayfinder 地图的工程 skill 前，读取 `docs/agents/issue-tracker.md`；规范跟踪器为 Ghost233/JevManager 的 GitHub Issues，账户遵守上方 Ghost233 护栏。

### 分类标签

分类或设置工单角色前，读取 `docs/agents/triage-labels.md`；采用默认五个分类角色，按映射使用实际标签。

### 领域文档

探索或修改领域行为前，读取 `docs/agents/domain.md`；采用单上下文的根 CONTEXT.md 与按需建立的 docs/adr/。
```

## docs/agents/issue-tracker.md 草稿

```markdown
# Issue 跟踪器：GitHub

规范仓库是 `Ghost233/JevManager`。新 issue、规格和 Wayfinder 地图使用 GitHub Issues；默认通过 gh CLI 操作，执行前先满足根 AGENTS.md 的 Ghost233 身份护栏。

## 账户与目标

- 先运行 `gh api user --jq .login`，有效账户必须是 Ghost233。
- 命令明确指定 `--repo Ghost233/JevManager`；API 使用该仓库路径。
- 身份不符、Ghost233 未登录或写权限不足时停止相关 GitHub 业务操作，完成不受影响的本地工作并报告具体条件，不改用其他账户。
- 多行正文写入任务临时文件，以 `--body-file` 传入；不把内容拼接为可执行 shell 文本。

## 操作约定

- 创建：`gh issue create --repo Ghost233/JevManager --title <title> --body-file <body-file>`。
- 读取：`gh issue view <number> --repo Ghost233/JevManager --comments`，同时获取标签。
- 列表：`gh issue list --repo Ghost233/JevManager --state open --json number,title,body,labels,assignees`，按角色与任务范围过滤。
- 评论：`gh issue comment <number> --repo Ghost233/JevManager --body-file <comment-file>`。
- 标签：`gh issue edit <number> --repo Ghost233/JevManager --add-label <label>`，映射见 triage-labels.md。
- 关闭：先记录完成证据或决定评论，再 `gh issue close <number> --repo Ghost233/JevManager`。
- 领取：核准身份后用 `gh issue edit <number> --repo Ghost233/JevManager --add-assignee @me`；这是领取工单的第一次写操作。

## 把 Pull Request 作为分类入口

**把 PR 作为请求入口：no。** 当前不把外部 PR 自动加入功能请求分类队列。

## 发布与读取

skill 要求发布到 tracker 时创建 GitHub issue；要求获取工单时读取该 issue 正文、评论和标签。to-spec / to-tickets 输出使用 ready-for-agent，不重复分诊。

## Wayfinding operations / 寻路操作

- 地图是带 wayfinder:map 标签的单个 issue；子项为 GitHub sub-issue，使用 wayfinder:research / prototype / grilling / task。
- 原生 sub-issues 可用时关联父地图；不可用时在子项引用地图，并在地图维护名称链接。
- 优先使用原生 issue 依赖。添加 blocked_by 的 issue_id 使用阻塞项的 database id，不使用 issue number 或 node id。
- 原生依赖不可用时，用正文的 Blocked by 名称链接表达；所有阻塞项关闭后才能领取。
- frontier 是地图的开放子项中，未分配且不存在开放阻塞项的集合；按地图顺序领取。
- 解决时将答案写为评论，再关闭子项，在地图 Decisions so far 追加一行摘要与名称链接；原型只链接资产。

## 现有本地资料与迁移边界

- 既有 `.scratch/jevmanager/` 的地图、规格、决策和来源，以及 `.scratch/jevmanager-build/` 的十张实现工单均保留。
- 本轮设置只写仓库配置，不创建远端标签、不迁移既有事项、不启动实现、不提交或推送。
- Ghost233 身份与仓库写权限核验通过后，迁移需单独确定范围并维护本地来源到 GitHub URL 的映射。
- 在迁移完成前，既有本地文件作为只读的规划依据，不把它们声称为已发布 GitHub issue，也不维护两套可写工单状态。启动原有实现流程前先完成迁移和 frontier 核对。
```

## docs/agents/triage-labels.md 草稿

```markdown
# 分类标签

| 规范角色 | GitHub 标签 | 含义 |
| --- | --- | --- |
| needs-triage | needs-triage | 维护者需要评估 |
| needs-info | needs-info | 等待补充信息 |
| ready-for-agent | ready-for-agent | 规格完整，可由代理处理 |
| ready-for-human | ready-for-human | 需要人类实施 |
| wontfix | wontfix | 不会处理 |

五个角色使用同名标签。已有 wontfix 复用；其他角色若未存在，后续由核准的 Ghost233 账户按需创建，不创建重复别名。

这些是分类角色。Wayfinder 类型标签与 blocked_by、assignee、open/closed 状态分别表达不同含义；ready-for-agent 不代表没有阻塞。
```

## docs/agents/domain.md 草稿

```markdown
# 领域文档

当前采用单上下文。根 CONTEXT.md 是术语表；相关 ADR 按需位于 docs/adr/。保留已有 CONTEXT.md，不创建空的 CONTEXT-MAP.md 或 ADR。

## 探索前读取

- 先读取根 CONTEXT.md；输出、工单和测试使用其中的领域词汇。
- 读取与当前工作相关的 docs/adr/。若以后出现 CONTEXT-MAP.md，按其指针读取相关上下文。
- 不存在的领域文件静默跳过；术语或真实架构取舍明确时再使用 domain-modeling 按需补充。
- 新术语在确定时更新术语表；实现细节留在规格/代码，不放入 CONTEXT.md。
- 若工作与现有 ADR 冲突，指出具体 ADR 和冲突，不静默覆盖。
```

## 本轮写入与保留

- 在现有账户护栏后补充单个 Agent skills 区块。
- 以 GitHub 种子模板更新 issue-tracker，增加已确认的目标仓库与现有资料迁移边界。
- 新建标签映射和领域读取规则；现有术语表、地图、规格、工单及原型来源保留。
- 用户本人完成登录切换后，已核验 gh 有效账户为 Ghost233、目标仓库权限为 ADMIN。远端标签创建和事项迁移尚未执行。
