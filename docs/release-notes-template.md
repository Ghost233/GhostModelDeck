# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 默认下载来源统一为 llama.cpp 主线和 oMLX 主线，移除 llama.cpp JEV 及重复的固定版本入口，保留本地 Splash 关联。
- 引擎管理新增“下载最新”和“检查更新”，根据上游正式发行选择 macOS arm64 安装包；oMLX 按当前 macOS 版本选择对应资产。
- 下载继续核对大小和 SHA-256，更新失败保留原安装；成功后保存选中的发行版本，重启后继续使用。
- 原固定主线和嵌入版本的实例归入统一 llama.cpp 主线，保留实例名称、公开调用名和参数快照。
- 已通过 GMD 验证 H2O 的 SystemOne 调用可使用 llama.cpp 主线或已增加 H2O 支持的新版 Splash。Splash 需单独更新关联的本地引擎；两种引擎的概率数值尚未完全对齐。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
