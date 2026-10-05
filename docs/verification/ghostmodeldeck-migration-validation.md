# GhostModelDeck 源码迁入基线验证

日期：2026-10-05。本记录覆盖工单 #13 的迁入、身份隔离、基础业务与原生起退基线，不代表整份首期规格或真实模型推理验收完成。

## 来源与范围

- 来源只读 checkout：`/Users/ghost233/Ghost233Code/JevManager`，HEAD `ff97c9a5b1c7ed164abe6f6906c03cacd65a4d3e`，本轮确认工作区干净。
- 当前分支 main，保留规划基线提交 `8860963eb1df6af985096b329ecee743b0da41ef`；未建立 worktree 或集成分支。
- 90 个新增实现文件已提交于 `0c5b344`，47 个与来源字节相同、43 个有改名或格式调整。逐文件 SHA-256 见 `ghostmodeldeck-source-migration.json`；该清单是本次快照，后续修复需要更新。
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
| 全新设置与原生起退基线 | 临时 HOME 无旧设置，Release 进程真实监听 MCP；原生 quit exit 0，应用 exit 0，54842 端口回收 | [原生记录](ghostmodeldeck-native-migration-smoke-legacy.json)；只覆盖空模型基线 |
| HF 生产业务入口 | 真实关键词搜索、固定 revision 元数据及 Q4_K_M 变体发现通过 | [HF 记录](ghostmodeldeck-hf-migration-smoke.json)；未下载模型 |
| 原生 JEV/MCP 基础入口 | tools/list 保留 consult_jev_council，新实现身份 ghostmodeldeck；零席位调用明确失败且不合成概率 | [原生记录](ghostmodeldeck-native-migration-smoke-legacy.json)；非真实模型概率验收 |

容器为独立 `ghostmodeldeck-checks-r24b`（Apple container 1.2.0），由原生 CLI 启动，脚本通过 Socktainer Docker API 执行。Flutter 使用来源容器复制出的独立缓存，固定 revision `5fc346839b5d0eef006ed8404392afb4dfae428d`；来源测试工作区未覆盖。复制的 Flutter 工具 package_config 引用 `/workspace/pub-cache`，因此另复制并挂载独立 pub 缓存。没有把旧测试结果计作新项目结果。

## 已处理的检查环境差异

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

先前 Codex CLI 审查发现 4 处改名引起的格式变化，已使用固定 Dart 格式化，并由上述容器 format 实际重验通过。不存在已核实的仓库“必须使用 Codex CLI”要求；后续最终审查遵循 implement-spec 与 code-review skill。本轮补齐了下列迁入基线证据：

- 在全新临时 HOME 与 CFFIXED_USER_HOME 启动真实 Release 二进制。由实际 PID 的 lsof 确認 127.0.0.1:54842 监听，未导入旧设置；通过真实 HTTP 完成工具发现及零席位拒绝，未启动或复用任何推理模型。
- 先前探针错误地向 2026-07-28 无状态协议发送传统 initialize，收到 HTTP 400；失败及强制清理仍保留在[第一次尝试记录](ghostmodeldeck-native-migration-smoke.json)。修正为来源已支持的 2025-11-25 有状态握手后，[重跑记录](ghostmodeldeck-native-migration-smoke-legacy.json)证明新 serverInfo、原工具名、明确零席位失败以及真实原生 quit/进程exit0/端口关闭。此修正是探针协议错误，不是修改应用规避失败。尚未独立复核新的无状态协议客户端路径。
- 通过实际 `HfModelBrowser.search`、`HfModelBrowser.selectRepository` 与 `ModelPackage.discover` 查询 HF，而非绕过业务的 curl；固定 Qwen revision `9217f5db79a29953eb74d5343926648285ec7e67`、Q4_K_M 发现成功。[原始元数据记录](ghostmodeldeck-hf-migration-smoke.json)不是模型下载/推理通过声明。

真实两席 JEV 概率、完整下载与多引擎实际模型、带载退出、Mac GUI 键鼠/窗口和 SDK 联调仍由 #15–#19 按首期规格完成；本基线不代替这些验收。
