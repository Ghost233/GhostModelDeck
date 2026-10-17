# 场景配置与实例运行控制交付记录

## 当前状态

2026-10-17。这是规格 #102 及子工单 #103～#111 的唯一当前交付入口。规格交付后，用户另行要求正式发布并选定 0.2.3；发布结果见[0.2.3 发布验收](release-0.2.3.md)。

- 阶段：前置及 A～D 全部完成并合入 dev；规格 #102 及 #103～#111 全部关闭，A01～A22 验收完成。
- 总交付起点：`20410147e8186c44910eb8f50e41ccfd0c26d5c8`。
- 固定候选：阶段 D `702d4b250d77e5a1084540363bd7fc2a00f58555`，集成提交 `9aadf56c85eb4446abd9e3414406bb2ba7982d49`，两者树完全相同。后续发布增量 `6bbdbb872a18a1d792abd51a2f0747b62a576f64` 只改变版本字段和发布文档，合入 main 的发布提交为 `b7ea928c9ba02e5fc23ada9cd477dc7141961158`。
- 审查：Standards、Spec 和跨阶段审查未关闭 P0／P1／P2 均为 0，见[总审查](scenario-runtime-controls-final-review.md)。
- 负责人：主线程，未启动子代理。
- 有效作业：无。隔离窗口验收已正常退出，自有进程与监听端口全部释放；正式 GMD PID 9547 和五个已有模型进程保留。
- 未关闭事项：无产品开发、验收或阶段集成待办。首次自动重开的一次原生失败保留为历史观察，原因未确定，不宣称修复；随后相同配置手动和自动重开成功。
- 下一动作：本次规格与后续 0.2.3 发布均已完成，没有活动交付作业。正式应用与已有模型服务保持原状，不自动切换本机版本。
- PR：前置 #112、A #114、B #115、C #116、D [#117](https://github.com/Ghost233/GhostModelDeck/pull/117) 均已合入 dev；[总 PR #113](https://github.com/Ghost233/GhostModelDeck/pull/113) 为 dev → main，已按后续正式发布授权合入 main。
- 同步：发布时本地 main／dev、跟踪分支与实际远端全部为 `b7ea928c9ba02e5fc23ada9cd477dc7141961158`；v0.2.3 本地及远端也指向该发布提交。最终结果文档另以元数据提交同步 main／dev，完整 hash 见发布记录的 final-sync.json；阶段分支仍对应各自已审查候选，没有 stash、文件搬移或恢复备份。


## 范围和阶段

来源：[正式规格](../requirements/mcp-scenario-aliases-and-runtime-controls-spec.md)、[实施工单索引](../requirements/mcp-scenario-aliases-and-runtime-controls-implementation-plan.md)、[ADR 0008](../adr/0008-mcp-scenario-aliases.md)。

| 阶段 | 范围 | 进入后继的条件 |
| --- | --- | --- |
| 前置 | 已保留的 Splash 持久准备、draft 修复及未关联配置删除 | 固定提交、核对可复用门禁与原生证据，审查后独立 PR 合入 dev |
| A | #103 单实例场景 → #104 委员会场景 → #105 容量预览和重启生效 | 同阶段前置切片验收并进入候选；完整阶段审查、门禁及 PR 集成 |
| B | #106 三表管理、#107 两行并发监控、#108 一分钟速度 | 独立切片定点验证；收齐后集中审查、门禁及 PR 集成 |
| C | #109 总开关 → #110 独立自启动设置 | 准入、取消、代次和资源验收后，阶段 PR 集成 |
| D | #111 总集成与原生短流程 | 全规格核对、总审查、最终门禁与真实验收；dev → main 总 PR ready |

原规格交付约定为阶段 PR 指向 `dev`，总 PR 从 `dev` 指向 `main` 并保持 ready；该状态已完成。用户随后另行要求正式发布并选择 0.2.3，总 PR 已在新授权下合入 main。沿用已授权的集成方案，使用当前工作区，不创建额外 worktree 或 codex 临时集成分支。Git 操作串行，保留用户及其他会话修改；合并后仅 fast-forward 同步本地相关分支。

实施与审查沿用 implement-spec、TDD、code-review 和 retro 的方法。用户的主线程要求取代它们的子代理分工。每次审查分别记录 Standards 和 Spec 两个轴，固定基准与已提交候选；阶段 PR 最终 ready 与总交付检查由本流程完成。

## 未实现功能

无。全部确认功能已实现、验收并集成。评测集继续作为可选功能，不新增逐模型成绩前置。

## 未验证变更

无。最后增量只涉及验收测试和文档，生产源码未变。规格收尾输入匹配 run-knMMJQ，完整宿主与增量检查合计覆盖 1072 个唯一用例。后续 0.2.3 只改变版本字段，已补版本相关检查及重新构建，不冒称旧指纹直接覆盖新版本字段。真实窗口、普通 HTTP／MCP、取消及资源收尾已补齐，见[原生窗口验收](scenario-runtime-controls-native-window.md)。

## 已验证并集成的阶段 D

阶段 D 验收测试为 `8bfb96317120efe8a52243f01e56f018a960e6d3`，最终复审候选为 `702d4b250d77e5a1084540363bd7fc2a00f58555`。PR #117 已合入 dev，集成提交为 `9aadf56c85eb4446abd9e3414406bb2ba7982d49`。总 PR #113 已在后续 0.2.3 正式发布授权下合入 main。没有未提交的产品改动或活动题集。

