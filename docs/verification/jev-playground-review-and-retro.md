# #36 审查与复盘记录

日期：2026-10-08（Asia/Shanghai）。固定阶段基线为 `6359dc14be4d426874ed83e30a65492a8140efce`，实施候选为 `91b793b63b79db9dafe33c8b47fa94af1add714f`。本记录补记该候选的初次双轴审查与已完成的会话/环境复盘；文档补记候选 `bc6b5095ee91f0121bcdc005b3207ffc84af99ea` 的后续 Spec 补充审查发现 1 项 P2，见下节；修正后的 `6359...HEAD` 最终整体双轴复审仍由主线程执行，不将初审当作最终复审。

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

## 修正后门禁及回环证据

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

## 保留的验收边界

当前证据使用真实 controller、gateway、协议服务/客户端及生产页面，仅在外部引擎进程/HTTP、必要文件和 Clipboard 平台 I/O 使用替身。应用内 HTTP owned lease 的取消边界与普通外部 HTTP 断连的业务预算边界见规范验证记录，二者没有混记。

#37 的真实模型、实际 Mac 窗口交互、Hermes/Codex 外部客户端及完整 Release 验收均未执行，本记录没有完成这些验收的声明。原文档补记阶段未重跑测试或操作运行资源；后续产品 P2 修正按最终输入重新完成定点、受影响、完整工程检查及有界 Mac 回环。未执行 GitHub 写操作或启动真实模型/应用窗口。
