# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 修复 Splash 临时未就绪后，GMD 永久将实例标记为失败、导致后续 HTTP／MCP 调用不可用的问题。当前请求保留真实未就绪错误，后续请求可在同一实例恢复后重试；应用不自动重试推理或重启模型。
- PID、模型、服务身份及运行代次真正失配时，继续标记失败并拒绝调用。状态同时包含未就绪和身份失配时，优先处理身份失配。
- 回归检查覆盖决策调用前后、HTTP／MCP、JSON／SSE、超时、取消和生命周期。真实 q14 使用现有模型服务定点验证，复用已成功的 Qwen 响应，只重试 JEV 阶段；未重新执行完整 36 条或模型评测集。
- 固定 SDK 的 macOS 宿主完整门禁 1003 项通过，arm64 构建及本地打包预检通过。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
