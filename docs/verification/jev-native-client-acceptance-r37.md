# #37 真实 JEV 与客户端专项验收

日期：2026-10-08（Asia/Shanghai）。来源：[真实 JEV 与客户端专项验收 #37](https://github.com/Ghost233/GhostModelDeck/issues/37)，父项 [命名 JEV 模型路由、标准协议与应用内推理测试场规格 #32](https://github.com/Ghost233/GhostModelDeck/issues/32)。本轮应用源码为 `51f8d962ca132b1d1d0179be93b0406b9726eff9`。**本期仅 JEV 的七项验收条件均已满足：真实客户端、窗口、持久配置、稳定绑定和最终资源/配置/共享资产收尾完成；当前候选待主线程统一审查与 Git 交付。**

本轮事实与结果保存在 [本轮来源记录](jev-native-client-acceptance-r37-source.json)。持久原始材料位于主工作区 `.scratch/jev-protocol-playground/continuation/`；`accept37-*` 为本轮客户端与独立校验材料，`native37-*` 为主线程实际 Release 应用、窗口、模型与配置材料。后续验收只使用本轮请求关联、实际实例与真实退出结果，不继承旧模型或旧客户端通过声明。

## 可观察的验收条件

| 条件 | 本轮完成证据 |
| --- | --- |
| 授权与 Ready | 用户在明确加载 Kev/Laya 并验收的确认提问后直接回复“继续”；主线程启动模型并确认实际 UI 两模型运行中、三个调用名均可调用。本轮成功 debug 关联实际 instance、alias 与 generation。 |
| 持久 quick/hard | 本轮 Release UI 保存离线配置：quick 绑定 Kev、20 秒；hard 绑定 Kev 与 Laya、40 秒；原生固定名绑定 Kev。退出/重启后 registry 与 C1 字节相同、离线发现为空；显式再启解析新 alias，三种调用名复杂混合成功。最终恢复 C0，C1 同字节保留为可恢复任务配置。 |
| 三题型与数学 | 普通 choice 与两种混合三题型实际返回均通过；复杂值、nullable criteria、空 images 保留。hard 两席 raw 的 Fraction 综合、score/confidence、noul 和 usage 与同次标准结果一致。 |
| 原生直连 | 固定调用名访问同一受管 Kev 实例，实际原生 answers/usage、confidence 保留；仅映射公开 model，无委员会结构。 |
| HTTP/MCP | 两入口发现三个相同 model/source 与新工具，schema 必填 model；6 HTTP + 6 SDK 决策调用通过，所有 MCP 文本 JSON = structuredContent，debug.converted_result = 本次业务结果。 |
| Hermes | 实际安装的 discovery → executor → registry → handler → SDK 与结果消费已执行，两种工具、三个显式 model 共 6 用例通过；协商协议和安装身份分别记录。 |
| 实际测试场 | 实际窗口三模式混合、同次 debug/raw、HTTP 实际复制、MCP 模型发现、普通混合 Form→JSON/default，以及复杂 JSON→只读提示 Form→JSON→实际提交均完成；复杂字段保留且两席成功。 |
| 资源与配置 | SDK/Hermes session/transport/thread/task 已释放，唯一任务 profile 已归档后删除；本次应用/模型 PID 退出、六端口关闭、C0 四目标配置恢复不存在，共享模型实算 SHA 未变，仅移动本次创建的配置到可恢复目录。 |

## 本轮模型与应用来源

主线程准备材料固定实际应用源码为上述集成提交，Mac Release 构建真实退出 0。最终独立核对应用全部 24 个常规文件与初始逐文件 SHA 相同；框架二进制的 symlink alias 不重复计数。清单 compact-JSON 编码（path→sha map，sort_keys=True，separators 为逗号/冒号）的 SHA-256 为 `25f8c319823f4cf780f6bbd708df6f88ffa69a9ed901f1cee1ef1933aab0810b`；保存的格式化 JSON 文件本身 SHA 为 `296a2dfef9f380c8746e75a169c3dd186736669c1c2762d4f9c4f1a6aed8fef7`。两种编码分别记录。本轮 linked 引擎为官方 b11381，实际版本输出 `0.5.0-dev (build 11381, commit 836d57176)`、Darwin arm64；Ready 与推理由本轮实际调用另证。

共享 Kev Q8_0 和 Laya Q8_0 的本轮完整字节 SHA-256 分别为 `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0` 和 `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2`；官方引擎归档为 `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341`。资产位置和所有权沿用共享模型库。

主线程 C0 保存记录显示任务前 `settings.json`、`engines.json`、`jev_models.json`、`startup-models.json` 均不存在。C1 保存记录和准备时实际 UI 显示全部三种名称未就绪。授权后本轮实际应用 PID 为 79681；HTTP 为 `http://127.0.0.1:54841`，MCP 为 `http://127.0.0.1:54842/mcp`；客户端推理发生在 2026-10-08 05:27–05:29 UTC。

成功同次 debug 保存于 `accept37-ready.json`：Kev instance/alias 为 `jev-86a2302d56798f093e5a2eca9d194d8e03390babd3c1f99d`、generation 1；Laya 为 `jev-2240374b4306cb2891ad7331a1f5daf57f0e0d0b0894a428`、generation 2。二者实际 binding 的 linked engine ID 为 `6580cfaca3ddda78d6aa13f3c5725f58479b583e`；全部后续 debug 保持同一实例与代次，实际 request/request_body/raw 的 alias 一致。

## 本次实际客户端结果

实际 initialize/list_tools/list_jev_models 与 HTTP GET `/v1/models` 发现 quick/council、hard/council、native-kev-q8/native。工具为 `decide_jev`、`decide_jev_batch`、`list_jev_models`，两决策 schema 均要求 model，没有平行旧工具。全部 12 用例推理前通过实际 schema 校验。Python MCP SDK 2.0.0 实际协商并采用 `2025-11-25`；服务自报 ghostmodeldeck/0.1.0，该服务字段不作为应用发行版本。

6 个 HTTP 和 6 个实际 MCP SDK 决策调用通过。普通 choice 的 input_tokens 为 quick/native 43、hard 88；复杂混合为 quick/native 209、hard 474；普通混合为 quick/native 118、hard 251。全部 output_tokens 为整数 0；default 严格只有 model/answers/usage，debug 对账本次标准结果、入场配置、每席 raw、实际请求、身份和完整委员会总结果。完整 12 结果保存在 `accept37-protocol-results.jsonl`，最终离线 oracle 真实退出 0、12 项通过。

| hard 同次结果 | choice 分布 / 结果 / confidence | score 分布 / 期望索引 / confidence | noul / input_tokens |
| --- | --- | --- | --- |
| HTTP 复杂混合 | a=0.343130330，b=0.656869670；b / 0.313739340 | [0.238898829, 0.294750154, 0.466351017]；1.227452188 / 0 | 0.886730052 / 209+265=474 |
| MCP 普通混合 | a=0.746808934，b=0.253191066；a / 0.493617867 | [0.086615625, 0.514805229, 0.398579146]；1.311963521 / 0.272207843 | 0.888896115 / 118+133=251 |

表格仅为显示而舍入；oracle 使用 raw 的完整 decimal，容差为 0.0001。每次原始响应与协议包装、请求关联和时间均保存，分别执行的推理不强求相同数值。

实际 Hermes 使用已安装源码 HEAD `bd0affe5e5f723579df8902852f5d0c47795f355`、stamp `0.21.5+6224.gbd0affe`，固定 CPython 3.14.7、MCP 2.0.0、jsonschema 4.26.0。执行前后确认解释器/wrapper、源码内容及依赖选择/锁文件/安装元数据 digest；此依赖摘要不覆盖全部依赖包字节，既有三处源码修改保留。唯一任务 profile 仅配置本机 gd，sampling/elicitation 关闭；未读取用户 profile/凭据、执行 launcher/bootstrap、安装更新或远程 LLM。

Hermes 完成三个 model 各自的单题 choice 与复杂混合 batch，6 个实际 dispatcher 调用均消费标准结果。观察到 executor/registry/handler/SDK 调用计数 7/7/21/28（包括发现与内部 schema 调用），协议采用 `2025-11-25`，SDK clientInfo 自报 mcp/0.1.0，与 Hermes 安装 stamp 分别记录。原始失败/清理失败均 null，真实退出 0，stderr 为空。该证据为已安装 Hermes executor 的发现、调用和结果消费，没有执行 Hermes 大模型 chat。

SDK context 释放后 new_pending_tasks 为空且无清理 warnings。Hermes pending_tasks/new_alive_threads 为空，retained loop 关闭/thread 不存活、model-tools loop 关闭，保留 server 的 session 为空/task done/inflight0/refresh0；只剩非活动 `_server_error_counts['gd']` 元数据。唯一任务 profile `/private/tmp/ghostmodeldeck-hermes37-lvhny9q1` 的 6 个生成文件及无凭据配置已完整归档并逐文件 SHA-256 核对后删除，记录见 `accept37-hermes-profile-cleanup.json`；用户原有 profile 未读、未改。

原始非零结果仍保留：protocol run01 退出 1 是 oracle 错把 EMD 除以 K−1，原生与 hard 两份成功输出离线修正复算退出 0 后，run02 仅执行剩余 10 项并退出 0；产品未改、这两份推理未重跑。第一次 profile 清理 helper 退出 1 是错误假设 Hermes 不会生成 scaffold/cache，删除前即终止；其后离线 oracle 因合集未生成而退出 1。核对任务目录所有权和无 symlink、完整归档后清理并重新生成合集，最终 oracle 退出 0。它们属于验收工具错误，未被计为原始运行通过。

## 实际窗口与复制的离线对账

主线程在实际 Release 窗口依次执行 native Kev → HTTP hard 双席 → MCP quick 单席普通混合三题型。本次实际 AX 显示的每次 request/debug 保存于 `native37-gui-records.json`，43489 字节，SHA-256 `d32d1f5ad0b82c4855c2e2847784489fca7a066cdb5ae1baec8c3fdaffc68147`。应用源码/PID 与本轮客户端记录一致；离线复核没有再次发起推理。

native 实际输入中的 alias 与所选 Kev/gen1、linked 引擎、固定调用名和 10 秒预算对应，实际 request_body=request，raw_response=result=converted_result。HTTP hard 40 秒两席和 MCP quick 20 秒一席的同次来源、配置、请求、完整 raw、标准结构与 usage 经同一独立 oracle 通过。三模式 input_tokens 分别为 118、251、118，output_tokens 均 0。原生普通 score 的完整分布 `[0.0730252457252356, 0.5217355585442086, 0.4052391957305559]` 与实际 confidence `0.28260333781631275` 一并保留，没有重算其原生字段。

主线程实际点击 HTTP debug 复制、粘贴至本次新建 TextEdit 文稿并本地保存为 `native37-gui-http-copy-debug.json`，18578 字节，SHA-256 `27b6f6f2e368a70dfb4b2bb499f9441b86fb461d4c99c72d30843494c2b495d0`。离线检查完整 JSON 对象与该次窗口 HTTP debug 相等。三个窗口模式及实际 clipboard 对账记录见 `accept37-gui-oracle-results.json`，真实退出 0，stderr 为空。

窗口工具障碍单独记录：CUA AX setValue/selection 未可靠改变 Flutter controller，初期无效 JSON 没有提交；通过鼠标选择真实文本区间清空后提交成功。本次新建 diagnostic 文稿最初保存到 TextEdit 默认 iCloud 目录，随后通过原生 MoveTo 移回任务本地，最终 URL 与读取字节确认；没有操作用户原有文稿。这些障碍不作为产品推理失败或成功证据。

## 实际 default、窗口关闭与重启恢复

`native37-gui-edit-default-discovery.json` 记录实际 MCP 发现三个名称/来源、普通混合请求 Form→JSON 后 JSON 值完全保留（不要求成员顺序）、default 结果只有 model/answers/usage、debug Checkbox 为 0 且调试面板消失。实际 default 与该输入先前 debug 的标准结果恰好相等，此次观察不构成重复推理数值恒定保证。该记录为普通文本混合，不作为复杂字段编辑的证明。

关闭窗口后 `native37-window-close-http.json` 的真实 HTTP hard 仍返回旧 Kev/gen1、Laya/gen2 的两席完整混合；离线 raw/Fraction、配置与 usage 验证通过。实际 lsof 列出应用 PID79681 的两协议监听及模型 PID91792/92011 的原生监听，两个 registry 字节与 C1 一致。初次记录驱动的 ps 子进程被 sandbox EPERM 拒绝，导致该次成功响应无法持久保存；换用实际 lsof 的定点记录成功。原始环境/工具障碍保留，没有作为产品失败或原始运行通过。

`native37-normal-quit.json` 记录原生正常退出后应用79681及两模型91792/92011 均不存在，process/lsof 探针为空，四端口54841/54842/62156/62415的 connect_ex 均为61（拒绝连接）。`native37-restart-offline.json` 记录同一 Release 源码重启为 PID6350，HTTP models200为空，仅应用协议监听恢复，没有隐式模型加载。engines.json 和 jev_models.json 的 SHA-256 在关窗和重启记录中均与实际 C1 快照字节独立核对相同。

上述四份实际记录经 `accept37-lifecycle-oracle.py` 离线验证退出 0、stderr 为空；该复核没有启动应用、模型或追加协议调用。

## 显式再启动与复杂窗口编辑

初次重启加载被自动审批拒绝：泛化“继续”被判断不足以授权此次精确模型重启，被拒绝的动作没有执行。用户随后明确回复“允许重新加载这两份模型并完成验收”，授权及解除记录为 `native37-restart-authorization.json`；主线程再通过实际 GUI 加载两模型。该审批记录与最初本轮加载/推理授权分别保留。

`native37-restart-live.json` 固定实际 PID6350 和原源码。C1 profiles 字节不变，Kev 解析到新 alias/instance `jev-4abc1ba32176bd73839bff7fffecc74b3de2735a28fc4b7e`、generation1/PID7190；Laya 解析到 `jev-b18b267108a58a94fa56ededb42c4567caf99ef937db22d7`、generation2/PID11929。两者 alias 与初轮不同，稳定资产/引擎 binding 保持不变。native-kev-q8、quick、hard 三种固定调用名的真实 HTTP 复杂混合全部200成功；原生/单席保留同次 raw，双席 Fraction 综合、confidence、noul 与实际用量通过。

主线程在真实窗口 HTTP hard 以完整复杂 JSON 执行 JSON→Form→JSON→实际提交。Form 对结构化 state、choice/score criteria 和 noul null 提供只读提示；最终实际 debug.input 与预备复杂请求按 JSON 值完全相等，包含 `English / 中文`、对象、数组、boolean、nullable 描述/criteria 及 `images: []`，未静默删除。两个真实席位、入场配置、新实例、raw 与标准结果同次对账通过。材料为 `native37-gui-complex-record.json`，22696 字节，SHA-256 `98a393365850bcf695013046b0afe6b9f4578ef394e9012171a58c27545cf984`。

以上三份持久记录经 `accept37-restart-oracle.py` 离线核验退出 0、stderr 为空，未追加推理或窗口操作。最终资源与配置恢复见下文。

## 最终收尾与保留

`native37-final-cleanup-and-preservation.json` 记录应用6350及本次模型7190/11929全部退出，真实 process 探针为空；协议与两轮原生服务的六个端口 connect_ex 均为61。本次配置只有严格匹配 C1 的 engines.json/jev_models.json，经主线程移动到 `.tooling/native37-state-20261008/c2-final/` 可恢复保留；settings.json、engines.json、jev_models.json、startup-models.json 原来不存在，当前均已恢复不存在。没有移动或删除用户已有配置及共享文件。

最终离线核对当前四目标确实不存在，C2 两文件的真实字节 SHA 和权限分别与 C1 及清理记录一致。root 最终实算的 Kev812406304/Laya449397600 字节及 SHA 与初始记录相同，当前文件大小也匹配；共享资产位置和所有权保留。任务 Hermes profile 已归档并删除，客户端资源已释放，所有运行条件闭合。

最终 `accept37-final-checks.py` 真实退出 0、stderr 为空；`accept37-local-final-checks.json` 绑定当前源码、98 个有效门禁输入、三份原有 source archive/log/exit 和 24 个实际应用文件。复核没有调用模型、在线端点、GUI、容器或新测试作业。保留的 C2 是本次创建的可恢复测试配置，不是尚未恢复的用户备份。

## 数值与协议断言

已执行有限矩阵为每个实际调用名：HTTP 普通 choice default、复杂混合 debug；MCP 单题 choice default、普通混合 debug；Hermes 单题与复杂混合 default。全部输入在推理前按本轮实际工具 schema 和模型发现校验。不同实际调用的细小数值差异单独记录，不强求重复推理数值相等。

独立 oracle 不导入产品计算代码。hard 两个完整成功席位的每题概率使用各席本次 raw 中的 decimal 值，以 Fraction 求等权平均。K=2 choice 取最高综合概率，完全相等时取按 ID 排序的首项，confidence 为两概率绝对差。K=3 score 为 `p1 + 2*p2`；以最低索引众数为点质量，使用等级步长单位的运输距离 `Σ p_i*|i-mode|`，confidence 为 `max(0, 1-1.5*EMD)`。noul 仅对标量求均值，不增加概率或 confidence。usage 累加完整成功席位的实际 input_tokens，output_tokens 为整数 0。

quick 单席与原生固定调用名分别核对本次实际单模型 answers/usage 保留。debug 核对来源、入场配置、绑定、实际 instance/generation、发送 request/request_body、原始 response 及公开 model 映射；完整混合响应使用同一组有效席位。标准输出和每席 raw 之间的比较始终来自同一次调用。

这些断言只验证本轮协议、身份、综合语义与记录口径，不表示概率已校准、决策正确率、席位独立性或性能保证。

## 确定性边界与工程门禁

[当前 #36 公开验证及最终门禁](jev-inference-playground.md#最终工程门禁)记录 92 个受影响用例、format 90 文件/0 改动、analyze 零诊断与全套 540 项测试，真实宿主/job 退出均为 0。最终 98 个输入的 compact-JSON manifest 为 `599a2a388cd2a425ae1e77dc938882505dffd4669138e2b7af8680af1e0298d2`，逐行 manifest 为 `9ba7d91275016afc6ede6ed2322a1b655c5a2ee72ff52271392a8cb1fe48de96`。本轮最终逐文件与当前分支核对相同，并核对三份归档、日志及真实 exit，复用这些有效门禁，不重复相同长作业；真实模型与客户端另列。

| 确定性要求 | 当前公开证据边界 |
| --- | --- |
| 必填/未知 model、名称冲突、alias 更换后稳定绑定、歧义、离线配置无加载 | #33 命名路由公开业务、真实 HTTP/MCP 与生产页面测试，纳入当前最终门禁。 |
| 配置变更/重命名/删除入场快照、单席/零席、批量整席非法退出 | #33 与 #34 公开业务和协议用例，采用已确认的外部引擎 I/O 替身；本轮真实 quick/hard 整批完整成功 raw 验证另列。 |
| confidence 独立已知向量、等权综合、用量与三题型 | 当前公开协议/业务向量测试；本轮真实结果 oracle 另列，不引用替身作为真实概率来源。 |
| 取消/超时、晚到封存、并发隔离、许可回收 | #35 与 #36 可控时序公开用例，当前 macOS HTTP owned lease 回环 19 ms 排空；普通外部 HTTP 断连仅沿用业务预算排空，不宣称即时取消。 |
| default/debug、实际发送请求、复制及认证凭据投影 | #35/#36 公开入口和生产页面用例，包含合法数据/真实凭据修正；本轮实际客户端、窗口 debug/default、实际复制与原始请求分别对账通过。 |

## 逐项验收与交接

按 #37 七条要求核对：授权/Ready 已明确；quick/hard 持久配置与混合三题型、每席 raw/综合/confidence/usage 完成；原生固定名同实例直连保留实际字段完成；实际 Hermes 新工具发现、显式 model、dispatcher 与结果消费完成；当前自动化边界及相关门禁有效；证据区分替身、真实模型、窗口与实际客户端并关联源码/实例/请求；本次资源释放、C0 恢复与共享文件保留完成。本期仅 JEV，不扩展标准文本、SSE、oMLX 或其他模型能力的验收。

原始工具/环境/审批错误与修正证据保留，root `continuation/retro37.md` 已关闭本期全部具体发现；当前未关闭 P0/P1/P2 均为0。记录不保证概率校准、决策正确率、席位独立性或性能。本验收候选只有两份新增文档，等待主线程统一审查与提交；Git/GH 操作权归 root，本 worker 未提交或推送。
