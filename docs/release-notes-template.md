# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 兼容 Splash 1.7，支持配置缓存循环状态精度（`--cached-states`）、聊天模板文件（`--chat-template-file`）和强制思考强度（`--reasoning-effort`）。新版启动沿用原有的自定义模板路径。
- 启动参数标题下显示可复制的原始命令行参数名。运行监控显示 Splash 的 SSD 缓存写入量、空闲状态缓存单元、首 token 预填充单元等待 P50 和强制思考强度。
- 当前 Splash 引擎帮助明确支持时，可选 Q4H 循环状态格式（`--state-format q4h`）。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
