# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 实例的“编辑参数”支持修改模型名字，并与其他参数一起保存。重名时提示冲突。保存新名字后，客户端需同步修改 `model` 配置。
- Splash 实例支持挂载视觉组件，包括支持视觉输入的决策模型。GGUF 可自动识别或手动选择 `mmproj`，MLX 使用模型内置视觉塔。
- 创建 Splash 新实例时默认检查视觉组件。识别成功后开启视觉，识别不到或检测失败时使用纯文本。已有实例保留原配置，可手动调整。
- 视觉投影文件在自动识别后显示完整路径。设置中的文件、目录和下拉选项过长时自动换行，已选内容和展开菜单均完整显示。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
