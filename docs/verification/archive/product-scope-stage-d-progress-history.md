# 阶段 D 过程历史快照

以下为已结束过程记录，不表示当前作业状态；当前状态只读上级唯一交付清单。

# 引擎来源与实例管理交付记录

## 唯一当前状态

2026-10-13。来源为 [产品职责与实例管理规格](../requirements/product-scope-and-launch-instances-spec.md) 和 #82–#96。主线程推进，没有子代理、容器或正式发布。

| 项目 | 当前状态 |
| --- | --- |
| 候选 | 阶段 D，分支 `codex/product-instances-stage-4`，起点 `58f452b4546acf186a86dc4315b335bb9b1d4134`；#95 已领取，只接通新对象并完成 #96 |
| 检查 | 阶段 D 相关模块 `run-wwjqwp` 61 项通过；静态检查 `run-0QGA1P` 通过。新增预算相关125项 run-F6ScQ7、静态run-SrWiyF通过；D 完整宿主门禁 run-gZVV07 已结束：956通过/4失败/退出1；四个原失败run-VHqGnj定点全部通过，三个受影响模块run-p2o9Le 79项通过，当前唯一最终门禁run-uCS7B1（stage-d-final-full-check-fixed.log），格式/分析通过，测试进行中；日志 stage-d-final-full-check.log；C 的 run-AGOOpq 仅覆盖已集成的 C |
| 未关闭事项 | 下拉重复激活原失败已关闭；4项原失败已关闭；剩余最终门禁、固定候选审查及阶段/总PR集成；阶段 C 全部结项，PR #99 已合入 dev |
| 下一动作 | 收取唯一最终完整门禁，提交固定候选、分别复审两轴，阶段 PR 合入 dev 后创建总 PR ready |
| 原生产物 | `stage-c-final-council-macos-build.log` 构建退出 0，应用、FlutterMacOS 和 App.framework 均为 arm64；这是 C 的已验证产物；D 目前有新应用代码，需一次新构建，不冒称旧产物覆盖 D |
| 服务交接 | Wiki/Kev-4B 交接独立推进，见下文；具体模型原生能力或成绩不作为阶段 C 交付条件 |

A、B 已完成，不列为待办。D 仅接通 #95 的新对象和 #96 最终集成；已有五项完整基准与整批功能不重新开发。

## 当前工作分类

- **未实现：** #96 最终集成、固定候选审查及总 PR。#95 接线已实现，原生与完整门禁尚待。
- **未验证：** 阶段 D 最小原生验收、最终完整检查及总审查；阶段 C 已完成集成，不是模型成绩验证。
- **已验证待提交：** 阶段 C 已全部提交、审查并集成；阶段 D 新对象身份、公开协议、取消及相关页面已有定点和 61 项模块通过证据，待最终验收后提交。
- **历史问题：** 字形损坏和旧黑屏目前未复现，根因未定；旧失败与取消检查保留。历史问题不以重跑题集替代诊断。

## 已完成阶段与分支

| 阶段 | 完成证据 | Git 状态 |
| --- | --- | --- |
| A #83–#86 | `run-70BRLY`：925 项、格式、分析通过；真实多目录/文件链接/安装交互及 arm64 产物通过 | [PR #97](https://github.com/Ghost233/GhostModelDeck/pull/97) 已合入 dev；阶段复审见 [报告](product-scope-stage-a-review.md) |
| B #87–#89 | `run-dDSmSQ`：935 项完整检查通过；保存快照、公开名、llama.cpp/JEV 健康启动/停止与真实短 HTTP 通过 | [PR #98](https://github.com/Ghost233/GhostModelDeck/pull/98) 已合入 dev `fd67875923b60d79da8731d0e979d62897b5d395`；见 [报告](product-scope-stage-b-review.md) |

本地/远端 dev 为 `58f452b4546acf186a86dc4315b335bb9b1d4134`；main 为 `0eda06296aa4fdff65b9ee83f90564ff7a76ebde`。2026-10-13 最近一次认证核对为 Ghost233，fetch 后这些分支同步。后续写操作完成后再核对完整 hash 与工作区状态。

## 阶段 C 已收齐证据

审查范围为 #90–#94，见 [阶段 C 首审与复盘](product-scope-stage-c-review.md)。固定提交复审已通过，两轴没有未关闭 P0/P1/P2。

