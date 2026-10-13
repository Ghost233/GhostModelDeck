# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 下载页统一列出引擎与模型任务，顶部汇总正在进行的任务数量，源码构建单独标注。
- 引擎下载显示进度条、百分比、已下载与总大小，以及实时更新的平均速度。校验、安装和结束状态分别显示，取消或失败后保留结果并可重试。
- 引擎管理页安装中的条目提供“查看下载”入口，其他页面仍可操作；并行下载任务可独立取消。
- 下载列表按需构建，避免一次性创建全部任务卡片。
- 只提供 macOS arm64（Apple Silicon）应用及配套运行时，不提供 Intel/x64、Linux、Windows 或通用双架构包。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
