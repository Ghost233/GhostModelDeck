# Ghost Model Deck 0.1.5 发布记录

2026-10-12，用户明确调用 deploy-release，并确定版本 0.1.5。用户授权将已有标签颜色配置审查后原样提交。0.1.4 已发布，本次不重用其 tag 或资产。

## 本地准备

固定 macOS arm64、Flutter 3.47.6／Dart 3.13.5、原 lockfile 与原 SHA 核验字体。run-xhVYH1 联网准备退出 0，lockfile 未变。版本变化之外的功能源码、测试和资产均与最终检查一致，原 895 项完整门禁及历史标签定点证据按未变化范围复用。

发布脚本 shell 检查通过，10 项本地流程回归通过。版本／更新四模块 run-IhliWF 的 41 项通过，退出 0；最终格式 run-HxP4jF 的 172 文件零改动，分析 run-VSI9Le 零诊断。最初检查命令写错文件名的 run-mdtDWj 保留，不计通过。

当前 0.1.5 App 构建退出 0、构建输入未变。主程序、App.framework 和 FlutterMacOS.framework 实际均 arm64，Info.plist 版本为 0.1.5。独立目录 `.tooling/release-precheck-0.1.5` 的 DMG、manifest 和 SHA256SUMS 本地校验通过。

`docs/agents/label-colors.json` 仅包含 11 个标签颜色，原字节保留。发布说明已更新为本次交付范围。没有模型评测作业，也没有 Linux、Windows 或 Intel 构建。

## 正式发布状态

当前完成本地准备。发布内容提交并同步 main 后，唯一发布入口为 `scripts/release.sh --dry-run` 和 `scripts/release.sh`。正式完成仍须确认对应 release.yml 成功，远端 Release／tag／pubspec／应用版本一致，以及三件套的大小和摘要；tag 推送成功不单独算发布完成。

完整本地构建、原日志和后续管线／资产核验记录位于 ignored `.scratch/playground-benchmarks/implementation/release-0.1.5-*`。
