# 0.1.8 发布验收

## 当前状态

**0.1.8 已正式发布，管线与正式资产核验均通过。** 用户明确授权提交及发布，并手动确定版本。发布提交为 `d5a59642e3a11e27c72dac678681c2f19a049a90`，tag 为 `v0.1.8`。

正式发布时间为 2026-10-13 20:22:21（UTC+8）。[Release](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.1.8) 为非草稿、非预发布版本。[管线 38396191336](https://github.com/Ghost233/GhostModelDeck/actions/runs/38396191336) 的 HEAD 与发布提交一致，最终状态为 `completed / success`。

## 发布内容与已验证证据

- 新增运行监控，以及 Splash 原生决策的 HTTP、MCP 和委员会接线。功能范围、原始失败与真实短调用详见 [功能交付记录](splash-jev-and-runtime-monitor-2026-10-13.md)。
- 完整宿主门禁 `run-F2IDyI`：980 项测试通过，格式和静态分析均退出 0，成功完成标记为 true。发布准备前，723 份输入和 12 份复审模块的 SHA 均与门禁记录一致。
- 版本修改只将 `pubspec.yaml` 从 0.1.7 改为用户选择的 0.1.8。锁文件、应用代码及已有真实短接口证据保持；不重复运行已通过的模型题集。
- 使用固定 Flutter 3.47.6、Dart 3.13.5 与现有 lockfile，在 macOS arm64 宿主检查。正式构建使用 `lib/main.dart`，不复用带私有配置的测试应用产物。
- 发布不安装或启动新正式应用，不操作其他会话使用的模型服务。

## 本地发布检查

| 检查 | 证据 | 结果 |
| --- | --- | --- |
| 在线环境准备 | `run-05TIKo` | 退出 0，lockfile 未变 |
| 版本与更新检查 | `run-YlWaaA` | 33 项通过，真实退出 0 |
| 发布脚本语法 | `bash -n scripts/release.sh scripts/build-release.sh` | 退出 0 |
| 发布脚本本地回归 | 固定 Python 执行 `python3 -B scripts/test_release.py` | 10 项通过，退出 0 |
| 正式入口构建 | `.scratch/release-0.1.8/build.log`、`build.exit` | `lib/main.dart`，版本 0.1.8，退出 0 |
| DMG 预检 | `package-precheck.log`、`package-precheck.exit` | 退出 0，bundle id 正确，三项二进制均 arm64 |
| 本地三件套核验 | `local-package-check.json` | SHA256SUMS、manifest 版本、大小和 SHA 全部匹配 |

本地预检 DMG 为 23,022,993 字节，SHA-256 为 `c77e38f450f54c614b093975eb1e9a92d47bba9c036efb62d7054ed6b87390aa`。正式 CI 资产将在发布后独立下载核验。

环境准备首次因 SDK 缓存写入权限而失败，原始记录 `run-OQbSSU` 保留。首次 Git 身份检查因沙箱无法访问钥匙串而停止。获准使用现有宿主缓存和凭据后，两项均已通过；没有改动 SDK、lockfile 或其他账户凭据。

## 提交与发布

20 份已审查文件提交到 main。本地 dev 通过祖先关系检查后完成 fast-forward；main/dev 从本地原子推送，实际远端及 origin refs 均与发布提交一致，工作区干净。GitHub 业务身份及实际 Git 凭据均为 Ghost233。

唯一入口 `scripts/release.sh --dry-run` 和 `scripts/release.sh` 均退出 0。正式 tag 的提交与根 pubspec 版本一致；只触发一份管线，没有重推 tag 或覆盖同版本资产。

## 正式资产核验

三件套下载到 `.tooling/release-verify-0.1.8/`。`shasum -a 256 -c SHA256SUMS` 退出 0。独立计算的文件大小与 SHA-256 均匹配 GitHub 资产元数据；manifest 的版本、tag、DMG 大小和摘要也匹配。

| 资产 | 大小（字节） | SHA-256 |
| --- | --- | --- |
| `GhostModelDeck-0.1.8.dmg` | 23,205,710 | `1a32171899708331ef488925767517f3573d5f7fd7f0226386c1a3279ae0e907` |
| `manifest.json` | 174 | `f6fe134f14177eaee9623a4f32dac0d5fef0215e16fa54ed218b25296d0c815b` |
| `SHA256SUMS` | 171 | `4491bc0253394477bf33783c24068571da6855d9ad6e9ba9fd175ebcea18e60c` |

只读挂载正式 DMG 后，应用版本为 0.1.8、构建号为 13，bundle id 为 `com.ghost233.ghostmodeldeck`。主程序、App.framework 和 FlutterMacOS.framework 均为 arm64。挂载已正常卸载，没有安装或启动下载的应用。

## 记录与最终同步

`.scratch/release-0.1.8/` 保存 `preflight.json`、`initial-sync.json`、`source-pushed.json`、`dry-run.log`、`publish.log`、`pipeline.json`、`release.json`、`asset-check.json` 和 `app-check.json`。最终同步与完成结果记录在 `final-sync.json` 和 `complete.json`。

发布后仅补充本记录和功能交付状态，不改变应用、版本、lockfile 或正式 tag。本地 main/dev 与实际远端保持同一完整提交，工作区无遗留修改。功能验收的原始失败和成功证据继续保留，没有新建备份或 worktree。
