# 最小桌面内容布局验收

日期：2026-10-05。对象：`test/desktop_layout_test.dart` 直接构建的生产页面与 `ModelRunDialog`，版本 `0.1.0+1`。这是 Linux arm64 容器内的 Flutter Widget 渲染证据；Mac 原生交互与真实模型验收另见已有记录。

## 约束与证据边界

- 声明的最小内容窗口为 900 × 560 logical px，设备像素比为 1。
- 按 `lib/main.dart` 预留 188 px 侧栏、1 px 分隔线，页面 padding 为左/上/右/下 32/30/32/28。生产页面实际约束为 **647 × 502 px**。
- 覆盖浅色、深色各 1.0 与 1.5 倍文字。复用生产 `buildJevTheme`；为可读截图加载容器已有 Noto Sans CJK 与 Flutter Material Icons，QA 主题只补充 text/input/button/dialog 的字体 family，未改主题颜色、字号、间距及布局。字体及栅格化不是 macOS 的系统字体证据。
- 页面截图左侧只标注 harness 和 fixture 边界，不复刻生产导航。右侧为生产 Widget；下拉菜单和弹窗来自其真实路由。另有两个生产 shell 病例通过公开 `JevManagerApp.build` 返回的 `MaterialApp.home` 保留原 shell，仅在外层替换 QA 字体主题；其图像附加 32 px 说明页脚，页面本身仍为 900 × 560。
- 使用公开的 `HfModelBrowser`、下载任务、模型库、引擎登记、委员会与 MCP 入口。HF metadata / 503 下载响应及引擎进程、架构探测、推理 HTTP 接口是外部 I/O fixture；文件扫描、安装清单、引擎登记、下载状态、综合评分和 MCP 监听均执行现有业务代码。
- 两个小型 GGUF fixture 和受管/关联引擎登记用于稳定制造界面状态，不能证明真实权重推理或真实引擎二进制。MCP 状态来自测试进程的实际 loopback 监听，不能证明 Codex 的接入。

### Linux QA 字体与冷容器

字体从容器公开工具链加载，未使用 `.tooling` 或宿主私有字体：

- CJK：Debian `fonts-noto-cjk` 的 `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`，以 QA family `Layout Noto CJK` 注册。
- 图标：固定 Flutter SDK 的 `/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf`，以原 `MaterialIcons` family 注册。
- 当前 `scripts/container/bootstrap-flutter.sh` 的 apt 安装列表已含 `fonts-noto-cjk`，固定 Flutter 3.47.6 / Dart 3.13.5（Flutter revision `5fc346839b5d0eef006ed8404392afb4dfae428d`）并执行 `precache --linux`。新空容器按该脚本准备字体；本轮使用既有容器，没有额外 apt 安装，也未另建冷容器复核下载过程。
- 设置 `JEV_LAYOUT_FONT` 可指定另一个 QA 字体文件；本次没有使用该覆盖。导出截图时若 CJK 文件缺失会直接失败。生产 Mac 字体设置不受这些测试注册影响。

## 自动化行为检查

34 个病例 = 7 个页面 + 运行弹窗 × 2 个主题 × 2 个文字缩放，另加生产 shell 在浅/深色 1.5 倍文字下的两个病例。

| 生产对象 | 状态与布局检查 |
| --- | --- |
| 发现模型 | HF 长仓库名、两种量化；搜索及下载操作可见 |
| 模型库 | 实际文件发现、运行实例；核验、删除模型、运行操作可见 |
| 下载任务 | 外部 503 导致的真实失败状态、长目标路径；重试操作可见 |
| 引擎管理 | 受管/关联引擎的真实登记；关联、解除关联操作可见 |
| 设置 | 长路径、来源下拉；两项展开可见，实际选择保存来源，Escape 关闭菜单 |
| 委员会 | 两席 fixture 咨询产生的真实综合结果；咨询操作与综合评分可滚入视口 |
| MCP | 已启动真实 loopback 监听；停止、复制配置操作可见 |
| 运行模型 | 两个引擎登记；运行/取消可见，两项菜单可见且可选择，取消按钮和 Escape 关闭弹窗；启动请求在外部进程边界受控等待时 Escape 保留弹窗、取消不可用，释放后业务实例就绪并关闭 |
| 生产 shell | 真实容器用户设置与文件系统；900 × 560 / 1.5x 的品牌、导航、设置可见；由实际 `McpPage.server.stop()` 收尾自动启动的监听，再 dispose |

所有病例检查 Flutter 异常（包含 RenderFlex 溢出）以及关键操作的命中测试和窗口内边界。滚动页面允许滚动后操作；没有断言主题实现常量。

## 视觉检查与结果

**行为：34 / 34 布局与交互病例通过；完整 143 项测试通过。视觉：已人工查看代表性的浅/深色 1.5x 页面、弹窗与菜单，另查看模型库、下载失败、委员会结果和 MCP 图像。** 文字、图标、状态及操作可读，未见溢出条纹、互相覆盖或被窗口裁掉的主要操作；委员会长内容按现有滚动区域查看，不要求所有内容同时显示。

本轮实际复现并交由主线程修复了三个生产问题，未修改其他生产布局：

