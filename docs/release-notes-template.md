# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- MCP 服务器新增用法说明，指导局部语义判断、模型调用名复用、循环上限和交回主模型。
- 更新 decide_jev、decide_jev_batch 和 list_jev_models 的工具描述，保留现有接口和参数结构。
- 明确批量判断共享同一 state，有前后依赖的问题分步调用。JavaScript 编排和实际操作取决于宿主支持及权限。
- 明确 confidence 描述分布形状，不代表正确率；任务完成仍需根据实际状态和验收条件验证。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
