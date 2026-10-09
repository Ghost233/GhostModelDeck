# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 为 llama.cpp / JEV 增加引擎默认启动参数和每模型独立配置，支持切换继承并保留调优内容。
- 支持自定义参数文本优先、常用表单覆盖提示、当前引擎帮助信息识别，以及完整命令预览和实际启动命令复制。
- 保存参数仅影响后续启动；引擎升级保留配置，解除关联后可在重新关联时手动恢复。
- 桌面与 SDK 共用启动配置；修复服务重启后网关无法完整关闭的问题，以及参数编辑焦点和引擎版本显示问题。
- oMLX 支持参数保存与识别，生产模型启动仍待接通；新增 Splash 配置和文本 Runtime 核心，应用内绑定、启动及真实模型验收仍在后续开发中。
- 统一应用显示名称为 Ghost Model Deck，并支持新版 SDK 的菜单栏许可桥接。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
