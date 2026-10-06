# 发布版本号规则

本文档是 GhostModelDeck 版本发布纪律的权威来源。DMG 发布 workflow（#26）、检查更新功能（#27）与 SDK 版本状况桥接（#28）均以本文为准。

## 版本权威

- 版本号的唯一权威来源是 `pubspec.yaml` 的 `version:` 字段，其中 **semver 部分**（`+` 之前的 `x.y.z`）为权威，`+build` 元数据不参与版本比较。
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

1. 在发布工单中手动 bump `pubspec.yaml` 的 `version:`（按上述递增规则），随功能改动一并合并到 main。
2. push 到 main 后，发布 workflow 检测到 semver 部分无对应 `v<x.y.z>` tag，即视为新发布：构建 DMG、生成 `manifest.json` 与 `SHA256SUMS`、打 tag 并创建正式（非 prerelease）GitHub Release。
3. 发布后在 GitHub Releases 页面核对三件套资产与版本号。
4. 如需撤回，按上述回滚流程执行。

## workflow 行为

发布由 `.github/workflows/release.yml` 在 **push 到 main** 时触发，行为如下：

- **no-op 判断**：workflow 读取 `pubspec.yaml` 的 semver 部分（`+` 之前），检查对应 `v<x.y.z>` tag 是否已存在。已存在视为该版本已发布，直接成功退出，不构建、不重复发布。
- **新发布**：tag 不存在时，workflow 在 macos-15 上用固定 Flutter 3.47.6（stable）构建，调用 `scripts/build-release.sh` 产出 DMG 与清单。
- **tag↔pubspec 强制一致**：发布前断言将创建的 tag 与 pubspec semver 部分严格相等，不一致即失败，不允许人工绕过。`gh release create` 基于当前提交原子地创建 tag 与正式（非 prerelease）GitHub Release。
- **发布资产（三件套）**：`GhostModelDeck-<x.y.z>.dmg`、`manifest.json`（含版本、tag、DMG 的 sha256 与字节数，供检查更新使用）、`SHA256SUMS`（覆盖 DMG 与 manifest.json）。
- **本地复现**：`scripts/build-release.sh` 可在本机直接执行同样的构建与打包；`--app-path <已构建的.app>` 可跳过 flutter build 只验证打包环节。
- **手动回滚**：错误发布按上文「回滚规则」执行（删除 Release → 删除 tag → 版本号作废 → 以下一个版本号重新发布）。

## 首发基线

首个正式 Release 为 `0.1.0`，对应首期收尾的 main HEAD。首次真实发布的执行不属于 workflow 工单范围，需单独确认。