## A01～A22 逐项验收映射

表内证据按业务、Widget、公开协议和真实窗口分别标明。A22 已补齐场景编辑、三表、两行监控、总开关、独立设置、重开和正常退出；详细观察及失败边界见原生窗口验收。

完整宿主证据为 run-JTZMOa；审查增量为 run-xJrwYw 与 stage-c-verification-bundle.json。草稿 HTTP 执行中总关闭新增回归 run-8Kqaw4：通过真实回环 HTTP 和原生 I/O 替身，未直接取消草稿按钮 token，仍获得 HTTP 499，普通及临时实例全部停止，保存配置和资产保留。随后 run-cBPv5b 两个受影响模块共 41 项、run-Zy4Vqq 分析与 run-knMMJQ 只读格式通过，当前为 1072 项组合覆盖，见 stage-d-verification-bundle.json。run-ftADsN 的新增测试花括号诊断原记录保留。未对真实模型执行题集。

| 条目 | 范围 | 当前证据 | 结论 |
| --- | --- | --- | --- |
| A01 | 四槽／编辑／持久化 | [model_scenarios_test.dart](../../test/model_scenarios_test.dart)、[mcp_page_test.dart](../../test/mcp_page_test.dart)；run-JTZMOa | 业务和 Widget 通过；原生编辑和重开保留见 A22 |
| A02 | 默认发现范围 | [council_mcp_test.dart](../../test/council_mcp_test.dart)；run-JTZMOa；native-105-63887/result.json；native-c-28409/result.json | 接口通过；关闭后实际列表为空 |
| A03 | 统一模型名字 | [council_mcp_test.dart](../../test/council_mcp_test.dart)、[instance_public_http_test.dart](../../test/instance_public_http_test.dart)；run-JTZMOa；native-105-63887/result.json | HTTP／MCP 解析和原生短调用通过 |
| A04 | 绑定与在途快照 | [council_mcp_test.dart](../../test/council_mcp_test.dart)、[council_scenarios_test.dart](../../test/council_scenarios_test.dart)；run-JTZMOa | 在途换绑不换实例、改名重开绑定通过 |
| A05 | 委员会可用性 | [council_scenarios_test.dart](../../test/council_scenarios_test.dart)；run-JTZMOa；native-105-63887/result.json | 全部成员固定容量及至少一成员可用的 partial 通过 |
| A06 | 场景文字边界 | [mcp_page_test.dart](../../test/mcp_page_test.dart)；run-JTZMOa | 编辑说明只保存，不启动／探测模型；业务和 Widget 通过 |
| A07 | 固定模板说明 | [council_scenarios_test.dart](../../test/council_scenarios_test.dart)、[council_mcp_test.dart](../../test/council_mcp_test.dart)；run-JTZMOa；native-105-63887/result.json | 刷新和重连说明、名字与容量通过 |
| A08 | 上下文与预览 | [council_scenarios_test.dart](../../test/council_scenarios_test.dart)、[model_run_dialog_test.dart](../../test/model_run_dialog_test.dart)；run-JTZMOa；native-105-63887/result.json | 全部成员最小值、影响预览、取消通过；原生预览、取消和重启见 A22 |
| A09 | 参数重启生效 | [launch_instances_test.dart](../../test/launch_instances_test.dart)；run-JTZMOa；run-xJrwYw；native-105-63887/result.json | 保存仍 4096、成功重启更新 8192；失败及旧代次不应用 |
| A10 | 三表行与列 | [library_page_test.dart](../../test/library_page_test.dart)、[engine_page_test.dart](../../test/engine_page_test.dart)、[instances_page_test.dart](../../test/instances_page_test.dart)；run-JTZMOa；run-xJrwYw | 变体／登记／保存配置独立成行及列完整；原生目视通过，见 A22 |
| A11 | 搜索排序分页 | [management_table_test.dart](../../test/management_table_test.dart)、[instances_page_test.dart](../../test/instances_page_test.dart)；run-JTZMOa；run-xJrwYw | 全数据查询后分页、稳定身份和大字号操作可达通过 |
| A12 | 两行与并发格子 | [runtime_monitor_page_test.dart](../../test/runtime_monitor_page_test.dart)、[runtime_monitor_test.dart](../../test/runtime_monitor_test.dart)；run-JTZMOa；existing-monitor-native-result.json | 两行／四槽／终态复用及不重复实例通过；原生目视通过，见 A22 |
| A13 | 阶段与排队 | [runtime_monitor_test.dart](../../test/runtime_monitor_test.dart)；run-JTZMOa；existing-monitor-native-result.json | 原生槽位与 HTTP 容量区分、阶段／排队解析通过；原生目视通过，见 A22 |
| A14 | 缺失监控数据 | [runtime_monitor_test.dart](../../test/runtime_monitor_test.dart)；run-JTZMOa | 零与未知分开、错误隔离通过；原生目视通过，见 A22 |
| A15 | 一分钟速度 | [runtime_monitor_minute_test.dart](../../test/runtime_monitor_minute_test.dart)；run-JTZMOa；existing-monitor-native-result.json | 60 秒边界、阶段耗时增量和实例／代次隔离通过 |
| A16 | 移除曲线详情 | [runtime_monitor_page_test.dart](../../test/runtime_monitor_page_test.dart)、[runtime_monitor_test.dart](../../test/runtime_monitor_test.dart)；run-JTZMOa | 无曲线／详情、采样与可见构建有界、隐藏迟到不发布通过 |
| A17 | 总开关关闭 | [engine_master_switch_test.dart](../../test/engine_master_switch_test.dart)、[model_launch_test_test.dart](../../test/model_launch_test_test.dart)、[benchmark_lifecycle_test.dart](../../test/benchmark_lifecycle_test.dart)；run-JTZMOa；run-8Kqaw4；native-c-28409/result.json | 执行／启动／批次及草稿 HTTP 取消通过；窗口保持可操作，见 A22 |
| A18 | 准入与关闭竞态 | [engine_master_switch_test.dart](../../test/engine_master_switch_test.dart)、[sdk_service_test.dart](../../test/sdk_service_test.dart)、[omlx_pool_test.dart](../../test/omlx_pool_test.dart)、[engine_catalog_splash_test.dart](../../test/engine_catalog_splash_test.dart)；run-JTZMOa；native-c-28409/result.json | 三引擎／SDK 准入、关开关代次及真实重开只选中实例通过 |
| A19 | 独立自启动配置 | [runtime_autostart_test.dart](../../test/runtime_autostart_test.dart)、[instances_page_test.dart](../../test/instances_page_test.dart)；run-JTZMOa；run-xJrwYw | 两类配置独立、不持久化当前状态、默认关闭、保存回滚通过 |
| A20 | 开启与并发启动 | [runtime_autostart_test.dart](../../test/runtime_autostart_test.dart)；run-xJrwYw；native-c-28409/result.json | 并发／幂等／失败隔离和手动重试通过，未选项不启动 |
| A21 | 配置与资源保留 | [engine_master_switch_test.dart](../../test/engine_master_switch_test.dart)、[runtime_autostart_test.dart](../../test/runtime_autostart_test.dart)、[launch_instances_test.dart](../../test/launch_instances_test.dart)；run-JTZMOa；run-xJrwYw；native-c-28409/result.json | 开关不改选择、不删资产／历史、不停正式服务通过；正常退出及配置指纹不变，见 A22 |
| A22 | 完整原生窗口短流程 | [原生窗口验收](scenario-runtime-controls-native-window.md)；native-window/gui-evidence.json、protocol.json、load-summary.json、final-off-discovery.json 和 final-quit-result.json | 通过：真实界面、HTTP／MCP、取消、所选实例重开、设置持久化及自有资源释放；原始失败另列 |

