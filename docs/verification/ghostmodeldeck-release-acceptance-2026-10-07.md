# GhostModelDeck 首期原生回归与本机 Release 交付验收（#19 R1，范围收缩）

日期：2026-10-07（Asia/Shanghai）· 分支 main（验收基线 HEAD `295cb40`，S1 SDK 接入终态）· 串行容器 `ghostmodeldeck-checks-r33b`（Up 1 day，Flutter 3.47.6 pinned `5fc346839b5d0eef006ed8404392afb4dfae428d`）

## 范围与固定禁令

本报告是 #19 范围收缩验收（R1），用户批准的硬范围：

- **禁止任何模型权重加载/推理**（llama.cpp 与 oMLX 同此，用户禁令时点 2026-10-06 20:50）；禁止真实 MacLauncher 应用联调；禁止签名/公证/发布/性能承诺。
- 允许并已执行：容器三门禁、`flutter build macos --release`、真实 `.app` 启动冒烟（空模型集）、证据汇总。
- 矩阵判定**不继承任何旧通过声明**：每项均引用可核对的既有证据文档 / commit / run id；旧身份（JevManager，2026-10-05 及以前）证据引用时注明日期与身份。

## 任务 1：最终容器门禁（SERIAL `ghostmodeldeck-checks-r33b`）

三命令按原文执行，基线 403：

| 闸门 | 证据 run id | 实际结果 |
| --- | --- | --- |
| `format --output=none --set-exit-if-changed lib test benchmarks` | run-ZWLZRj | `Formatted 67 files (0 changed)`，exit 0 |
| `analyze` | run-UJoain | `No issues found!`，exit 0 |
| `test` | run-4GRuQb | `All tests passed!`，403 通过（= 基线 403，含 `sdk_service_test.dart` 24 个 S1 新测试），exit 0 |

format 0 changed，未触发写回，后续闸门无需重跑。原始归档在 `.tooling/container-tests/run-{ZWLZRj,UJoain,4GRuQb}`。

## 任务 2：`flutter build macos --release` 产物核对（本机）

- 工具链：Flutter 3.47.6 stable（rev `5fc346839b`，2026-09-30），Dart 3.13.5；Xcode 27.0（27A266a）；flutter 不在 PATH，使用 `/Users/ghost233/flutter/bin/flutter` 绝对入口（与 [acceptance-environment-baseline.md](acceptance-environment-baseline.md) 一致）。
- 构建结果：`✓ Built build/macos/Build/Products/Release/GhostModelDeck.app (47.2MB)`；`du -sh` 实测 45M。
- 产物事实（实读 `Contents/Info.plist` 与二进制）：
  - `CFBundleIdentifier` = `com.ghost233.ghostmodeldeck`（符合预期）；`CFBundleName` = `GhostModelDeck`；`CFBundleShortVersionString` = `0.1.0`（`CFBundleVersion` 1）；`CFBundleExecutable` = `GhostModelDeck`。
  - 主可执行为 Mach-O universal（x86_64 + arm64）。
  - bundle 结构：`Contents/{Frameworks,Info.plist,MacOS,PkgInfo,Resources,_CodeSignature}`；Frameworks 含 `App.framework`、`FlutterMacOS.framework`。
  - 主可执行 SHA-256：`2dd89b118e16566ffb71cf51d0871d5f95492a14cd4c03877a25645a43d48f4e`。

## 任务 3：真实 `.app` 启动冒烟（空模型集，2026-10-07，Asia/Shanghai）

GUI 自动化可用（AppleScript System Events 具备无障碍权限），逐步记录：

