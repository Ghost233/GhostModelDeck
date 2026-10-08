# GhostModelDeck 标准发布流程

仅在用户明确要求正式发布时执行 `scripts/release.sh`。编辑发布 skill、脚本或 workflow 只完成编辑与验证。版本规则的唯一来源是 [发布版本号规则](../release-versioning.md)。

## 发布前

1. 由人手动确定并修改根 `pubspec.yaml` 的版本，按规则递增；不带 `+build`。完成对应改动的本地门禁、Mac 构建和发布包预检，再提交并合入 main。
2. 当前工作区切到 main，保留并妥善处理用户未提交文件。只采用 fast-forward 同步，本地 main、origin/main 与实际远端必须相同。脚本不会 stash、提交、切换分支、bump 或推送 main。
3. GitHub 业务身份和实际 Git 凭据均为 Ghost233。脚本核验 HTTPS origin 为 Ghost233/GhostModelDeck，并为每次 Git 远端调用使用已核验的 gh credential helper；不修改其他账号的凭据。

## 入口

```sh
scripts/release.sh --dry-run
scripts/release.sh
```

空跑显示仓库、已手动选定的版本、tag 与完整 main 提交，不创建或推送 tag、不改工作区文件、不 fetch。身份切换仅用于仓库账号护栏。

正式执行为当前 main 创建附注 `vX.Y.Z` tag 并推送，随后验证实际远端 tag 提交。tag 触发 [release.yml](../../.github/workflows/release.yml)，由现有 [build-release.sh](../../scripts/build-release.sh) 生成 `GhostModelDeck-X.Y.Z.dmg`、`manifest.json`、`SHA256SUMS`。普通 push 到 main 不再触发正式发布。

脚本输出「完成：vX.Y.Z 已推送」代表受理，不代表 DMG 已发布。

## 失败恢复

| 失败点 | 保留状态与下一动作 |
| --- | --- |
| 分支、工作树、账号、版本或同步检查 | 不创建 tag。按错误解决；不自动暂存或覆盖用户文件。 |
| tag push 失败 | 本地 tag 保留。先核对远端是否已有 tag；若没有，运行 `scripts/release.sh --dry-run --retry-tag`、再运行 `scripts/release.sh --retry-tag`。只重推指向当前 main 的同一 tag，不移动 tag、不再次 bump。 |
| tag 已在远端 | 不重新推送或创建版本，跟踪该提交的既有管线。 |
| workflow 构建失败，尚无正式资产 | 定位原错误，在本地完成对应验证。输入未变的临时故障可重跑原 run；代码修复使用下一个手动版本，保留原失败。 |
| Release 创建失败或资产不完整 | 先核对已有 Release/资产，不能把管线重试或 exit 0 当成完整发布；不覆盖同版本 DMG。按版本文档撤回并作废该版本，再发布下一个版本。 |

## 完成验证

每个认证 gh 命令前按 AGENTS.md 切换并核验 Ghost233；业务命令显式指定本仓库。

```sh
gh run list -R Ghost233/GhostModelDeck --workflow release.yml --commit <发布提交>
gh run watch <run-id> -R Ghost233/GhostModelDeck --exit-status
gh release view vX.Y.Z -R Ghost233/GhostModelDeck
gh release download vX.Y.Z -R Ghost233/GhostModelDeck --dir <本次验证目录>
```

选择与发布 tag/完整提交匹配的 run。网络瞬态故障重试同一读取，不创建第二次发布。验收：对应管线成功，Release 是正式版本，tag/root pubspec/manifest/.app 版本一致，三件套名称、大小与 SHA 校验通过，本地 main/tag 与实际远端一致。下载目录内运行 `shasum -a 256 -c SHA256SUMS` 并核对 manifest 中 DMG 的大小和 sha256。

本地流程回归：`python3 -B scripts/test_release.py` 使用临时 Git 仓库与本地裸仓库，在外部 Git/gh CLI 接缝模拟身份；不访问 GitHub，不发正式版。Shell 入口需通过 `bash -n scripts/release.sh scripts/build-release.sh`。真实包预检可用 `scripts/build-release.sh --app-path <本次已构建的.app> --output-dir .tooling/release-precheck`，只产出忽略的本地文件，避免覆盖既有 dist。