| 行为 | 已有证据与范围 |
| --- | --- |
| Splash/oMLX、实例、委员会与公开调用 | `run-vgVM0O`：196 项受影响检查通过，源码输入未变 |
| 资源准备态 | 原失败 `run-wQ9K2E` → `run-7zBFk1`；`run-pnNgED` 32 项通过。真实窗口显示准备中、操作暂关；读取完成后显示已保存，没有缺失误报 |
| 委员会失效说明 | 原失败 `run-BtWsxE` → `run-neVq1n`；`run-1qu8jx` 44 项通过。真实窗口同时显示缺失原因与旧运行仍可调用，恢复目录后清除标红 |
| 引擎页面旧提示 | `run-XTbkyF` 原失败 → `run-EVm8zu`；`run-v0ifeo` 27 项通过。保留真实来源、两项未安装及操作断言 |
| 原位置更新及启动零推理 | `run-cWWcKm` 的 7 项旧契约失败已成组处理；参数别名新增断言错误 `run-n5s8Ub` 保留，`run-jjlvQC` 定点及 `run-5KlWJI` 33 项模块回归通过。错误架构、检查期间文件变化和参数保留断言继续执行 |
| 未知架构显式短测试 | `run-3jSqk0` → `run-VuRUGf`；只拒绝实际缺失/损坏，不新增架构或模型名称名单 |
| 最终静态与构建 | `run-49SojX` 分析通过；最后构建及三项实际架构均通过，测试修改不触发重复构建 |

真实证据位于 `.scratch/product-scope-20261012/`：

- `stage-c-splash-native-http.json`：普通 JSON 与 SSE 返回 OK/200，所属进程停止，外部 Splash 保留；原参数失败单独保留。
- `stage-c-omlx-native-http.json`：真实模型物理加载、普通 HTTP 非空完成文本、停止。固定模型提交及 SHA 见 `omlx-native-model-receipt.json`，准备作业已经结束。
- `stage-c-omlx-private-native.json`：第一份内存保护拒绝保留；未保存草稿使用明确 2 GiB 保护上限后 HTTP 200，临时进程为 0，保存文件摘要不变，已有 StartLux 保持。
- `stage-c-root-unlink-native-http.json`：解除读取关联后标红，旧运行与实际命令保持，HTTP 仍 OK/200；原目录恢复，文件及公开名不变。
- `stage-c-native-error-file.json`：明确无效参数真实失败，一行摘要，完整 2409 字节日志与堆栈保留；Finder 选中正确文件。失败进程清零，原 Splash 参数已通过界面还原。
- `stage-c-final-native-incremental.json`：准备、资源恢复、最终缺失说明、正常退出与产物绑定。验收委员会 `stage-c-resource-check` 保留，没有自动删除或概率请求。

`run-mdxC6d`、`run-XTbkyF`、`run-cWWcKm` 保留原始失败/中断，均不计完整通过。其他定点原失败和先前阶段的成功记录见 [历史快照](archive/engine-sources-and-installation-2026-10-12-progress-history.md)，不再把其中的旧作业状态当作当前待办。

## 服务交接独立记录

用户已明确授权向「设计标准化 Wiki 构建流程」回复及恢复通知，并在该会话授权创建/启动精确 Kev-4B 验收实例。GMD 主线程独占正式 GUI 创建与启动；协议请求由对方唯一执行者负责，不自动换模型或运行题集。

- StartLux 文本服务保持；原生接口实际由引擎返回 501 “This model is not a decision model”，GMD 如实返回 502。该模型能力不兼容不阻塞产品阶段交付。
- 现有 Kev-4B 文件 3033489824 字节，全 SHA `33ae6b18926502b2209a1bf7d3b61a350d65938441515c686bb87d226a19eff9` 及前后 stat 已核对。已创建并启动唯一保存实例，公开号 `kev-4b-q4-k-m`，保存参数与授权边界一致；实际加载身份、容量 65536/width1、PID8631 和引擎 SHA 已核对，ready 回执已落盘。显示名称不作为前置。
- 交接主记录：`startlux-current-public-service-status.json`。Kev 独立记录：`kev4b-private-native-ready.json`。只在实际保存、加载和元数据核对后登记 ready；失败保留原文。
- GUI 操作两次遇到“用户改变应用”护栏，持久文件确认没有创建重复实例。用户已回复“现在可以继续操作 GMD”；随后从精确模型库项成功创建，未重复实例。

## 固定收尾规则

相关契约检查 → 最小原生流程 → 关闭已知问题 → 完整门禁 → 提交 → 固定提交复审 → 阶段 PR 合入 dev。阶段 D 完成后总审查，`dev → main` 总 PR 保持 ready，等待用户合并。

只支持 macOS arm64。固定 Flutter/Dart SDK、lockfile、联网解析和宿主检查；字体与布局断言保持。主线程只保留一份同类作业，长作业 sleep 300 实际结束后收取。保留其他会话修改，不正式发布。

