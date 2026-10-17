# Ghost Model Deck 0.2.3 正式发布验收

2026-10-17。用户明确要求正式发布，并手动选择版本 0.2.3。发布使用 `scripts/release.sh`，正式 DMG 由 GitHub Actions 构建。发布后只核对远端管线、Release 和资产元数据，不下载、安装或运行正式包。

## 当前状态

正式发布已完成。总 PR [#113](https://github.com/Ghost233/GhostModelDeck/pull/113) 已在本次发布授权下合入 main，发布提交为 `b7ea928c9ba02e5fc23ada9cd477dc7141961158`。Actions 成功，正式 Release 和三份非空资产均已核对；当前 GMD 及模型服务没有切换。

## 本次范围与审查

包含规格 #102 的四个可配置场景、统一 HTTP／MCP 模型名字、三张管理表、两行槽位监控和分钟速度、引擎总开关与独立自启动配置。也包含前置的 Splash 持久运行目录、draft 引用修复和未关联启动配置删除。

原功能交付见[唯一交付记录](scenario-runtime-controls-delivery.md)，固定提交和跨阶段审查见[总审查](scenario-runtime-controls-final-review.md)，真实窗口见[原生验收](scenario-runtime-controls-native-window.md)。Standards、Spec 及跨阶段审查无未关闭 P0／P1／P2。首次隔离自动重开的一次原生启动失败及随后同配置成功的观察仍保留，不宣称根因已修复。

本次发布增量将 pubspec 从 0.2.2 改为用户确定的 0.2.3，并人工更新发布说明。对 run-knMMJQ 的 743 个输入复核，仅 pubspec 有变化；还原版本字段后精确匹配旧指纹。应用、测试、依赖 lockfile 均未变化。

## 本地验收

- 原功能最终门禁为完整宿主检查及必要增量的组合，1072 个唯一测试具有成功证据，原始失败与范围证明保留。本次不重复未受影响的全量检查或模型题集。
- 版本修改后联网准备 `run-6gFM4B` 退出 0，现有 lockfile 未变。固定 Flutter 3.47.6、Dart 3.13.5、已有 SHA 校验字体和 macOS arm64 宿主环境保持。
- `run-YEUbYs` 对版本比较、SDK 版本桥接和更新界面三个模块的 33 项检查全部通过，真实退出 0，标准报告成功完成且无失败，检查期间输入未变。
- `bash -n scripts/release.sh scripts/build-release.sh` 退出 0；`python3.12 -B scripts/test_release.py` 的 10 项本地发布入口回归全部通过，退出 0，不访问 GitHub 或创建正式 tag。
- 固定 SDK 从 `lib/main.dart` 构建 0.2.3，命令为 `flutter build macos --release --no-pub --target lib/main.dart`，设置 `FLUTTER_MACOS_ARM64_ONLY=true`，真实退出 0。生产入口没有使用隔离窗口壳。
- 主程序、App.framework 和 FlutterMacOS.framework 实查均仅 arm64；bundle ID 为 `com.ghost233.ghostmodeldeck`，应用版本为 0.2.3。
- `scripts/build-release.sh --app-path <本次生产产物> --output-dir .tooling/release-precheck-0.2.3` 退出 0。应用、pubspec、manifest 和 tag 名一致，本地预检包及清单的 SHA256SUMS 检查退出 0。
- 构建和打包期间 743 个当前输入指纹均未变化。没有替换 `/Applications/Ghost Model Deck.app`，没有启动或重启已有模型服务。

## 正式结果

- 正式 Release：[v0.2.3](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.2.3)，非草稿、非预发布。
- 发布时间：北京时间 2026-10-17 08:34:15。
- 发布 tag 与源码提交：`b7ea928c9ba02e5fc23ada9cd477dc7141961158`。
- [Actions 38986792791](https://github.com/Ghost233/GhostModelDeck/actions/runs/38986792791) 匹配 v0.2.3 及上述完整提交，状态 completed、结论 success，执行一次，CI 构建号为 18。
- tag 校验、依赖解析、DMG 和清单构建、Release 创建均成功；应用版本与 arm64 架构检查依据同一成功构建步骤及其执行脚本。
- 远端三份资产均为 uploaded，名称符合约定且大小大于零；发布后没有下载正式资产或重新计算正式包哈希。

| 远端资产 | bytes |
| --- | --- |
| GhostModelDeck-0.2.3.dmg | 23292860 |
| manifest.json | 174 |
| SHA256SUMS | 171 |

## Git 同步与服务

版本及发布前核对提交为 `6bbdbb872a18a1d792abd51a2f0747b62a576f64`，Standards／Spec 增量复审无未关闭 P0／P1／P2。#113 合并树与该候选完全一致。合并前先快进本地 main，合并后再快进同步本地 main 和 dev，并更新实际远端 dev；两分支均为同一发布提交。

发布入口 dry-run 与正式执行均退出 0，仅创建并推送一次 v0.2.3。本地和实际远端 tag 对象一致，剥离后的发布提交均为 `b7ea928c9ba02e5fc23ada9cd477dc7141961158`。未创建额外分支或 worktree，未 stash、reset、移动或覆盖其他会话文件。

本记录的最终结果另以文档提交同步 main／dev，不改变发布 tag、应用代码或版本。最终同步见 final-sync.json；发布源提交和文档提交分别记录。正式 GMD PID 9547，以及已有模型 PID 76193、78333、78337、85046、95457 保留。发布成功不代表本机已安装或运行新版本。

身份核验出现过瞬时 TLS handshake timeout，保留错误并重试同一读取，没有创建第二次发布。唯一发布管线没有失败或重跑。

## 证据

发布增量记录位于 `.scratch/release-0.2.3/`：verification-scope.json、release-cli-verification.json、build-precheck.json 和对应日志。原规格证据位于 `.scratch/scenario-runtime-delivery-20261016/`，宿主原始记录位于 `.tooling/host-tests/`。
