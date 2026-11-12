# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 当关联的 Splash 在帮助中列出 `--activations q4h` 时，激活精度可选择实验性的 4 位注意力 Q。切回旧构建时，GMD 保留原设置，并在启动时跳过该值。
- 实例参数的“空闲释放时长”说明了默认值 `10m` 和权重重载行为。可指定 `90s`、`5m` 等正时长，也可用 `off` 关闭自动释放。释放后的下一条请求会自动加载模型权重，首 token 可能多等一次加载。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
