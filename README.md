# Ghost Model Deck
Ghost Model Deck

## 文档先行迁移

Ghost Model Deck 将从 JevManager 扩展为通用模型及多类引擎的统一管理入口。规范和来源资料已先行迁入，首期规格已汇总；应用源码迁入与新能力实现由后续工单交付。

- [迁移说明与后续范围](docs/migration/README.md)
- [工程规范](docs/engineering.md)与 [项目界面记录](docs/design.md)
- [领域词汇](CONTEXT.md)
- [GhostModelDeck：从 JevManager 扩展为多引擎模型管理器的首期决策地图](https://github.com/Ghost233/GhostModelDeck/issues/1)
- [GhostModelDeck 首期规格](docs/spec.md)
- [首期实施交接与工单索引](docs/implementation-plan.md)
- [旧 JEV 规格来源](docs/migration/jevmanager-source/docs/spec.md)
- [GitHub 跟踪器](docs/agents/issue-tracker.md)
- [JevManager 原 README](docs/migration/jevmanager-source/README.md)

首期范围为标准 LLM 模型管理与统一本机 API、原 JEV 委员会及 MCP、HF 下载和 MacLauncher SDK；引擎先覆盖 llama.cpp 与 oMLX。目标是本机 Release 与真实联调，采用全新设置和独立模型库复用；OCR、生图、生视频、其他引擎及公开分发后续处理。当前尚未迁移应用代码或实现新增能力，旧测试不计作新项目验收。

规范规格与七张实现工单已发布到 [GhostModelDeck 首期规格](https://github.com/Ghost233/GhostModelDeck/issues/12)，使用原生子项和阻塞关系；当前起点为 [迁入 JevManager 源码并完成 GhostModelDeck 身份替换](https://github.com/Ghost233/GhostModelDeck/issues/13)。

规范与历史证据保留来源和日期。旧模型、决策委员会的分数与验收结果只证明旧阶段的相应行为，不能作为图像、视频、OCR 或其他引擎的能力证明。

通用 macOS UI 规范继续使用个人 `$macos-ui-standards` skill，仅在用户明确调用时应用。代码、测试、运行脚本、模型文件、引擎安装和应用构建产物尚未迁入；复制的检查命令需要完整源码迁移后才可在本项目执行。
