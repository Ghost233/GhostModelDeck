# GhostModelDeck 文档迁移第一批

日期：2026-10-05。来源目录：`/Users/ghost233/Ghost233Code/JevManager`；目标：`/Users/ghost233/Ghost233Code/GhostModelDeck`。

## 本批范围

- 完整 `docs/`，包括规范、规格来源、Agent 文档、研究笔记、验证记录、截图及已下载的历史参考文档。
- 根 AGENTS.md、CONTEXT.md、analysis_options.yaml 与 .gitignore；保留目标原 README 并加入迁移入口，源 README 完整保存在来源快照。
- 四组 `.scratch` 中的规划 Markdown 与 JSON 来源记录；本地文档复制不迁移 GitHub issue。
- 文档引用的中文基准输入和结果数据；基准运行代码属于后续批次。

复制文件及 SHA-256 见 [清单](manifest.json)。需要澄清新旧范围的文件添加迁移说明或跟踪器绑定；其源内容另存于 `jevmanager-source/`，其余复制内容保持原样。

## 目标范围与原记录

新目标是通用模型及多类引擎管理，包含图像生成、视频生成、OCR 与专用引擎。旧 JEV 规格、术语和委员会契约属于原阶段资料，新引擎的能力、输入输出、运行边界和验收需要后续规格与实测。

个人 macOS UI skill 已在用户目录，两个仓库可复用同一份；这里复制的 Apple 资料是历史本机快照，原始下载文件继续由 .gitignore 排除。

## 后续迁移

主线程完成后再处理 `lib/`、`test/`、`macos/`、`scripts/`、pubspec 文件、基准运行器及其他实现。模型/引擎/构建产物和机器配置是否迁移按用户后续指示确定。

迁移前重新核对来源代码与开发文档。主线程可能在本批之后更新内容，本清单代表复制时点，不代表开发冻结或最终交付；补迁移只覆盖经比较确认的文件。
