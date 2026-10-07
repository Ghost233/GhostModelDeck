# #35 调用内 debug 与取消结果验证

来源：[打通按次 debug 与取消结果](https://github.com/Ghost233/GhostModelDeck/issues/35)。规格为 `docs/requirements/protocol-converters-and-playground.md` 和 `docs/requirements/jev-model-routing-and-council-profiles.md`，承接 ADR 0001/0002 与 #33 的受管请求、取消和排空语义。

本切片在 `codex/jev-call-debug` 上从 `ee4ac0ef2b25acef22ee55725c67b3f647ddd590` 实施。现以普通 merge 接纳 root 已审查的 #34 集成 `dd4c36470af8c1a83c3c74b36101ab5faca783a4`。单处 fixture teardown 冲突同时保留 identity 与 child-exit 门闩释放；合并后的完整 format/analyze/test 已通过，结果见下文。

## 行为与边界

`JevModels.decide` 只在本次 `debug: true` 时创建调用局部证据。配置、调用名、绑定、输入来自本次入场对象；业务结果来自同次 await 返回值，未读取 `lastResult`、`lastBatchResult` 或 `CouncilState` 拼装结果。普通成功保留 `model/answers/usage` 三字段；失败通过同一 `JevRequestException.toJson()` 供软件、HTTP 与 MCP 投影。

`DecisionIOTrace` 经公开受管 `LlamaEngine.decideBatch` 进入实际 `_request` 边界，记录同一次写入的序列化 body，在完整响应接收后、HTTP 状态与 JSON/业务校验前保存 raw 字符串。非法 JSON 和非 200 原文同样保留；未收到完整 raw 时为 null。该公开接缝也可用于后续测试场的受管原生模式。显示/复制前使用 `sealDebugJson` 生成脱敏的深不可变 JSON 副本，原始捕获只在本次内存中，不自动存盘或建立历史。

委员会在停止点先封存 IO，再沿原有 owner 排空。公开返回前的主动取消仍撤回可用成功；同样时序的整轮截止保留完整成功席位，零成功截止报 `timed_out`。原生成功承接 #33 的 microtask 返回门；实际身份故障清理中发生取消也以 `cancelled` 投影。取消不停止驻留模型或其他请求。转换对象仅包含标准成功或错误，避免嵌入 debug 自引用。

调试投影采用明确字段，未收集入站或引擎认证 headers。API key、Authorization、Cookie/Set-Cookie 字段按大小写及嵌套位置脱敏，已发现凭据的回显也在展示副本中替换。实际业务输入及标准答案不经脱敏改写。软件提交时消费本次 debug 设置，开始即清旧输出；本次 JSON 使用 SelectableText，并可复制。

## 公开回归

替身仅在外部进程/子进程退出、HTTP 和文件 IO；实际受管 `LlamaEngine`、`CouncilController`、`JevModels`、HTTP/MCP server 均参与。测试未 mock 委员会或路由业务，也未启动或下载真实模型。

- 原生默认/显式 debug、完整 IO/转换、非法 JSON、业务非法响应、非 200、未完整接收响应；每份证据与实际外部请求对账。
- 委员会成功、非法响应及已登记离线绑定；各席状态/错误/raw、有效席位与完整总结果一致。
- 快席 owner 已释放后主动取消与整轮截止的对照；旧慢席放行、旧 token 重复取消、后续调用正常及原 JSON 深层封存。
- 零成功截止与原生真实 10 秒预算；取消与超时区分，许可归零且驻留 PID 保持。
- 外部 `EngineChild.exitCode` 门闩阻塞真实身份故障清理；覆盖委员会截止后尚未公开返回时取消，以及无取消对照和并发健康席位。
- 同实例的不同配置及原生调用反序返回；独立输入、raw 标记、用量和预算。运行中编辑、重命名及删除只影响新请求，入场配置保持原名、成员与预算。
- 接纳 #34 唯一 serializer 后，通过真实 `/props` IO 门闩修改调用方的嵌套 state、instructions、候选描述、score legend 与 images，并修改绑定和名称；原生/委员会的 debug 深快照、实际发送 body 与 raw 输入标记一致，后续采用新配置。
- 真实 HTTP `/v1/systemone`、MCP `decide_jev`/`decide_jev_batch` 的默认/false/true，两种来源的成功/错误、text 与 structuredContent 相同、无凭据及无 debug 持久化。
- 实际 HTTP 连接断开与 MCP SDK Abort 仅检查终止、排空、隔离、后续健康及 PID；未声称断开的客户端收到业务取消 JSON。非流式 HTTP 断开可依保存的整轮/原生预算结束，证据不声明即时断连检测。
- 软件两种来源提交、清旧输出、取消、后续默认关闭、可选择 JSON 与真实 Clipboard.setData 内容；GUI IO 门闩在 `runAsync` 的真实异步区创建。

## 命令与证据

独占容器 `ghostmodeldeck-checks-r35`，Socktainer 上下文；固定 Flutter 3.47.6、Dart 3.13.5、SDK Git `5fc346839b5d0eef006ed8404392afb4dfae428d`。所有 runner job 由容器主进程执行，每次在线 pub get；未改为离线或并行提交同一长任务。每个 run 保存 `job.sh/source.tar.gz/result.log/exit`，完整命令、源码归档及逐文件内容清单 SHA-256、日志 SHA-256 和实际退出码在 `/private/tmp/ghostmodeldeck-implementation-context/implementation35-status.json`。

#34 集成前的本地结果：受影响 JEV/council/protocol/widget/managed engine/gateway 模块 144 测试通过（`run-SMdCxX`，退出 0）。集成前新增公开回归共 15 项，覆盖上列多个时序和协议向量；集成后另补一项合法深 JSON 与 trace 的交叉回归。

| 完整门禁 | 真实结果 | 原始 run |
| --- | --- | --- |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | 83 文件、0 改写，退出 0 | `run-McvjPI` |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh analyze` | 零诊断，退出 0 | `run-6mrWvB` |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh test` | 474 测试通过，退出 0 | `run-3txEPP` |

归档字节 SHA-256 分别为 format `74e695c48c3076d022c0967ff55c1504d8198f463c744805183a8182e6ad9cb6`、analyze `51d468dcf11884aae08d6d8d0935116d5aa0d06ccc28ae392309ffe1344f69b0`、test `63a1dec3590ea596bf8140c582ec57c011c6a0e63895deaec2eea59b2a1649d7`。逐个解包并按文件名与文件内容 SHA-256 排序核对，91 文件的内容清单 SHA-256 均为 `5074cb203575cfd04afc43d87756d5834775b73b487176893f17be80c8f6b21c`；归档元数据差异未被当作源码差异。这组历史通过不代替输入合并后的重新验证；合并后的结果另列。

原始 RED 与测试工具失败保留在 run 目录：本次 model/完整证据缺失、native 错误丢 debug、委员会取消丢证据、零成功截止误报普通零成功、凭据泄露、原生清理窗口取消误报引擎错误、公开 trace 可变、软件 debug 继承均先失败后定点通过。另有注册外的离线 fixture、测试 JSON 类型 cast 和 Flutter fake-zone 门闩错误，按测试工具原因修正；其非零退出及原始日志未作通过统计。

## 范围限制

本记录证明可控 IO 下的公开调用、协议与 Widget 行为。真实引擎/模型、真实 Mac 桌面窗口、Hermes/Codex 客户端和 Release 验收未执行，不以本次容器结果替代这些验收。完整新测试场属于 #36；本切片仅使现有软件页面查看并复制本次结果。

## #34 集成后的最终结果

普通 merge 的前置为 `dd4c36470af8c1a83c3c74b36101ab5faca783a4`；当前 #35 候选完整包含该已审查提交。定点交叉回归 `run-ipXCPb` 两项通过，退出 0；受影响模块 `run-c8TwnW` 157 项通过，退出 0。合并后新增公开回归累计 16 项。

| 完整门禁 | 真实结果 | 原始 run |
| --- | --- | --- |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | 84 文件、0 改写，退出 0 | `run-UQKZWn` |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh analyze` | 零诊断，退出 0 | `run-9NBnOn` |
| `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r35 ./scripts/test-container.sh test` | 484 测试通过，退出 0 | `run-TFhfts` |

三项实际检查的 92 个文件逐项与产品源码相同。内容清单采用两种明确编码，文件集合与各文件 SHA-256 完全一致：

- UTF-8 LF 行清单：按路径排序，每行 `path + " " + file_sha`，末尾也保留 LF；8,607 字节，SHA-256 为 `6e6f3ff5ca765ed16a5aa6a62fbf8fe284de20d7553a9fe0a557333cbcef9720`。
- 与前阶段统一的 compact JSON：`json.dumps(path_to_sha, sort_keys=True, separators=(',', ':')).encode('utf8')`；8,976 字节，SHA-256 为 `66e65fccaa195e3d2672f72d7c3d928ba9f0723d23924cbbffd16ce37e9c71c1`。

完整 92 路径及文件 SHA、两种编码表达式、三个实际 run 的对照和独立归档/日志字节 SHA，保存于 [源码与双编码证据](jev-call-debug-and-cancellation-source.json)。归档字节 SHA 与内容清单 SHA 分别记录，未把编码或归档元数据差异当作源码差异。

原始 RED、fixture/tool 失败与 analyze 的 6 条及后续剩余 1 条诊断均保留；最终零诊断与成功退出来自实际重新检查。未修改锁文件、SDK 或容器设置，也未在此切片执行 GitHub 写操作或推送。

## 首轮审查与环境 retro

首轮 Standards 与 Spec 均以 `ee4ac0ef2b25acef22ee55725c67b3f647ddd590` 为固定点、`fc37dbc0cc16e57b479ab6bf12fee4798ed7ef32` 为候选，沿完整 `git diff base...HEAD` 覆盖全部 18 个变更文件，包含已正常 merge 的 #34 前置、产品代码、测试及历史验证文档。Standards 发现 0、Spec 发现 0，两轴 P0/P1/P2 均为 0。该两轴源码审查未重跑测试，既有通过结果作为实际证据引用。

同一候选的环境 retro 按 38 次真实 run、失败锚点原始日志、工程规范与既有检查入口复盘导航、机械规则、信息访问和工具成本；环境 P0/P1/P2 均为 0，新增修复候选 0。已修复的产品 RED、fixture/tool 错误与分析诊断保留真实非零结果，不重复作为剩余环境缺陷。首轮两轴与 retro 原始报告位置及字节 SHA 见上述 [证据 JSON](jev-call-debug-and-cancellation-source.json)。

本次收尾只更新验证 Markdown 与证据 JSON，92 个产品检查输入未变，复用已经通过的最终门禁；已核对文件内容与记录清单、JSON 与链接，并执行 `git diff --check`，未重跑产品检查。**截至本次文档更新，更新后最新 HEAD 的最终完整差异复审尚未执行**；首轮审查与 retro 的零发现不代表最新 HEAD 已通过最终复审。