保留公开 HTTP/MCP、原生题目、固定 submodule、五项完整基准、Jevman 100 局、无快速试跑、摘要分页和 Finder 文件入口。评测是可选功能，不要求每个模型跑全部题集。未受影响成功证据直接复用；失败、取消、超时或缺失完成证据不计通过。

阶段 C 最后完整检查 run-8LKd5e 已结束，953 通过、1 失败。原失效成员保存断言和零延迟等待不符合新持久保存路径；原失败 run-VlPyKv 保留。run-23zdhL 定点通过，验证改名/重开仍保留两份引用，再显式移除缺失引用。相关模块 `run-4TsQFq` 46 项通过，日志 stage-c-final-member-reference-affected.log；应用代码未改，原生产物复用。

最终宿主检查 run-AGOOpq：954 项，格式 189 文件无变化，分析无问题，退出 0；完成标记及当前指纹核对通过。构建绑定的应用代码未变，原生产物复用。当前没有有效检查作业，对应固定提交已复审并集成，见阶段 C 记录。

阶段 C PR #99 已回读 MERGED；dev 本地/远端同为 58f452b4546acf186a86dc4315b335bb9b1d4134，阶段三分支同为3678eb5a5a596af8c27a2a085c7e6ce31591ff63，#90–#94已关闭。当前进入阶段D，不把阶段C重新列为待办。

阶段 D 增量：run-MbhQrp 原生实例对象查找原失败 → run-RSnhwM；保存下一次重绑误改当前身份 run-QSQxdn → run-wJyVGI。公开 HTTP/MCP 的实例/委员会基础请求及既有完整计划取消/历史由新接线夹具验证，run-wwjqwp 61 项相关模块通过。没有重新开发基准或跑真实模型题集。服务交接已确认在途为零；一次代表性请求 HTTP 200/6.05 秒，原超时请求的原文缺失，不算精确重放。诊断证据见 wiki-representative-native-diagnostic/record.json。协议作业继续暂停，接下来更新应用并恢复原配置。

新增范围：用户于 2026-10-13 明确要求 JEV 默认请求预算统一为 60 秒，保留已明确配置的预算。实例增加正整数秒配置、持久化与公开协议读取。聊天/嵌入、引擎探测超时及 Jevman 原定 2 秒决策/30 秒 warmup 保持既有语义。Kev 使用同一资产及启动参数；Wiki 请求仍暂停。原失败 run-quzIic → run-mHcpSY 持久化定点通过。

Kev 预算生效：GUI 持久保存60秒/revision2，同一GGUF和启动参数；stage-d-budget-native/record.json 最小公开HTTP200、0.188秒、实际预算60000000us。已通知Wiki线程继续开发，业务题测试暂停没有自动撤销。StartLux保存配置在本轮前已不存在，按当前配置保留，不自动恢复。

黑屏新证据：原生窗口选择下拉对象后根页面和公开监听消失，进程仍在。系统日志与短栈已保留，正常退出不响应后仅释放本应用两个进程并恢复同一产物。固定Flutter下拉选项重复语义激活最小用例 run-0rbcly 明确释放根页面。修复只保护桌面根路由，弹窗路由保持；旧图形根因不笼统归为字体或Metal。完整门禁未启动，先闭环本失败。

最终原生复核：用户明确反馈“选择成功，窗口正常”，AX确认Kev公开名被选中、根页面和测试场仍在。run-j4UMXZ定点及run-xVzztG 52项回归通过；run-AG4IY6仅报告根路由有意拒绝完成的must_call_super提示，补局部原因说明后静态通过。新增注释不改变运行语义；最终arm64产物已核对。原先黑屏现场与强制收尾不计通过，修复后正常退出已完成。

run-gZVV07已发现4项：desktop_layout_test两项生产夹具只复制旧home，未复制新增路由工厂；council_test默认预算仍断言10秒；benchmark_runner_test默认客户端仍断言30秒。保持原失败、先收取真实作业结果再修改测试；字体、可点击、超时及资源断言全部保留，不扩展为模型题集或重新构建未改变的应用。

run-VHqGnj四个原失败通过。生产布局夹具使用真实根路由，字体/可点击/最小尺寸断言全部保留；委员会默认60秒精确计时在59.9–61秒边界，无伪造意见和子进程清理断言保持；批次客户端60秒且完整400题/200对断言保持。仅测试修改，未重建或重启应用。

受影响三个模块run-p2o9Le 79项全部通过；保留原完整失败run-gZVV07和定点回执。最终门禁重新覆盖最终测试内容，应用代码、固定SDK/字体/lockfile与原生产物保持。
