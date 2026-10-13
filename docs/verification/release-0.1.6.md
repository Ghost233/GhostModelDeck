# Ghost Model Deck 0.1.6 发布验收

2026-10-13。用户明确授权合并总PR并正式发布，手动确定版本0.1.6。使用deploy-release及唯一入口scripts/release.sh，没有自动推导版本或重用v0.1.5。

## 合并与来源

- [总PR #101](https://github.com/Ghost233/GhostModelDeck/pull/101) 已合入main，合并提交c3cf097556372f2b2f4a8f671b1fa2d99a1e0741。
- 发布tag v0.1.6指向7abb8ed4644be0cc04eadcecfe86ae28b1eef4e1；根pubspec与正式应用版本均0.1.6，正式应用构建号11。
- [正式管线38357927024](https://github.com/Ghost233/GhostModelDeck/actions/runs/38357927024) 对应同一完整发布提交，真实conclusion=success。
- [正式Release](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.1.6) 非草稿、非预发布，于2026-10-13 14:43（UTC+8）发布。

## 验证

程序集成及最终960项宿主门禁run-uCS7B1已通过。此次只修改pubspec版本元数据和发布文档，程序集、业务测试、固定SDK及lockfile保持，按影响范围复用原成功；没有再次运行模型题集。

版本相关run-joPIv2 33项、静态run-6JQkeb、发布入口10项回归及shell静态检查通过。在线prepare run-xhWwz7保持原lockfile；0.1.6本地arm64构建和真实三件套预检通过，dry-run显示完整tag/提交，正式入口仅执行一次。

正式资产已下载，SHA256SUMS、manifest大小/sha256及GitHub资产digest逐一核对。只读挂载正式DMG，核对bundle id com.ghost233.ghostmodeldeck、应用版本0.1.6，以及主程序、App.framework、FlutterMacOS.framework均为arm64；镜像已卸载。没有构建或提供其他平台/架构。

| 正式资产 | 字节数 | SHA-256 |
| --- | ---: | --- |
| GhostModelDeck-0.1.6.dmg | 23093450 | 57492aa08d29e670c2d062dba31c1bac5c623732395c6569b893284041ae1cae |
| manifest.json | 174 | cb62d81ce143892dc4e2905b36b0270ba78549b719f7e78935a8e6224607f537 |
| SHA256SUMS | 171 | 290c776f3d3e0604d40bddb754cc3275dee698ce44510e3c5cec304bfe7a404d |

本地预检DMG与正式CI构建的DMG分别核对，未把本地预检哈希冒称正式资产。正式tag不移动、不覆盖资产。后续仅发布验收文档提交，tag保持发布来源提交，本地main/dev及tag分别与实际远端核对。

## 服务交接与记录

构建前等待Wiki唯一在途作业结束，正常退出旧应用；构建后恢复同一Kev-4B保存实例、b11381引擎、原CLI及60秒预算，公开元数据核对实际加载身份，未发生成请求。已向获授权的Wiki线程发送恢复通知；自动审批要求删去本地路径/PID等字段，已采用仅授权资产/参数/公开名/加载状态的通知，没有绕过或残留阻塞。

原始日志、管线/Release响应、正式下载校验、应用核对及最终同步收据位于.scratch/product-scope-20261012/release-0.1.6/，正式下载三件套保留在.tooling/release-verify-0.1.6/。没有自动stash、清理、移动、覆盖用户或其他会话文件，没有额外worktree或子代理。
