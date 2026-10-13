# Ghost Model Deck 0.1.7 发布

用户明确授权提交推送及正式发布，并手动选择 0.1.7。本地检查、0.1.7 构建与打包预检已通过；下一步提交推送并通过唯一入口 `scripts/release.sh` 发布。正式管线、资产核验和分支同步结果完成后更新本记录。

## 范围与审查

本次发布包含 [引擎下载列表修复](engine-download-list-2026-10-13.md)：统一任务列表、进行中数量、下载百分比与平均速度、安装中条目的“查看下载”入口及按需构建列表。审查沿用工程规范，核对后台任务归属、每份下载独立计时、阶段与终态展示、取消隔离及原有配置入口。

只提供 macOS arm64。没有新增依赖，保留原 lockfile；本次没有运行模型评测集，也没有退出或恢复正在运行的模型服务。

## 本地证据

| 检查 | 记录 | 结果 |
| --- | --- | --- |
| 完整宿主门禁 | `.tooling/host-tests/run-ez1INK` | 960 项通过，退出 0；192 文件格式无变化，分析无问题 |
| 受影响模块 | `.tooling/host-tests/run-f9hHk7` | 133 项通过，退出 0；包含双任务真实 HTTP、独立取消和字体布局 |
| 0.1.7 在线依赖准备 | `.tooling/host-tests/run-tXmndW` | 退出 0，lockfile 未变 |
| 版本相关检查 | `.tooling/host-tests/run-D8AuiG` | 33 项通过，退出 0 |
| 发布脚本语法 | `bash -n scripts/release.sh scripts/build-release.sh` | 退出 0 |
| 发布入口本地回归 | 固定 Python 执行 `python3 -B scripts/test_release.py` | 10 项通过，退出 0；不访问 GitHub |
| 0.1.7 arm64 构建 | `.scratch/release-0.1.7/build.log`、`build.exit` | 退出 0，应用版本 0.1.7 |
| DMG 打包预检 | `.scratch/release-0.1.7/package-precheck.log`、`package-precheck.exit` | 退出 0，主程序及两份 framework 均为 arm64，三件套 SHA 校验通过 |

960 项门禁之后，仅 `pubspec.yaml` 的发布版本元数据变化；应用代码、测试和 lockfile 指纹一致。版本相关测试、0.1.7 的真实 arm64 构建及 DMG 预检分别记录，不宣称旧产物已经覆盖新版本输入。

构建、空跑、发布、正式管线和资产核验的原始记录位于 `.scratch/release-0.1.7/`。版本及 tag 必须为 `0.1.7`、`v0.1.7`，正式三件套为 `GhostModelDeck-0.1.7.dmg`、`manifest.json`、`SHA256SUMS`。

本地预检 DMG 为 23,010,638 字节，SHA-256 `632309155e5c160a0824aa405da5db1f5e7d5a31784cd4ed22db548efa5f03fe`。这是本地预检产物；正式 CI 产物按实际发布资产独立下载并校验。
