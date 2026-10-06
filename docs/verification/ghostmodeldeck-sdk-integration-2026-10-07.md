# GhostModelDeck × MacLauncher SDK 接入验收报告（#18 公开切片 S1）

日期：2026-10-07 · 分支 main（基线 HEAD 1d7a433）· 串行容器 `ghostmodeldeck-checks-r33b`（Flutter 3.47.6，pinned 5fc346839b5d0eef006ed8404392afb4dfae428d）

## 范围与固定输入

- SDK 固定来源：`https://github.com/Ghost233/MacLauncher.git` @ `bc7262f4047e81f55922c203948ac64d9e0e2d13`，子目录 `packages/maclauncher_sdk`；本票唯一授权的依赖变更。`pubspec.lock` 由容器内 ONLINE `flutter pub get` 真实解析生成（仅新增 `maclauncher_sdk 0.1.0`，零传递新增）。
- 新增 `maclauncher.json`（仓库根）：schemaVersion 1；project `com.ghost233.ghostmodeldeck` / GhostModelDeck；单一服务 `inference` / 推理服务；entry `{kind: app, path: build/macos/Build/Products/Release/GhostModelDeck.app}`；不声明 `onSetEntryManaged`。
- 全部裁决依据 `docs/research/maclauncher-sdk-contract.md` 与 `docs/spec.md`「SDK 与窗口生命周期」节、验收矩阵 A09/A10。

## 交付物

| 文件 | 内容 |
| --- | --- |
| `lib/sdk_service.dart`（470 行，新） | `LauncherInferenceService`：SDK 客户端生命周期 + 五个回调的业务语义；`StartupModelSet`：启动模型集合持久化（`startup-models.json`，schema 1，坏结构真实报错不静默） |
| `lib/manager_lifecycle.dart`（+7） | `ManagerLifecycle` 持有并按序装配/处置 `LauncherInferenceService`（dispose 幂等，断开 SDK 但绝不触碰业务模块） |
| `lib/main.dart`（+20，最小接线） | 构造 `StartupModelSet` 与服务，注入真实网关/MCP/引擎目录引用与窗口激活 seam |
| `lib/library_page.dart`（+34，GUI 最小增量） | 运行行火箭开关：显式点击加入/移除启动模型集合（`Icons.rocket_launch[_outlined]`），落盘持久化；`startupSet == null` 时不渲染开关 |
| `test/sdk_service_test.dart`（1428 行，新，24 个测试） | 见下「测试证据」 |
| `pubspec.yaml` / `pubspec.lock` / `maclauncher.json` | 依赖与清单，如上 |

## 固定语义实现要点

- `onStart`：受理即分配 `instanceId` 并记日志 → 开公开 API 网关 → 开 JEV MCP → 显式加载启动模型集合；启动受理只代表受理，空集合 / 缺资产 / 单条加载失败均真实报告（`启动集合加载失败：<artifactId>：<error>` 入日志，不抛回启动器）；`ready` 为真当且仅当网关与 MCP 均在运行。
- `onRecycle`：先关新入场（引擎目录 `stopManaged` 的 admission hold 语义）→ 排空/取消 → 卸载全部受管模型 → 停网关与 MCP；保留应用、SDK 连接、配置与模型文件，可再启动。
- `onStatus`：真实快照（state/instanceId/ready/message），`observedAt` 为真实 UTC 时间。
- `onLogs`：真实批次，旧→新，`limit` 默认 200、clamp 1–500，未知字段不伪造。
- `onOpenWindow`：激活主窗口最小 seam；seam 未配置时抛 `StateError('窗口激活 seam 未配置')`（真实失败，不假装成功）。
- busy 门闩与按请求 id 去重遵循 SDK 固定源码语义（`service busy: inference`；同 id 重放只执行一次）；SDK dispose / 断连 / 启动器崩溃不回收业务；明确 `onRecycle` 或进程退出才完整收尾；第二连接冲突不抢占。
- 损坏的启动集合配置使 `onStart` 真实进入 `failed` 并带错误消息（`StartupModelSet.load` 在服务 try 范围内执行）。

## 测试证据（替身边界声明）

真实 `maclauncher_sdk` 客户端 + 真实 loopback socket；启动器侧协议对等体（`_LauncherPeer`）按固定源码语义实现（welcome accept/reject、reject 后关闭 socket 以触发 SDK 5s 重连节奏、request/response、ping/pong、按 id 去重、busy 互斥）——这是本票允许的替身边界。业务模块全真：真实 `LlamaEngine`/`EngineCatalog`/`ModelUseRegistry`/网关/MCP，引擎对端为实现真实握手契约的本地 HTTP 假 llama-server（`/health` JSON、`/props` 别名与模型路径一致性、`/v1/chat/completions` 严格 `TextResult.parse` 契约），模型文件为夹具最小字节，**未加载任何真实模型权重**。并发/取消/重连用确定性信号（Completer/事件），不用 sleep 计时；widget 测试按既有惯例以 `runAsync` 内有界轮询等待真实库扫描。

24 个新测试覆盖：握手 hello/welcome 字段、拒绝重连（不 hammer）、start 受理/幂等/busy、启动集合真实加载与缺资产真实报告、recycle 顺序与可再启动、status 快照、logs 批次与 limit clamp、openWindow seam、第二连接不抢占、断连不回收业务、pong 超时断连重连、dispose 纪律（含与在途 start 竞态不双执行不复活）、`StartupModelSet` 持久化/坏结构报错、模型库页开关显式切换与持久化。

## 门禁（串行容器 `ghostmodeldeck-checks-r33b`，最终树）

| 闸门 | run id | 结果 |
| --- | --- | --- |
| `format --output=none --set-exit-if-changed lib test benchmarks` | run-vXxwYy | 0 changed，exit 0 |
| `analyze` | run-ei0RRx | No issues found，exit 0 |
| `test` | run-Qsdl0B | **403 过 0 败**（基线 379 → 403，+24，只增不减） |

注：容器 `dart format` 对本票文件非单次幂等，已按「容器内 format 至不动点 + base64 管道回写宿主」对齐；format 写回后 analyze 与 test 为写回后的全新运行。

## 未证事项（显式出界）

- 真实 MacLauncher 应用端到端联调、真实 `.app` 拉起：未做（本票禁止）。
- 原生窗口激活的系统级验证：属 #19 范围，本票仅交付最小 seam 与其调用证据。
- 真实模型权重加载：按用户指令全程未做，引擎证据基于契约等价假对端。
- 上游 SDK 未做任何修改；无 push、无 GitHub issue 操作。