| 时刻 | 步骤 | 实际观察 |
| --- | --- | --- |
| 01:23:20 | 启动前基线 | 无 GhostModelDeck / llama-server / oMLX / mlx_lm 进程；127.0.0.1:54841 与 54842 均空闲 |
| 01:23:26 | `open -n build/macos/Build/Products/Release/GhostModelDeck.app` | 进程 PID 62906 出现；监听 127.0.0.1:54841 与 127.0.0.1:54842 |
| 01:23:40 | System Events 查询窗口 | 窗口「GhostModelDeck」存在 |
| 01:23:47 | 点击 AXCloseButton 关窗 | 窗口数归 0；PID 62906 存活；54841/54842 仍 LISTEN（符合设计：关窗业务进程存活） |
| 01:23:58 | `tell application "GhostModelDeck" to quit` 明确退出 | 进程正常退出 |
| 01:24:03 | 退出后核对 | 无任何残留受管进程（无 llama-server / oMLX / mlx_lm）；54841/54842 均已释放 |

全程未加载任何模型权重、未触发任何下载（空模型集）。本冒烟不代替带载窗口验收。

## 任务 4：验收矩阵 A01–A12 逐项证据（docs/spec.md:154-165）

时序前提：oMLX 池原生终裁 r68b attempt#7（26/26 PASS）完成于 2026-10-06 20:47:54，**先于** 20:50 禁令，属合法既有证据；禁令之后未产生任何原生加载/联调证据，凡需这些的复验均判未执行。

