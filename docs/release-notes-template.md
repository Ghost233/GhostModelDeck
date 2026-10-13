# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 引擎管理展示仓库或本地源码地址，提供 llama.cpp JEV b11381、llama.cpp 主线、Splash 主线与 oMLX 主线四个默认来源。关联、下载和 Git 构建入口统一管理，安装进度放在下载页。
- 模型库支持多个读取目录和一个下载保存目录，按真实文件边界去重；未识别文件不展示，关联解除保留权重和已有运行。
- 新增保存实例：独立保存模型、引擎、参数及公开调用名。同一组合可以保存多份配置；参数列表可恢复覆盖值，草稿测试不改变保存配置。
- 接通 llama.cpp、Splash 和 oMLX 的保存实例运行与公开路由。普通启动检查实际加载身份，推理由用户主动发起；资源缺失时保留配置、标红原因，已有运行与实际命令继续可查看和停止。
- 委员会选择已保存实例，缺失引用保留并标红；测试场通过普通 HTTP/MCP 使用实例或委员会。已有五项完整原题基准、Jevman 100 局、整批对照、取消、历史、分批摘要与 Finder 文件入口保持。
- JEV 默认整轮请求预算改为 60 秒，实例可保存显式预算；已有明确配置保留。Jevman 的原固定决策和 warmup 时限保持。
- 修复下拉选项重复激活误弹出桌面根页面并释放服务的问题；保留普通弹窗关闭和应用正常退出行为。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
