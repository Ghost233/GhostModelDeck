# JevManager

## GitHub 账户（强制）

- 本仓库的 GitHub 业务操作仅允许使用 **Ghost233** 账户，包括 `gh`、GitHub 连接器和 Git 远端操作。
- 使用 `gh` 前，运行 `gh api user --jq .login` 核验有效身份；使用连接器前，核验该连接器的实际账户。Git remote 中的用户名、commit author 和保存的活动账户名称不能代替有效身份核验。
- 身份不是 Ghost233 时，停止 GitHub 业务操作。已有登录可执行 `gh auth switch --hostname github.com --user Ghost233`；没有登录则由用户完成 Ghost233 登录，再重新核验。身份检查、登录和账户切换仅用于满足此护栏。
- Git 远端写操作还必须确认实际使用的认证凭据属于 Ghost233；不以 `gh` 身份推断独立 Git credential helper 的身份。
- 保留其他账户的既有凭据，不用其他账户作为回退，不把密码或 token 写入文件、命令输出或聊天。

## Agent skills

### Issue 跟踪器

执行读写工单、规格或 Wayfinder 地图的工程 skill 前，读取 `docs/agents/issue-tracker.md`；规范跟踪器为 Ghost233/JevManager 的 GitHub Issues，账户遵守上方 Ghost233 护栏。

### 分类标签

分类或设置工单角色前，读取 `docs/agents/triage-labels.md`；采用默认五个分类角色，按映射使用实际标签。

### 领域文档

探索或修改领域行为前，读取 `docs/agents/domain.md`；采用单上下文的根 CONTEXT.md 与按需建立的 docs/adr/。
