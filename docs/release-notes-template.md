# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 模型路由的调用名可用于 OpenAI Chat Completions、Responses、Anthropic Messages、System One、JEV MCP 和 Embeddings。可用能力、上下文和并发容量取自当前实例。
- Responses 可通过 `previous_response_id` 在切换实例后续接对话。历史保存在 GMD 内存中，遵守 `store: false`。
- 可追踪预填充支持路由名。切换实例后，已登记的操作仍绑定原实例。Chat Completions 支持普通和流式工具调用。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