## 阶段 D 原生窗口验收

隔离应用调用同一生产 main，只替换外部存储和 socket 边界，不替换业务、运行时或模型。macOS arm64 构建和签名通过；应用名称为 GMD Acceptance 102，避免与正式 GMD 混淆。验收使用实际 GhostSplash 和已有 InnerJev 文件，未运行模型题集。

已完成真实窗口场景与委员会配置、三表与搜索、容量预览取消、保存不打断及重启应用、两行四槽监控、分钟速度、执行与排队取消、自动开启的两种重开状态、正常退出和自有资源收尾。六个短 HTTP 请求中，关闭前完成两项 HTTP 200，其余四项 HTTP 499；不把取消计为模型通过。HTTP／MCP 关闭后仍可访问且发现列表为空。

首次自动重开出现一次原生启动失败，相同配置手动重试及下一次自动重开成功。原失败保留，原因未确定，不宣称修复；GMD 正确显示失败，不自动换模型或循环重试。最终已无活动验收作业，正式应用和已有模型进程保留。

隔离壳构建、输入工具、监听日志与发现断言的原始执行器失败单独保留；不把它们改写成产品通过。具体数据、端口、PID、执行结果与复用边界见[原生窗口验收](scenario-runtime-controls-native-window.md)。

## 已验证并集成的阶段 C

PR #116 已合入 dev，合并提交 `88180ba5dec4121c596dc0a1f67c7dbb8017ae48`。#109／#110 已按验收评论关闭，#111 已分配给 Ghost233。实现候选 `39b46447edd903ef08ee1a771f1e7cf46f758c2f`，文档候选 `2f6cdbc18274f33f05c11722e837e57d06f741fb`，双轴复审与复盘无未关闭 P0／P1／P2，见[阶段 C 审查](scenario-runtime-controls-stage-c-review.md)。

1071 项组合范围及原始失败见下方增量记录和 `stage-c-verification-bundle.json`；真实取消、重开和资源收尾见 `native-c-28409/result.json`。生产入口产物保存在 `.scratch/scenario-runtime-delivery-20261016/production-c/Ghost Model Deck.app`，三个 Mach-O 仍仅 arm64；为后续隔离窗口构建保留，不覆盖正式应用。六个相关本地分支已与实际远端核对一致，机器记录为 `stage-c-integration.json`。

## 已验证并集成的阶段 B

PR #115 已合入 dev，合并提交 `6026b0c7f1c5db436873db3cb22c48f12640009f`。实现候选 `f19d8f90551dd62b3411462e16ad75e7c91a0d7e`，最终双轴复审与复盘无未关闭 P0／P1／P2。下面保留原始增量、失败与复用边界，不再视为阶段 C 待办。

