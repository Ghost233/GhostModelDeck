# JevManager

## GitHub 账户（强制）

- 本仓库的 GitHub 业务操作仅允许使用 **Ghost233** 账户，包括 `gh`、GitHub 连接器和 Git 远端操作。
- 每次执行需要认证的 `gh` 业务命令前，先执行 `gh auth switch --hostname github.com --user Ghost233`，再执行 `gh api --hostname github.com user --jq .login`；只有有效身份为 Ghost233 才继续，设置了 GH_TOKEN 或 GITHUB_TOKEN 时同样核验。
- 使用连接器前，核验该连接器的实际账户。Git remote 中的用户名、commit author 和保存的活动账户名称不能代替有效身份核验。
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

## 工程规范

- 修改 Dart、Flutter、原生桥接或检查脚本前，读取 [工程规范](docs/engineering.md)，执行与改动相关的检查并报告实际结果。
- 审查时以工程规范核对代码标准，以 `docs/spec.md` 和来源工单核对产品行为；例外必须说明适用规则、原因及验证结果。
