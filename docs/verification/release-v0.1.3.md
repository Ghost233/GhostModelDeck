# v0.1.3 发布前验证

2026-10-08，用户明确选择 `0.1.3` 并授权正式发布，也授权提交既有 `.gitignore` 的本机账号配置忽略项。候选基于 `591067e5e0d3aeae138595e5c73f245776fa66fd`，包含已完成的 JEV 总 PR 内容、菜单栏/Dock 与图标调整、标准发布入口及手动版本修改。

## 最终本地门禁

| 命令 | 结果 |
| --- | --- |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | exit 0，90 文件、零改动。 |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh analyze` | exit 0，零诊断。 |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh test` | exit 0，540 项通过。 |
| `python3 -B scripts/test_release.py` | exit 0，9 项通过。 |
| `bash -n scripts/release.sh scripts/build-release.sh scripts/test-container.sh` | exit 0。 |
| release.yml YAML、tag 触发条件及全部 5 个 shell 步骤语法 | exit 0。 |
| `FLUTTER_BIN=/Users/ghost233/flutter/bin/flutter scripts/build-release.sh --output-dir .tooling/release-v013/local-package` | exit 0，完整 Mac Release 构建及真实 DMG 打包。 |
| SHA256SUMS、manifest、只读挂载和包内检查 | exit 0，版本 `0.1.3`、bundle id `com.ghost233.ghostmodeldeck`、可执行文件、Applications 安装链接和 README 一致；包含 arm64。 |
| `git diff --check` | exit 0。 |

源码使用固定 Flutter 3.47.6 / Dart 3.13.5，通用门禁在 Socktainer 中执行，Mac 构建与镜像验收在宿主执行。最终门禁输入的完整 SHA 清单与原始日志、真实退出码放在 `.tooling/release-v013/`，并核对运行期间输入未变化。

本地预检 DMG 为 24,559,499 字节，SHA256 `3a1500e638f7d6d41584f08fa096bd9b510723e653cae561705d5e85a92f609a`。它是本地构建的预检产物；正式管线使用 CI 运行号构建，正式 DMG 需单独下载并核验，不能复用此哈希。

此前真实 JEV 与客户端验收见 [记录](jev-native-client-acceptance-r37.md)，窗口/Dock 与图标验收见 [记录](menu-bar-and-icon.md)。本次产品代码未再修改这些行为。菜单栏菜单项的自动化直接点击限制仍按原记录保留。

此记录只证明发布前本地门禁。正式发布需按 [发布流程](../agents/release.md) 核验对应 release.yml、正式 Release、三件套资产、包内版本及本地/实际远端 main 和 tag。
