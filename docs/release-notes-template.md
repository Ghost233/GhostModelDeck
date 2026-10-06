# GhostModelDeck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [docs/release-versioning.md](release-versioning.md)。

## 本次变更

<!-- 发布后人工补充本次变更摘要；workflow 不自动推导变更内容。 -->

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
