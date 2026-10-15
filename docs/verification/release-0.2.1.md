# Ghost Model Deck 0.2.1 发布记录

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

## 发布状态

版本修改后的联网准备通过，lockfile 未变化。
更新检查和版本桥接共 23 项通过（`run-tUFqrP`），发布流程回归 10 项通过，Shell 静态检查通过。
0.2.1 实际构建退出 0，bundle ID 为 `com.ghost233.ghostmodeldeck`。
主程序、App.framework 和 FlutterMacOS.framework 均经 lipo 核对为 arm64。
本地打包预检退出 0，应用、pubspec 和 manifest 的版本一致，本地预检包的校验和通过。
这些本地前置使用本机构建产物，没有下载远端发行包。

主线程审查未发现未关闭 P0／P1／P2。
当前本地前置已完成，提交、tag、Actions 和正式 Release 结果待发布后补充。

原始代码与模型验证记录位于 `.scratch/llama-fast-20261015/`。
本次发布证据位于 `.scratch/release-0.2.1/`。
当前正式 GMD 及现有模型服务保持运行，发布不表示已安装或启用新版本。
