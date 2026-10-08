# #36 审查与复盘记录

日期：2026-10-08（Asia/Shanghai）。固定阶段基线为 `6359dc14be4d426874ed83e30a65492a8140efce`，实施候选为 `91b793b63b79db9dafe33c8b47fa94af1add714f`。本记录补记该候选的初次双轴审查与已完成的会话/环境复盘；文档补记候选 `bc6b5095ee91f0121bcdc005b3207ffc84af99ea` 的后续 Spec 补充审查发现 1 项 P2，见下节；第一次 P2 修正提交为 `328403bb4e02340563a6348b1074a0cc5057491b`；其后的 v2 审查再次确认 1 项未知凭据 P2，当前修正后的 `6359...HEAD` 最终整体双轴复审仍由主线程执行，不将初审当作最终复审。

## 初次审查与复盘结果

| 环节 | 审查范围与结论 |
| --- | --- |
| Standards | 固定基线至实施候选的完整九文件变更；硬规则违反 0、判断类问题 0，P0/P1/P2/P3 均为 0。 |
| Spec | 逐项核对 #36 验收标准；缺失/部分实现 0、未请求行为/范围蔓延 0、错误实现 0，发现总计 0。 |
| 会话与环境复盘 | 初审双轴均为 0 后执行；新增 P0/P1/P2/P3 均为 0，当前无新增环境修复候选。 |
| 既有待办 | PR/hook 检查未接入的已有 CI 护栏 P3 继续 deferred；本阶段没有升级严重度的新证据，也未新增重复候选。 |

规范依据为仓库 AGENTS、工程规范、设计规范、CONTEXT、相关 ADR 及已确认需求。复盘核对了原始失败、真实退出码与最终输入证据：机械诊断由已有 linter 捕获并修正；取消断言加入待决同伴及业务截止前排空条件，揭示并修复了原先可能以截止排空误判主动取消的弱点。失败的 socket reset 实验已移除，产品错误与测试工具/环境假设错误分别保留，不将失败计为通过。

## 后续补充审查与修正

后续 Spec 补充审查确认 1 项 P2：无上下文凭据投影损坏合法 JEV 标识、概率/legend、标准结果及页面复制。初审的零发现记录是历史事实，此 P2 修正了原结果保留标准的审查结论；既有 CI 护栏 P3 deferred 未因此变更。

