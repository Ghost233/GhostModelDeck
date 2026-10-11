# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 增加顶层“引擎／测试场”分区。基础测试集中到通用 LLM、JEV 和嵌入入口，通过公开 HTTP 或 MCP 调用已就绪模型。
- 提供 DecideBench、JEVal、一致性 JevBench、JevAdvBench 和 Jevman 五项完整原题基准。题源固定版本，保留原评分；Jevman 默认 100 局，不提供快速模式。
- 支持多对象、委员会、多基准及 HTTP／MCP 整批对照。按对象、基准和通道顺序执行，分别保存成绩、失败、超时与取消状态。
- 历史和报告分批显示摘要，每页最多 20 项。完整数据通过文件路径和 Finder 查看，支持导出、Jevman 观看、逐局回放与独立重放核对。
- 支持文本嵌入 GGUF 模型与公开向量接口，提供嵌入基础测试；保留 StartLux 受管决策读出与实际容量发现。
- 支持从本地 Git 或 GitHub 克隆 llama.cpp 及兼容分支，经 CMake 编译、核验和登记后绑定模型运行。源码可声明原生 JEV 接口支持，实际不支持时保留引擎错误。
- 完善整批取消、目标失效隔离和应用退出收尾。明确退出后保存中断记录；重启只查看历史，不自动续跑。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
