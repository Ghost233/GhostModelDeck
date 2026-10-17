# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 增加四个可编辑场景，可绑定保存的实例或委员会；HTTP 与 MCP 共用模型名字，MCP 默认只列出启用且可用的场景。
- 上下文容量来自实例生效配置，委员会取全部成员的最小值。参数编辑可预览关联容量，保存后重启实例才生效。
- 模型、引擎和实例改为支持搜索、筛选、排序和分页的表格，按模型变体、引擎登记和实例配置分别展示。
- 运行监控改为每个实际运行实例两行，展示原生推理槽位、阶段、排队、累计 token 和最近一分钟的平均 prefill／decode 速度，移除曲线和展开详情。
- 增加引擎总开关。关闭时取消受管工作并释放运行资源，窗口和 HTTP／MCP 监听保留；开启时仅自动启动勾选的实例。
- 总开关自动开启设置与实例自启动选择独立保存，不恢复上一次总开关状态。所选实例并发启动，单项失败保留真实结果。
- Splash 自动准备持久运行目录并引用已有模型文件，修复失效 draft 引用；移除未关联启动配置的历史恢复功能。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
