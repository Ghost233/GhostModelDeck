# Ghost Model Deck 0.1.7 发布

**0.1.7 已正式发布，管线与正式资产核验均通过。** 用户明确授权提交推送及正式发布，并手动选择版本。发布提交为 `a722f78b2f096542651e4b0d3fe16b0a35dbea31`，tag 为 `v0.1.7`，唯一入口 `scripts/release.sh` 的空跑和正式执行均退出 0。

正式发布时间为 2026-10-13 16:24:06（UTC+8）。[Release](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.1.7) 为非草稿、非预发布版本；[管线 38368752229](https://github.com/Ghost233/GhostModelDeck/actions/runs/38368752229) 的 HEAD 与发布提交一致，最终状态 `completed / success`。

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

## 正式资产核验

三件套下载至 `.tooling/release-verify-0.1.7/`。`shasum -a 256 -c SHA256SUMS` 通过，文件大小及独立计算的 SHA-256 与 GitHub 资产元数据一致，manifest 的版本、tag 及 DMG 大小、摘要均匹配。

| 资产 | 大小（字节） | SHA-256 |
| --- | --- | --- |
| `GhostModelDeck-0.1.7.dmg` | 23,095,721 | `2346297eaac791517babc837b4f6573921bb8124fa07dcbcbb4d993379499618` |
| `manifest.json` | 174 | `d6043a3cad02b6224c28627047e5f634b6fe6cab29279a1fdfaab1fd5e4e43ca` |
| `SHA256SUMS` | 171 | `238a15b5c696fcc4a9a9473ca8a8032681a48dbb33be6c95627f16d190eaca9e` |

只读挂载正式 DMG 后，核对应用版本为 0.1.7、构建号为 12、bundle id 为 `com.ghost233.ghostmodeldeck`。主程序、App.framework 和 FlutterMacOS.framework 的实际架构均为 arm64；挂载已卸载。没有安装或启动下载的正式应用。

## 记录与同步

`.scratch/release-0.1.7/` 保存 `preflight.json`、`source-pushed.json`、`dry-run.log`、`publish.log`、`pipeline.json`、`release.json`、`asset-check.json` 和 `app-check.json`。最终同步和完成状态分别保存在 `final-sync.json`、`complete.json`。

发布后只补充本记录和修复验证文档；这份文档提交不改变应用、版本、lockfile 或正式 tag，不重建或覆盖 0.1.7 资产。本地 main/dev 与实际远端完成 fast-forward 同步，正式 tag 仍固定在上述发布源提交。

提交后的推送前检查曾因凭据核验模块导入生成 `scripts/__pycache__/release.cpython-312.pyc` 而停止，原失败记录保留在 `prepush-command-failure.json`。仅清理本次新生成的缓存并改用 Python `-B` 后继续推送；没有删除、移动或暂存其他会话文件。
