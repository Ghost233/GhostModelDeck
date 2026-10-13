# 0.1.9 发布验收

## 当前状态

**0.1.9 已正式发布，管线与正式资产核验均通过。** 用户于 2026-10-14 明确授权提交及正式发布，并手动选择版本。31 份文件的发布提交为 `dc1541fd9ab3261d69e4a09c57f42e7427d0fa2b`，正式 tag 为 `v0.1.9`。

唯一发布入口 dry-run／正式执行均退出 0。[管线 38441815159](https://github.com/Ghost233/GhostModelDeck/actions/runs/38441815159) 的提交和 tag 与候选一致，最终为 completed／success。[正式 Release](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.1.9) 发布时间为 **2026-10-14 01:58:37（UTC+8）**，不是草稿或预发布版。

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

本地 DMG 为 23,013,446 字节，SHA-256 为 `78e98bb2d26eea70cb9d3fa94b8bd590e1a0099c0fefa231197685459f7dc77c`。正式 CI 资产已另外下载核验，记录如下；本地预检和正式 CI 的包摘要分别保留。构建与预检没有运行应用、模型或题集。

已核验 Ghost233 业务身份与实际 Git 凭据，并 fetch／核对实际远端。发布前 main／dev／origin refs 同为 `a6051761011e0c8777f63ab504aa21e9d540a1ef`，不需要 stash、备份、历史改写或额外分支。

## 正式资产核验

三件套下载到 `.tooling/release-verify-0.1.9/`。`shasum -a 256 -c SHA256SUMS` 退出 0；独立计算的大小和 SHA 均匹配 GitHub 正式资产元数据，manifest 的版本、tag、DMG 大小和摘要匹配。

| 资产 | 大小（字节） | SHA-256 |
| --- | --- | --- |
| `GhostModelDeck-0.1.9.dmg` | 23,102,845 | `a7377d49ac86383bcf62b6c6d46e7f36a07396580df90995363534bcf1683447` |
| `manifest.json` | 174 | `8640f38e2db46138e58f25756775bf071132fbe94046ae351f41a111c9eed23e` |
| `SHA256SUMS` | 171 | `0cd26e0886f6b596014786c1dc8c8111415e4b40004e99302a6377a073bf1924` |

只读挂载正式 DMG 后，应用版本为 0.1.9、构建号 14、bundle id 为 `com.ghost233.ghostmodeldeck`。主程序、App.framework 和 FlutterMacOS.framework 均为 arm64，没有私有测试配置入口。挂载正常卸载，没有安装或启动下载的应用，没有接管现有模型服务。

## 提交与最终同步

源码与版本先提交到 main，本地 dev 通过 fast-forward 同步后，两分支从本地原子推送；实际 Git 凭据和 GitHub 业务身份均核验为 Ghost233。唯一正式 tag 保持指向发布提交，不重推、不移动、不覆盖同版本资产。

发布后仅补充本记录及功能交付状态，不改变应用、测试、版本、lockfile 或正式 tag。本地 main／dev 与实际远端保持同一完整提交，最终同步及完成记录保存到 `final-sync.json`／`complete.json`；工作区无遗留修改，不存在备份、stash 或额外 worktree。

提交前的辅助清单脚本首次因状态行首空格被裁剪而退出 1，发生在暂存／提交之前，没有改动文件或创建 tag。改用文件名清单后，31 份授权文件核对、提交和原子推送均通过，原错误保留在本次记录中。

`.scratch/release-0.1.9/` 保存本次准备、源码提交、dry-run、正式入口、管线、Release、资产及应用核验原始记录。完整功能门禁及原始失败证据继续保留。
