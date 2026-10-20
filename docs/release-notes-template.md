# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 实例配置采用 A 方案分组侧栏，为 llama.cpp 和自定义 Splash 提供开关、枚举、数值、滑块、单位、路径和列表等对应控件，按所选引擎安装显示适用参数。
- 每个实例独立保存生成默认值，区分继承、关闭和指定数值；下一次 JSON／SSE 请求采用新设置，单次显式参数仍优先，已准入请求保持原快照。
- 加载资源、上下文、计算、ANE、缓存、磁盘和服务预算使用类型化控件，并说明依赖关系和生效阶段；加载配置在下次成功启动后生效。
- 支持逐项编辑停止字符串、JSON／Schema 输出、思考与模板对象、Splash 调度和缓存隔离，保留有效附加字段及现有文本优先规则。
- 显式选择原始 Splash 草稿与 compact ranking，校验来源并展示实际容量和正常回退；准备与运行期间保护目标和草稿的全部分片。
- llama.cpp 提供普通 draft、EAGLE3、MTP、DFlash、DSpark 的模式、路径和调优选项，按官方参数启动，实际兼容性与运行结果由原生引擎判断。
- 保存失效来源或另一引擎的待应用配置后，当前运行实例仍保留自己的来源、容量、凭据和停止入口；历史 CLI 草稿线索须重新选择来源或明确关闭。
- 修复启用原生访问密钥后的内部状态、发现、监控与推理认证；多个实例各自使用有效凭据，诊断展示继续脱敏。
- 修复 Splash uint64 种子的短测试编码和路径中间编辑光标；测试运行明确展示本次 32-token 覆盖，临时实例完成后自动停止。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
