# Ghost Model Deck 0.1.5 发布记录

2026-10-12，用户明确调用 deploy-release，并确定版本 0.1.5。用户授权将已有标签颜色配置审查后原样提交。0.1.4 已发布，本次不重用其 tag 或资产。

## 本地准备

固定 macOS arm64、Flutter 3.47.6／Dart 3.13.5、原 lockfile 与原 SHA 核验字体。run-xhVYH1 联网准备退出 0，lockfile 未变。版本变化之外的功能源码、测试和资产均与最终检查一致，原 895 项完整门禁及历史标签定点证据按未变化范围复用。

发布脚本 shell 检查通过，10 项本地流程回归通过。版本／更新四模块 run-IhliWF 的 41 项通过，退出 0；最终格式 run-HxP4jF 的 172 文件零改动，分析 run-VSI9Le 零诊断。最初检查命令写错文件名的 run-mdtDWj 保留，不计通过。

当前 0.1.5 App 构建退出 0、构建输入未变。主程序、App.framework 和 FlutterMacOS.framework 实际均 arm64，Info.plist 版本为 0.1.5。独立目录 `.tooling/release-precheck-0.1.5` 的 DMG、manifest 和 SHA256SUMS 本地校验通过。

`docs/agents/label-colors.json` 仅包含 11 个标签颜色，原字节保留。发布说明已更新为本次交付范围。没有模型评测作业，也没有 Linux、Windows 或 Intel 构建。

## 正式发布状态

正式发布已完成。[v0.1.5 Release](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.1.5) 为正式版本，非草稿、非预发布。[release.yml 第 10 次运行](https://github.com/Ghost233/GhostModelDeck/actions/runs/38168698349) 成功，真实 watch 退出 0。唯一发布入口创建并推送的 tag 为 `v0.1.5`，发布提交为 `1907bb6d0ba94f550a2f0f646f8f4ea795b773ed`。

正式三件套已下载并校验：`GhostModelDeck-0.1.5.dmg`、`manifest.json`、`SHA256SUMS`。DMG 为 23,012,149 字节，SHA-256 为 `a9a398483da3702a238307f19721ee74c787d8a84bfd90ecfb0b4c38de883af5`。manifest／tag／根 pubspec／包内应用版本均为 0.1.5；包内构建号为 10，与 CI 运行号一致。

正式 DMG 已只读挂载核对。bundle id 正确，主程序、App.framework 和 FlutterMacOS.framework 实际均仅 arm64。校验和检查与镜像卸载均退出 0，没有安装或执行下载包。

发布后的本地 main／dev 与实际远端同步，附注 tag 的对象及完整提交同实际远端。状态文档提交不改变 tag，也不重建或覆盖正式资产。标签颜色配置原字节已提交保留，工作树干净。

完整构建、发布入口日志、管线退出及资产核验收据位于 ignored `.scratch/playground-benchmarks/implementation/release-0.1.5-*`，下载的正式三件套位于 `.scratch/releases/v0.1.5/`。原检查命令失败仍保留，不混入成功结论。
