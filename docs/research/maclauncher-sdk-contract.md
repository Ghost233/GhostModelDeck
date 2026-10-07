# MacLauncher SDK 接入与生命周期契约

研究日期：2026-10-05。对应工单：[核实 MacLauncher SDK 的接入与生命周期契约](https://github.com/Ghost233/GhostModelDeck/issues/3)。本笔记提供规划依据，不表示 GhostModelDeck 已接入或通过联调。

## 证据基线与结论

按用户指定的 [SDK 接入指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/SDK_INTEGRATION.md) 核验官方仓库固定提交 `bc7262f4047e81f55922c203948ac64d9e0e2d13`。指南 blob 为 `ee6462db9ff12e88bb6344d9b4378bee001184c2`，与主线程读取的远端内容一致；源码通过本机 Git 对象的 `git show <固定提交>:<路径>` 读取，未使用有未提交修改的 MacLauncher 工作区或其 HEAD 作为事实基线。

接入的职责边界已经清楚：MacLauncher 负责显式关联、发送请求和展示快照，GhostModelDeck 负责推理实例的业务生命周期、状态、日志与入口。启动器不是引擎进程监督器，打开应用也不代表推理服务已就绪。固定 SDK 的入口归还实现与指南存在差异，必须在接入验收前处理。[职责 ADR](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/adr/0001-application-owned-lifecycle.md)、[拉起实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/launch_orchestrator.dart#L10-L13)

## 已核实的契约

### 依赖、关联与身份

- SDK 是纯 Dart；官方依赖入口为 `https://github.com/Ghost233/MacLauncher.git` 的 `packages/maclauncher_sdk` 子目录。指南示例使用 `ref: main`，同时建议固定 tag 或 commit；接入验收应记录具体版本。本次审计版本的包名为 `maclauncher_sdk`、版本 `0.1.0`，Dart 约束为 `^3.13.0`。主线程已核验 [JevManager 固定来源](https://github.com/Ghost233/JevManager/blob/ff97c9a5b1c7ed164abe6f6906c03cacd65a4d3e/pubspec.yaml#L6-L7) 为 `^3.13.5`，两者声明相容；实际依赖解析与构建未验收。[指南依赖](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/SDK_INTEGRATION.md)、[包清单](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/pubspec.yaml#L1-L12)
- 用户选择项目目录中的 `maclauncher.json` 才建立关联，没有自动扫描。配置为 `schemaVersion: 1`，包含 `project.id/name` 和 `services[].id/name`；项目身份稳定且全局唯一，服务身份在项目内唯一，显示名不参与身份。复制并改名不会自动改变项目身份；新项目必须明确自己的身份，避免与 JevManager 副本冲突。[关联指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/PROJECT_ASSOCIATION.md#L3-L31)、[配置校验](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/manifest.dart#L138-L177)
- `entry` 可省略；配置时可选 `.app` 或 executable。相对入口与工作目录以配置目录为基准；`.app` 用系统 `open`，executable 用 detached 模式且不经 shell、不捕获业务输出。只有启动操作可以先拉起应用，等待 SDK 连接后再发业务请求；查询、回收和打开窗口均不拉起离线应用。默认等待 SDK 连接为 30 秒。[关联指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/PROJECT_ASSOCIATION.md#L27-L30)、[入口打开实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/entry_launcher.dart#L19-L65)、[拉起协调器](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/launch_orchestrator.dart#L64-L120)
- 握手检查协议版本、hello 结构、已关联项目和同项目活跃连接；对应拒绝原因为 `protocol-version`、`invalid-hello`、`unknown-project`、`conflict`。同 `projectId` 的第二个活跃 SDK 连接不能抢占第一连接。这是 SDK 会话约束，不是应用进程的单实例锁。[握手实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/server.dart#L11-L17)、[握手检查](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/server.dart#L165-L201)

### 服务回调与真实观察

`services` 的键是服务身份；非 null 回调声明能力。只声明 `onStatus` 就只有观察能力，不能假装可以启动、回收或读日志。[ServiceCallbacks](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L10-L35)

| 回调 | 接入边界 |
| --- | --- |
| `onStart` | 调用应用自己的启动路径；回调确认不等于服务 running/ready，仍由状态查询证实。重复启动已运行实例要由业务正确处理。 |
| `onRecycle` | 释放服务的端口、受管子进程与连接，保留 GhostModelDeck 应用进程和 SDK 连接。 |
| `onStatus` | 报告真实 `stopped/starting/running/stopping/failed/unknown` 快照、真实 UTC 观察时间，以及可证实的 ready 和业务运行身份。SDK 断连不等于业务 stopped/failed。 |
| `onLogs` | 返回最近批次，旧→新且最多 `query.limit` 条；默认 200、协议收敛为 1–500。缺少原始时间、分流、运行范围时保留未知，不伪造。 |

来源：[启动确认与超时语义](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/operations.dart#L9-L24)、[示例重复启动](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/example/minimal_app/lib/fake_business.dart#L27-L44)、[回收指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/SDK_INTEGRATION.md)、[状态协议](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/protocol/messages.dart#L19-L83)、[日志协议](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/protocol/messages.dart#L129-L173)

启动器默认立即查询、每 5 秒刷新，每服务最多一个在途状态查询。超过 15 秒无成功结果，或应用原始 `observedAt` 已过期，展示为未知并保留上一真实快照；缺少观察时间不能冒充实时验证。模型加载超过 30 秒时，请求等待可能超时，但应用回调仍继续；后续查询应反映实际进展，不能据超时杀掉引擎或自动重发。日志 UI 打开时每 2 秒查询，批次整体替换，失败保留旧内容并标记。[状态观察实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/status_observer.dart#L40-L61)、[失效判断](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/status_observer.dart#L117-L155)、[请求超时实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/server.dart#L280-L306)、[日志展示指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/LOGS.md#L3-L25)

### 窗口、连接与退出

- `AppCallbacks.onOpenWindow` 由应用激活或创建主窗口；`onSetEntryManaged(true/false)` 由应用隐藏或恢复自己的入口，返回 `true` 才确认。启动器先完成初始状态查询，再请求接管，迟到确认按当前 launcher session 校验。未声明入口能力时仍可协作服务，并保留应用入口。[入口指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/ENTRY_HANDOFF.md#L6-L14)、[应用回调](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L38-L51)、[接管实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/handoff.dart#L111-L149)
- `connect()` 立即返回；默认 5 秒重试、5 秒 ping，距最近 pong 超过 15 秒后断开（每秒检查）。SDK 未连接时应用继续独立工作；正常断连或重启会重新握手。状态流为 disconnected/connecting/connected/rejected，拒绝带原因。[连接实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L54-L109)、[重试循环](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L175-L215)、[看门狗](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L298-L311)
- `dispose()` 停止重连、取消连接尝试、销毁通信、关闭状态流，可重复等待同一 dispose future，实例随后不能复用；不会回收业务，也不等待在途业务回调结束。回调可以继续工作，但不能回到旧连接。应用自身退出需要另有受管业务清理路径，不能把 dispose 当作清理业务。[dispose 实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L163-L173)、[过期响应守卫](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L360-L368)、[生命周期测试断言](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/test/lifecycle_test.dart#L255-L308)
- 启动器正常退出或解绑尽力发送 `managed:false`，每会话默认等待 3 秒；连接消失只清除启动器自己的接管记录。此路径从不发送 recycle，启动器关闭或崩溃不能成为业务收尾事件。[归还实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/handoff.dart#L174-L195)、[SDK 职责声明](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L65-L69)

### 并发、去重与应用侧约束

- 同一服务的 SDK `start/recycle` 回调互斥，第二个变更立即返回 busy，不排队；门闩属于 SDK 实例，跨重连保留。status/logs 不受门闩影响，不同服务互不阻塞。这个门闩不覆盖应用 UI 自己调用的业务路径，也不保护不同服务共用的 GPU、端口等资源；后两点是据源码范围得出的接入约束。[门闩范围](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L144-L147)、[互斥实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L446-L460)
- 去重仅在同一连接上按 request id：同 id 复用在途 future 或已完成结果；完成结果最多 128 个、按插入顺序淘汰，重连新建缓存。不能以此代替业务对重复启动的处理，不能承诺跨会话 exactly-once；新 id 的同服务并发变更得到 busy。请求超时不取消回调，启动器不自动重发。[请求去重源码](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/request_dedup.dart#L16-L63)、[每连接新缓存](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L234-L236)、[请求路由](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L349-L358)、[等待语义](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/server.dart#L280-L306)

## 文档与固定源码差异

1. **失联入口归还尚无 SDK 实现证据。** [入口指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/ENTRY_HANDOFF.md#L16-L23) 写明 SDK 在断连、错误与心跳超时后自行归还；但完整 SDK client 中只有收到 `setEntryManaged` 请求才调用应用回调，[断连 finally](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L198-L215)、[serve finally](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L313-L318) 和 [dispose](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/client.dart#L163-L173) 均没有 `onSetEntryManaged(false)`。示例也未提供 AppCallbacks。[minimal_app](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/example/minimal_app/bin/minimal_app.dart#L19-L33)；现有测试证实的是启动器 `releaseAll()` 发送 false，并未证明崩溃时 SDK 自动恢复。[归还测试](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/test/handoff_test.dart#L258-L311)。因此不能把指南承诺直接当作可用能力；选择已修复 SDK 版本，或由应用补足并验收断连及迟到回调恢复，属于后续接入决策。
2. **去重不是按参数，也不是 LRU。** [SDK 指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/SDK_INTEGRATION.md) 的“参数相同”和“LRU”表述，与按 id 查表、命中不更新次序的 [RequestDedup](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/maclauncher_sdk/lib/src/request_dedup.dart#L39-L59) 不一致。验收采用源码实际语义，不能期望两次新 id 的相同操作被复用。
3. **服务集合不一致不一定握手拒绝。** SDK 指南的笼统表述应以 [关联指南](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/docs/PROJECT_ASSOCIATION.md#L24-L26) 和源码细化：hello 只检查 service 声明格式与唯一性，不比对绑定服务集合；额外服务可登记但不会在绑定范围外路由，绑定服务缺少能力则 unavailable/unsupported。[hello 校验](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/server.dart#L242-L277)、[路由交集](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/operations.dart#L294-L309)。接入仍应保持配置与预期服务声明一致。

## 版本状况查询（#28 接入，SDK 基线提升）

2026-10-07 增补：上文契约的证据基线为固定提交 `bc7262f4047e81f55922c203948ac64d9e0e2d13`，各节链接保持该基线不变。工单 [#28](https://github.com/Ghost233/GhostModelDeck/issues/28)（提交 `e9bdb77`）把应用锁定的 SDK ref 提升到 `5d81583bf07e3a97160259435809662a303e9908`（含版本状况能力），本节以该提交为事实基线：

- `AppCallbacks.onVersionStatus → Future<VersionStatus>` 声明版本状况能力；`VersionStatus` 字段为 `state`（`success|failure|unsupported`）、`currentVersion`、`hasUpdate`、`latestVersion`、`downloadUrl`、`sha256`、`failureReason`。[应用回调](https://github.com/Ghost233/MacLauncher/blob/5d81583bf07e3a97160259435809662a303e9908/packages/maclauncher_sdk/lib/src/client.dart)、[消息模型](https://github.com/Ghost233/MacLauncher/blob/5d81583bf07e3a97160259435809662a303e9908/packages/maclauncher_sdk/lib/src/protocol/messages.dart)
- 未注册回调时 SDK 自动应答 `unsupported`；回调抛异常由 SDK 兜底为 `failure`——应用侧回调仍应自身不抛（双层防御）。
- 本应用映射（`lib/version_status_bridge.dart`，复用 `lib/update_checker.dart` 单一查询接缝）：有更新 → success + hasUpdate + latestVersion/downloadUrl/sha256 透传；已最新 → success + hasUpdate=false；仓库尚无正式 Release → unsupported（如实：当前无更新渠道）；查询异常 → failure 携带真实原因。当前版本来自 Info.plist（package_info_plus），不硬编码。
- 验收证据：socket 级测试实证能力声明、未注册自动 unsupported、异常兜底 failure；容器串行门禁 run-XKnfQi/run-usANPK/run-5uhoQJ 全绿（450/450）。
- 已知边界：unsupported 状态的原因经 `failureReason` 字段透传（SDK 文档称该字段语义上属 failure，字段本身原样透传）；`SDK_INTEGRATION.md@5d81583` 另有「解除绑定表现」一节（persistent rejected=未关联，应提示重新关联而非无限等待），尚未集成，留作跟进。

## 运行时发现（#30 接入，SDK 基线提升）

2026-10-07 增补：工单 [#30](https://github.com/Ghost233/GhostModelDeck/issues/30) 把应用锁定的 SDK ref 提升到 `b48c5a9c232a609b59c9510c59cca82046fc9e55`（含运行时发现，上游 [PR #51](https://github.com/Ghost233/MacLauncher/pull/51)），本节以该提交为事实基线：

- hello 握手新增可选 `projectName` 与 `entry`（`SdkEntry`）自报字段；缺省时省略，线形与旧版逐字节一致，旧启动器不受影响。新增握手拒绝原因 `pending-approval`：项目未关联且未忽略时启动器把项目放入「待批准」，用户在管理窗口一次性批准即建立运行时绑定（`BindingOrigin.runtime`）。`pending-approval` 是批准前正常状态，不是错误；SDK 按 `retryInterval`（5 秒）持续重试，批准后握手自动成功，应用不得当作配置错误。[connect 参数与语义](https://github.com/Ghost233/MacLauncher/blob/b48c5a9c232a609b59c9510c59cca82046fc9e55/packages/maclauncher_sdk/lib/src/client.dart)、[拒绝原因常量](https://github.com/Ghost233/MacLauncher/blob/b48c5a9c232a609b59c9510c59cca82046fc9e55/packages/maclauncher_sdk/lib/src/protocol/messages.dart)
- `SdkEntry`：`appBundle(path)` 经系统 `open` 拉起；`executable(path, args, workingDirectory)` detached 拉起；`currentAppBundle()` 从 `Platform.resolvedExecutable` 推导自身 `.app`（非 bundle 运行返回 null）；`currentExecutable()` 上报当前可执行文件。路径须绝对；启动器在批准时校验存在性，入口事后失效为可恢复的「入口失效」状态。[入口自报](https://github.com/Ghost233/MacLauncher/blob/b48c5a9c232a609b59c9510c59cca82046fc9e55/packages/maclauncher_sdk/lib/src/entry_report.dart)
- 本应用接入（`lib/sdk_service.dart` `connect()`）：自报 `projectName: 'GhostModelDeck'` 与 `entry: SdkEntry.currentAppBundle() ?? SdkEntry.currentExecutable()`（DMG 安装后解析为 `/Applications/GhostModelDeck.app`，开发期退回当前可执行文件）。连接日志对 `pending-approval` 降噪：待批准期间只公告一次「请在启动器管理窗口批准关联」，重试的 connecting/disconnected/rejected 不刷日志；connected 或其他拒绝原因退出该期间。
- 与配置绑定的关系：`maclauncher.json` 配置绑定仍是支持路径（可选增强），本应用保留该文件不动；同 `projectId` 的运行时绑定与配置绑定冲突时走启动器既有冲突弹窗，迁移为配置绑定，行为由上游负责。运行时绑定由 hello 驱动服务声明 diff 与入口失效自愈。
- 验收证据：socket 级测试实证 hello 自报 `projectName`/`entry`、`pending-approval` 只公告一次且不以拒绝原因原文呈现、批准后正常记录 connected。

## 建议的最小联调验收门槛

以下是据上述契约提出的验收建议，本次未执行，不是已通过结果。

1. **固定版本可构建**：记录 git commit、应用 Dart/Flutter 版本及依赖解析结果；两侧 Dart 约束已声明相容，实际依赖解析与应用构建仍须通过。
2. **身份与能力**：显式关联新项目配置；未关联项目拒绝；第二连接拒绝且不影响第一连接；只开放声明的能力和绑定服务范围；改显示名不改身份。
3. **拉起与独立运行**：启动器未运行时应用正常操作；从有效 entry 拉起并握手后才发 start；入口已打开但未连接时不显示业务已启动；离线 status/recycle/openWindow 不拉起应用。
4. **业务与状态**：针对选定服务分别启动和回收真实受管实例；回收释放其资源、应用仍存活；状态反映 loading/ready/failure 的事实及真实观察时间；重复 start 不创建重复实例；请求超过 30 秒后业务继续且能观察最终状态。
5. **并发与旧连接**：同服务新 id 的 start/recycle 并发得到 busy，status/logs 仍可读；同 id 只执行一次；重连缓存不延续、旧回调不响应新会话；应用内操作与 SDK 操作共同遵守业务所有权及共享资源约束。
6. **窗口与入口**：打开原窗口有效；接管仅在隐藏成功后确认；正常退出、崩溃、断连、心跳超时及接管迟到回调后，入口均能恢复且业务不被回收。固定版本的自动归还缺口必须先有明确处理方案与可复现验证。
7. **观察失败与日志**：旧 `observedAt` 和查询失败显示未知并保留旧快照，不捏造 stopped/failed；日志限制、顺序、未知字段与截断标记正确，关闭面板停止读取。
8. **dispose 与应用退出**：dispose 后停止连接重试、不会触发 recycle，不阻塞在途业务回调；真正退出应用时由应用自己的路径清理受管资源，不停止外部接入实例。

## 留给后续决策与未验证项

- HITL：启动器服务按模型能力（LLM/JEV）、引擎还是受管实例划分；哪些服务允许登录自动启动、如何选择待启动模型。SDK 不规定粒度；启动器现有自动启动是按个人偏好对仍在有效配置内的服务每次启动器进程通知一次，重启会再通知，不能由研究代理代定新项目策略。[自动启动实现](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/autostart.dart#L44-L74)、[通知范围](https://github.com/Ghost233/MacLauncher/blob/bc7262f4047e81f55922c203948ac64d9e0e2d13/packages/launcher_core/lib/src/autostart.dart#L83-L136)
- 后续接入决策：采用哪个固定 SDK 版本，以及入口恢复缺口由 SDK 还是应用解决；新项目稳定身份、发布后的入口路径和应用自身单实例机制。
- 未执行依赖解析、应用编译、真实引擎或 SDK socket 联调；现有 socket 测试仅阅读断言，未运行。仅核验了两侧 Dart 约束声明相容，未验证实际工具链与依赖解析、macOS 打包、菜单栏控制或引擎停止行为，也没有修改启动器仓库、绑定配置或应用代码。
