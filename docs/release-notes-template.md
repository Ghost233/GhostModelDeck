# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 新增“运行监控”页面，汇总保存实例与当前并发，展示排队、prefill、decode、token 数和平均速度，并提供速度曲线。
- 监控支持 llama.cpp、Splash 和 oMLX 的实际状态。实例与请求分批显示，隐藏页面停止轮询；引擎未提供的字段显示为“—”。
- Splash 可绑定兼容的决策模型，并将声明支持的原生 `/v1/systemone` 接入 GMD 的公开 HTTP、MCP 和委员会。取消、超时及实例失效均保留真实失败。
- 使用指定的实验 Splash 源码完成 Kev、StartLux 与 Qwen3.5-4B 的短接口验证。实验参数保存在独立测试配置中，正式版不自动覆盖已有实例参数。
- 当前实验 Splash 的概率来自候选 token logits；Kev 专用 cls 输出头尚未核验。本次验证接口兼容性，不提供模型准确率结论。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
