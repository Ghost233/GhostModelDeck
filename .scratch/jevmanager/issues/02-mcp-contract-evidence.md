# 核实 MCP 接入与决策接口契约

ID: 02
Title: 核实 MCP 接入与决策接口契约
Parent: [JevManager：现成决策模型桌面管理与 MCP 委员会路线图](../map.md)
Type: research
Label: wayfinder:research
Mode: AFK
Status: resolved
Assignee: Ghost233
Executor: mcp_contract_research
Blocked by: none

## Question

对于本地桌面应用管理的常驻委员会服务，官方 MCP 规范、SDK 和目标客户端支持哪些接入方式？最小 `consult_jev_council(state, options)` 工具怎样携带结构化结果、各席位状态和错误，客户端怎样发现工具并发起真实调用？

调查 stdio 与 Streamable HTTP 的启动者、生命周期、版本与本地访问边界；区分 MCP 传输与模型 `/v1/systemone` 推理 API。先查明目标客户端适用的协议基线，再收集对应的协商、tools/list 与 tools/call 契约；若该基线需要 initialize，包含其握手验收。不要把不同协议版本的流程混用，不修改客户端配置。

## Answer

[MCP 接入与委员会工具契约证据](../../../docs/research/mcp-contract-evidence.md) 已记录官方规范、SDK 发布版、目标客户端入口和待审阅的工具契约。stdio 与本地 HTTP 都是可评估路径；不同 MCP 协议版本的协商与调用流程不能混用，Dart 项目维护的 SDK 也不能自动称为 MCP 官方 SDK。

研究已解除契约事实阻塞。传输、SDK、常驻策略与概率字段仍由后续 HITL 决策确定。本机只检查 CLI 版本与帮助，没有启动 MCP 或完成 Codex 接入；协议兼容性仍需实际调用验证。

## Comments

- 用户已选 Codex 为首个客户端。研究报告归属：`docs/research/mcp-contract-evidence.md`。即使支持文档明确，也须后续实际接入验收。
- 2026-10-04：研究完成；解决的是协议和可用实现的事实，不是替用户选择实现。
