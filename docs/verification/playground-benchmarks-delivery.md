# 测试场与原题基准交付

规格：[#62](https://github.com/Ghost233/GhostModelDeck/issues/62)。起点：`07729aec710cb5516e77ae853b152f529ab3b897`。

用户已授权 dev 集成分支、阶段分支/PR；最终 dev → main 总 PR 保持 ready 待合并。阶段一 #63–#65 已验收并通过 [阶段 PR #74](https://github.com/Ghost233/GhostModelDeck/pull/74) 合入 dev（`8da3777caf5a2eab8fffa8e230cdead28578caa4`）。阶段二 #66–#67 已验收关闭，PR #75 已合入 dev。当前进入阶段三 #68–#72。全部五项基准和真实完整评测仍属于总验收，不降低规模。

## 当前交付状态（2026-10-10，macOS arm64）

| 项目 | 当前结论 |
| --- | --- |
| 当前代码 | 已提交产品基线为 `112680b0ddc1bde120743a3be198494f34501de1`，验证开始 HEAD 为 `0a1d779e89d62aec2887ab021738a6c4d2a4cbf6`。本次 Page 代际及历史读取修复已通过原失败用例、必要 27 项回归和最终 780 项门禁，源码保持冻结，现进入提交及增量复审。另一会话的 `93a86ff` 发布文档提交及外来标签文件保留。 |
| 完整门禁 | 最终唯一 `run-I9PGT7` 已通过：145 文件格式零改动、全仓分析零诊断、全部 780 项测试，三个步骤及整体退出 0，用时 27 分 44 秒，清理正常。647 个输入前后及当前逐一一致，清单摘要 `01998b4c40788e66a6680e405924359c2d6797b8fdee0941275a4f29a3d65216`。主线程独立核对原四个退出文件及全部摘要。三份当前原生评测使用 `112680b` 产物；更新构建仍待。 |
| 真实模型 | 阶段二六份完整 400 题已通过。JEVal 全部 11,257 题执行，独立全局及 77 分组评分核对退出 0。一致性全部 10,320 次请求有效，正常 GUI 导出和上游独立评分退出 0。JevAdvBench 全部 11,368 次请求已执行：9,474 有效、1,894 失败、零超时；独立核对退出 0，但原完整成绩不可评分。Jevman 100 局仍待。日志捕获实例的正常空闲退出通过，原黑屏和历史问题仍待关闭。 |
| PR | 阶段 PR #74／#75 已合入 dev；阶段三 PR 与最终 dev → main 总 PR 尚未创建。最终总 PR 仅保持 ready，由用户合并。 |

下列记录保留各候选执行时的状态与原始失败。当前交付状态以本表为准，旧候选的门禁不能替代新修改的验证。

JEVal 全量独立分组核对已完成，固定 Python 3.12.14 真实退出 0。顶层 `groups` 的 77 个分组全部一致：来源 58、领域 10、语言 2、题型 3、输入长度 4。各维度均覆盖全部 11,257 条记录，指标差异及缺失组均为 0。长度维度是声明的 UTF-8 字节辅助分桶。全部 1,629 个失败中，1,623 个为原模型上下文超限，6 个为公开入口请求字节上限拒绝。原导出前后字节数和 SHA 不变。记录为 ignored `native-stage3-jeval-groups-audit-result.json` 和 `native-stage3-jeval-groups-audit-execution.json`。

一致性批次于 2026-10-10 10:05:22 UTC 完成。10,320 个请求全部有效，50 个关系各覆盖 240 案例，12,000 个关系试验及 14,838 个 outcomes 全部评分。普通 GUI 导出为 251,045,036 字节，SHA-256 `5c83b259a84a7eb374f2b127aced4dfb8c6eddc53580d048c874cd7970e193f9`。固定 CPython 3.12.14 的原作者审计真实退出 0，406 个字段、固定阈值、bootstrap 和 CI 全部一致。binary 为 67.12990196078431%，graded 为 93.14047453961789%；这些均为本项基准成绩。证据为 ignored `native-stage3-author-audit-controller-coherence.json` 和 `native-stage3-controller-coherence-author-audit-summary.json`。

终态首次 GUI 仍显示旧 3,221 条进度，并出现日志未完整封存的读取错误。正常刷新后 AX 未更新；后续普通 Tab 使错误消失，历史更新为完整 10,320 条。选择准确运行编号后，报告与正常 GUI 导出成功。原始失败及恢复分别保留，普通公开发现返回 200，诊断日志只有 Impeller 启动信息。恢复动作不能证明错误根因；只读诊断确认了活跃日志追加与旧描述符读取的竞争窗口，尚待有限复现。现有页面代际修复不覆盖该读取路径。记录为 ignored `native-stage3-root-coherence-gui-recovery.json` 和 `native-stage3-coherence-history-diagnosis.md`。

JevAdvBench `run-1791627398683874` 于 10:25:54 UTC 完成全部 11,368 次公开 HTTP 请求，没有重试或截题。有效 9,474、失败 1,894、超时及缺失均为 0。正常 GUI 导出为 409,569,490 字节，SHA-256 `00dc6100288ce202c1cb1b02d0752df6fc46358427de8a17459a1352826d4059`。独立原作者核对真实退出 0，1,515 个字段及原请求摘要一致。全部失败为 1,581 个 HTTP 400 附加字段拒绝和 313 个 HTTP 502 包装的引擎上下文超限。原完整报告不可用，129 个分组未评分，52 个配对分组有缺口；失败没有计作抗扰动成功。人工标签与模型共识、有效覆盖和未知分母分别保留。证据为 ignored `native-stage3-author-audit-controller-adversarial.json` 及 `native-stage3-controller-adversarial-*.json`。

三份完整当前记录保存后，日志捕获实例正常 CmdQ 退出。自有 app 90625 和 Kev 21079 均消失，54841、54842 和 58045 拒绝连接；未发送信号。三份完整历史头文件字节保持，六项配置与最新接管基线一致，外部 LM Studio 进程保留。这仅证明该实例的空闲正常退出，旧黑屏后的退出失败和新候选的运行中中断验收仍待。记录为 ignored `native-stage3-root-logged-normal-quit-before.json` 与 `native-stage3-root-logged-normal-quit-after.json`。

活跃日志的有限复现 `run-YRUGX1` 真实退出 1：旧描述符捕获第一行长度后，普通 HTTP 合法持久化第二行，原 Store 末尾校验正确拒绝旧描述符，页面显示读取错误。另一原失败 `run-raD60J` 确认成功选择合法历史后旧错误残留。最小 Page 修复仅让同 ID 的真实活跃批次直接跟随当前快照，并在成功选择时清旧错误；静态及完成历史仍严格读取。两项同例 `run-8v3bNR` 全断言通过，测试及外层退出 0，输入一致。测试接缝初次 `File.open` 签名错误单独保留，未计业务红。必要 Page／navigation／game integration／Store 四文件回归 `run-7G93Zd` 在途，随后相关分析及最终完整门禁仍待。证据为 ignored `stage3-check-queue-active-history-*.json`。

本轮历史修复的必要四文件回归 `run-7G93Zd` 完成 27 项，测试及外层退出 0。分析 `run-B8mBNW` 首次退出 1，只有新增测试两处大括号诊断；原实现者仅机械补括号，逆向重构源码摘要证明其他内容保持。修复后同分析 `run-lUBOcm` 零诊断退出 0，格式 `run-MwmzmQ` 两文件零改动退出 0。当前 647 个输入与最终清单逐一匹配，源码继续冻结，由唯一 SDK 队列执行 `run-I9PGT7` 完整门禁。记录为 ignored `stage3-check-queue-active-history-affected-summary.json` 及 `stage3-check-queue-active-history-final-full-*.json`。

原黑屏实例 PID 70984 的历史统一日志补查真实退出 0，取得故障时段 476 条事件。AppKit 在 16:14:31 本地时间记录退出请求和 `NSTerminateLater`，晚于 16:07 的首次黑屏；这说明当时原生退出等待 Dart 收尾结果，但日志没有暴露此前 Flutter 失去正文与 HTTP 关闭的原因。没有将缺少日志当作根因排除或验收通过。记录为 ignored `native-stage3-black-historical-log-summary.json`。

当前没有本次原生评测在途，最终宿主门禁不依赖真实模型。为释放共享服务，主线程按已有授权恢复原安装版 0.1.3／build 8，app 840、Qwen 8748 和 Kev 11665 均运行。普通 HTTP 200 精确发现原 Qwen ID 与 `sentinel-kev`；普通 MCP 经 initialize、工具发现和实际公布的 `list_jev_models` 返回 native 对象，客户端会话已关闭。六项配置仍与接管时最新基线逐字节一致，已向授权会话发送恢复通知。恢复的是原 Qwen2.5-0.5B，与对方计划验证的 Qwen3.5 区分；没有冒称后者 Ready 或质量通过。下一次 Jevman 实机前重新协调在途请求，并备份当时最新状态。首次未初始化请求及错误工具名调用分别保留为协议操作失败。记录为 ignored `native-stage3-interim-original-service-ready.json`、`native-stage3-interim-original-mcp-tools.json` 和 `native-stage3-interim-original-mcp-discovery.json`。

两轴首审发现唯一 P2：Jevman 正式成功公开调用的端到端 P50/P95 为空。当前固定 `112680b` 的两轴 V2 复审均为 P0/P1/P2 各 0，原问题已关闭。复审复用 `fa6` 的 48 文件覆盖，独立核对当前 647 个输入全部匹配。报告为 ignored `stage3-prenative-standards-review-v2.md/json` 和 `stage3-prenative-spec-review-v2.md/json`。修复保留原游戏评分和平均延迟，排除预热、失败与取消。原失败 `run-yAfkSA` 保留；同例 `run-HzXjuz`、无成功及页面两项 `run-UZH5yj`、相关分析 `run-pUZnkK` 均退出 0。唯一三文件回归 `run-7SkElR` 已完成：48 项通过，测试与外层退出均为 0，输入前后一致。四文件最终格式检查 `run-EJRENm` 零改动。唯一新完整门禁 `run-W06BOL` 已通过：145 文件格式零改动、分析零诊断、777 项全测试，三个步骤与整体退出均为 0，用时 29 分 07 秒。647 个输入与当前源码逐一相同，清单摘要 `a60e2ec3e6a3c0420fd8d840f0661f544ea98ea4f428f441266777649ef1eadd`。准确记录为 ignored `stage3-check-queue-p2-final-host-summary.md` 与 `stage3-check-queue-p2-final-host-result.json`。

旧候选 Mac Release 编译真实退出 0，678 个构建输入一致。另一会话在构建期间提交了三个发布文档，记录器因 HEAD 改变而退出 1；两种结果分别保留。当前生产代码修复需要新产物。其他会话提交及未跟踪的标签文件保持。阶段 PR 如何排除这三个外来文档，留到 Git 交付时处理。真实模型接管尚未开始；新门禁和构建通过后，沿用用户授权协调旧服务释放。

当前候选 Mac Release 构建为 ignored `native-stage3-build-repair1-result.json`。编译和记录器真实退出均为 0，HEAD 前后为 `112680b`，678 个输入前后及当前一致。App.framework SHA-256 为 `cd563edfcd24dae304179ecd6aa79bffe6c13dadeed928cd3eecaecc0744f113`。SDK 默认产物含 arm64 和 x86_64 slices；本次仅验收 macOS arm64，未执行 Intel 适配或测试。真实应用和模型尚未启动。

首条服务协调消息遭自动审批拒绝，理由是需要指定会话的明确授权。用户随后明确授权向“讨论 Codex Observer 监控方案”发送交接及恢复消息，同一工具发送成功。Sentinel 已确认真实推理结束、没有在途调用、后续测试不需要模型。主线程已发送接管通知，并授权唯一 native_stage3 执行者先备份当下最新六项配置，再正常退出旧应用并开始完整真实评测；实际初次 CUA 选取调用等待 852.8 秒后中断，没有退出或修改配置。主线程接管后成功读取界面；再次核对最新六项配置与备份一致，正常 CmdQ 后旧应用及两个自有模型退出，公开端口拒绝连接。一次退出后的目标 AX 观测重新打开了旧应用，已再次正常 CmdQ 并以进程检查确认退出；外部 LM Studio 保持。新候选 PID 70984 的 sample 退出 0，Code Type 为 ARM64，普通公开发现返回 200。GUI 按既有 b11381 原参数启动 Kev，选择现有 `sentinel-kev`，完整 JEVal HTTP 运行 `run-1791617331969869` 于 15:28:51 开始。当前观察 2,340 / 11,257 个有效返回，零失败、零超时；运行期配置与调用名锁定，离页及关窗／重开仍同 PID、同 run 持续执行。完整成绩和独立评分尚待，未把部分成绩当验收。当前执行者为主线程，唯一有效运行按非阻塞 CLI 五分钟观察。证据为 ignored `native-stage3-root-*.json`。

阶段二 [PR #75](https://github.com/Ghost233/GhostModelDeck/pull/75) 已合入 dev，合并提交 `a7c1aaced3b3f679fb8d3f7886ab82c64ca3f5a4`。代码候选固定为 `072335d0cdaa44296ae44103f36b5a13171229dd`，实机开始时的文档提交为 `bc0276beeb80ab193d27fec96d859587be1ff6b2`，随后仅更新交付记录。主线程负责 Git、门禁和实机队列；`comparison_67` 负责代码修复，`native_66` 负责唯一实机验收。

阶段二候选的完整宿主门禁 `run-VqlJZR` 已通过：121 文件格式零改动、全仓分析零诊断、718 项测试通过。三个步骤与整体退出码均为 0，296 个输入摘要与已验收的阶段二源码一致；该门禁不覆盖当前阶段三工作区。固定 Flutter 3.47.6／Dart 3.13.5、现有 lockfile、联网解析和已核验字体环境继续复用。字体与布局断言完整保留。Linux、Windows 和 Intel/x64 已移出本次范围；本次没有新建或恢复容器。

单题期限误取消整批、启动窗口忽略中断和 typed 超限 POST 提前取消请求体三项问题均已修复。原失败、定点回归与完整门禁记录保留。两轴 V2 复审均为 P0/P1/P2 各 0，原启动窗口 P2 已关闭。当前 Release 构建真实退出 0，版本保持 0.1.4，86 个构建输入未变。实际 Dart App.framework 摘要为 `ea1652ef2e747b2a5076b40d85b312bebc3e62e79f5be5116d88f4326569fbed`；实际应用运行于 ARM64。

用户已授权临时释放 Sentinel 使用的旧服务，正常退出安装版 0.1.3，并复制最新六项配置作为恢复基线。当前候选通过真实 GUI 启动 `run-1791589928095898`，顺序执行 native-kev、quick 和 hard 各 HTTP/MCP 共六份完整 DecideBench。每份均为原 400 题、200 对，总计 2,400 个有效返回，失败和超时均为 0。原生单模型及 quick 两种协议的 accuracy 均为 43.50%、pair accuracy 为 16.50%；hard 两种协议分别为 51.50% 和 25.50%。这是本项基准成绩，不代表其他基准或总规格完成。

GUI 导出包含完整六份独立结果。六份上游未修改请求构造、解析与评分审计均退出 0；独立普通 HTTP/MCP 客户端及原始请求核对也退出 0。参与对象的配置锁、切页继续运行、执行中关闭并重开窗口已实际核验。手动停止 Kev 后，依赖它的三个对象标记不可用，独立 Laya 仍完整完成 400 题并通过上游评分核对。

正常 CmdQ 将执行中的 MCP 批次封存为 interrupted（31/1,200），后续对象零执行，完整成绩为空。应用及其拥有的模型进程全部消失，五个相关端口均拒绝连接。先前完整记录字节保持不变。重启历史、导出和删除保护均已完成。GUI 删除本次取消记录 `run-1791590650888920` 曾被自动审批拒绝；用户随后明确确认这条已备份记录，同一 GUI 删除成功。其余五条历史、22 个题源和四个模型摘要未变。最新六项配置的字节和存在状态全部恢复，安装版 0.1.3／build 8 及原 Qwen、Kev 两项 Ready 服务正常运行，公开 HTTP/MCP 发现精确匹配。主线程核对实际配置、历史及进程后，已通知 Sentinel 服务恢复。

证据位于 ignored `.scratch/playground-benchmarks/implementation/`：`stage2-final-repairs-host-gates.json`、两份 `stage2-*-review-v2.md`、`native67-build-current-result.json`、`native67-full-batch-author-audit/summary.json`、`native67-public-client-result.json`、`native67-manual-stop-terminal-evidence.json` 、`native67-normal-quit-evidence.json`、`native67-summary.json`、`native67-restoration-final.json` 和 `stage2-acceptance-merger.md`。独立 merger 已逐项核对 #66 九项与 #67 七项，全部满足；#66、#67 已发布验收评论并关闭。主线程先更新本地 dev，再推送远端；dev、main 及两条阶段分支的本地／实际远端完整 hash 均分别一致。#68–#73、五项完整基准及最终 dev → main 总 PR 仍待完成。

阶段三基于已同步 dev `a7c1aaced3b3f679fb8d3f7886ab82c64ca3f5a4`，工作分支为 `codex/playground-stage-3`，实现候选已提交为 `fa6da5f`，尚未创建阶段 PR。JEVal、一致性 JevBench、JevAdvBench 与 Jevman 原题子模块均已固定完整提交；HF 子模块取得真实 33,533,925 字节 Parquet，摘要匹配原 LFS 对象。Git LFS 仅在本任务目录准备固定 Mac arm64 工具，不修改全局安装；检出原失败及修复记录保留。

JEVal 原题模块的全量字段、原评分和有限边界 6 项回归 `run-mR1p7P` 退出 0，两模块分析 `run-qiO5A7` 零诊断。完整一致性请求、两套独立作者向量、50 关系及固定 CI、非法概率和 95% 覆盖边界 4 项回归 `run-fORtgR` 退出 0，模块与共享数值接口分析 `run-NJzml8` 零诊断。朴素求和造成的原评分差异已由独立诊断重现，并对齐当前固定 CPython 3.12.14 的求和语义；原评分期望、容差和分母未变。上游历史具体运行时未知，留空。

原攻击的 JSON 转义、额外字段及送达事实已有定点反馈。公开客户端保留原 HTTP 文档，来源可将不支持字段交给正常 HTTP/MCP 入口真实判断；基础编辑器默认预校验保持。实际双通道拒绝、原文证据与受影响 53 项回归 `run-bY8m3u` 全部通过。扰动模块的原统计、精确整数原文、MCP 拒绝分类及有限边界已完成，最终模块回归 `run-MWf7WK` 与分析 `run-UduXpY` 均退出 0；原失败保留。应用原题资源／runner／增量历史集成和受管 Jevman 正在实施。新增 manifest 资产入口后，宿主准备 `run-83BV1K` 在线解析和整体退出均为 0，lockfile 未再改变。

阶段三第二轮有界队列已完成：原题完整分母保护由 `run-7GGYP9` 失败闭环至 `run-ZUv3ss` 通过；日志写前归属保护由 `run-AC1wWh` 失败闭环至 `run-vLlP8X` 通过，相关历史与资源回归均退出 0。原游戏预热普通 HTTP 取消 `run-P0sgJs` 及原录像重放、解析、运行时回归 `run-LY2NJE` 共七项通过，最终联合分析 `run-QeLOLT` 零诊断。自包含游戏桥接产物为 64,433 字节，SHA-256 `e4c1296b3f2c9958e9837ef329daceb9aadc8cb7e400e27c86a7ba5d379e8c39`，14 个构建输入与 manifest 一致。详细记录为 ignored `stage3-check-queue-loop2-summary.json`；取消是生命周期边界检查，未执行完整 100 局。当前由唯一 SDK/Node 队列继续游戏运行中取消及日志完整性分类，主线程继续负责最终候选、完整门禁、实机与 Git 交付。

第三轮有界队列已完成：游戏运行中取消 `run-KXq36M` 首次退出 0，保留第一局真实部分录像、完整成绩为空、自有进程与请求释放、原模型实例存活，封存结果不可修改。日志完整性与安全分类 `run-7t9816` 六项首次全部通过；同长损坏、符号链接和异主 descriptor 均明确拒绝，正常独立导出及只删除所选 header/journal 的保护通过。相关分析 `run-9ufLDC` 零诊断，业务检查输入前后不变；没有重建未变游戏产物或重复无关成功。记录为 ignored `stage3-check-queue-loop3-summary.json`。后继队列集中检查游戏目标失效／正常关闭／公开业务错误与四题库页面；游戏应用组装拟复用现有唯一批次 operation、配置锁和逐局增量日志，不修改原帧调度。

第四轮集中反馈：游戏目标失效、正常关闭及 HTTP/MCP 业务错误四项 `run-rdRLAe` 首次通过。四题库选择器先保留真实网络测试接缝失败，修正后取得缺少选择器的业务红 `run-7k3bKV`，最小实现后 `run-xQ6Ys4` 通过，原页面与导航 12 项 `run-HbGklq` 全部退出 0（含完整 400 题报告）。游戏日志 codec 由缺 API 红 `run-QTLV5m` 闭环至 `run-djRd80` 通过；逐局持久化回调由缺 API 红 `run-xvvJ5u` 闭环至两项 `run-vJloHM` 通过，游戏文件十项 `run-1fCYPa` 全部退出 0。游戏桥接已按修改后的原结束收尾接缝重新构建，当前 64,433 字节产物 SHA-256 为 `2da761b7a73588f015d95ccf97793b09966fcfe375ad992dc7a741b714c8bbd8`，14 个输入和 manifest 已核对。未改原帧调度，未运行完整 100 局。受管游戏资源组装由实际缺 API 红 `run-BPQeJY` 进入实现；安装资产入口新增桥接文件后，统一队列负责一次联网准备与后续定点验证，原评分／分组报告及共用游戏批次接线仍待闭环。

第四轮最终收尾：`run-xLIQN0` 联网依赖准备与整体退出均为 0，lockfile 未变；游戏资源组装 `run-UYqjVP` 三项通过，验证安装资源校验、固定 arm64 缓存复用、损坏桥接和符号链接保护。相关十文件分析 `run-yYb5Bs` 零诊断，645 个输入与交接时内容一致。第五轮关闭独立评分报告失败：测试先仅将两个 Completer 移至真实异步区，原 20 秒／10 秒期限不变，`run-O5UnH3` 得到没有超时或清理错误的 `1 / 400` 对 `1 / 11257` 业务红。最小报告修复后 `run-sm2nug` 通过，原分母、部分 ACC／MAE 为空、五维原分组与 JSON、无配对指标及一次正常 HTTP 请求均核对；受影响四文件 `run-Pq32S1` 二十项通过，最后相关七文件分析 `run-VjwsTk` 零诊断。详细记录为 ignored `stage3-check-queue-loop4-summary.json` 和 `stage3-check-queue-loop5-summary.json`。当前继续共用游戏 operation／历史／退出接线，并准备三来源完整原输入的日志规模验证；没有阶段三完整门禁或真实完整模型验收的通过声明。

第六轮已完成共用游戏执行器与完整输入存储验证。游戏批次 API 缺失红 `run-BErXW2` 后，首候选语法错误 `run-q8lTr2` 真实退出 65 已保留；修复后 `run-77zpzd` 两项通过，验证唯一批次门禁、全部配置锁、schema 5／6 部分录像历史往返及零执行准入窗口退出。相关分析 `run-ubQvVy` 零诊断。唯一完整日志规模作业 `run-wz1RW0` 用时 8 分 42 秒，四项全部通过，测试与整体真实退出码均为 0，647 个输入前后未变，清理完成。JEVal 11,257 行、coherence 10,320 行及 Adv 11,368 行的 journal 分别为 585,297,271／168,530,809／359,273,665 字节；Adv HTTP／MCP 两份完整 leaf 共 22,736 行，独立导出为 821,214,025 字节。原输入摘要、原字段／原文、4,564 个数字字面量、全量读取／导出和 owner 拒绝均通过。三份逐题 snapshot／save 各读取 N 行、每行最多一次、重复终态保存零历史读取，原 `≤ 2N + 2` 断言未放宽。这些用例为明确标识的 cancelled 存储 fixture，没有执行模型，不证明系统累计 I/O 或真实模型完整评测。记录为 ignored `stage3-check-queue-loop6-summary.json` 和 `stage3-check-queue-loop6-scale-outer-result.json`。当前推进 main／ManagerLifecycle／页面的游戏装配；受影响回归集中留到接线后一次执行，完整门禁与实机仍待。

游戏应用组装已完成本批闭环：原构造参数缺失 `run-SZAd6u`、错误要求游戏 manifest 有 `files` 的页面失败 `run-UU8oi9` 保留，按原 `bundleInputs/games` 修复后 `run-52SPtQ` 通过准备、正常 HTTP 首局、离页继续、重挂取消、部分历史和自有资源收尾。唯一受影响回归 `run-b9ZDBh` 二十文件 130 项全部通过，相关 34 项分析 `run-GMZina` 零诊断。随后固定 #68–#71 候选，唯一全仓宿主门禁 `run-I0GRe7` 完成 145 文件格式零改动、全仓分析零诊断、776 项全测试（含完整 Scale 与全部旧断言），三个步骤及整体退出均为 0，用时 27 分 29 秒，清理正常。647 个源码输入前后及当前一致，清单摘要 `c0ca5ffab390d28536aae693df471e5e4910a95ec10d0c38c9adc8d703365752`；SDK、字体、lock、五个实际固定子模块和当前游戏产物一致。证据为 ignored `stage3-check-queue-loop7-summary.json`、`stage3-check-queue-prenative-summary.md` 与 `stage3-check-queue-prenative-result.json`。该门禁允许进入当前 Mac 构建和真实模型验收，不代表 #72、阶段三 PR 或总规格完成。

上述阶段三证据属于原题模块与定点回归，尚不代表安装版集成、真实模型完整 11,257／10,320／11,368 请求、Jevman 100 局或新的完整门禁通过。旧阶段二 718 项和原生六份记录仅覆盖已验收的阶段二候选。阶段三仍须固定最终内容后完成本阶段完整门禁、真实模型、独立原评分及资源收尾；最终总 PR 继续待全部规格完成后创建并保持 ready。

实机 JEVal `run-1791617331969869` 已完整执行：11,257 / 11,257，缺失 0；9,628 有效、1,629 失败，客户端和服务端超时均为 0。首个原始错误为模型请求 7,147 tokens 超过原 4,096-token 上下文，经普通 HTTP 返回 502；没有截题、改参数或重试。GUI 完整导出为 620,489,987 字节，SHA-256 `b5362228a645e7e498944e136bb303ed311b281bcf426424d94268b673e24c24`。独立固定 CPython 审计退出 0，原始七字段摘要一致，原分类分母 10,938、score 分母 319；accuracy 0.44459681843115745、Brier 0.5869310679447592、ECE 0.16444844651608945、score MAE 1.1214232346609345 与导出相符。原失败输入法为自动化 AX setter 没有触发 TextField.onChanged，正常键盘输入后 GUI 导出成功。准确证据为 ignored `native-stage3-root-jeval-independent-score*.json`。

导出后切换题库出现原生窗口黑屏、普通发现端口拒绝连接，app 70984 和自有 Kev 74256 仍运行。正文缺失检查真实变红，正常 CmdQ 未释放资源；核验路径及父子关系后只对这两个 PID 发 TERM 清理。原进程退出码不可取得，清理辅助命令退出 0，清理不算正常退出通过。完整历史及配置保护保留。当前以同一已验证二进制 PID 90625 捕获 stderr，有限重放的来源切换、完整历史加载、关窗重开、Ready 模型条件均保持正文，原问题尚未复现或关闭。没有修改产品代码、放宽断言或重跑 JEVal。此候选阶段验收仍未完成。记录为 ignored `native-stage3-root-black-*.json` 和 `native-lifecycle-diagnosis.md`。

同一二进制日志捕获下，一致性 `run-1791621521579905` 于 16:38:41 经 GUI 开始普通 HTTP 全量评测，固定 jevbench-240、10,320 唯一请求 / 12,000 关系，首次 123 有效返回、零失败。只有一个有效运行；唯一只读观察者使用 CLI 五分钟间隔，主线程保留应用操作。完整成绩、独立评分、JevAdvBench 11,368、Jevman 100 局及退出／恢复仍待。

用户提醒完成时，小头文件显示一致性仍在运行，1,548 / 10,320，尚未封存；GUI 却显示旧 JEVal 的“完整执行”报告。进程核对只有同一个 app 90625。原完整历史加载与新批次启动重叠时，`run-215nzI` 确认新运行及公开 HTTP 首请求成立，但界面缺少新运行编号，真实退出 1。

最小页面修复给历史选择增加代际检查。主动开始新批次会废弃旧加载并清空旧报告；runner、题源、评分和预算保持。同例 `run-4JTOZG` 全断言通过，测试与外层退出 0。新报告、取消、旧完整 400 题保留、正常重选和零额外 HTTP 均已核对。准备时序错误及新测试占位文本误判保留；原期限与业务断言保持。

必要三文件回归 `run-4fMlcV` 的 19 项全部通过，测试与外层退出 0；分析 `run-cD2zk2` 零诊断，格式 `run-REpQI7` 零改动。647 个输入前后与当前一致，清单摘要 `f2ba01fd862fe3b69a390bd5e7f6042036763a05578524db66517efd24ac74b4`。新完整门禁已授权唯一 SDK 队列执行，对应构建尚待。正在运行的一致性评测继续使用原 `112680b` 产物，页面修复尚未部署。证据为 ignored `question-integration-history-selection-handoff.md` 与 `stage3-check-queue-history-selection-race-*.json`。

JEVal 三族来源后续核查已完成。作者论文证实 Decider、JevBench 和 JevForge 的原项目指针；JevBench 的 200 行均唯一映射到公开原题。作者历史导入提交及其他两族逐行绑定仍未知。报告为 ignored `jeval-source-identity-followup.md`，不代表 #68 产品或模型验收。

## 历史执行记录

当前记录入口：`.scratch/playground-benchmarks/implementation/delivery-state.json`。阶段二主线程负责应用组装、退出、配置锁、检查与 Git；实现者分别拥有资源与原题解析、公开请求执行与记录、评测页面。以下记录按发生时间保留原始失败及阶段证据，旧的待验收描述由较新记录更新。

本机 Apple container 1.5.0 与服务版本一致；已有 ghostmodeldeck-checks-r35 具备 Flutter 3.47.6 / Dart 3.13.5，首次状态与进程检查显示无在途检查。首次原生 copy 阻塞，vminitd 日志确认 readonly filesystem，取样后终止本次两个 CLI 等待进程，退出 143，未进入测试，不记为红/通过。接下来仅恢复该检查容器后重试，不修改其他容器。

当前正常应用公开 HTTP/MCP 服务可达，GET /v1/models 返回 200 空列表；任务独立实例的 JEV/LLM 最小预检已通过并回收，最终新编辑器桌面验收尚未执行。所有工单保持开放。


临时 Apple container `gmd-playground-checks-20261009` 使用 --rm，不建立持久卷。441MB 工具链传输 SHA-256 与宿主一致。默认 DNS 192.168.64.1 无法解析 Debian，实测 119.29.29.29 可解析、1.1.1.1 超时；仅修改本次临时容器解析器。联网 apt 准备最终退出 0，版本与原固定工具链一致。

当前自动化证据：#63 客户端期限红 run-XEYID0（exit1，未实现API），绿 run-8Td0Q2（exit0）；#64 JSON/发现 run-Ukl1Wk 中该项通过（同批 JEV UI 用例另有失败，整批 exit1）。普通 HTTP 取消最初委员会探针可能被其2秒预算掩盖，改用原生公开模型后 run-KzD7Rl 明确 exit1；生产连接修复后相同用例 run-6zgQah exit0，外部引擎响应仍保持等待。该修复尚需成功/错误/并发及真实模型验证，不能据此结项。


最小真实模型预检（04:25:14–04:25:33 UTC，真实退出 0）：通过生产目录/运行管理器关联既有 b11381 引擎，仅在独立临时配置内显式加载既有 Kev/Laya 资产。实际公开 HTTP 与 MCP 均发现 native-kev/quick/hard，6 次混合 choice/score/noul 调用成功，公开 model/answers/usage 与本次 debug 保存；两自有模型进程在生产 shutdown 后均不存在。记录及源码文件指纹位于 `.scratch/playground-benchmarks/implementation/native-jev-preflight.json`。这是可执行路径预检，不等于最终编辑器、取消或完整基准验收；未改用户配置与模型文件。


LLM 最小真实预检也完成（真实退出0）：生产模型下载流程取得固定 Qwen2.5-0.5B Q4_K_M 491,400,032 字节与预期 SHA-256、安装回执；在任务独立配置中显式启动，公开 JSON/SSE 成功并记录实际 usage/finish/raw。真实 SSE 收到增量后取消，部分文本保留且不标完整，模型 permit 释放，生产 shutdown 后自有模型进程不存在。证据为 `.scratch/playground-benchmarks/implementation/native-llm-model-prepare.json` 和 `native-llm-preflight.json`；同样只证明当前路径可执行，最终页面/候选源证据待验收。

Sentinel 有界对接资料见 [公开契约](../integration/sentinel-public-api.md)，明确现有入口、真实临时样例及后续预填/缓存/结构化输出缺口，不添加新接口。


当前新增应用级证据：JEV公开候选 run-QPdKZA exit0；普通HTTP/MCP并发取消隔离 run-KSj1En exit0（两用例，不含lease）；JEV独立客户端原文对账/实际发送快照/导出不覆盖 run-fIRWp3 exit0。LLM JSON/SSE run-pVqp2Z exit0；同期间并发无关请求取消隔离在 run-dkESoz 三个客户端用例中通过（该批UI故障整体exit1，不冒称整体通过）；LLM UI 真实发现/编辑/提交/会话/复制在 run-Wt9wgH exit0。期限、导出、显示脱敏及更完整边界仍在实施中。

五题源获取预检已完成，持久副本 `.tooling/playground-source-preflight-20261009`、报告 `.scratch/playground-benchmarks/implementation/sources-preflight.md`。全量一致性锁 jevbench-240（12000关系/manifest 10320唯一请求），JEVal实际Parquet SHA与LFS OID一致并页脚11257行。Jevman archive 内 node_modules 是作者绝对符号链接，不能当作依赖；锁定Node与tsx/esbuild/native包已获取核验，尚未安装运行。许可/署名条件、Parquet全解码与计分器尚未闭环，这些预检不算完整评测。


新增有界资料归属：Sentinel 公开契约核对由主线程负责，交付 `docs/integration/sentinel-public-api.md`。这属于补充对接说明；新预填/缓存/grammar/slot 能力留在 Sentinel 的后续规划，未纳入 #62 工单验收，未向其他聊天发送消息。


初次 merger 只读核对完成（`merger-63.md`）：构造/枚举/调用点及接入兼容。发现 JEV 外部引擎非法响应的应用级覆盖和客户端成功schema校验缺口，原实现者集中修复；旧小测不同源码快照不得替代最终门禁。

公开 LLM 输出脱敏定点证据：真实HTTP JSON usage意外凭据 run-wEROeC 红→run-oVno5W 绿（exit0）；真实SSE同缺口 run-py6S1h 红→run-ylZEAh 绿（exit0）。复用既有语义投影保留合法任务文本、实际usage和cached_tokens，去除意外credential metadata；合法LLM任务文本复制 run-Qu7toC 红→run-3WL6SC 绿（exit0）。以上仍需最终受影响模块/全门禁覆盖。


基础切片两轴首审：Standards 2个P2（LLM发现连接生命周期、JEV导出primary/cleanup双错），Spec无已证实产品缺陷；25文件指纹保持一致。首轮全test run-QNg64V exit1/+640 -3，两个旧懒菜单布局和一项旧HTTP取消兼容；原始错误已隔离，未删测试/降约束。集中修复定点/同类及7完整受影响模块 run-2bpGe9 exit0/+107。最终全门禁/复审待重跑，先前全analyze零诊断不能替代修复后的新候选。

实际桌面 v3 预检：使用UI选择任务Qwen缓存、核验、标准引擎运行并启用公开API，完成JSON/SSE/400拒绝/主动及在途离页取消；5个导出全部实际发送快照对账，随后独立普通客户端仍成功。Qwen已正常停止。再通过UI核验/启动原有Kev/Laya，创建任务native-kev/quick/hard配置，完成3对象×HTTP/MCP的6次同一复杂state、三题型请求；6记录全部对账，hard显式debug converted_result等于本次output、2个真实有效席位。最初编辑未获得焦点的3单题记录只作单题证据，未计混合全量通过。

桌面原始导出及摘要在`.scratch/playground-benchmarks/implementation/gui-llm-v3-summary.json`、`gui-jev-mixed-v3-summary.json`；当前运行app PID80433、两自有JEV进程仍用于联调，C0用户配置备份在`.tooling/playground-native-state-20261009/c0`。修复改变构建输入后须更新并对账；最终退出/恢复用户配置尚未执行，不能宣称资源闭环。


最终基础候选门禁：run-Y0Ar5n format exit0（105文件、0changed），run-tFtXZn 完整analyze exit0零诊断，run-JHypT9 全test exit0/+646。V2 Standards/Spec复审均无未关闭P0/P1/P2，复盘见foundation-retro.md。Mac v4构建exit0、构建及独立校验源指纹与当前产品源一致。

最终原生v4：冷启动GET models实际空；UI显式核验/运行Kev/Laya；独立普通HTTP/MCP对native-kev/quick/hard共6次复杂state+choice/score/noul通过并保留源码指纹/实际raw/debug（live-jev-v4.json）。最终表单实际添加score/noul并提交导出（gui-jev-form-v4.json）三题型已核。验证脚本第一次误用不存在的codec方法编译exit254，未计通过；修正公开JevModelRequest codec后真实退出0。最终JEV取消原生证明与修复后LLM GUI审计仍待，#63/#64尚未关闭。

正常退出v4后app20363及两子进程23513/24846均不存活，HTTP/MCP/两原生端口都拒绝连接。仅按C1摘要完全匹配移除任务新建settings/jev_models/public_models，C0原文件保持字节一致；共享模型与原引擎均保留，任务配置C1可恢复备份留在tooling。没有Git提交、推送、PR或工单结项；后续导航和五完整基准未实施，不将基础进展当总规格完成。

最终基础 LLM 原生验收（2026-10-09 07:10 UTC）：v4 全构建输入 SHA 与当前候选一致，GUI JSON/SSE/HTTP400/按钮取消/离页取消五件导出逐项核对实际请求；两取消部分文本798/1255字符且无DONE，独立普通后续HTTP成功。正常退出app66728/model68391全消失、3端口拒绝，C0配置恢复，共享资产保留。验收映射见 ignored acceptance-64.md / gui-llm-v4-summary.json；这是#64基础工单证据，#65–#73仍未完成。

2026-10-09：#64七项验收评论已发布并关闭；#63 native cancellation v5退出1，同实例独立大批请求返回504，已取消请求许可2→1约8.3ms。原始失败保留，正在对照相同请求无取消基线，尚不能归因为CPP任务未终止或产品缺陷。授权dev已从同名本地分支推送，本地/实际远端均07729aec710cb5516e77ae853b152f529ab3b897；阶段分支仍无提交/PR。受管Jevman开发资源预检九命令退出0，原23回放测试及独立43依赖integrity通过，puregreedy一局7276帧且模型calls0，回放一致；不计完整100局评测。

#63最终普通取消验收v7退出0：同真实Kev实例上原长A24题/80facts实际后台processing后，普通HTTP及MCP取消只归还其许可2→1（6486/5600us），独立短B完整成功、最终active0、晚结果不改写。B短基线104ms；v6无取消长B自身10.1s超预算说明v5不能归因于取消。保留v5/v6失败及v6工具模板错误；不提高native10s/committee30s。v7源码与final v4匹配，拥有PID17510/17881及temp root已收尾。基础#63/#64七项验收均齐，后续导航及五完整基准仍未完成。

当前阶段入口（2026-10-09）：基础候选已提交并推送571e096b089cd21b6d392792b8b94788b548962f，阶段PR [#74](https://github.com/Ghost233/GhostModelDeck/pull/74) 为draft，目标dev。本地/实际远端阶段分支该SHA一致，dev/main均07729aec710cb5516e77ae853b152f529ab3b897。#63/#64真实验收后关闭，原生依赖核验已解锁#65，实施者llm_basic_64只拥有main/council及导航相关测试。root准备独立APFS克隆的三模型fixture和原Qwen相对路径receipt，原文件SHA不变；尚未作为导航/完整基准通过。dev还未合入任何实现，总规格#62保持开放。

#65候选实现已冻结：run-fsZdcS配置/迁移12+导航3共15通过exit0，原desktop完整run-vHReyw34通过exit0。实际Macv5 build exit0/77输入匹配；新顶部区域与能力Tab、共享设置、显式三模型启动与只配委配置已演示。LLMJSON、hard三typeHTTP/MCP原文/debug两席位、SSE生成中能力切页取消（部分3016字符）与返回输入/输出留存导出已核对。v5发现rapid双Cancel会重复pop根route使Flutter黑屏、main dispose后正常CmdQ无法完成；此为未关闭P2，不能依据其他成功宣称正常退出通过。按准确PID/command仅TERM本次4自有进程、5端口拒绝、哈希核对原配置恢复，forcedcleanup单独记录为非正常退出通过。je63单一owner两export dialogs红绿修复中；冻结记录65-freeze.json及gui-stage65-v5-summary.json，后续新Mac候选、完整门禁和两轴审查尚待。中断后原临时容器缺失，恢复无挂载容器-b固定SDK/seedSHA/在线DNSHTTPS及ready成功；首次GitTLSpub失败exit69后重试恢复，不计业务结果。外来docs/agents/label-colors.json保留排除。

最终v6原生复验（2026-10-09 09:21 UTC）：77构建输入与候选匹配，冷公开发现为空；显式三模型Ready。真实LLM及hard三type结果之后，两类export实际连续Cancel/Confirm均只关闭modal、保留page/input/result，可重新打开导出。JEV真实24题/80facts请求在客户端测试中切引擎再返回，cancelled600541us、原输入留存且output/debug/raw均null；之前剪贴板未编辑到位及隔工具回合后10s服务器504的尝试保留未计取消通过。取消后独立HTTP/MCP六次混合三type正常，最终CmdQ正常退出app62896及models65060/65886/66884（无信号）、5端口拒绝、原配置哈希恢复。首套完整test run-fXZt1i退出1/+654/-2：遗漏旧jev_model_page_test咨询已原case红后迁publicHTTP（所有原配置及标准结果断言保留），定点/完整file/analyze/format通过；oMLX原失败是并行loopback临时端口碰撞，原case隔离run-PZu7qr退出0，未改业务。最终完整门禁将concurrency1运行全套，不减测试或断言。V2两轴0openP0/P1/P2，因新增旧用例迁移及本证据文档须补受影响复审。

阶段1最终门禁通过：run-mGkdYe格式exit0/106文件0改动，run-iM6vlI全analyze exit0/零诊断，run-BLuHvO全test --concurrency1 exit0/656通过，串行完整保全部测试及业务断言。三份归档内全部lib/test/lock/config与当前候选字节哈希一致，Macv6全部77输入匹配；shell入口bash-n和diffcheck0。V3两轴全base→30文件覆盖且无openP0/P1/P2，首全套失败/网络失败/原生失败均保留而非当pass。汇总证据ignored stage1-final-verification.json，当前无live作业或native测试进程，原用户配置已恢复。阶段1 #63/#64/#65已具备验收，#74尚draft待最后记录审查/提交后按授权合入dev；#62及#66–73完整基准和main总PR仍待，不以阶段1验收代替总交付。

阶段二 #66 起点为 dev `8da3777caf5a2eab8fffa8e230cdead28578caa4`，工作分支 `codex/playground-stage-2`。DecideBench 以 submodule 固定原提交 `18e9c5eedd2855257ae534b5879ebba613479586`；安装版资源模块实际 HTTPS 获取并核验 22 文件／921,100 字节，保留原 400 题、200 对、297 示例、63 模板。最终资源预检 v2 退出0；公开 HTTP 全400题的外部引擎 I/O 替身测试 run-rWjji5 退出0，原请求摘要及独立原评分向量通过，二者不能替代真实模型完整评测。

2026-10-09 检查环境按更新后的工程规范转为宿主机，固定 Flutter 3.47.6 (`5fc346839b5d0eef006ed8404392afb4dfae428d`)／Dart 3.13.5；在线 pub get 退出0，lockfile未改。每次定点检查记录 HEAD、执行前后源码指纹、命令、日志及真实退出码。资源实现者首次 Flutter analyze wrapper 因 SDK cache 写权限退出1，已单独保留；安全的固定 Dart 分析随后四个文件零诊断，不冒称 wrapper 通过。宿主退出测试 host-runner66-shutdown-red 真实退出1：两例均为预期 interrupted、实际 running，close 清理的晚到事件错误另记；应用图退出用例 host-manager66-red2 复现同一记录错误；host-navigation66-red 复现 JEV 缺基准菜单。这些失败正在修复，阶段二尚未提交或验收。

阶段二当前行为闭环：host-shutdown66-green 退出0/4项（退出标中断、保存与释放、资源完整加载取消）；host-report66-green 退出0/1项、完整400次公开 HTTP 和200对报告/逐题原文/历史/安全导出删除。页面首个5s超时经SDK runAsync契约定位为测试假异步区创建Completer，移到真实IO同区后原期限及断言全部保留，host-ui66-zone-green退出0。准备中重挂无法取消的业务红 host-preparation66-red 退出1，资源状态转为资源owner后 host-preparation66-green退出0/3项，包含准备失败与最小桌面视口。选择同一活跃历史批次导致显示“运行中”旧快照的红 host-history66-live-red 退出1，最小跟随当前id修复后退出0。原始失败、真实退出及源码指纹均保存；这些I/O替身行为证据仍不计真实模型成绩。

执行器单题503按原400分母继续、不重试，host-singlefail66-green退出0/1项（正确399/400，正确配对199/200，有效399/失败1，公开HTTP502保留引擎原503错误）。实际HTTP监听停止、内部模型元数据仍Ready的红复现后，下一题前通过普通公开发现判断对象不可调用，host-listener66-green退出0/1项。合法raw与parsed不同选择的外部记录损坏已真实红后拒绝，host-raw66-green退出0/1项；非success响应不授予typed任务字段脱敏豁免，相关原题及Store回归退出0/6项。真实写入失败仍标running且退出吞保存错误的host-storage66-red退出1，当前单一执行器owner修复中。无阶段二提交/PR或真实完整模型验收，#66及#62保持开放。

JEVal前置解码技术预检与阶段二实现独立：隔离固定纯Dart包libbigdata1.0.1/libcompress1.2.1真实解码原11257行/7列，摘要精确匹配独立PyArrow oracle，主项目pubspec/lock未变。只证明Mac arm64解码路径，未提前实施#68、未重托管/翻译题目，也未冒称Intel或模型评测验收。证据见ignored jeval-decoding-preflight.md。

2026-10-09 用户进一步修正本次交付：**产品、全部检查、真实验收及评测运行时均仅 macOS arm64**。Linux、Windows、Intel/x64 及其验证移出本次范围；旧容器和跨架构资料仅属历史参考，本次不新建或恢复容器。原功能、普通公开HTTP/MCP、委员会对照、五项完整原题基准、Jevman100局、无快速试跑及字体/布局/业务断言保持。统一一次准备固定SDK/lock/联网解析、已核SHA字体、实际MacSDK MaterialIcons、显式Python和规范临时目录后，固定 #66 候选集中完成门禁与真实验收，不反复冻结。

修正时当前状态：#66生产代码已实现于 `codex/playground-stage-2`，基准HEAD `8da3777caf5a2eab8fffa8e230cdead28578caa4`，尚未提交。首套宿主完整测试 `host-full66-test` 真实退出1、623通过/70失败、输入前后不变；不能宣称门禁通过。规范临时目录定点证实模型扫描路径及sticky安全用例恢复通过，但原文件watch故障注入仍迟到、系统Python不支持测试所需参数，正在仅修测试环境/真实外部FS接缝，保原5s及失败/清理断言。全仓分析两项构造器写法诊断已机械修正，后续最终分析待运行。真实Mac模型400题、独立原评分、退出/历史尚未执行；阶段二尚无commit/PR。阶段一PR #74已合入dev，main保持总PR目标，最终总PR尚未创建。

统一宿主环境准备已实际完成：`scripts/test-host.sh prepare`，`.tooling/host-tests/run-9gqo2h` 退出0；Darwin/arm64、Flutter3.47.6/Dart3.13.5固定摘要、Python3.12.14、已核SHA Noto CJK与实际SDK MaterialIcons、物理TMPDIR全部记录，在线pubget退出0且lock未变。后续只复用该清单，不再逐项补环境。原4失败定点 `run-O03nsG`退出1：两真实Python原案通过，两FS故障注入新fixture条件触发过早报LateInitializationError；单一owner修正此接缝，保全部断言。规格/开放工单#62、#66–73已按Ghost233更新平台范围（状态仍OPEN），#73验收清单原必需容器条款已改宿主Macarm64；预检Intel/x64移出本次待验收。

当前分支同步只读核对：local dev/realremote dev均`8da3777caf5a2eab8fffa8e230cdead28578caa4`，main均`07729aec710cb5516e77ae853b152f529ab3b897`，阶段1均`bb8fefcea6102154b1395a19f5ef168f0f43ecd6`；stage2只本地未提交分支，无远端或PR，不处于behind。原他会话规范编辑已保存变更前快照，label-colors未跟踪文件保留。当前候选状态入口ignored `66-current-candidate-status.json`；完整门禁与真实400题仍待，未宣称交付完成。

固定 #66 候选最终宿主集中门禁已通过：`scripts/test-host.sh check`，`.tooling/host-tests/run-Z3naYe` overall/format/analyze/test全部真实退出0；120文件格式零改动、全仓分析零诊断、完整694项测试通过。输入全量SHA与当前工作区一一匹配且作业前后不变，汇总ignored `66-final-host-gates.json`。上一套run-PRbMok的691通过/2失败全部保留：Mac安全祖先mock改为实际规范路径、保拒绝0777非sticky断言且实际注入证据，两案0与完整21案0；网关超大请求413响应先于订阅取消的真实时序缺陷修复，原案fresh/pool/403/GET0与完整Gateway/ownedHTTP39案0；JEV同类actual oversizedchunked256KiB案直接0，未无证据改其产品。

已向唯一native_66执行者放行同候选Mac构建与真实完整400题流程。build实际0、86构建输入前后一致、版本0.1.4；固定Flutter默认生成universal arm64+x86_64 Mach-O，验收与实际运行仅macOSarm64，该Intel slice不形成支持或待验收要求，也不准备x64运行时。本轮没有全局SDK配置修改、thin或正式发布。真实模型400、独立评分、正常退出与重启历史仍执行中，未以构建或694项测试宣称这些已通过。阶段二没有commit/PR，#66/#62继续OPEN；Git方案和同期修改保留规则不变。


## #66 已验收候选记录（2026-10-09，macOS arm64）

本次仅适配 macOS arm64，所有检查在该宿主机执行。Linux、Windows、Intel/x64 不属于本次验收；不新建或恢复容器。规格、#62 及开放子工单 #66–#73 已更新这一范围，原生题目、固定 submodule、公开 HTTP/MCP、委员会对照、五项完整基准、Jevman 100 局及无快速试跑要求保持。

#66 当前候选在 `codex/playground-stage-2`，基于 `8da3777caf5a2eab8fffa8e230cdead28578caa4`，尚待提交。所有已确认问题已关闭，主线程核对 295 个门禁输入文件摘要与当前内容完全相同；没有重复执行相同完整检查。统一环境准备通过在线依赖解析，保留原 lockfile，固定 Flutter 3.47.6 / Dart 3.13.5、实际 Mac SDK MaterialIcons、已校验 Noto CJK 字体及显式 Python 3.12.14。当前完整门禁 `.tooling/host-tests/run-Z3naYe`：格式检查 120 文件零改动、静态分析零诊断、完整测试 694 项全部通过，三个真实退出码均为 0；字体与布局断言完整保留。

同一产品输入的 Mac 构建真实退出 0，版本保持 0.1.4，86 项构建输入直到验收结束未变。实际应用进程确认为 ARM64；Flutter 默认产物包含 x86_64/arm64，这是产物事实，不构成 Intel 适配或待验收要求。真实模型使用 Kev 0.8B 的已校验资产，llama.cpp b11381/836d57176，客户端 30 秒与原服务 10 秒预算均保持。

真实 GUI 首次下载 22 个固定源文件（921,100 字节），与 submodule `18e9c5eedd2855257ae534b5879ebba613479586` 的原始字节逐一相符。实际应用拥有的公开 HTTP 批次 `run-1791553928995984` 完整执行 400 题、200 对：400 有效返回、0 失败、0 超时；accuracy 43.50%（174/400）、pair accuracy 16.50%（33/200），Brier 0.6850367414、ECE 0.0869743106，成功调用延迟 p50 106.193 ms、p95 151.05555 ms。独立审计使用未修改的上游请求构造、解析和评分函数，对账全部 400 个原请求与实际原始响应，原成绩一致，真实退出 0。资产来源/量化元信息缺失仍如实记录 null，不由文件名补造。

真实切页后任务继续；执行至 302 题时关闭窗口，后台完成 400 题。按钮取消记录 30 题且无完整成绩；正常 CmdQ 在 38 题时保存 interrupted。重启历史查看/导出成功，不自动续跑；删除仅移除所选取消记录，题源、模型及其他记录摘要不变。最终正常退出后所有本次拥有的应用/模型进程消失，54841/54842/60797 均拒绝连接，六项原用户配置恢复；用户模型与其他会话文件保留。任务创建的缓存及完整/中断历史保留在应用支持目录供复核，任务配置另留可恢复备份。当前没有可持续 Ready 对象或稳定公开服务。

证据入口：`.scratch/playground-benchmarks/implementation/native66-summary.json`、`native66-full400-author-audit.json`、`native66-restoration.json`、`66-root-evidence-audit.json`、`66-final-host-gates.json`。原环境和执行器失败日志保留；包括首次沙箱构建拒绝及 CUA 首次选择应用耗时 2157 秒，均不算模型失败或成功检查。

Git 状态：阶段一 PR [#74](https://github.com/Ghost233/GhostModelDeck/pull/74) 已合入 dev；#66 尚待候选提交/工单验收，#67 未完成，阶段二 PR 和最终总 PR 尚未创建。最近已核对 dev 本地/实际远端均 `8da3777caf5a2eab8fffa8e230cdead28578caa4`，main 均 `07729aec710cb5516e77ae853b152f529ab3b897`。下一步是 #66 纳入阶段候选→#67→阶段二审查/复盘/集成；总规格仍开放，最终 dev→main 总 PR 将保持 ready 待用户合并。


当前 Git/工单推进：#66 九项已由 root 与独立 merger 验收，代码提交 `ad4ec18609b3851e328fa4eb2b9380d7157b2374` 已推送且本地/远端一致，[#66](https://github.com/Ghost233/GhostModelDeck/issues/66) 已关闭。阶段二 [PR #75](https://github.com/Ghost233/GhostModelDeck/pull/75) 已创建并附到本聊天，目标 dev、保持 draft。#67 已领取，尚未实施；阶段二整体审查/复盘尚待，dev 仍为阶段一合并结果。最终 dev→main 总 PR 尚未创建，最终仅 ready 待用户合并。主线程保留其他会话 `docs/agents/label-colors.json` 未跟踪文件；没有 stash、reset、覆盖或新增 worktree。


当前代码候选 072335d：全部已确认修复已通过718项完整宿主门禁；两轴复审分别为Standards P0/P1/P2均0、Spec P0/P1/P2均0，原启动窗口P2已关闭，覆盖固定base8da至当前完整diff。当前Release构建真实退出0、版本0.1.4，86构建输入与HEAD前后一致。实际Dart App.framework摘要为`ea1652ef2e747b2a5076b40d85b312bebc3e62e79f5be5116d88f4326569fbed`。记录为ignored stage2-standards-review-v2.md、stage2-spec-review-v2.md、native67-build-current-result.json。

本阶段剩余为真实3对象×HTTP/MCP六份完整400题、独立原评分和正常客户端核对、原生退出／历史验收。实际54841/54842及0.1.3两个Ready模型仍由Sentinel会话保留；新候选已准备，但没有实机GO。需要落实临时正常退出旧服务、保留最新六配置、验收后恢复原服务的使用安排，获准前只读观察。阶段PR75仍draft，#66/#67和总规格不以代码门禁或旧真实400题代替最终验收。
