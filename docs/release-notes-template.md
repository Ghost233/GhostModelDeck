# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 在“计算与 ANE”新增“实验性量化 FFN（不保留全量 FP16 缓存）”开关。默认关闭，按实例保存，重启后生效。
- 开启此选项需要支持新参数的 Splash 引擎。当前限普通生成的 Qwen3.5-4B，支持 Standard DFlash 或不使用草稿模型。
- 启动检查分别显示请求值、实际模式和 FP16 缓存字节。旧状态缺少字段时显示“未知”，原生拒绝时保留启动错误。
- 按当前 Splash 帮助识别参数支持情况。旧版本不接收此参数，界面提示更新引擎或关闭选项；已有实例保持原配置。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
