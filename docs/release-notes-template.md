# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 修复 Julia-1 等决策 GGUF 省略可选温度字段时，被 GMD 误判为模型不完整、无法启动的问题。缺省温度交给 llama.cpp 使用默认值 1。
- 显式非法温度仍会报错，scorer 尺寸等原有检查继续保留。回归覆盖缺省温度、零温度和错误 scorer。
- 真实 Julia-1、Laya、Kev-0.8B 已通过 llama.cpp 的短公开 JEV 调用；修复后的 GMD 三成员委员会返回全部席位成功。未运行模型评测题集。
- 固定 SDK 的 macOS 宿主完整门禁 1003 项通过，版本修改另做相关检查、arm64 构建和本地打包预检。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
