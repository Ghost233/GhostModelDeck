# JevManager 实现工单

Stage: to-tickets
Status: migrated-to-github-read-only-index
Source: [JevManager 首版：并发决策委员会与桌面模型管理](https://github.com/Ghost233/JevManager/issues/10)
Approval: 2026-10-04 用户明确批准拆分方案及依赖关系

十张工单已发布到 GitHub，父子关联与依赖均经核验。此索引和 issues/ 仅保留迁移来源；执行状态统一在 GitHub 维护，正式实现尚未开始。完整映射见 [迁移记录](../github-migration/index.md)。

| 规范工单 | 开始前必须完成 | 只读来源 |
| --- | --- | --- |
| [紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11) | 无 | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/01-hf-search-files.md) |
| [下载所选资产到用户模型库](https://github.com/Ghost233/JevManager/issues/12) | [紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/02-download-install.md) |
| [共享模型库的扫描、识别与手动删除](https://github.com/Ghost233/JevManager/issues/13) | [紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/03-shared-library.md) |
| [LM Studio 接入与实例能力检查](https://github.com/Ghost233/JevManager/issues/14) | [共享模型库的扫描、识别与手动删除](https://github.com/Ghost233/JevManager/issues/13) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/04-lmstudio-provider.md) |
| [兼容补充引擎让决策资产实际就绪](https://github.com/Ghost233/JevManager/issues/15) | [LM Studio 接入与实例能力检查](https://github.com/Ghost233/JevManager/issues/14) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/05-compatible-engine.md) |
| [两席真实并发咨询与等权综合](https://github.com/Ghost233/JevManager/issues/16) | [兼容补充引擎让决策资产实际就绪](https://github.com/Ghost233/JevManager/issues/15) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/06-concurrent-council.md) |
| [超时、无效响应和部分结果的完整返回](https://github.com/Ghost233/JevManager/issues/17) | [两席真实并发咨询与等权综合](https://github.com/Ghost233/JevManager/issues/16) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/07-partial-failures.md) |
| [Codex 通过本机 HTTP MCP 咨询委员会](https://github.com/Ghost233/JevManager/issues/18) | [超时、无效响应和部分结果的完整返回](https://github.com/Ghost233/JevManager/issues/17) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/08-codex-mcp.md) |
| [关窗继续与明确退出的正确收尾](https://github.com/Ghost233/JevManager/issues/19) | [Codex 通过本机 HTTP MCP 咨询委员会](https://github.com/Ghost233/JevManager/issues/18) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/09-background-lifecycle.md) |
| [中文对照闭环与本机应用交付](https://github.com/Ghost233/JevManager/issues/20) | [下载所选资产到用户模型库](https://github.com/Ghost233/JevManager/issues/12)、[关窗继续与明确退出的正确收尾](https://github.com/Ghost233/JevManager/issues/19) | [来源快照](../github-migration/sources/.scratch/jevmanager-build/issues/10-delivery-evidence.md) |

初始可领取工单（迁移验收时）是 [紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11)。它完成后，下载与共享库管理可分别推进；领取前以 GitHub 的实时状态和分配为准。
