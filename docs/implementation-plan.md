# GhostModelDeck 首期实施交接

日期：2026-10-05。规范产物为 [GhostModelDeck 首期规格](https://github.com/Ghost233/GhostModelDeck/issues/12)；本地正文见 [spec.md](spec.md)。本文件只索引实现工单，不将工单状态复制为本地完成记录；实际状态、assignee 和 blocked_by 以 GitHub 为准。

| 顺序 | 可交付切片 | 原生前置 | 主要验收 |
| --- | --- | --- | --- |
| 1 | [迁入 JevManager 源码并完成 GhostModelDeck 身份替换](https://github.com/Ghost233/GhostModelDeck/issues/13) | 无 | A01/A12，新名称应用与基线回归 |
| 2 | [支持通用模型资产与完整 MLX 模型包](https://github.com/Ghost233/GhostModelDeck/issues/14) | [迁入 JevManager 源码并完成 GhostModelDeck 身份替换](https://github.com/Ghost233/GhostModelDeck/issues/13) | A02/A03，完整包、独立目录与失败/删除保护 |
| 3 | [实现按能力验证的受管引擎与 llama.cpp 标准 LLM](https://github.com/Ghost233/GhostModelDeck/issues/15) | [支持通用模型资产与完整 MLX 模型包](https://github.com/Ghost233/GhostModelDeck/issues/14) | A04/A07/A08，真实两能力与资源归属 |
| 4 | [安装并运行受管 oMLX 模型池](https://github.com/Ghost233/GhostModelDeck/issues/16) | [实现按能力验证的受管引擎与 llama.cpp 标准 LLM](https://github.com/Ghost233/GhostModelDeck/issues/15) | A04/A05/A07，分发布局、私有运行与显式加载约束 |
| 5 | [提供统一文本 Chat 与 SSE 本机 API](https://github.com/Ghost233/GhostModelDeck/issues/17) | [安装并运行受管 oMLX 模型池](https://github.com/Ghost233/GhostModelDeck/issues/16) | A06/A07，稳定 ID、真实 HTTP/SSE与冷请求拒绝 |
| 6 | [接入 MacLauncher 整体推理服务与窗口协作](https://github.com/Ghost233/GhostModelDeck/issues/18) | [提供统一文本 Chat 与 SSE 本机 API](https://github.com/Ghost233/GhostModelDeck/issues/17) | A09/A10，启动集合、回收/再启动、状态/窗口/连接 |
| 7 | [完成首期原生回归与本机 Release 交付](https://github.com/Ghost233/GhostModelDeck/issues/19) | [接入 MacLauncher 整体推理服务与窗口协作](https://github.com/Ghost233/GhostModelDeck/issues/18) | A01–A12，最终真实闭环与独立证据报告 |

## 实施约束

- 开始前领取当前无阻塞工单，读取 AGENTS.md、[工程规范](engineering.md) 与 [领域词汇](../CONTEXT.md)。使用当前主工作区，不额外创建 worktree/临时集成分支；保留用户已有文件。
- 文件/目录和依赖变更以各工单及规格为边界。source 固定提交、应用身份、模型/引擎/SDK/环境版本都记录；现有旧规格和验证资料作为来源证据保留。
- 自动检查在 Socktainer 的隔离检查副本执行，Mac Release/窗口/真实模型/API/MCP/SDK 在宿主验收。遵循 [环境基线](verification/acceptance-environment-baseline.md)，不将查询成功、元数据或旧150项测试当作新功能通过。
- 拿到失败事实后修复并重跑相关范围；未解决阻断缺陷、实际未执行部分、版本/布局不符必须明确保留。目标包/fixture 不适配时调查并更新可复核组合，不放宽 Ready 或隐式加载规则。
- 当前交接仅完成规划。应用代码尚未迁入，所有实现工单仍待执行；没有模型下载、引擎安装或真实联调。
