# Issue 跟踪器：GitHub

规范仓库是 `Ghost233/JevManager`。新 issue、规格和 Wayfinder 地图使用 GitHub Issues；默认通过 gh CLI 操作，执行前先满足根 AGENTS.md 的 Ghost233 身份护栏。

## 账户与目标

- 每次需要认证的 gh 业务命令前，先运行 `gh auth switch --hostname github.com --user Ghost233`，再运行 `gh api --hostname github.com user --jq .login`；有效账户必须是 Ghost233，包括环境 token 覆盖时。
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
- 原生 sub-issue API 的 sub_issue_id 使用子项的 database id。
- 优先使用原生 issue 依赖。添加 blocked_by 的 issue_id 使用阻塞项的 database id，不使用 issue number 或 node id。
- 原生依赖不可用时，用正文的 Blocked by 名称链接表达；所有阻塞项关闭后才能领取。
- frontier 是地图的开放子项中，未分配且不存在开放阻塞项的集合；按地图顺序领取。
- 解决时将答案写为评论，再关闭子项，在地图 Decisions so far 追加一行摘要与名称链接；原型只链接资产。

## 已迁移的规划与实现工单

- [Wayfinder 地图](https://github.com/Ghost233/JevManager/issues/1) 与八张决策已作为解决记录关闭；[首版规格](https://github.com/Ghost233/JevManager/issues/10) 是十张实现工单的父项。
- 领取实现工单时，读取规格的开放 sub-issues、assignees 和 blocked_by；仅领取未分配且所有阻塞项已关闭的工单，按规格顺序选择。
- `.scratch/jevmanager/` 和 `.scratch/jevmanager-build/issues/` 仅保留迁移来源，执行状态与后续答案统一在 GitHub 维护。
- 来源到 GitHub URL 的映射见 `.scratch/github-migration/index.md`；校验记录见同目录 manifest.json，冻结快照位于 sources/。历史快照中的迁移前状态不用于当前领取判断。
