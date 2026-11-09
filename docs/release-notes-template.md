# Ghost Model Deck {{VERSION}}

发布 tag：`{{TAG}}`。版本号与发布纪律见 [发布版本号规则](https://github.com/Ghost233/GhostModelDeck/blob/{{TAG}}/docs/release-versioning.md)。

## 本次变更

<!-- 每次发布前人工更新本节；workflow 不自动推导变更内容。 -->

- 引擎管理页在“检查更新”按钮上显示结果。已是最新版时显示“无需更新”。发现新版时显示“最新版本”与版本号，点击该按钮才下载安装。“重新下载”移至“更多”菜单。
- Splash 视觉输入会直接选中自动识别到的 `mmproj`。自动和手动选择的路径都完整显示，过长时自动换行。
- 应用重启后保留已确认结束的预填任务状态。旧响应不可恢复时，查询会返回结果不可用。已释放的缓存标识可以再次使用。

## 资产

- `GhostModelDeck-{{VERSION}}.dmg`：macOS 安装镜像（Apple Silicon，未签名、未公证；安装说明见 DMG 内 README.txt）。
- `manifest.json`：版本与 DMG 的 sha256、大小清单（供检查更新功能使用）。
- `SHA256SUMS`：DMG 与 manifest.json 的 sha256 校验和，可用 `shasum -a 256 -c SHA256SUMS` 核对。
