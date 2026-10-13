# 0.1.9 发布验收

## 当前状态

用户于 2026-10-14 明确授权提交及正式发布，并手动选择版本 **0.1.9**。功能验收、版本检查、正式入口构建与本地 DMG 预检均通过；当前准备提交并同步 main／dev，再执行发布入口。尚未创建或推送 tag，尚未宣布发布完成。

本次内容为引擎启动性能、取消完整性及兼容性预检、重新下载、实例并发启动与取消回收。完整功能记录见 [引擎启动与重新下载](engine-startup-and-redownload-2026-10-13.md)。

## 复用证据与范围

- 完整宿主门禁 `run-Umbldq`：989 项全部通过，格式／分析／测试退出 0，成功完成标记为 true，源码指纹未变化。发布准备再次核对全部输入，应用、测试、基准及 lockfile 与该门禁相同。
- 本次版本修改仅将根 `pubspec.yaml` 从 0.1.8 改为用户选择的 0.1.9，并更新发布说明。应用代码与 lockfile 不变；完整业务门禁及真实短调用证据直接复用，补跑版本和更新相关检查。
- 真实 EmbeddingGemma 2 公开 HTTP 短调用已通过，两个中英文输入返回两个 768 维非零向量；正式发布不再次运行模型题集。
- 使用固定 Flutter 3.47.6、Dart 3.13.5、Python、字体和 lockfile，在 macOS arm64 宿主联网准备依赖及检查。正式构建使用 `lib/main.dart`，不使用私有配置的测试入口。
- 发布仅提供 macOS arm64，不安装或启动新的正式应用，不操作其他会话使用的模型服务，不创建子代理、容器、分支或 worktree。

## 本地发布检查

| 检查 | 证据 | 结果 |
| --- | --- | --- |
| 联网宿主准备 | `run-uXSvp2` | 退出 0，lockfile 未变 |
| 版本／更新检查 | `run-py71Ww` | 41 项通过，退出 0 |
| 发布脚本语法 | `bash -n scripts/release.sh scripts/build-release.sh` | 退出 0 |
| 发布入口本地回归 | 固定 Python 执行 `python3 -B scripts/test_release.py` | 10 项通过，退出 0 |
| 正式入口构建与 DMG 预检 | `build-and-package.log`／`build-and-package.exit` | `lib/main.dart`，版本 0.1.9，bundle id 正确，三项二进制均 arm64，退出 0 |
| 本地三件套 | `local-package-check.json` | SHA256SUMS、manifest 版本／大小／SHA 全部匹配 |

本地 DMG 为 23,013,446 字节，SHA-256 为 `78e98bb2d26eea70cb9d3fa94b8bd590e1a0099c0fefa231197685459f7dc77c`。正式 CI 资产仍须独立下载核验。构建与预检没有运行应用、模型或题集。

已核验 Ghost233 业务身份与实际 Git 凭据，并 fetch／核对实际远端。发布前 main／dev／origin refs 同为 `a6051761011e0c8777f63ab504aa21e9d540a1ef`，不需要 stash、备份、历史改写或额外分支。

## 待完成

1. 提交并同步本地与实际远端 main／dev。
2. 唯一发布入口 dry-run 和正式执行，跟踪对应完整提交的管线。
3. 正式 Release／tag／版本、三件套 SHA／大小及正式 DMG 内 .app 版本和架构核验。

发布相关原始证据将保存至 `.scratch/release-0.1.9/`，本地预检及正式资产核验使用各自独立的 `.tooling/` 目录，保留失败记录。
