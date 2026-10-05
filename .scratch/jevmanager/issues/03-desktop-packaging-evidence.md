# 核实 Flutter macOS 构建与引擎打包边界

ID: 03
Title: 核实 Flutter macOS 构建与引擎打包边界
Parent: [JevManager：现成决策模型桌面管理与 MCP 委员会路线图](../map.md)
Type: research
Label: wayfinder:research
Mode: AFK
Status: resolved
Assignee: Ghost233
Executor: desktop_packaging_research
Blocked by: none

## Question

用户已确定使用标准 Flutter 桌面应用、macOS 优先。依据官方 Flutter/Dart 和 Apple 文档，明确真正的 Mac 应用交付、原生引擎打包、开发和测试要求。项目依赖与测试必须在容器，用户仅明确允许原生推理引擎；哪些 Mac 编译、签名或桌面运行步骤还需要单独明确范围？

调查 Dart 进程管理、原生 sidecar 路径、macOS Sandbox 与网络和文件访问、子进程继承、窗口关闭与退出事件。检查可读取的当前 Flutter/Xcode 工具存在性，不安装依赖、不启动应用、不更改系统配置。不再比较或替换用户已选定的 Flutter。

## Answer

[Flutter macOS 构建与原生引擎打包边界](../../../docs/research/desktop-packaging-evidence.md) 已记录标准 Flutter 项目、Mac 构建链、进程管理、bundle helper、Sandbox 文件访问和发行的官方依据。Linux 容器可以承担共享逻辑验证，但不能代替 macOS release 与桌面联合验收；宿主的 SDK、依赖解析、Mac 编译与桌面验收范围仍需后续明确。

模型库共享目录中的扫描和下载是不同访问行为。保留 Sandbox 时应按只读导入或读写下载配置所选目录权限，并验证跨启动及 helper 访问；不保留 Sandbox 的直接发行方案也不能照搬这套前提。引擎下载与签名更新取决于发行方案，研究不替用户选择渠道。

本机仅确认 Xcode CLI 的存在与版本、PATH 中未见 Flutter/Dart；没有安装、构建或运行。事实研究已完成，生命周期及实施边界交给 HITL 工单决定。

## Comments

- 用户已选标准 Flutter macOS 应用；这是研究的输入，不是仍待裁决的桌面壳选型。
- 研究报告归属：`docs/research/desktop-packaging-evidence.md`。本机为 arm64，当前 Docker context 是 socktainer；硬件 sysctl 和 Apple container 状态在当前沙盒中读取被拒绝，不能据此说服务停止或内存是 64GB。
- 2026-10-04：研究完成，包含共享目录读写与 Sandbox 条件；用户指定 Flutter 的决定保持不变。
