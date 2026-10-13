# 引擎来源与实例管理交付记录

## 唯一当前状态

2026-10-13。来源为 [产品职责与实例管理规格](../requirements/product-scope-and-launch-instances-spec.md) 和 #82–#96。主线程推进，没有子代理、容器或正式发布。

| 项目 | 当前状态 |
| --- | --- |
| 候选 | 阶段 C，分支 `codex/product-instances-stage-3`；起点及 HEAD 为 `fd67875923b60d79da8731d0e979d62897b5d395`，实现和测试仍未提交；当前内容由 `run-8LKd5e/input.json` 绑定 |
| 唯一完整检查 | `run-AGOOpq` 已结束：954 项、格式与分析通过，退出 0，成功标记存在；前后和当前输入一致，无有效检查作业 |
| 未关闭事项 | 完整门禁终态；提交后的固定候选双轴复审；阶段 C PR 与 dev 集成；阶段 D #95/#96。已知原失败已关闭：`run-23zdhL` 定点及 `run-4TsQFq` 46 项模块通过；完整门禁已通过；仍须固定提交复审 |
| 下一动作 | 提交最终候选 → 固定提交双轴复审 → 阶段 C PR 合入 dev → 同步本地与远端；再推进 #95/#96 |
| 原生产物 | `stage-c-final-council-macos-build.log` 构建退出 0，应用、FlutterMacOS 和 App.framework 均为 arm64；此后只调整测试，应用代码未变，产物继续复用 |
| 服务交接 | Wiki/Kev-4B 交接独立推进，见下文；具体模型原生能力或成绩不作为阶段 C 交付条件 |

A、B 已完成，不列为待办。D 仅接通 #95 的新对象和 #96 最终集成；已有五项完整基准与整批功能不重新开发。

## 当前工作分类

- **未实现：** #95 测试场对保存实例/委员会的新对象接线，以及 #96 最终集成。
- **未验证：** 提交后的固定候选复审和阶段 PR 集成；完整门禁与原生验收已通过，不是模型成绩验证。
- **已验证待提交：** 阶段 C 主要实现、相关模块检查、arm64 原生产物、短公开调用、草稿隔离、资源恢复、实际快照及错误文件/Finder。
- **历史问题：** 字形损坏和旧黑屏目前未复现，根因未定；旧失败与取消检查保留。历史问题不以重跑题集替代诊断。

## 已完成阶段与分支

| 阶段 | 完成证据 | Git 状态 |
| --- | --- | --- |
| A #83–#86 | `run-70BRLY`：925 项、格式、分析通过；真实多目录/文件链接/安装交互及 arm64 产物通过 | [PR #97](https://github.com/Ghost233/GhostModelDeck/pull/97) 已合入 dev；阶段复审见 [报告](product-scope-stage-a-review.md) |
| B #87–#89 | `run-dDSmSQ`：935 项完整检查通过；保存快照、公开名、llama.cpp/JEV 健康启动/停止与真实短 HTTP 通过 | [PR #98](https://github.com/Ghost233/GhostModelDeck/pull/98) 已合入 dev `fd67875923b60d79da8731d0e979d62897b5d395`；见 [报告](product-scope-stage-b-review.md) |

本地/远端 dev 为 `fd67875923b60d79da8731d0e979d62897b5d395`；main 为 `0eda06296aa4fdff65b9ee83f90564ff7a76ebde`。2026-10-13 最近一次认证核对为 Ghost233，fetch 后这些分支同步。后续写操作完成后再核对完整 hash 与工作区状态。

## 阶段 C 已收齐证据

审查范围为 #90–#94，见 [阶段 C 首审与复盘](product-scope-stage-c-review.md)。固定提交复审尚未执行。

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

最终宿主检查 run-AGOOpq：954 项，格式 189 文件无变化，分析无问题，退出 0；完成标记及当前指纹核对通过。构建绑定的应用代码未变，原生产物复用。当前没有有效检查作业，接下来提交并复审固定提交。
