# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 修复启动时引擎检查导致界面长期等待的问题。刷新不再遍历整包计算哈希，也不执行 Python、依赖或 GPU 兼容性探针；实际启动失败保留真实错误。
- 引擎增加“重新下载”，任务进入“下载”列表，显示数量、进度、速度和取消入口。失败或取消时恢复原安装，保留参数及实例引用。
- 不同实例可独立并行加载，启动集合也同时加载各配置；重复启动同一实例复用已有作业，取消一个实例不影响其他实例。
- 修复取消冷启动后被晚到退出回调改为失败的问题。模型库移除“核验”按钮，保存参数的普通启动和草稿短测试均直接调用所选引擎。
- 已通过 EmbeddingGemma 2 的真实公开 `/v1/embeddings` 短请求验证，中英文输入返回 768 维非零向量。实例配置仍由用户选择、保存和启动。
- 使用固定 SDK 在 Mac 宿主完成 989 项完整功能与布局检查；已有真实模型评测证据复用，不要求每个模型运行题集。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
