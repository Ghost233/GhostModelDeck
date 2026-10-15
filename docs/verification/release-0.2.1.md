# Ghost Model Deck 0.2.1 正式发布验收

2026-10-15。用户明确要求提交和正式发布，并手动选择 0.2.1。
唯一发布入口为 `scripts/release.sh`，正式 DMG 由 GitHub Actions 构建。
用户本次明确取消远端资产的本地下载验证，以 Actions 发布成功及远端 Release 资产核对为完成条件。

## 范围与本地证据

本次修复 Julia-1 缺少可选决策温度时，GMD 将模型误判为不完整的问题。
允许缺省温度，交给 llama.cpp 使用默认值 1；显式非法温度和 scorer 尺寸检查继续保留。
用户模型与引擎参数属于本机使用配置，没有加入发行包默认配置。

- 定点复现：同一份 Julia-1 原 GGUF，修复前扫描退出 255、判为 incomplete；修复后退出 0、判为 complete。
- 受影响模块：模型库与实例共 83 项通过，记录 `run-740yXH`。
- 完整宿主门禁：`run-V7lDD6`，格式、静态分析和 1003 项业务／Widget 检查通过，真实退出码为 0，源码指纹未变化。
- 真实接口：三个小模型由 llama.cpp b11381 加载，choice、score、noul 均返回 HTTP 200。修复后的 GMD 生产模块通过公开 HTTP 完成 fast 三席位调用，三个成员均为 ok，诊断进程已退出。
- 上述完整门禁覆盖本次最终应用与测试代码。随后只修改发布版本和文档，相关版本检查、带新版本的 arm64 构建及打包预检单独记录；不重复模型题集。

检查使用固定 Flutter 3.47.6（提交 `5fc346839b5d0eef006ed8404392afb4dfae428d`）、Dart 3.13.5 和原 lockfile。
共享 SDK 已更新，本次使用 `.tooling/flutter-3.47.6` 的独立固定副本，未回退共享 SDK。
字体沿用已通过 SHA 核验的 Noto 字体，保留全部字体和布局断言。
SDK 初始差异及首次引导错误保留在原记录中，没有记为检查通过。

## 正式结果

- 正式 Release：[v0.2.1](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.2.1)，非草稿、非预发布，已于北京时间 2026-10-15 10:54:48 发布。
- 源码与 tag 提交：`b7e8721bf3cadb44bf2fc1b87e4f184d32160709`。
- [Actions 38673104099](https://github.com/Ghost233/GhostModelDeck/actions/runs/38673104099)：对应 v0.2.1 和完整发布提交，已完成，结论为 success。版本校验、构建清单、发布步骤全部成功，CI 构建号为 16。
- 远端 Release 含以下三件套，状态均为 uploaded，大小均大于零。
- 发布提交中的根 pubspec 为 0.2.1，与 tag 一致。正式管线成功执行了应用版本、arm64 架构和清单生成检查。
- 按用户要求，仅读取 Actions 与 Release 远端元数据；没有下载正式发行资产到本地，没有对正式包重新计算哈希，也没有安装或运行新版本。

| 远端资产 | bytes |
| --- | --- |
| GhostModelDeck-0.2.1.dmg | 23102591 |
| manifest.json | 174 |
| SHA256SUMS | 171 |

## 本地前置与同步

版本修改后的联网准备通过，lockfile 未变化。
更新检查和版本桥接共 23 项通过（`run-tUFqrP`），发布流程回归 10 项通过，Shell 静态检查通过。
0.2.1 实际构建退出 0，bundle ID 为 `com.ghost233.ghostmodeldeck`。
主程序、App.framework 和 FlutterMacOS.framework 均经 lipo 核对为 arm64。
本地打包预检退出 0，应用、pubspec 和 manifest 的版本一致，本地预检包的校验和通过。
这些本地前置使用本机构建产物，没有下载远端发行包。

主线程审查未发现未关闭 P0／P1／P2。
发布入口 dry-run 与正式执行均退出 0，只创建并推送了一次 v0.2.1。
发布时本地 main、dev、跟踪分支及实际远端均指向发布提交，本地 tag 对象和解引用提交与实际远端一致。

共享工作区的三份发布流程文档更新与用户本次要求一致，审查后原样保留于独立提交 `3d655338ee8e365f26d033190eacdb8c9aa7ad3f`。
没有 stash、reset、覆盖他人文件或创建额外分支、worktree。
后续补充本发布记录的文档提交不改变发布 tag 或应用源码，main 和 dev 继续采用 fast-forward 同步。

原始代码与模型验证记录位于 `.scratch/llama-fast-20261015/`。
本次发布证据位于 `.scratch/release-0.2.1/`。
当前正式 GMD 及现有模型服务保持运行，发布不表示已安装或启用新版本。
