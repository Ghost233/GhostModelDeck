# 发布版本号规则

本文档是 GhostModelDeck 版本发布纪律的权威来源。DMG 发布 workflow（#26）、检查更新功能（#27）与 SDK 版本状况桥接（#28）均以本文为准。

## 版本权威

- 版本号的唯一权威来源是 `pubspec.yaml` 的 `version:` 字段，其中 **semver 部分**（`+` 之前的 `x.y.z`）为权威，`+build` 元数据不参与版本比较。本仓库约定版本号**不带** `+build` 后缀；构建号（`CFBundleVersion`）由发布 workflow 注入 GitHub Actions 运行号（`github.run_number`），本地构建由 Flutter 以版本号兜底。
- 版本号由**人**在每个发布工单的实施中手动递增；禁止 CI 或脚本自动推导、自动 bump。
- 应用内读取当前版本必须来自打包信息（Info.plist / package_info_plus 等派生值），不得硬编码。

## 递增与 rollover 规则

版本号格式为 `x.y.z`，每次发布递增 **1**，采用「满 10 进位」的十进制 rollover：

- `z` 满 10 时进位为 `y+1.0`：`0.1.9` 的下一个版本是 `0.2.0`。
- `y` 满 10 时进位为 `x+1.0.0`：`0.9.9` 的下一个版本是 `0.10.0`（**不是** `1.0.0`——y 从 9 进为 10，不发生二次进位）。
- `1.0.9` 的下一个版本是 `1.1.0`；`1.9.9` 的下一个版本是 `1.10.0`。
- 每次发布最多进位一次；`0.9.9` 不跳级到 `1.0.0`。

该规则保持 semver 序单调递增（`0.1.9 < 0.2.0`、`0.9.9 < 0.10.0`），因此检查更新可以直接使用 `pub_semver` 标准比较，无需特殊处理 rollover。

## tag 规则

- tag 格式为 `v<x.y.z>`（例如 `v0.1.0`）。
- tag 与 `pubspec.yaml` 的 semver 部分必须**严格相等**；发布 workflow 强制校验，不一致即失败，不允许人工绕过。

## 回滚规则

- **版本号绝不重用。** 同一版本号不得对应两个不同的 DMG（保护 sha256 校验信任链）。
- 错误发布的撤回流程：
  1. 删除对应的 GitHub Release；
  2. 删除对应 tag（`git push origin :refs/tags/v<x.y.z>` 及本地删除）；
  3. 该版本号作废，永不再用；
  4. 修复问题后，按递增规则以**下一个版本号**重新发布。

## 发布操作清单

1. 在发布工单中按上方规则由人手动修改 `pubspec.yaml`，完成本地门禁与发布包预检，随已审查内容合入 main，并同步本地 main。
2. 明确要求正式发布时执行 `scripts/release.sh --dry-run`，核对当前手动版本与 tag/完整提交，再执行 `scripts/release.sh`。
3. 脚本仅创建并推送 `v<x.y.z>` 附注 tag，不自动 bump、不提交、不推送 main。tag 触发 workflow 构建并创建正式 Release。
4. 发布后核对三件套资产、manifest 版本/大小/哈希、SHA256SUMS 与应用版本；失败恢复见 [标准发布流程](agents/release.md)。

## workflow 行为

- `.github/workflows/release.yml` 由 **push v* tag** 触发；普通 push 到 main 不发布。
- tag 去掉 v 后必须与根 `pubspec.yaml` 版本严格相等，不接受 `+build`；checkout 的提交必须等于发布 tag 的提交。
- 使用固定 macos-15 / Flutter 3.47.6 调用 `scripts/build-release.sh`；该脚本验证应用 bundle id、可执行文件及 `.app` 版本。
- tag 已由本地发布入口创建，CI 使用 `gh release create --verify-tag`，不自动生成 tag、不覆盖同版本资产。同一 tag 的流水线串行执行。
- 资产为 `GhostModelDeck-<x.y.z>.dmg`、`manifest.json`、`SHA256SUMS`。构建号由 `github.run_number` 注入。
- `scripts/build-release.sh --app-path <已构建的.app>` 在本机预检打包环节；应用版本必须与 pubspec 一致。

## 首发基线

首个正式 Release 为 `0.1.0`，对应首期收尾的 main HEAD。

首发历史曾由 main push 自动发布。当前流程已改为显式版本 tag：版本修改或功能合入 main 不发布，只有明确发布并推送对应 tag 才触发正式管线。
