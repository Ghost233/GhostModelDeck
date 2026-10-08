# GhostModelDeck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 支持严格的 JEV JSON 输入，以及标准 `model / answers / usage` 的 JEV HTTP 与 MCP 输出。
- 通过虚拟 JEV 模型选择不同委员会配置，也支持按上游模型名直接调用。
- 增加 JEV 输入输出测试场与按需显示的调试输出。
- 主窗口打开时显示 Dock，关窗后隐藏 Dock 并保留菜单栏与后台服务；更新应用图标。
- 完善手动版本、显式版本 tag、DMG 和更新清单的标准发布流程。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
