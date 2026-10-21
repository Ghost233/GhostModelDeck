# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 兼容 Splash 1.4 的模型目录接口。分词器由模型目录提供，启动命令按实际引擎帮助生成；旧版引擎保留原有参数方式。
- 新版 Splash 使用公开的本地模型准备接口，核对选中的目标文件和草稿模型。关闭草稿模型时，不采用缓存中的默认草稿。
- 分别保存模型目录身份和服务模型名称，修复重复准备或重启时的身份检查。
- 启动前重新读取新版 Splash 的参数帮助，避免引擎原地升级后沿用旧参数。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
