# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 为明确声明支持的 Splash 运行实例开放增量预填充，并提供操作查询、取消及结果重放接口，供 Sentinel 等客户端使用。
- 文本生成和因果决策模型分别核对能力；旧版引擎及不支持的模型保留原有普通调用，未确认完成的请求不会被当作已释放。
- 同一运行实例和缓存盐的普通请求与预填请求协调占用，避免并发修改同一缓存。
- 修复模型迁移后编辑实例时可能误选 `mmproj` 的问题；原模型缺失时需明确选择新的主模型。
- GMD 重启后若无法确认旧引擎的终态，相关操作会保持未知；跨重启的自动占用恢复尚未实现。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
