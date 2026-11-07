# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 修复 Splash 的 H2O、D3 等决策后端在运行监控中缺少统计的问题，显示活动任务数、已完成评分任务数和累计 GPU 前向时间。
- 接入新版 Splash 的累计输入 token 和前向墙钟时间，按最近一分钟的累计变化计算 prefill 速度。GPU 时间单独展示。
- 决策模型的输出标注“无文本生成”，decode 显示“不适用”。未上报的原生槽位容量保持未知，不用 HTTP 队列容量代替。
- 兼容旧版 encoder 的已有统计；新增输入与墙钟统计需要单独更新关联的 Splash 引擎，并重启对应实例。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
