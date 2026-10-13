# 0.1.8 发布验收

## 当前状态

用户已授权提交并正式发布，手动确定版本为 0.1.8。功能验收、版本检查和本地包预检已通过；下一步提交、同步 main/dev，并发布及核验正式资产。

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

提交已审查内容，同步本地 main/dev 并推送。再通过 `scripts/release.sh` 发布，核对对应管线、正式 Release、DMG、manifest.json 和 SHA256SUMS。完成前核对本地分支及 tag 与实际远端一致。
