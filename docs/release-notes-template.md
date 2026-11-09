# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 本地网关为 Splash 和 llama.cpp 主线接入 OpenAI Responses 和 Anthropic Messages。两个接口支持普通 JSON 响应和 SSE 流式响应。Messages 还提供 `/v1/messages/count_tokens`。
- Splash 实例的参数编辑页新增“视觉输入”。启用“挂载视觉”并重启实例后，GGUF 模型自动识别配套的 `mmproj`，也可以手动选择投影文件。MLX 模型使用内置视觉塔。已有实例默认关闭视觉。
- Splash 确认视觉组件已加载后，GMD 在 `/v1/models` 返回视觉能力，并接受 Chat Completions 的图片输入。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