| 项 | 判定 | 证据与说明 |
| --- | --- | --- |
| A01 源码迁入/独立身份/全新设置/来源归属 | **通过** | [ghostmodeldeck-migration-validation.md](ghostmodeldeck-migration-validation.md)（2026-10-05）：来源 JevManager HEAD `ff97c9a5` 只读，90 文件提交 `0c5b344` 逐文件 SHA-256 在案；容器 format/analyze/150 测试（run-SwRQLw / run-F2lg3l / run-nkIdYL）；全新临时 HOME 原生起退、54842 真实监听与回收；`serverInfo=ghostmodeldeck`。[acceptance-environment-baseline.md](acceptance-environment-baseline.md) 声明旧身份 150 项测试不计入新身份。 |
| A02 HF 搜索/变体/revision、完整 GGUF/MLX、共享扫描 | **通过**（禁令前真实证据；S1 后未复验） | [ghostmodeldeck-gguf-live-asset-validation-r38.md](ghostmodeldeck-gguf-live-asset-validation-r38.md)：生产入口真实下载 Qwen2.5-0.5B q4_k_m 491,400,032B，SHA-256 与固定 revision `9217f5db` 一致，终态 installed，`scan(verifyFiles:true)` sourceVerified=true。[ghostmodeldeck-mlx-live-asset-validation-r42.md](ghostmodeldeck-mlx-live-asset-validation-r42.md)：真实 MLX 九文件 289,598,797B 落盘。[ghostmodeldeck-mlx-structural-verification-r55.md](ghostmodeldeck-mlx-structural-verification-r55.md)：生产扫描器复扫 complete/chat/qwen2/4bit·G64，独立复哈希通过。[ghostmodeldeck-shared-jev-assets-r43.md](ghostmodeldeck-shared-jev-assets-r43.md)：既有资产前后哈希一致。[ghostmodeldeck-mlx-download-preflight-r40.md](ghostmodeldeck-mlx-download-preflight-r40.md)：压缩来源 fail-closed 真实失败记录。 |
| A03 续传/缺文件/冲突/失败、删除/在用保护 | **通过** | 真实原生（2026-10-06 01:06，禁令前）：[ghostmodeldeck-native-jev-r48.md](ghostmodeldeck-native-jev-r48.md) 与 [ghostmodeldeck-native-text-sse-r48.md](ghostmodeldeck-native-text-sse-r48.md)——生产 `prepareDeletion` 对在用权重真实拒绝，B 停后删除计划才成功，停 A 不伤 B，权重前后哈希一致。容器 loopback fixture（注明非真实网络/权重）：[ghostmodeldeck-model-packages.md](ghostmodeldeck-model-packages.md)（#14 续传 Range/If-Range/206、404/哈希错/截断/冲突、in-use 保护，run-RxNj4u / run-u5Ie1u）；[ghostmodeldeck-residual-natural-exit-r42.md](ghostmodeldeck-residual-natural-exit-r42.md)（失败残留自然退出 + 删除保护协调，run-6Diyrg 38 过）。 |
| A04 两引擎普通 LLM、安装/版本/关联、能力分离 | **通过**（真实加载证据 2026-10-06 01:06–01:13，禁令前；禁令后不可复验加载部分） | [ghostmodeldeck-native-dual-https-install-r47.md](ghostmodeldeck-native-dual-https-install-r47.md)：生产 `LlamaEngine.install()` 真实官方 HTTPS 双安装（标准 b11146 sha `41df13c1…`、JEV b11381 sha `6a072f8b…`），独立 curator 复哈希全过。[ghostmodeldeck-llama-native-version-preflight.md](ghostmodeldeck-llama-native-version-preflight.md)：真实版本探测。[ghostmodeldeck-native-text-sse-r48.md](ghostmodeldeck-native-text-sse-r48.md)：标准实例真实加载固定 Qwen GGUF，非流式 10 tokens、SSE 32 tokens + [DONE]、流中取消；普通模型 typed decision 被拒 notReady（能力分离原生实证）。[ghostmodeldeck-managed-engines.md](ghostmodeldeck-managed-engines.md)：能力分离容器证据（run-Qqq2oG 红 → run-UbJ7f1 绿）。 |
| A05 oMLX 私有分发、运行、pin/fallback/profile、冷请求不加载 | **通过**（终裁完成于禁令前 2 分 06 秒；禁令后不可复验） | [ghostmodeldeck-omlx-pool-native-verdict-2026-10-06.md](ghostmodeldeck-omlx-pool-native-verdict-2026-10-06.md)：终裁总 PASS，HEAD `e6b9d21`，生产全链 install→pin/fallback→物理加载→非流式/SSE/取消→stop→stopManaged 26/26；冷拒栅栏、SIGTERM exit -15 无 SIGKILL、端口释放、9 权重 SHA 不变；attempt1–6 内存压力 prefill 400 与 attempt7 证据 JSON 被并发覆盖事故均如实记录（结论靠驱动日志 27 行 + r66/r67 独立证据交叉印证）。支撑链：[ghostmodeldeck-omlx-native-final-2026-10-06.md](ghostmodeldeck-omlx-native-final-2026-10-06.md)（r63 install PASS，损坏 DMG fail-closed）、[ghostmodeldeck-omlx-native-prerequisite-r53.md](ghostmodeldeck-omlx-native-prerequisite-r53.md)（私有 DMG 布局）、r61/r62 失败与 #20/#21/#22/#23 修复链（`7f6d9af`/`6e897eb`/`6f7f8d4`/`19c22a2`）。 |
| A06 统一 ID、模型列表、Chat/SSE、多模型/错误/重启 | **未执行**（原生公开网关端到端） | 仅有容器证据：[ghostmodeldeck-public-gateway-2026-10-06.md](ghostmodeldeck-public-gateway-2026-10-06.md)（#17 G1：固定端口 54841、公开 ID `gmd-<artifactId>` 跨重启不变、/v1/models、chat/completions、404/503/400 零转发零加载、SSE 分帧/[DONE]；379 测试 run-eFoq0x），该文档自身声明未证真实原生引擎端到端。原生链路需模型加载，禁令后无法补验，禁令前未安排过该链路原生验收。 |
| A07 并发/停止/SSE 断开/取消/内存失败/收尾 | **通过**（禁令前真实原生证据） | [ghostmodeldeck-omlx-pool-native-verdict-2026-10-06.md](ghostmodeldeck-omlx-pool-native-verdict-2026-10-06.md)：真实 SSE 逐帧审计（零 keepalive 帧）、流中取消无伪造终止帧、stop.* SIGTERM exit -15、端口/PID 释放。[ghostmodeldeck-native-text-sse-r48.md](ghostmodeldeck-native-text-sse-r48.md)：双实例 A/B 对等隔离，取消后 activeRequests=0 且对端仍 Ready。[ghostmodeldeck-omlx-pool-r65.md](ghostmodeldeck-omlx-pool-r65.md)（容器 TDD 352/352：stop 隔离、残留重试、SIGTERM→SIGKILL 升级）为确定性行为证据，替身边界已注明。内存失败面：r68b attempt1–6 因宿主内存压力（用户进程 RSS≈26GB）prefill 400，如实记录为环境内存失败而非引擎缺陷。 |
| A08 JEV 两席/概率/综合/分歧/失败/MCP | **通过**（禁令前真实原生证据） | [ghostmodeldeck-native-jev-r48.md](ghostmodeldeck-native-jev-r48.md)（2026-10-06，`fff82a3`）：两个独立原生 JEV 进程（Kev/Laya 真实权重，SHA 在案）各 earn Choice/Score/Noul，混合 typed 请求 + 真实两席 Council，停一席保留另一席，干净收尾。[ghostmodeldeck-native-mcp-recycle-r48.md](ghostmodeldeck-native-mcp-recycle-r48.md) / [ghostmodeldeck-native-mcp-recycle-r52.md](ghostmodeldeck-native-mcp-recycle-r52.md)：真实 MCP listener、两工具发现、stopManaged 回收端口/PID、显式重启新 PID/generation、单席诚实报告。旧身份（2026-10-05，注明日期）：[council-live.md](council-live.md)、[council-failures-live.md](council-failures-live.md)、[codex-mcp-live.md](codex-mcp-live.md)；合成例局限（英文合成请求、12 案例非泛化）各文档已如实声明。 |
| A09 SDK 关联/起停/状态/日志/启动集合/重复/部分失败 | **部分通过** | [ghostmodeldeck-sdk-integration-2026-10-07.md](ghostmodeldeck-sdk-integration-2026-10-07.md)（#18 S1，HEAD `1d7a433`→`295cb40`）：真实 `maclauncher_sdk` 客户端（Git 固定 `bc7262f`）+ 真实 loopback socket + 全真业务模块；启动集合真实加载与缺资产/单条失败真实报告、busy 门闩、按 id 去重、第二连接不抢占、断连不回收业务、pong 超时重连、dispose 竞态；24 个新测试，容器 403/403（run-vXxwYy / run-ei0RRx / run-Qsdl0B）。边界：启动器侧为协议对等体替身、引擎对端为契约等价假 server、未载权重。**未执行**：真实 MacLauncher 应用端到端联调（S1 报告明示 + 20:50 禁令）。 |
| A10 关窗/重开/入口/独立运行/重连/冲突/退出 | **部分通过** | 本轮新增（任务 3）：当前 HEAD `295cb40` 真实 Release `.app` 空模型集原生冒烟——启动监听 54841/54842、窗口出现、关窗业务进程存活（双端口保留）、明确退出后零残留受管进程与端口释放（见上时间线）。可引用旧身份带载证据（2026-10-05，JevManager.app PID 28227）：[manager-lifecycle-live.md](manager-lifecycle-live.md)——两次关窗后 SDK/Codex 仍可调用、重开同 PID、Cmd+Q 后无受管残留、LM Studio 原服务保留。**未执行**：新身份带真实模型的关窗/重开复验（需模型加载，禁令覆盖）；MacLauncher 入口接管联调（禁令）；窗口激活 seam 原生系统级验证（S1 报告明示属 #19 但未排入本轮范围）。 |
| A11 基础键鼠/导航 + 旧锁屏异常复测 | **部分通过** | 本轮任务 3 以 System Events 确认新身份窗口真实出现并以 AXCloseButton 真实关窗（最小原生 GUI 交互）。既有：[native-navigation-diagnostic.md](native-navigation-diagnostic.md)（2026-10-05）——锁屏恢复后 PID 43015 导航/输入失效（CPU 89%），同一构建正常 Quit 重启后同断言 passed；**明确不称已定位或永久修复锁屏/输入问题**，符合「未复现不称修复」口径。[desktop-ui-revision.md](desktop-ui-revision.md)、[ui-flow-redesign.md](ui-flow-redesign.md)、[hf-search.md](hf-search.md)：原生 CUA/AX 真实点击（旧身份）。[desktop-layout.md](desktop-layout.md) + [screenshots/](screenshots/)：34/34 布局交互病例 + 143 项测试，文档自身声明为容器 Widget 证据非原生窗口管理证据。**未执行**：新身份下完整原生键鼠/导航复测与锁屏场景复测（本轮范围只到启动冒烟）。 |
| A12 格式/静态分析/测试/容器零诊断及真实 Mac 构建/启动 | **通过**（本轮新证据） | 容器三门禁零诊断（任务 1）：format run-ZWLZRj 0 changed、analyze run-UJoain `No issues found!`、test run-4GRuQb 403/403。真实 Mac 构建/启动（任务 2/3）：当前 HEAD `295cb40` 下 `flutter build macos --release` 产出 `GhostModelDeck.app`（45M，universal，`com.ghost233.ghostmodeldeck`，主可执行 SHA-256 `2dd89b11…d48f4e`），并真实启动/关窗/退出冒烟通过。此前唯一 Mac 构建证据 [ghostmodeldeck-migration-validation.md](ghostmodeldeck-migration-validation.md)（2026-10-05，46.2MB）早于 S1 SDK 接入，本项由本轮证据闭合。 |