- 共用表格实现全数据搜索／状态筛选／排序后分页，每页最多构建 20 行；窄窗口横向滚动。
- 引擎页已使用来源、版本、状态和操作列；下载／参数／详情保留，删除与解除关联移入更多菜单。生命周期、参数弹窗、源码详情的测试操作已按新表格先滚到可见区域。
- 模型库每个变体一行，显示格式、量化、大小与目录；创建实例按该行资产身份调用。共享 projector 在仍有其他变体引用时保留。详情只展示有限摘要和文件路径，完整目录通过 Finder 查看；既有运行和公开 API 操作保留在详情入口。
- 实例表显示保存配置、统一模型名字、模型、引擎、生效上下文、配置并发、自启动、状态和操作；复用已有启动集合持久化，不因勾选而启停模型。改名、复制、JEV 预算及删除移入更多，编辑／运行／停止保留行内。
- 并发显示只读取可识别的原生推理配置；不把 HTTP 队列大小当作推理槽位，未知显示 —。上下文显示已生效值，预览和保存配置仍按阶段 A 的重启语义处理。
- 三表字体／布局、Finder 通道、原生监控数据链和分钟窗口已有增量证据；不将切片通过当作最终整体交付完成。

- `run-b7Sc16`：共用表格三项检查通过，包含 63 行跨页搜索、排序／筛选后正确对象操作、深浅主题真实字体长路径与操作可达。
- `run-JqtBUe` 引擎旧布局未提供表格的原失败保留；`run-FLm2cu` 默认来源、版本和表格列定点通过。
- `run-dpcEZr` 静态提示已按规范修正，`run-nvCOqt` 通过。
- `run-PTMzGv` 旧“没有任何输入框”断言失败；改为精确只允许新增搜索及状态筛选后 `run-yzCINx` 原用例通过，原无模型启动／连接表单限制保留。
- `run-RwAXhV` 安装按钮因表格横向滚动不可见导致点击未命中，先滚到可见区域后 `run-MBqcMz` 原用例通过；原时限与断言不变。
- `run-GGyGco` 的源码详情仍使用旧“最后一行”定位，排序后选错对象；改为按引擎身份定位并主动翻转排序后 `run-UngACn` 通过。随后 `run-4JveE4` 引擎页、启动生命周期和源码对话框三个模块 22 项全部通过。

- `run-HgyB80`：参数弹窗与共用表格 33 项通过；`run-89G1kR` 七个受影响文件分析通过。
- `run-PgIqFz` 模型库按变体展示的原失败保留。实现后该新用例通过，旧创建实例用例因操作列需横向滚动而未命中，`run-Znlkk7` 保留；明确滚动后 `run-Gj9CDD` 原失败通过，`run-hTvNGR` 模型库及参数生命周期两模块 33 项通过。`run-TGb9kb` 三文件分析通过。
- `run-Mu01aX`：实际临时 GGUF 文件验证删除一个变体不会删掉另一变体仍引用的 projector；删除最后一个变体时清理配套文件。只操作本次测试临时目录，没有更改用户模型文件。`run-AOMj59` 模型库和共用表格两模块 7 项全部通过，`run-41ctjL` 新增用例分析通过。

- 实例表的精确原失败 `run-GW7K4m` 确认 DataTable 尚未实现；此前 `run-y2RENw` 是 Widget 夹具网络拦截，未作为功能红灯。`run-uBJxS3` 配置并发语义与 63 份实例跨页查询、自启动保存、复制隔离通过。
- `run-KvPegM` 预算菜单测试在 FakeAsync 时间域保存等待超时，原失败和终止收尾错误分开保留；仅调整菜单开启的测试时间域后 `run-7H7FVY` 原用例通过，`run-EpenDb` 参数预览、预算、准备中保护、改名和 SDK 自启动表格入口五项全部通过。
- `run-tpNaPf` 精确发现 2 倍字号的排序表头溢出；让最小列宽随字号增大后，`run-HN9OPu` 原失败通过，`run-976je9` 实例表与共用表格两模块九项通过，包含深浅主题、1.5／2 倍字号、长名字和操作可达。没有裁掉排序图标或放宽断言。

- `run-hf7Mwb` 模型／引擎表八项桌面布局通过，表头与数据样式明确断言真实字体。测试 DataTableTheme 漏用字体的原方块字截图保留，可读截图在 `stage-b-table-layout-fonts`，已实际查看。
- `run-janGZ3` 模型摘要和 Finder 原生通道边界通过，真实目录传入正确，模型文件未变。`run-ptgBKX` 14 个本批文件分析通过，`run-iWzlEj` 后续两个测试文件分析通过。
- `run-z33No9` 前 50 项通过，一项异常摘要用例因操作列未滚到可见区域失败；原失败保留。仅补明确滚动后 `run-IoNEGj` 原失败通过，`run-GSoHQk` 参数／SDK／完整桌面模块 99 项全部通过。输入对比只有该测试文件变化，其余成功证据复用；两次运行重叠四项，当前受影响范围合计 145 个唯一用例有成功证据。
- #106 切片机器记录：`issue-106-acceptance.json`。不将原失败命令改写为通过；此切片验收不代替阶段 B 收齐后的完整门禁与审查，工单保持 OPEN 至阶段集成。

- #107：曲线、展开详情和详情入口已删除，每个实际受管运行实例独立两行；按原生 memory plan／slots 数据展示并发，排队独立。场景和委员会不增加监控实例；保存参数不改变原运行身份。
- `run-47rkUt` 复现 HTTP 容量冒充推理槽位、未知被当零、oMLX 全池统计被借给所选模型三个数据问题；均定点关闭。`run-P27sow` 监控数据和页面两模块 15 项通过，保留分页、字体、旧代次、隐藏页面及错误隔离，新增四槽位／三排队、槽位复用和一万个槽位仍只构建可见部分。
- `run-Ris6PB` 通过拥有进程身份的读取入口确认：HTTP 容量为 256 时原生并发仍为 4，读取不产生聊天或决策请求。`run-OaDkNM` 九个文件分析通过。原始类型导入、缓存 API 和静态失败保留。
- 本地 GhostSplash 的原生 Ready／memory plan 数据流与阶段累计耗时字段已只读核对，未修改引擎源码；来源指纹和 #107 机器记录见 `issue-107-acceptance.json`。#108 接入前，分钟平均保持 —，不拿全会话平均顶替。

