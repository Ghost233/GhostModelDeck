# 独立审查：首版实现

基点 `236a016b8e2fe5366fbe35e413815890a500633c`，固定审查提交 `12ff8ddd8e6393a27c7f1131a053e884051aa132`。命令 `git diff <基点>...<审查提交>`；commit 列表仅该实现提交。三个新代理并行、相互独立，只读源码与文档，没有自行重跑测试或运行服务。

## Standards

1. **P2 — 退出前等待下载任务完成收尾。** `main.dart:102` 仅等待 ManagerLifecycle，然后同步 downloader.close 回复 native 成功。close 只发取消，不等待安装 finally/回滚。安装中退出可能留下无完整记录的正式文件，违反工程 E03/E04。提供可等待的封口、取消、收尾，并在 native 允许退出前等待；补确定性行为验证。
2. **P2 — 停止实例期间提供反馈并阻止重复提交。** `library_page.dart:618` 的按钮只受删除/核验 busy 控制。慢进程退出期间仍可重复停止并显示运行中，违反设计规范执行中反馈要求。按实例显示停止中，禁用重复操作，验证延迟退出及失败恢复。
3. **P2 — 设置长路径缺少完整值入口。** `settings_page.dart:131` 两行省略路径，没有 Tooltip、详情或复制。违反设计规范长路径可查看完整内容要求；保留紧凑布局并增加完整值入口。

Standards：3 项，最严重 P2；没有单独报告的重要坏味道，不把文件大小或抽象选择本身当硬违规。

## Spec

1. **P2 — 原生 Laya 包的嵌套配套文件被遗漏。** `model_package.dart:326` 仅收集权重同层依赖，使 `convaiinnovations/laya-multilingual@1720e3e3357cfe1e281542e223f8273b0890ca34` 被误判缺分词器并禁用下载。规格要求内部解析 tokenizer/config/head 等完整配套文件。固定清单实际上包括 34,363,188-byte 的 `tokenizer/tokenizer.json`，以及 `rl_agent_config.json`、`encoder/config.json`、tokenizer 配置。官方 loader 使用本地 tokenizer/config/完整权重；本次未运行它的原生推理，不称 ready。

修复应只关联所选包内的嵌套依赖，避免其他模型目录；只有 tokenizer 配置、缺词表载荷的包仍应 incomplete。依据：[固定 HF 清单](https://huggingface.co/api/models/convaiinnovations/laya-multilingual/revision/1720e3e3357cfe1e281542e223f8273b0890ca34?blobs=true)、[固定官方 loader](https://github.com/NandhaKishorM/laya/blob/8a6e1328cce2460a0e5aa348ad465bb1b5821cd2/laya/agent.py#L235)。

Spec：1 项，最严重 P2；未发现有证据的范围蔓延。

## 运行与数据可靠性

1. **P2 — 本地复用回执被模型库忽略。** `model_library.dart:490` 只接受 hf/lmStudio；`model_downloader.dart:590` 本地复用写 source:local。再次扫描丢失固定 repository/revision/license/upstream hash，无法正确对比后续内容变化。接受合法 local 回执并按上游哈希核验，同时保留未网络传输事实。
2. **P2 — 索引模型重复下载报告冲突。** `model_downloader.dart:145` 只对 resolved 复用，indexed 包会重复传输，最后 `:782` 因已有安装记录报冲突。核验已保存展开清单后复用，或安全接受同身份同内容的已有记录；拒绝变化 revision/hash，不覆盖正式共享文件。

可靠性：2 项，最严重 P2；其余所查委员会并发、取消、MCP 共用实例及原生退出路径没有可操作发现。

## 处理状态

六项由一个实现代理逐项经公开业务入口复现、修复和回归：

| 项目 | 修复与行为证据 |
| --- | --- |
| 下载退出收尾 | close 返回 Future，统一生命周期立即封口并等待；HTTP 下载中退出及真实 Directory.watch 触发第一条正式 hardlink 后退出，回滚完成才返回，既有共享文件保留、无安装记录 |
| 停止操作 | 按实例显示停止中/禁用；受控慢子进程只提交一次停止，失败后恢复操作，成功后 stopped |
| 完整目录 | 省略布局保留，Tooltip 显示完整路径，900×560/1.5x 无溢出 |
| 本地复用回执 | 接受合法 local/无传输记录，保留仓库与版本；同尺寸内容改变后 corrupt |
| 索引包重复下载 | 同身份、展开清单、全量哈希核验后零网络复用；伪造清单、变化内容或 revision/hash 被拒绝并保全原文件 |
| 嵌套 Laya | 固定 HF API 元数据快照经公开浏览/包解析入口关联六个必要文件；移除完整 tokenizer 载荷仍 incomplete，不称推理 ready |

完整 148 项测试通过（run-xO8axh），format 54 文件零改动（run-srCxku），完整 analyze 零诊断（run-X5J7v8）。六项均先红后绿；61 文件冻结清单 SHA-256 `9026f3ecd525897a94db398d1a3d23daf9bfe2b5a22c95b2ed30c4b0cf630a8f`，与最终测试源码一致。

该阶段尚待原审查者复查及修复提交的原生编译/验证，没有 P0/P1；后续结果见“最终复查”。

## 首轮修复复查与补充

固定修复提交 `98bbca3da8e2fdb22307d406c65a0f9b8ba5dd86`：Spec 确认嵌套 Laya 已解决、无新增；可靠性确认本地回执/索引复用已解决、无新增；Standards 确认停止/长路径已解决，但发现下载清理失败会被两层 catch 吞掉，退出仍可能误报成功。

同一实现代理补齐清理异常传播：逐项尝试剩余资源释放，保存第一份取消 Future，清理失败穿过包级/文件级 catch 到达 close 与统一 shutdown；changes 仍关闭。真实文件系统干预使回滚身份检查实际抛错，确认 shutdown failed、MCP/受管子进程仍收尾、共享文件保留。桌面调用只处理已经封口并发布的 failed 状态，禁止新下载/重试，原下载器 close 仍保持失败，不将错误重新变成正常取消。

补充修复最终 150 项测试通过（run-irz8Ju），format 54 文件零改动（run-RvAktF），analyze 零诊断（run-FZg11k）。冻结清单 SHA-256 `8faa80652cc6bdd07d4338562489ae0676750f034681d070b5fd7893bb703f5c`。该阶段尚待最后一项的固定提交复查与原生构建，后续结果见“最终复查”。

## 最终复查

最终代码提交 `49c2ad275cd7d99d90d18ea1ac48e707bf8a472c`：Standards 确认三项均解决、无新增 P0/P1/P2；Spec 确认一项仍解决、无新增；可靠性确认两项及清理失败补充均解决、无新增。三个原审查者各自只读核对固定提交、回归用例及日志，没有声称自行重跑测试。三个轴保留独立结论，不相互抵销。

该代码的最终 Mac release 编译成功（46.2 MB）。最终原生应用已经实际打开并成功切换设置与模型库；完整模型、MCP 与明确退出证据按对应原生记录的具体提交/阶段分别表达。
