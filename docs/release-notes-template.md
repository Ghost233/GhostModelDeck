# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- Splash 1.6.1 的激活精度可单独选择自动或 BF16。关联较旧的 Splash 时，GMD 保留该设置，并使用引擎默认激活精度启动。
- 新建 Axion MiniPlus V2.1 35B 或 Qwen3.8 Flash Next 实例时预选 Q4H。留空会沿用引擎默认值，已有实例继续使用保存的配置。
- 模型库识别 Flash Next GGUF，并为带 PLE 表的模型显示缓存预算。Splash 1.6.1 的自动预算使用 SSD 行缓存，按可用内存调整。
- Splash 在就绪前退出时，实例详情会显示退出状态码。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
