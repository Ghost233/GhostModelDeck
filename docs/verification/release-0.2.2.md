# Ghost Model Deck 0.2.2 正式发布验收

2026-10-16。用户明确要求正式发布，并手动选择版本 0.2.2。
唯一发布入口为 `scripts/release.sh`，正式 DMG 由 GitHub Actions 构建。
发布后只核对远端管线、Release 和资产元数据，不下载、安装或运行正式包。

## 本次范围

MCP 服务器新增服务器级 `instructions`，并更新三个工具的描述。
说明覆盖局部语义判断、调用名复用、共享状态、循环上限、交回主模型和结果验证。
JavaScript 编排和实际操作取决于宿主支持及权限。
工具名称、输入与输出 schema、业务处理和运行生命周期均保持不变。

新增两项公开 MCP 协议测试，覆盖新版发现与旧版初始化中的说明和工具描述。
旧测试及断言全部保留。本次没有启动真实模型题集，也没有重启现有 GMD 或模型服务。

## 本地验收

- 联网依赖准备：`run-T6XL9J`，退出 0，现有 lockfile 未变化。
- 最终完整宿主门禁：`run-orZHkR`，202 个文件格式检查、静态分析及 1005 项业务／Widget 测试全部通过。
- 完整门禁真实退出码为 0，标准测试报告确认成功完成、没有失败，检查期间源码指纹未变化。
- 先前相关回归的本机连接错误保留原记录；定点复验及本次完整门禁均通过，没有删测试或放宽断言。
- 0.2.2 Mac 构建退出 0，bundle ID 为 `com.ghost233.ghostmodeldeck`。
- 主程序、App.framework 和 FlutterMacOS.framework 经 lipo 核对，均仅为 arm64。
- 本地打包预检退出 0，应用、pubspec 和 manifest 的版本一致，预检包校验和通过。

检查使用固定 Flutter 3.47.6（提交 `5fc346839b5d0eef006ed8404392afb4dfae428d`）及 Dart 3.13.5。
SDK 位于 `.tooling/flutter-3.47.6`，字体沿用已通过 SHA 校验的 Noto 字体。
只支持 macOS arm64，不提供其他平台或架构产物。

主线程完成工程规范和需求审查，未发现未关闭 P0／P1／P2。
额外核对表明，应用源码除服务器说明及三个工具描述外没有变化。
完整门禁、构建和打包使用同一份应用源码及版本，未修改共享 SDK。

## 正式结果

- 正式 Release：[v0.2.2](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.2.2)，非草稿、非预发布。
- 发布时间：北京时间 2026-10-16 15:44:35。
- 发布 tag 与源码提交：`a6ace8f1baa554ae594cb6ae668be6758f5ab85b`。
- [Actions 38868759304](https://github.com/Ghost233/GhostModelDeck/actions/runs/38868759304) 对应 v0.2.2 及上述完整提交，状态为 completed，结论为 success。
- tag 校验、依赖解析、DMG 和清单构建、Release 创建步骤均成功，CI 构建号为 17。
- 远端三份资产均为 uploaded，名称符合约定且大小大于零。版本、arm64 架构和清单检查依据成功的 CI 构建记录。

| 远端资产 | bytes |
| --- | --- |
| GhostModelDeck-0.2.2.dmg | 23103589 |
| manifest.json | 174 |
| SHA256SUMS | 171 |

## Git 同步与服务

发布前已将本地 main、dev 快进到同一发布提交，再原子推送两个分支。
本地分支、跟踪分支及实际远端均核对一致，固定提交复审未发现未关闭 P0／P1／P2。
发布入口 dry-run 和正式执行均退出 0，只创建并推送了一次 v0.2.2。
本地 tag 与实际远端 tag 指向同一发布提交。

后续只补充本文的发布结果，采用文档提交并继续同步 main 和 dev，不改变发布 tag。
没有创建额外分支或 worktree，没有 stash、reset、移动或覆盖其他会话文件。
正式发行资产未下载到本地，也未重新计算正式包哈希、安装或运行新版本。
当前 GMD 和模型服务保持原状，发布不代表本机已切换到新版本。

本次发布证据位于 `.scratch/release-0.2.2/`。
MCP 定点回归及原始失败位于 `.scratch/mcp-usage-guidance-20261016/` 和对应宿主检查目录。
