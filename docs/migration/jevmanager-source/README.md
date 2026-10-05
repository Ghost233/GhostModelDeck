# JevManager

使用现成决策模型的标准 Flutter 桌面管理应用。macOS 优先，提供 Hugging Face 搜索与下载、自定义和共享模型存放路径、本地模型识别、推理引擎管理、多模型委员会，以及首先接入 Codex 的 MCP 服务。

核心流程：大模型提交同一份上下文和候选项 → 多个 Jev 类决策模型并发判断 → JevManager 汇总各模型结果并计算综合意见与分歧 → 通过 MCP 返回给大模型，由大模型作最终判断。模型下载和引擎管理用于支撑这条流程。

Wayfinder 决策、规格和实现工单统一在 GitHub Issues 维护，操作账户固定为 Ghost233。本地规划资料保留为来源快照。

当前已实现模型包搜索与下载、共享模型库、引擎管理、并发委员会和本机 HTTP MCP。150 项容器测试、格式检查和完整静态分析通过，覆盖最小窗口、浅深色与放大文字。真实 Codex 已实际发现、调用并消费桌面应用的两席结果，关窗后仍可调用，重开保留实例，明确退出完成受管进程及 MCP 收尾。三份独立审查发现的六项 P2 及后续清理失败传播问题已回归修复，三个原审查者分别复查通过。

## 本机运行

工具链为 `~/flutter`（3.47.6）、`~/dart`（3.13.5）；Mac 编译使用 Xcode。

```sh
./scripts/run-desktop.sh
```

应用位于 `build/macos/Build/Products/Release/JevManager.app`。这是不启用 App Sandbox 的本机 release 构建，未作分发签名、公证或公开分发。下载来源与模型目录在设置里；可使用 LM Studio 的既有模型目录。引擎页安装或关联标准 llama-server，模型库运行时选择具体引擎，委员会页面选择已就绪席位。

应用启动时开启 `http://127.0.0.1:54842/mcp`，MCP 页提供实际状态及 Codex 接入配置。唯一咨询工具 `consult_jev_council` 接收 `state` 和 `options: [{id, text}]`，不执行候选行动。客户端的工具授权仍受其自身配置约束；本机非交互验收使用 `codex exec --approve-for-me`，由独立审查决定调用，不将工具设为免审批，也不改全局配置。

## 验证

通用测试在既有 Socktainer 容器运行：

```sh
./scripts/test-container.sh test
./scripts/test-container.sh analyze
```

已安装并核验 Kev Q8_0、Laya Q8_0 和官方 b11381 引擎后，可以复现原生中文对照：

```sh
~/dart/bin/dart --packages=.dart_tool/package_config.json benchmarks/run_native.dart
```

脚本读取应用保存的模型目录，只咨询并清理自己创建的实例。12 个合成案例中 Kev 为 12/12、Laya 为 8/12、综合为 11/12；本轮综合弱于 Kev 单独使用，不能推导泛化或校准收益。

- [JevManager：现成决策模型桌面管理与 MCP 委员会路线图](https://github.com/Ghost233/JevManager/issues/1)
- [JevManager 首版规格](https://github.com/Ghost233/JevManager/issues/10)
- [实现工单拆分方案](.scratch/jevmanager/ticket-plan.md)
- [已发布的实现工单](.scratch/jevmanager-build/index.md)
- [GitHub 迁移记录与来源映射](.scratch/github-migration/index.md)
- [JevManager 术语表](CONTEXT.md)
- [Issue 跟踪器：GitHub](docs/agents/issue-tracker.md)
- [桌面职责与视觉验收](docs/verification/desktop-ui-revision.md)
- [最小窗口、主题与文字缩放](docs/verification/desktop-layout.md)
- [代理完整模型包验收](docs/verification/proxy-package-live.md)
- [完整交付核对](docs/verification/delivery-audit.md)
- [真实并发委员会验收](docs/verification/council-live.md)
- [截止、取消与部分结果验收](docs/verification/council-failures-live.md)
- [MCP 与 Codex 验收状态](docs/verification/codex-mcp-live.md)
- [中文对照与资源口径](docs/verification/chinese-benchmark.md)
- [原生中文对照结果](benchmarks/results/2026-10-05/chinese.jsonl)

已完成的研究：

- [现成决策模型与 Mac 引擎证据](docs/research/model-runtime-evidence.md)
- [LM Studio 下载、共享目录与引擎集成证据](docs/research/lmstudio-integration-evidence.md)
- [Flutter macOS 构建与原生引擎打包边界](docs/research/desktop-packaging-evidence.md)
- [MCP 接入与委员会工具契约证据](docs/research/mcp-contract-evidence.md)

模型卡宣称与本机实测分别记录；不会仅凭 GGUF 后缀判定兼容，也不会把演示界面当成真实推理验收。
