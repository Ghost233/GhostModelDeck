# Ghost Model Deck
Ghost Model Deck

只编译和提供 **macOS arm64（Apple Silicon）** 版本，应用及配套引擎、运行时均遵守这一限制。不提供 macOS Intel/x64、Linux 或 Windows 版本，也不提供通用双架构安装包。构建和检查要求见 [工程规范](docs/engineering.md)。

## 功能

Ghost Model Deck 管理本机模型、引擎和启动配置。当前产品职责为：

下列职责已确认；实例管理和委员会实例引用仍在实施。完成状态以[当前验收记录](docs/verification/engine-sources-and-installation-2026-10-12.md)为准。

1. 关联和设置已有引擎。
2. 下载引擎，或从用户指定的 Git 来源构建引擎。
3. 关联本地模型；模型库可添加多个目录。
4. 下载模型；新文件只写入一个选定的保存目录。
5. 管理实例配置：保存模型、引擎和启动参数的组合。同一组合可保存多份参数配置。
6. 提供聊天测试和题集测试。用户选择是否测试，模型库不显示“待验证”标签。
7. 配置委员会，成员引用已有实例。引用的实例、模型或引擎缺失时保留配置并标红。

模型库只显示识别出的模型，忽略其他文件和目录。实例配置与实际运行进程分开管理；保存配置不启动模型。文件损坏、缺失和真实运行错误仍如实提示。

公开 HTTP、MCP 和 SDK 继续使用同一业务入口。评测集属于可选功能，不要求每个模型运行全部题集。原生题目、固定 submodule、完整基准规模、摘要分页和 Finder 文件入口保持。

## 文档

- [当前规格](docs/spec.md)
- [领域词汇](CONTEXT.md)
- [工程规范](docs/engineering.md)
- [当前修改与验收记录](docs/verification/engine-sources-and-installation-2026-10-12.md)
- [旧项目迁移记录](docs/migration/README.md)