1. 可取消的运行弹窗设置 `barrierDismissible: false`，菜单关闭后 Escape 无法关闭弹窗。修复允许 route 取消，仍由现有 `PopScope(canPop: !_working)` 拒绝启动中退出。四个主题/缩放病例均验证取消按钮、Escape 和启动保护。
2. 真实字体下，900 × 560 / 1.5x 的侧栏品牌 `Row` 在 152 px 内溢出 15 px。品牌文字改为受约束的单行省略，并保留完整 Tooltip。
3. 同一约束下，侧栏 `Column` 底部溢出 8 px。模型/服务导航区域改为可滚动，品牌与设置保持固定；浅/深色病例均检查 Tab 到 MCP、Enter 打开实际页面。

原始侧栏红例保存在本地 [浅色修复前截图](../../.tooling/desktop-layout/shell-before-light-1.5x.png) 和 [深色修复前截图](../../.tooling/desktop-layout/shell-before-dark-1.5x.png)。这些是 Noto QA 字体红例，未把早期 Ahem 缺字图当成产品视觉问题。

### 可查看的代表图

下列均为最小窗口、1.5x 文字；文件名标明主题，图像内部标明 Widget/container 证据边界。14 张代表图和 [SHA-256 清单](screenshots/desktop-layout-sha256.txt) 保存到仓库；全部 54 张图像保存在本地 [.tooling 截图目录](../../.tooling/desktop-layout/screenshots/)。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 生产 shell | [图像](screenshots/desktop-shell-light-1.5x.png) | [图像](screenshots/desktop-shell-dark-1.5x.png) |
| 长名称 HF 模型 | [图像](screenshots/desktop-search-light-1.5x.png) | [图像](screenshots/desktop-search-dark-1.5x.png) |
| 设置与长路径 | [图像](screenshots/desktop-settings-light-1.5x.png) | [图像](screenshots/desktop-settings-dark-1.5x.png) |
| 设置来源两项展开 | [图像](screenshots/desktop-settings-menu-light-1.5x.png) | [图像](screenshots/desktop-settings-menu-dark-1.5x.png) |
| 已安装/已关联引擎 | [图像](screenshots/desktop-engines-light-1.5x.png) | [图像](screenshots/desktop-engines-dark-1.5x.png) |
| 运行模型弹窗 | [图像](screenshots/desktop-run-dialog-light-1.5x.png) | [图像](screenshots/desktop-run-dialog-dark-1.5x.png) |
| 两个引擎菜单展开 | [图像](screenshots/desktop-run-dialog-menu-light-1.5x.png) | [图像](screenshots/desktop-run-dialog-menu-dark-1.5x.png) |

### 最终检查与冻结源码

| 检查 | 实际结果 | 原始证据 |
| --- | --- | --- |
| 布局与截图矩阵 | 34 通过；54 PNG | [run-h1LFeX](../../.tooling/container-tests/run-h1LFeX/result.log) |
| 全范围 format | 53 文件，0 改动 | [run-Jt01Q4](../../.tooling/container-tests/run-Jt01Q4/result.log) |
| analyze | 零诊断 | [run-HEPjLb](../../.tooling/container-tests/run-HEPjLb/result.log) |
| 完整 test | 143 通过 | [run-Nhi8KD](../../.tooling/container-tests/run-Nhi8KD/result.log) |
| 导出 | 每块、完整归档及 54 PNG SHA-256 全部匹配 | [导出校验](../../.tooling/desktop-layout/export-final.log) |

最终 53 个 Dart 文件的 [宿主源码 SHA 清单](../../.tooling/desktop-layout/frozen-dart-sha256.txt) 与 [最后一次完整测试的容器副本清单](../../.tooling/desktop-layout/container-dart-sha256.txt) 逐行一致；[配置 SHA](../../.tooling/desktop-layout/frozen-config-sha256.txt) 另记 pubspec 与分析配置。生产文件在截图与完整检查之间没有变化：

```text
lib/main.dart             e8bf5f100a591961bfd32ec00669501699043688baf32eebdcb0886234c808dd
lib/model_run_dialog.dart 39fad251c2855702c19467d0641784367f85c0fd64dea342510b6c537320bfb7
test/desktop_layout_test.dart b3560eb9b650d88c7671af57f71d366a4016a21a218fbcc5191af6db7c2fac1f
screenshots.tar.gz       969f800ad58cba2b325c52142f566ec6146c4d7636a208272a1633ed12ac5fc6
```

本记录没有执行 Mac 原生最小窗口、深色或系统字体缩放验收，也未替代此前 Mac 浅色 1100 × 700 实窗、真实模型、Codex 和生命周期的独立验收。Widget 输入事件不证明 macOS 原生窗口管理；系统字体、辅助功能及超出本轮 fixture 的长内容仍需各自实测。

## 重现

```sh
./scripts/test-container.sh test test/desktop_layout_test.dart \
  --dart-define=JEV_LAYOUT_SCREENSHOTS=/workspace/layout-screenshots \
  --reporter expanded
./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks
./scripts/test-container.sh analyze
./scripts/test-container.sh test
```

截图按 Socktainer 手册分块 base64 导出（本轮用 512 KiB 块），每块独立解码并核对 SHA，再按二进制顺序组合、核对完整归档 SHA 和 54 PNG 的 SHA。早期截断块未通过对账，已重传后验证；不使用损坏归档。
