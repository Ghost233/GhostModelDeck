# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 在运行监控页新增混合引擎日志，汇总 Splash、llama.cpp 和 oMLX 的标准输出与错误输出，标注时间、引擎和实例。每个引擎及混合列表保留最近 1,000 条日志，重启应用后清空；写入前脱敏认证凭据。
- 接入 Splash 的实时评分任务列表，显示 H2O 等决策模型的排队数、任务阶段和输入 token。任务结束后恢复空闲，保留累计评分统计。
- H2O 按原生单批评分上限保留固定卡片，显示空闲、排队、处理中和评分中。排队任务超过卡片数量时扩展列表。单批评分上限与生成模型槽位、HTTP 接纳数分别处理。
- GMD 启动 llama.cpp 实例时默认启用 `--metrics`，补齐队列、累计 token 和速度统计。未上报的字段继续显示“—”。
- H2O 实时任务状态需要关联支持 `encoder_requests` 的新版 Splash。更新 GMD 后，需单独更新关联的 Splash 引擎并重启实例；本次安装包不包含外部 Splash 二进制。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