矩阵摘要：**通过 8**（A01、A02、A03、A04、A05、A07、A08、A12），**部分通过 3**（A09、A10、A11），**未执行 1**（A06），失败 0。

## 任务 5：未执行项清单（如实）

1. **HF 下载原生复验**（S1 SDK 接入后的生产入口真实下载复跑）——未执行；A02 依赖禁令前（2026-10-06）r38/r42/r55 真实证据。
2. **LLM 原生推理复验**（文本生成/SSE 真实权重链路）——未执行，用户 2026-10-06 20:50 模型加载禁令。
3. **JEV 两席原生复验**——未执行，同上禁令；A08 依赖禁令前 r48/r52 证据。
4. **OOM / 长加载复验**——未执行（需真实权重加载）；既有 r68b attempt1–6 内存压力失败已在 verdict 文档如实记录，本报告不宣称任何内存行为结论。
5. **MacLauncher 真实应用联调**（真实拉起、入口接管、窗口激活 seam 系统级验证）——未执行，禁令覆盖。
6. **公开网关原生端到端**（A06：54841 接真实引擎的多模型/错误/重启矩阵）——未执行，需模型加载。
7. **带载关窗/重开/退出复验**（A10 带载部分，新身份）——未执行，需模型加载。
8. **完整原生键鼠/导航与锁屏场景复测**（A11 缺口）——未执行；本轮范围只到启动冒烟（窗口出现 + 关窗 + 退出），锁屏异常未复现亦不称修复。

## 交付与边界声明

- 本报告为 #19 R1 唯一新交付文件，docs-only；未修改任何源码 / 测试 / 既有证据文件；无 push、无 GitHub issue 操作。
- 构建产物位于 `build/`（gitignore 排除），不入库。
- 本报告不包含任何签名/公证/发布/性能结论；任务 3 的进程/端口观察不构成性能基准。
- 全部禁令前原生证据（2026-10-05/06）在本轮未被复跑，按「既有证据引用」使用；禁令后新生的原生证据仅任务 2/3 的构建与空模型集冒烟。
