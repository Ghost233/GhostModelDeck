# 核实现成模型资产与可运行引擎

ID: 01
Title: 核实现成模型资产与可运行引擎
Parent: [JevManager：现成决策模型桌面管理与 MCP 委员会路线图](../map.md)
Type: research
Label: wayfinder:research
Mode: AFK
Status: resolved
Assignee: Ghost233
Executor: model_runtime_research
Blocked by: none

## Question

前述 Kev、StartLux/StarLux、JevK5/JevM5、Laya 等候选中，哪些确实存在并提供可下载的完整推理资产？依据一手仓库、模型文件清单和源代码，哪些资产与固定版本的原生 Mac 引擎匹配，能够提供 typed decision 概率接口，而不是仅能生成聊天文本？

研究要为模型目录的准入规则提供证据：原始来源、许可证、固定 revision、必要文件和大小、adapter/merged/head 区别、引擎及其 API、中文能力证据、上游宣称与独立验证的区别。优先找少量可信的候选，不为了填满三个席位纳入不确定模型。

## Answer

[现成决策模型与 Mac 引擎证据](../../../docs/research/model-runtime-evidence.md) 已建立 Kev、Laya multilingual、StartLux 与 JevK5 的固定资产和引擎事实矩阵。当前核查的 llama.cpp 主线能识别特定 Kev 与 English Laya 决策资产；其他同名或同后缀资产可能属于 ggmlc、encoder-only 或需要 wrapper，不能互换。

报告包含必要文件、revision、大小与 SHA-256、许可证、题型接口、中文证据和限制。原对话的泛化兼容性、排名与内存承诺不能作为验收结果。研究已完成；首版模型、具体引擎和是否需要异源席位仍待用户决定，本机推理均未运行。

## Comments

- 初步证据：Kev 原仓库有 adapter 和 head；mys 的 Kev GGUF 明确称不适用于 llama.cpp；llama.cpp 当前文档存在 `/v1/systemone`，但非决策模型会返回 501。需要逐资产核实，不能推导出所有 GGUF 都兼容。
- 研究报告归属：`docs/research/model-runtime-evidence.md`。不下载权重、不运行模型；文档支持不等于本机通过。
- 2026-10-04：研究完成，兼容性应由具体资产与固定引擎共同判定，不能只用模型名称或文件后缀判定。
