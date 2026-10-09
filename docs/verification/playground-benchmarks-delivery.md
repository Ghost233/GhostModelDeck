# 测试场与原题基准交付

规格：[#62](https://github.com/Ghost233/GhostModelDeck/issues/62)。起点：`07729aec710cb5516e77ae853b152f529ab3b897`。

用户已授权 dev 集成分支、阶段分支/PR；最终 dev → main 总 PR 保持 ready 待合并。当前阶段一 #63–#65，#63/#64 并行实施，#65 等待两项验收。全部五项基准和真实完整评测仍属于总验收，不降低规模。

当前记录入口：`.scratch/playground-benchmarks/implementation/delivery-state.json`。主线程负责检查入口与公开网关；实现者分别拥有 JEV 编辑器和新增 LLM 编辑器。已有规格及领域文档保留。

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
