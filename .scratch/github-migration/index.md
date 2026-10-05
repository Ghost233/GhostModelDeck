# GitHub 迁移记录

Status: verified
Actor: Ghost233
Verified at: 2026-10-04T04:56:24Z

规范跟踪器为 [Ghost233/JevManager 的 GitHub Issues](https://github.com/Ghost233/JevManager/issues)。当前状态与后续答案统一在 GitHub 维护；此文及 sources/ 是迁移记录。

核验覆盖 20 张工单、9 张关闭的历史记录、10 张开放实现工单、18 个原生父子关联及 21 条依赖。8 份历史答案与 11 份支撑资料已保存为评论，工单及资料快照以 SHA-256 核验；映射与校验值见 [manifest.json](manifest.json)。

初始可领取工单（迁移验收时）：[紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11)。正式实现尚未开始；领取前重新读取 GitHub 的 assignees、状态和 blocked_by。

## 来源与规范工单

| 规范工单 | 迁移验收状态 | 只读来源 |
| --- | --- | --- |
| [JevManager：现成决策模型桌面管理与 MCP 委员会路线图](https://github.com/Ghost233/JevManager/issues/1) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/map.md) |
| [核实现成模型资产与可运行引擎](https://github.com/Ghost233/JevManager/issues/2) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/01-model-runtime-evidence.md) |
| [核实 MCP 接入与决策接口契约](https://github.com/Ghost233/JevManager/issues/3) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/02-mcp-contract-evidence.md) |
| [核实 Flutter macOS 构建与引擎打包边界](https://github.com/Ghost233/JevManager/issues/4) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/03-desktop-packaging-evidence.md) |
| [确定模型下载与安装规则](https://github.com/Ghost233/JevManager/issues/5) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/04-download-install-policy.md) |
| [确定桌面与推理及 MCP 的生命周期](https://github.com/Ghost233/JevManager/issues/6) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/05-desktop-lifecycle.md) |
| [确定委员会语义与真实验收标准](https://github.com/Ghost233/JevManager/issues/7) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/06-council-acceptance.md) |
| [验证桌面管理的完整操作路径](https://github.com/Ghost233/JevManager/issues/8) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/07-desktop-flow-prototype.md) |
| [核实 LM Studio 下载及共享模型目录与引擎集成](https://github.com/Ghost233/JevManager/issues/9) | 已关闭的历史记录 | [来源快照](sources/.scratch/jevmanager/issues/08-lmstudio-integration-evidence.md) |
| [JevManager 首版：并发决策委员会与桌面模型管理](https://github.com/Ghost233/JevManager/issues/10) | 开放 | [来源快照](sources/.scratch/jevmanager/spec.md) |
| [紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/01-hf-search-files.md) |
| [下载所选资产到用户模型库](https://github.com/Ghost233/JevManager/issues/12) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/02-download-install.md) |
| [共享模型库的扫描、识别与手动删除](https://github.com/Ghost233/JevManager/issues/13) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/03-shared-library.md) |
| [LM Studio 接入与实例能力检查](https://github.com/Ghost233/JevManager/issues/14) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/04-lmstudio-provider.md) |
| [兼容补充引擎让决策资产实际就绪](https://github.com/Ghost233/JevManager/issues/15) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/05-compatible-engine.md) |
| [两席真实并发咨询与等权综合](https://github.com/Ghost233/JevManager/issues/16) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/06-concurrent-council.md) |
| [超时、无效响应和部分结果的完整返回](https://github.com/Ghost233/JevManager/issues/17) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/07-partial-failures.md) |
| [Codex 通过本机 HTTP MCP 咨询委员会](https://github.com/Ghost233/JevManager/issues/18) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/08-codex-mcp.md) |
| [关窗继续与明确退出的正确收尾](https://github.com/Ghost233/JevManager/issues/19) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/09-background-lifecycle.md) |
| [中文对照闭环与本机应用交付](https://github.com/Ghost233/JevManager/issues/20) | 开放 | [来源快照](sources/.scratch/jevmanager-build/issues/10-delivery-evidence.md) |

## 支撑资料

- [docs/research/model-runtime-evidence.md](https://github.com/Ghost233/JevManager/issues/2#issuecomment-5976584974) · [来源快照](sources/docs/research/model-runtime-evidence.md)
- [docs/research/mcp-contract-evidence.md](https://github.com/Ghost233/JevManager/issues/3#issuecomment-5976586435) · [来源快照](sources/docs/research/mcp-contract-evidence.md)
- [docs/research/desktop-packaging-evidence.md](https://github.com/Ghost233/JevManager/issues/4#issuecomment-5976588958) · [来源快照](sources/docs/research/desktop-packaging-evidence.md)
- [docs/research/lmstudio-integration-evidence.md](https://github.com/Ghost233/JevManager/issues/9#issuecomment-5976589335) · [来源快照](sources/docs/research/lmstudio-integration-evidence.md)
- [CONTEXT.md](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976589684) · [来源快照](sources/CONTEXT.md)
- [benchmarks/fixtures/zh-decision-smoke.json](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976590037) · [来源快照](sources/benchmarks/fixtures/zh-decision-smoke.json)
- [docs/prototype-toolchain.json](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976591402) · [来源快照](sources/docs/prototype-toolchain.json)
- [AGENTS.md](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976592790) · [来源快照](sources/AGENTS.md)
- [docs/agents/issue-tracker.md](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976612960) · [来源快照](sources/docs/agents/issue-tracker.md)
- [docs/agents/triage-labels.md](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976613262) · [来源快照](sources/docs/agents/triage-labels.md)
- [docs/agents/domain.md](https://github.com/Ghost233/JevManager/issues/10#issuecomment-5976615845) · [来源快照](sources/docs/agents/domain.md)