公开原生/真实 HTTP/MCP 与实际页面预览/复制先红后绿。共享 sealer 现在区分标识字典、明确任务数据和凭据配置/诊断，完整 raw JSON 采用结构上下文；真实凭据 extras、raw header/error 与已知 echo 仍受保护。named council quick/hard 的每席和完整 aggregate/votes/legend、converted_result、input/request/raw_response 都加入断言。没有取消原有凭据保护，也没有修改推理输入或虚构响应字段。原始失败及精准修复范围见 [规范验证记录](jev-inference-playground.md#p2-补充审查修正)。

## v2 审查与当前修正

| 环节 | 范围与结论 |
| --- | --- |
| v2 Standards | `6359...328403b` 完整阶段；发现 0。 |
| v2 Spec | 同一范围；1 项 P2，涵盖原生 default 未知 plaintext 字段漏扫，以及有效答案的未知 instructions 字段继承请求问题豁免。 |
| 当前修正 | 共享 sealer 按 questions/answers/aggregates 及实际题型区分任务数据，扫描所有非任务 plaintext；公开 adapter/page 红→绿，最终整体双轴复审仍待主线程执行。 |

第一条公开红 `run-VmH97F` 宿主/job 1/1，绿 `run-pxLRNZ` 0/0；第二组编译错误 `run-TlHJk1` 1/1 单独保留，不能作为产品行为失败证据。随后真实行为红 `run-GbN1wN` 1/1，三种 adapter 和实际原生页面失败；`run-qn0HW5` 0/0，10 个定点用例通过。新的凭据 fixture 使用互不包含的值，避免子串脱敏掩盖漏扫。原先合法 ID/JSON 描述/legend、数值概率、input/converted/raw、委员会每席和完整总结果矩阵均保留；真实凭据字段、未知 extras 和 known echo 继续覆盖。

临时证据目录与旧 Mac driver/log 消失；原记录保留为历史，本次以持久目录中的当前归档/日志与新建有界回环验收。r33b 重启失败的实因是三个临时 bind 源已不存在；任务自有 r35 保留 SDK/cache，修复 one-shot initializer 的重启入口后使用原 bootstrap 主 runner。未改产品检查脚本、全局重启运行时或操作其他容器。失败传输与实际校验恢复过程见 [当前环境记录](jev-inference-playground.md#本次环境恢复与证据持久性)。

## 第一次 P2 修正门禁及回环记录（历史）

完整命令、归档、原始失败边界与可复现 manifest 编码以 [测试场验证记录](jev-inference-playground.md#最终工程门禁) 为规范记录。原文档补记提交仅改变文档；后续 P2 修正改变了共享 sealer 与相关测试输入，以下采用重新验证的最终输入，不复用旧输入 hash。

| 最终记录 | 实际结果 |
| --- | --- |
| `run-uSFoec` format | 宿主/job 退出 0/0，90 文件、0 改动。 |
| `run-VgWQQ4` analyze | 宿主/job 退出 0/0，零诊断。 |
| `run-TbAa9t` 受影响回归 | 宿主/job 退出 0/0，76 个测试通过。 |
| `run-8X3K05` 全量回归 | 宿主/job 退出 0/0，524 个测试通过。 |
| 最终源码 macOS 有界回环 | 宿主退出 0，本次 owned lease/许可 8 ms 排空，待决同伴及后续请求成功；监听器继续 running，驻留实例未被停止，最终登记/许可归零。 |

98 个最终产品输入的 compact-JSON manifest 为 `97608b10207e458396f78cb9f36f3fcb2ec438c38d9e723cc9bae73dec7ea4a3`；等价逐行 manifest 为 `dd1191db163bb5eee141b6997d4c73e774c94e9bf495278b79d08b8e8ab7a923`。macOS 回环验证的 gateway SHA-256 为 `3244db601a61666914a37170c613890104c6e010d7993994f5b75fef0c1e1c3f`，adapter SHA-256 为 `c9b8eb5e7bfd14d7a363dd0ab455dcd6e12b71df7ef9bc87525a32f8a1839f75`；脚本 SHA-256 为 `530576309522c4fb8d499f8df2d4b89c18017b34f406640fd54b2775bd14e900`。

共享 sealer 的最终源码 SHA-256 为 `4f14eb970efdc16b8cdd5d839dd5dc01d08b83f0106498a1bb80b84da1b876c4`；独立门禁记录为 `r36-p2-gates-independent.json`。

## 后续完整审查与当前上下文来源修正

完整 `6359...a5c55bf` 阶段审查为 Standards 0 / Spec 1 项 P2：未知嵌套 request/response 形状或 model 字符串仍能重新取得任务免疫。初审 0 → 合法数据 P2 → 未知凭据 P2 → 嵌套形状 P2 的各次结论均保留。当前修正改为调用方声明根角色，只经真实业务字段传播，未知 metadata 与编码 JSON 不能改变来源。

原始响应的已验证来源由本次 DecisionBatchResult DTO 或委员会有效 answers 表达，不使用 status/HTTP 200 或任意 JSON 形状决定信任。公开取消用例用实际引擎状态通知作为到达屏障，验证本次仍以 cancelled 错误结束、已验证 raw 任务数据保留、未知凭据隐藏；未验证原文 model/answers 不能获得免疫。生产结果源仍为本次 await 返回值，未借测试观察的共享状态构造结果。

`run-20ZNB0` 1/1，六个 adapter/page 用例全部失败；`run-kma9sH` 0/0，14 个定点通过。取消保护红 `run-XrFwQQ` 1/1 与未匹配 guard 的 `run-vVzTaj` 1/1 均按原始结果保留，不把部分通过计为门禁通过。新 `lib/jev_models.dart` 仅涉及必要 debug 根角色接线，固定阶段完整文件范围现在为 13；最终整体双轴复审由主线程执行。

## 第二次 P2 修正最终证据（历史）

| 检查 | 最终结果 |
| --- | --- |
| `run-ywfyAD` 受影响八文件 | 宿主/job 0/0，80 tests passed。 |
| `run-ZwBx0K` format | 宿主/job 0/0，90 files / 0 changed。 |
| `run-HNlrDA` analyze | 宿主/job 0/0，零诊断。 |
| `run-eHc7GE` 全量回归 | 宿主/job 0/0，528 tests passed。 |
| 当前源码 macOS 回环 | 宿主退出 0，15 ms 排空本次 lease/许可；待决同伴和后续调用成功，监听器继续运行，清理前驻留 kill 为 0，最终登记/许可归零。 |

上述四个容器归档与 `a5c55bf` 该次修正的工作区逐文件核对相同 98 个输入，compact-JSON `bb91f663fe3d7a50d37169651f3282aacbbd65a66ad629cabee7c78648e3707d`，逐行 `1205422f8ebd9f5f13bb12c6a6933e7c5e8b164ce93222e767933949212bcd34`。新 Mac driver SHA-256 `8a0f8cf0f1e4e05b180d72ffee683fa54b2e9402d41bcf6aa37c712c9f79454c`，最终 sealer SHA-256 `b8f23a28a2f113243fb14cf21f9e9eda900186b14967dbd6691cad21e2d97e35`；完整命令、归档/日志 hash 和宿主/job 退出码见 [最终门禁](jev-inference-playground.md#最终工程门禁) 与持久主工作区 `.scratch/jev-protocol-playground/continuation/r36-projection-status.json`、`r36-final-gates.json`、`r36-final-mac-owned-http.json`。

当前证据修正了 v2 P2 的两条具体路径，并保留先前合法数据 P2 的行为要求。最终整体 Standards/Spec 双轴复审仍由主线程执行，本记录不先行宣称零发现。

## 后续合法调用身份 P2 与当前修正

完整 13 文件 `6359...54ec9e6` 审查：Standards 0，Spec 1 项不同 P2。嵌套形状与 per-call DTO 来源修正已通过审查；新发现是原生固定调用名列表与页面发现 ID 的通用扫描错误收集合法 header 风格名称，从而损坏本次证据与可调用的复制名称。

修正只增加明确 caller-owned configuration 固定调用名列表和 discovery `instances[].model/data[].id` 字符串位置；发现其他字段仍通用扫描，未知形状不授予角色。非空 trimmed String 的名称契约、全局唯一、无强制前缀保持。

测试作者错误 `run-cZ5r5m` 1/1 独立保留；真实公开红 `run-en8QHm` 1/1（2 通过/4 失败）揭示原生证据及 HTTP/MCP 页面复制被破坏。绿 `run-krCWCO` 0/0，7 个定点通过：实际三种发现/页面复制、复制名称的后续显式调用、固定原生名/委员会名、合法复杂描述与 raw/converted，同时另一个真实凭据和未知发现 extras 受保护。此前各轮 Spec 发现与失败历史继续保留；当前完整阶段双轴复审由主线程执行。

## 上下文来源修正最终证据（历史）

| 检查 | 实际结果 |
| --- | --- |
| `run-v19ZLE` 最终定点 | 宿主/job 0/0，16 passed。 |
| `run-Okl0YN` 受影响八文件 | 宿主/job 0/0，85 passed。 |
| `run-8JnDxC` format | 宿主/job 0/0，90 files / 0 changed。 |
| `run-ReToZt` analyze | 宿主/job 0/0，零诊断。 |
| `run-4yKj9l` 全量 | 宿主/job 0/0，533 passed。 |
| 当前源码 macOS 回环 | 宿主退出 0，11 ms 排空本次调用；同伴及后续调用成功，监听器运行，清理前驻留 kill 为 0，最终登记/许可为 0。 |

四份最终容器归档与工作区逐文件核对相同 98 个输入：compact-JSON `ac4ef1e497368e5507b805f903dae7ad2ce9e17562a47444190833606741a8e3`，逐行 `aafbb804adfaa9cf3a42c89898f71c43eff340ea5a3b679578c16f7531e08175`。新的 sealer SHA-256 为 `117ee68707308224383ee1528ad28df160197b9736120c60aea16090c47650de`。当前 [工程与 Mac 证据](jev-inference-playground.md#最终工程门禁) 保存到持久 `continuation/r36-bounded-projection-status.json`、`r36-bounded-final-gates.json`、`r36-bounded-final-mac-owned-http.json`，主线程的独立核验为 `r36-bounded-independent.json`。

后续审查揭示的嵌套形状缺陷和本轮暴露的取消证据误脱敏均据真实公开失败修正；此前各轮失败/通过记录保留，没有使用 HTTP 状态、测试数量或已取消结果推断成功。最终完整 13 文件 Standards/Spec 审查与复盘仍由主线程执行，此处不提前宣称零发现。

## 当前合法身份修正的最终证据

| 检查 | 结果 |
| --- | --- |
| `run-krCWCO` 身份/发现定点 | 宿主/job 0/0，7 passed。 |
| `run-vuVmQs` 三处测试 lint 定点 | 宿主/job 0/0，零诊断。 |
| `run-VBF1xV` 最终受影响八文件 | 宿主/job 0/0，92 passed。 |
| `run-lsRKPc` format | 宿主/job 0/0，90 files / 0 changed。 |
| `run-KI6bzw` analyze | 宿主/job 0/0，零诊断。 |
| `run-kA1KET` 全量 | 宿主/job 0/0，540 passed。 |
| 最终源码 Mac 回环 | 宿主退出 0，19 ms 排空，待决同伴/后续请求成功，服务与驻留实例保留，登记/许可为 0。 |

三处新增页面测试 multiline if lint 的 `run-uCuL6h` 1/1，以及未匹配首次缩进编辑的 `run-Y9xdMT` 1/1 保留为真实检查失败。精准修复后重新完成最终门禁，未把零诊断前的结果计为通过，也未复用测试输入变化前的 source manifest。

最终四份容器归档与工作区 98 个输入一致：compact-JSON `599a2a388cd2a425ae1e77dc938882505dffd4669138e2b7af8680af1e0298d2`，逐行 `9ba7d91275016afc6ede6ed2322a1b655c5a2ee72ff52271392a8cb1fe48de96`。当前 [工程与 Mac 证据](jev-inference-playground.md#最终工程门禁) 位于 `continuation/r36-identity-projection-status.json`、`r36-identity-final-gates.json`、`r36-identity-final-mac-owned-http.json`；独立核验 `r36-identity-independent.json` 与完整类别审计 `r36-projection-boundary-audit.md` 均由主线程保存。

类别审计覆盖八个生产 sealer 调用位置和有限成对代表，缺口集合 0。 本轮有界恢复复盘见持久 `continuation/retro36-recovery-supplement.md`：没有未闭环的环境 P0/P1/P2，既有 CI 护栏 P3 继续 deferred。主线程已采用用户授权的新收尾流程，后续以当前有效覆盖执行一次 IMPACT 复审，复盘仅补本轮新的修复/恢复事实，再处理阶段 PR；此处不把旧零发现自动当作当前候选审查结论。

## 保留的验收边界

当前证据使用真实 controller、gateway、协议服务/客户端及生产页面，仅在外部引擎进程/HTTP、必要文件和 Clipboard 平台 I/O 使用替身。应用内 HTTP owned lease 的取消边界与普通外部 HTTP 断连的业务预算边界见规范验证记录，二者没有混记。

#37 的真实模型、实际 Mac 窗口交互、Hermes/Codex 外部客户端及完整 Release 验收均未执行，本记录没有完成这些验收的声明。原文档补记阶段未重跑测试或操作运行资源；后续产品 P2 修正按最终输入重新完成定点、受影响、完整工程检查及有界 Mac 回环。未执行 GitHub 写操作或启动真实模型/应用窗口。
