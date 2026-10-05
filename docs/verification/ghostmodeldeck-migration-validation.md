# GhostModelDeck 源码迁入验证（进行中）

日期：2026-10-05。工单 #13 尚未验收或关闭；本记录不代表整份首期规格完成。

## 来源与范围

- 来源只读 checkout：`/Users/ghost233/Ghost233Code/JevManager`，HEAD `ff97c9a5b1c7ed164abe6f6906c03cacd65a4d3e`，本轮确认工作区干净。
- 当前分支 main，保留规划基线提交 `8860963eb1df6af985096b329ecee743b0da41ef`；未建立 worktree 或集成分支。
- 90 个新增实现文件已暂存，47 个与来源字节相同、43 个有改名或格式调整。逐文件 SHA-256 见 `ghostmodeldeck-source-migration.json`；该清单是本次快照，后续修复需要更新。
- `.scratch/jevmanager/assets/prototype-v1.dart` 为本次未迁的历史原型资料，不属于应用运行所需文件。已有目标文档未由来源版本覆盖。

## 实际检查结果

| 项目 | 实际结果 | 证据 |
| --- | --- | --- |
| 格式 | 54 文件、0 改动，通过 | `.tooling/container-tests/run-SwRQLw/result.log` |
| 静态分析 | No issues found，通过 | `.tooling/container-tests/run-F2lg3l/result.log` |
| 首次全量测试（缺字体） | 148 通过、2 失败，exit 1 | `.tooling/container-tests/run-q9wQBw/result.log` |
| 补齐字体后全量测试 | 150 项全部通过，exit 0 | `.tooling/container-tests/run-nkIdYL/result.log`；[保存的日志](ghostmodeldeck-migration-layout/test.log) |
| Mac Release | 已执行成功，产物 46.2 MB | `/tmp/gmd-build-macos.log`；`build/macos/Build/Products/Release/GhostModelDeck.app` |
| 产品 bundle ID | 读取实际产物为 `com.ghost233.ghostmodeldeck` | 通过 PlistBuddy 读取产物 Info.plist |
| 原生交互/退出 | 尚无完整可接受证据 | 先前启动进程观察与 pkill 不等价于正常退出及无残留验收 |

容器为独立 `ghostmodeldeck-checks-r24b`（Apple container 1.2.0），由原生 CLI 启动，脚本通过 Socktainer Docker API 执行。Flutter 使用来源容器复制出的独立缓存，固定 revision `5fc346839b5d0eef006ed8404392afb4dfae428d`；来源测试工作区未覆盖。复制的 Flutter 工具 package_config 引用 `/workspace/pub-cache`，因此另复制并挂载独立 pub 缓存。没有把旧测试结果计作新项目结果。

## 当前失败与下一步

两个失败用例是 `run-dialog preserves minimum desktop layout (dark-1.5x)` 与 `run-dialog preserves minimum desktop layout (light-1.5x)`，在 `test/desktop_layout_test.dart:364` 得到：

```text
Expected: null
Actual: FlutterError:<A RenderFlex overflowed by 195 pixels on the right.>
```

已确认缓存引导绕过了 bootstrap 中的系统包安装，容器缺少 Noto CJK 字体（测试默认路径 `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`）。首次测试实际回退到测试默认字体，不能等同于来源环境中的 Noto CJK 布局检查。

从来源容器只读复制 `NotoSansCJK-Regular.ttc` 到独立 SDK 缓存，SHA-256 为 `b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a`。通过已有 `JEV_LAYOUT_FONT` I/O 入口指定这份字体，在同一隔离容器、同一源码上执行 `flutter test test/desktop_layout_test.dart`：34 项全部通过（后台任务 bash-490，exit 0），包含原失败的两项深浅主题 1.5 倍缩放用例。未改布局代码、缩小倍率或跳过断言。

已将相同字体补齐至默认路径，取消冗余慢速 apt 下载，通过原 `scripts/test-container.sh test --dart-define=JEV_LAYOUT_SCREENSHOTS=/workspace/gmd-layout-images` 重跑完整测试（后台任务 bash-525）：150 项全部通过，exit 0，证据 `.tooling/container-tests/run-nkIdYL/result.log`。这次是新身份源码实际重跑，不是复用旧150项结果。

已保存并实际查看 900×560、1.5 倍文字缩放的运行对话框菜单[深色截图](ghostmodeldeck-migration-layout/run-dialog-menu-dark-1.5x.png)与[浅色截图](ghostmodeldeck-migration-layout/run-dialog-menu-light-1.5x.png)：新品牌来源标签可读、两个引擎选项可见，没有原失败的右侧溢出。截图有明确 widget fixture 标记，仅限所选字体与容器渲染环境，不冒充原生 Mac 视觉验收。

可长期复核的 [format 日志](ghostmodeldeck-migration-layout/format.log)、[analyze 日志](ghostmodeldeck-migration-layout/analyze.log)、[test 日志](ghostmodeldeck-migration-layout/test.log)与 [Mac Release 日志](ghostmodeldeck-migration-layout/macos-release.log)已保存到仓库证据目录。

## 审查边界

先前 Codex CLI 审查发现 4 处改名引起的格式变化，已使用固定 Dart 格式化，并由上述容器 format 实际重验通过。不存在已核实的仓库“必须使用 Codex CLI”要求；后续最终审查遵循 implement-spec 与 code-review skill。规格中的真实 HF/JEV 基本回归、全新设置与原生生命周期仍需补充证据。