- #108 六十秒计数窗口已接入两行页面，绘图历史已删除；重启身份、时钟／计数回退、缺失／零值、长间隔和迟到数据均有可控时间断言。详细数据来源与语义见[阶段 B 监控证据](scenario-runtime-controls-stage-b-runtime.md)。
- 实际现有 Splash 状态表明原生宽度在 memory_plan.budget，修正了仅靠原夹具未发现的路径遗漏。`run-rHxZLR` 定点通过，`run-OZVB5I` 对现有服务三次只读 GET 验证了原生 4／HTTP 1、真实阶段耗时和约 35.4 token/s 的 decode 窗口值。没有发起推理或重启服务。
- `run-LOydwU` 十文件分析通过，`run-GEpGZy` 六个监控及受影响引擎模块 124 项全部通过。分钟统计机器记录见 `issue-108-acceptance.json`。

### 阶段 B 最终验证与构建

- `run-cVvH6b` 完整执行：格式 213 文件退出 0，静态分析退出 0；1046 测试通过、3 个旧 UI 定位失败，整体真实退出 1，不重标为通过。
- 三项失败分别为参数识别、oMLX 弹窗按旧位置选择了其他引擎，以及查看下载未横向滚动。`run-kJAcmi` 三项原失败通过；同时将最后一处同类参数位置定位改为稳定引擎身份。`run-x121X3` 四份完整测试 47 项通过，`run-xmn8IO` 四文件分析与固定 Dart 的只读格式检查通过。
- 两次检查期间输入均未变。最终与完整运行相比只变化四个测试文件，应用代码未变；这些文件的用例名称全集一致且已完整重验，其余结果复用，当前全部 1049 项有成功证据。原完整运行失败状态保持；机器组合记录为 `stage-b-verification-bundle.json`。
- 固定 SDK 的 macOS release 构建真实退出 0；应用、App.framework、FlutterMacOS.framework 实查均仅 arm64。构建期间源码未变，输入与最终验证完全相同；记录为 `stage-b-build.json`／`stage-b-build.log`。正式应用 `/Applications/Ghost Model Deck.app` 未覆盖、未切换，PID 9547 未重启。

- 实现提交 `155d047` 的复审发现 R-B-SPEC-01：oMLX 的 stats 请求已有 model/session 筛选，之前一律留空累计量过于保守。现仅在生产入口确认请求作用域后恢复累计量，未筛选调用继续不借用全池数据；分钟速度仍不借用会话 gauge。
- `run-16IWH4` 三条正反数据范围契约通过，`run-OWzW8V` 从实际回环 HTTP 验证两模型选择器和不同累计量；`run-ba9ghK` 六个实际受影响模块 76 项通过，`run-akX5bO` 四文件分析通过。
- 该复审增量仅涉及 RuntimeTelemetry.omlx 和 OmlxEngine.readTelemetry 两个观察路径及两份测试，两个新增用例使最终覆盖为 1051。其余成功证据按未受影响范围复用，原完整运行退出 1 保留。最终组合为 `stage-b-final-verification-bundle.json`，未把原失败命令伪装为成功。

实现与复审修复均已提交。固定基准至最终候选的 Standards／Spec 双轴报告、复盘及复用边界见[阶段 B 审查](scenario-runtime-controls-stage-b-review.md)。阶段 A 代码、审查、集成及工单结项均已完成，不重复列为待办。

## 已验证并集成的前置改动

2026-10-16 对 `run-47WdgK` 输入逐文件重新计算 SHA-256，729 个检查输入全部未变。
真实退出码为 0，标准报告 successful_completion 为 true、failure_reported 为 false；检查期间输入未变。
因此可复用其 1011 项完整宿主检查，仅覆盖原前置代码，不宣称覆盖后续新增功能。

前置原生短 HTTP、arm64 构建与资源收尾证据见 [原记录](splash-managed-models-2026-10-16.md)。本轮不无故重跑原题集或重复启动正式服务。

