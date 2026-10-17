# Ghost Model Deck 0.2.3 正式发布验收

2026-10-17。用户明确要求正式发布，并手动选择版本 0.2.3。发布使用 `scripts/release.sh`，正式 DMG 由 GitHub Actions 构建。发布后只核对远端管线、Release 和资产元数据，不下载、安装或运行正式包。

## 当前状态

发布前检查已通过，尚未推送 tag。已验收的总 PR #113 将在本次发布授权下合入 main，再同步本地分支。版本修改、打包预检与发布记录不改变已验收的应用功能。

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

待完成总 PR 合并、main 同步、发布入口 dry-run 和正式 tag 推送，再记录匹配提交的 Actions 与正式 Release。缺少远端证据不记发布完成。

## 证据

发布增量记录位于 `.scratch/release-0.2.3/`：verification-scope.json、release-cli-verification.json、build-precheck.json 和对应日志。原规格证据位于 `.scratch/scenario-runtime-delivery-20261016/`，宿主原始记录位于 `.tooling/host-tests/`。