前置代码固定为 `74001ac865188e5c5764b6be4e08c9719bb23cfc`，主线程 Standards／Spec 双轴复审及 retro 无未关闭 P0／P1／P2。
[Splash 自动准备持久模型目录并移除解绑配置历史 #112](https://github.com/Ghost233/GhostModelDeck/pull/112) 已合入 dev，合并提交为 `7e029d6a273d766a3488cead37aba4f861769a49`。
已核对本地和实际远端 main、dev、前置阶段分支的完整 hash，全部对应一致；未提交规划文档完整保留。

机器核对记录：`.scratch/scenario-runtime-delivery-20261016/baseline-revalidation.json`。

## 已验证并集成的阶段 A

当前阶段 A（#103～#105）的应用改动已提交为 `1f2e4bbcd1560cf61d4101aa2d406167b9d3ccdd`。固定提交审查见 [阶段 A 报告](scenario-runtime-controls-stage-a-review.md)，两个轴未关闭 P0／P1／P2 均为 0；PR #114 已合入 dev，合并提交 `d25241179fbf297e13548dfcf47173c6d02addd5`。新增场景持久化与编辑组件，接入共用决策路由、普通 HTTP 路由和应用组装。以下保留阶段 A 的原始增量过程；最终验证和复用边界在本节末尾：

- `run-kRy0TN`：MCP、页面和实例 HTTP 三个模块 21 项通过。此前 `run-IbaJfG` 在旧 Widget 夹具收尾挂起，已按失败终止并保留真实退出码 1。
- `run-qjGzKH`：共享网关、聊天、嵌入及保存实例 HTTP 四个模块 44 项通过。
- `run-TkA6q5`：场景重开、写失败回滚、名字冲突三个公共保存入口用例通过。
- `run-tqP6N1`：11 个受影响文件静态分析通过；后续新测试的最终静态检查仍需随下批代码收齐核对。
- 对话框释放问题：`run-p9b0fR` 原失败，等待路由完成再释放后 `run-ce11v4` 定点通过。
- Widget 夹具问题：`run-rZdKcE` 的有时限反馈明确停在 model subscriptions；单独卸载页面的 `run-8hmj5n` 仍失败。在真实 I/O 域预先初始化业务控制后，`run-1Lns9K` 及原三模块回归通过。清理完成结果由 runAsync 外层断言验证。
- `run-HwO8YS` 虽然报告退出 0，但缺少可靠的清理完成断言，不作为该问题的通过证据。所有原始失败、编译错误和格式化输入变化记录均保留。

机器进度与原始证据索引位于 `.scratch/scenario-runtime-delivery-20261016/`。正式应用及模型服务没有重启，新模型题集运行数为 0。

### #103 后续收齐的证据

- `run-3qU8gI`：10 个实际受影响模块共 101 项通过，包含动态说明、旧会话工具刷新／重连、在途换绑、冷态和删除、嵌入别名及生效容量生命周期。
- `run-XftkVO` 动态说明原失败，`run-B1mR53` 及后续模块回归通过。预算遗漏由 `run-9QvUBx` 复现，`run-G02zFC` 原用例与既有预算契约通过。
- `run-jwYMTm` 复现实例删除后残留容量缓存，`run-kDdDpx` 定点通过；运行中保存、停止、成功重启和复制的断言全部保留。
- `.scratch/scenario-runtime-delivery-20261016/native-103-7132/result.json`：一个独立 InnerJev／Splash 实例，两次短请求，HTTP 200／OK，MCP 返回有效概率，场景名字一致，配置容量 4096。自有进程与进程组均已退出，清理错误为零，源码指纹未变。
- 实际登记文件与随机端口独立于正式服务，准备目录位于持久应用数据目录，模型权重仍引用已有文件；正式 GMD 未切换、未重启。
- `run-Uftexo` 因引用不存在的测试文件整体失败，未计通过；核对实际路径后的 `run-3qU8gI` 才作为模块证据。字符串 lint 原始结果也保留，修复后 `run-DVqgn1` 分析通过。

### #104 和 #105 增量证据

- 委员会采用稳定内部身份；改名及重开保留绑定，删除后同名重建不接管旧场景。至少一个成员就绪即可调用，容量按全部配置成员取最小值。`run-6aev7O` 及 `run-xI43D5` 分别验证业务与页面；`run-c85xQR` 静态分析通过。
- MCP 场景短名单不作为已知模型调用白名单；批次准入、逐题准入及 Jevman 步进保持公开协议调用。原失败 `run-o07qqs`、`run-TckHjX`、`run-YFzA2z` 保留；`run-wAyGA8` 原有完整批次取消契约通过，未减 400 题或计划请求断言。
- `run-H6xd3V` 出现两项旧 MCP 列表断言后已停止，整体失败，不计通过。对应断言改为场景默认空列表，并保留对已知实际名字的全部真实协议调用；`run-p7MFa7` 原三用例通过。
- `run-EGagkQ` 复现冷态保存后容量提前变化；`run-GzCr7L` 冷态重开与运行中重启两用例通过。生效容量持久保存，待应用参数与生效容量分开。
- `run-vJe0m4` 记录预览入口缺失；`run-ADJh4t` 实例、委员会和场景影响预览通过，无保存或启动副作用。
- `run-FsKTus` 的容量持久化失败和取消用例断言通过，但新 Widget 夹具在 FakeAsync 等待真实 I/O，整体终止退出 1，不计模块通过。该用例改用明确的真实 I/O 域，`run-YsaCz8` 原窗口用例通过，外层检查执行与清理完成。
- `run-O7p11b`：通过公开 HTTP／MCP 核对保存不生效、身份失败不生效、成功重启后更新容量与工具描述，并验证生效快照重开保留。失败不换模型；正式模型服务没有重启。

- `run-EHdpve`：六个受影响模块 53 项通过；`run-zWbfyX` 修复唯一静态提示后通过。
- `.scratch/scenario-runtime-delivery-20261016/native-105-63887/result.json`：真实 InnerJev／Splash 独立实例保存 8192 参数后仍发布 4096；成功重启后发布 8192。委员会含一个冷态 16384 成员，公开 MCP 短调用返回 partial；HTTP 聊天成功。自有进程与进程组均已退出，清理错误为零；与模块回归的全部源码输入一致。

- `run-skzuBR`：格式 209 文件和静态分析通过；发现 benchmark 页面把 MCP 短名单作白名单，以及 source_systemone 的旧发现断言，已停止失败作业，整体退出 1。Flutter 收尾的 sink 错误另记，原业务失败不被原进程退出 0 覆盖。
- `run-1k6Dhw`：两项原失败定点通过。进一步入口核对发现 JEV 页面也按短名单限制已知名字，`run-NJSusO` 精确复现提交按钮不就绪；修正后 `run-sQgrUf` 三个页面用例通过，包含取消隔离、全部合法特殊名字调用。未从空列表跳过既有断言。

- `run-fzlAoG`：页面、协议和保存实例等前 84 项通过；Splash 默认未指定容量的公开发现断言失败，整体失败。原因为运行快照遗漏引擎已观测容量，并非模型能力判断。补齐快照后 `run-5ijP3p` 原失败通过，`run-okh2j6` 三个受影响模块 66 项全部通过；没有放宽容量断言。`run-5FF5PL` 相关页面与协议静态分析通过。

### 阶段 A 最终验证与复用边界

- 完整宿主检查 `run-yHcvfT`：格式 209 文件退出 0；静态分析退出 0；测试完整执行，1028 项通过、1 项委员会页面夹具失败，整体真实退出 1。该命令不重新标为通过。
- 唯一失败由实际 I/O 订阅在 FakeAsync 域创建造成，修正测试夹具后 `run-DO2qhw` 原用例通过，`run-SKr7tM` 委员会页面整个模块 13 项通过；原两秒时限、缺失资源标红、恢复、删除和字体布局断言均保留，并增加缺失原因和清理完成断言。`run-aGY2hA` 该文件静态分析通过，固定 Dart 的只读格式检查退出 0。
- 两次宿主检查输入均在各自运行期间保持不变。最终源码与完整检查输入逐文件对比，仅 `test/council_page_test.dart` 不同；该测试文件未被其他测试导入或导出。整个修正文件已经重新验证，其余成功项复用，覆盖当前全部 1029 项测试。不将重叠模块用例重复相加，也不将原失败命令包装成退出 0。
- 验证组合记录：`.scratch/scenario-runtime-delivery-20261016/stage-a-verification-bundle.json`。它保留完整运行的真实失败状态、唯一变化文件、对应模块成功结果和最终全部输入指纹。
- 固定 SDK 的 `flutter build macos --release --no-pub`，命令级 `FLUTTER_MACOS_ARM64_ONLY=true`，真实退出 0。应用、App.framework、FlutterMacOS.framework 的 `lipo -archs` 均为 `arm64`；构建输入与最终验证一致，构建期间源码未变。记录：`stage-a-build.json` 与 `stage-a-build.log`，位于同一机器证据目录。

原始失败与各次源码输入完整保留在 `.tooling/host-tests/`；没有用超时、终止或缺失证据计通过。

## 检查与执行规则

- macOS arm64 宿主机，固定 Flutter／Dart SDK、现有 lockfile、联网依赖解析；不创建或恢复容器。
- 使用现有宿主检查入口；一次准备，复用有效环境。字体与布局断言保留。
- 小修复先原失败、再受影响模块；代码和已知修复收齐后才集中完整门禁。
- 同一作业只保留一份。长作业由主线程 sleep 300 后收取；短 API 和文档检查直接收取。
- 成功证据仅在相关输入、环境和覆盖范围未变时复用；失败、取消、超时和缺失证据不记通过。
- 模型题集是可选功能，不要求每个模型重跑。新功能只补必要真实公开 HTTP／MCP 与原生启停验证。
- 不正式发布，不下载或切换正式发行版，不以模型成绩替代产品功能验收。

## 历史问题

前一轮原始失败和修正保留在原记录及机器日志中，不再次列为本轮未关闭问题。旧黑屏事件按原生复现证据判断，不用重复跑大题集代替诊断，不未经验证宣布修复。

## 阶段 C 增量证据（历史）

下列按当时执行顺序保留原始失败、修复和验收；其中 OPEN、复验中或门禁待收取等描述不是当前状态。当前状态只见本文顶部。

- `run-7Rdjc3` 保留接口未实现的原始红灯。`run-NJymXu` 新夹具未建立登记文件导致读取失败；在真实保存入口准备后，`run-XHhgXK` 两项核心准入与公开 HTTP／MCP 取消通过。
- `run-PJYbb8` 四项通过，新增就绪身份检查中的取消、关／开／关与旧代次收尾。
- `run-F4AKGo` 和 `run-7OBIle` 保留 SDK 测试夹具未选启动实例的失败。纠正夹具后 `run-doPIrx` 验证 SDK 不绕过关闭准入，且 oMLX 原生／配置实例启动及时取消并可重新开启，两项通过。
- `run-M5X1Yd` 保留新增 Llama 回归缺少类型导入的原始编译失败；其中 Splash 晚关联继承总开关和界面两项分项通过。补导入后 `run-1GgQyp` 清理失败、保留 live 残留、拒绝重开和显式重试全部通过。
- 全部只使用原业务入口与原生 I/O 边界替身；未启动、停止或重启正式模型服务，未运行模型成绩题集。

- #109 切片：`run-SVEj6F` 六份受影响模块共 97 项全部通过，真实退出 0；`run-Pit4aI` 14 文件分析通过。已进入阶段 C 候选，可推进同阶段 #110；工单结项仍待阶段 C 完整验收、固定提交审查及 PR 集成。

- #110：`run-c495Mw` 保留未实现接口红灯；`run-lnnmPq` 发现测试把主动移除再添加造成的列表顺序变化错误归入总开关。改为开关前后精确字节比较后 `run-nri10B` 七项通过。
- `run-3UhoVU` 五项自启动业务通过：旧选择保留、独立布尔配置、保存失败回滚、并发、单项失败／手动重试、加载及准备期关闭后不迟到启动。当前开关状态从不写入配置。
- `run-vcv54N` 保留设置页面尚未完成持久化便断言的原失败；改为等待真实保存通知后 `run-uJNFgv` 深浅主题／两倍真实字体的设置与实例选择双向同步通过，原布局和断言不变。
- `run-rUjVAD` 总关闭使整批状态为 cancelled、只消费首条替身请求、历史不记完整成功，HTTP／MCP 接入保留。没有重新执行真实模型评测。
- `run-d7yJMx` 18 文件分析通过。
- `run-CRsq87` 十二份受影响模块真实退出 1，135 项通过、六项失败；六项均为新增侧栏开关在 ColoredBox 下缺少 Material 承载。应用组件已补承载，原字体、布局、导航断言保留，先定点复验原失败。
- `run-Ve0WwE` 六项原失败全部通过。问题只涉及侧栏开关的绘制承载，业务取消和持久化代码没有因此改动；再收取受影响的三个完整界面模块。
- `run-NP5Ast` 三个完整界面模块 39 项全部通过。原生验收前无已知界面失败。
- 原生控制首轮真实退出 255：HTTP 非流式聊天漏接 SplashRequestException，取消被当作未处理异常。原日志与命令保存为 `failure-1-native-controls-c.*`；本次独有进程组 16829 和子进程 16878 经过命令路径、PGID 与模型目录身份核对后清理，正式 GMD PID 9547 保留。记录为 `native-c-16780/aborted-cleanup.json`。
- `run-R8Nhqj` 用公开 HTTP 精确复现普通响应未处理异常与首帧前流式返回 502 两个问题。统一使用既有 DecisionCallFailure 转换后 `run-CSqJds` 两项均返回 499／cancelled，监听仍可用。原生同一路径复验中，尚不将该问题记为最终验收通过。
- 最小原生复验 `native-c-28409/result.json` 真实退出 0：原生 JEV MCP 短调用通过，HTTP 取消明确返回 499／cancelled；关闭耗时 323 毫秒。两个自有 PID 28454、28542 均已退出，两个端口 63912、64085 均可重新绑定；清理错误为空。重新开启仅加载已选择实例；正式 GMD PID 9547 的启动时间和命令前后相同。未运行模型成绩题集。
- `run-3N82yR` 四份受影响网关模块 49 项全部通过。原生发现的取消缺口已关闭，没有已知门禁前待修复项。
- #109 切片已进入候选后推进 #110，同阶段负责人已登记为 Ghost233。两工单仍 OPEN，待阶段 C 完整验收、提交、复审及 PR 集成后关闭。
- `run-VbUzes` 完整门禁停在静态分析：219 文件格式通过，新增 Splash 取消回归误加的 dart:async 导入未使用，分析退出 1，测试未运行。原失败保留；只删除这条测试导入，应用输入和原生成功证据不受影响，先定点分析后再继续最终门禁。
- `run-KK59sX` 原静态诊断定点通过。随后继续最终完整门禁，当时只保留这一份有效完整运行，随后结果见下一条。
- `run-JTZMOa` 完整宿主门禁真实退出 0：219 文件格式检查、全仓静态分析和 1070 项测试全部通过；标准完成标记成功、无失败，检查期间输入未变。它覆盖审查前候选，不冒称覆盖后续修正。
- R-C-SPEC-01：将页面与自启动共用的资源准备移入已有 LaunchInstances 业务所有者后，`run-gpBgyx` 精确复现一处目录失效阻止有效实例启动；原扫描诊断保留，已去除全局抛错，先定点复验。此前 `run-phiQpi` 是新增用例插入脚本锚点失败导致无匹配，退出 79，不算产品红灯或通过。
- `run-1iXvzc` 原始部分目录失效回归通过，有效实例启动且缺资源实例单独报错；`run-weIaIj` 三份增量文件分析通过。当前与完整门禁相比只变化 main.dart、launch_instances.dart 和新增该用例的 runtime_autostart_test.dart；通过恢复原准备方法后重新计算 SHA，确认 main 其余代码和 LaunchInstances 既有启动／停止／参数路径逐字未变。范围证明为 `stage-c-review-delta-scope.json`，原生协议成功证据按未受影响路径保留；新准备入口和全部调用者由受影响回归补验。
- `run-xJrwYw` 七份受影响模块 100 项全部通过，`run-VtbFMp` 对最终 lib／test 共 218 文件只读格式通过。与完整运行相比，测试文件移除新增用例后 SHA 精确等于原输入，没有删除或改名旧用例；最终 1071 个唯一用例有成功证据。组合记录为 `stage-c-verification-bundle.json`，不把旧输入完整门禁冒称为直接执行了新输入；原失败保留，未重复未受影响的规模回归。
- 固定 SDK 的 macOS release 构建真实退出 0，最终输入在构建期间未变。应用、App.framework 和 FlutterMacOS.framework 实查均仅 arm64；产物为 build/macos/Build/Products/Release/Ghost Model Deck.app，未替换正式应用。记录为 `stage-c-build.json`／`stage-c-build.log`。
