# 2026-10-05 生命周期验收

对应 #19。业务收尾、真实窗口及 Codex 客户端的关窗/重开/明确退出验收已完成。

## 已通过

- ManagerLifecycle.shutdown 同步封口 Council、Catalog，取消并等待桌面与 MCP 咨询，等待核验/启动中的引擎收口，再停止受管进程；阶段失败仍尝试其余清理并返回明确失败。
- 109 项容器测试通过（run-IvtHpS），analyze 无问题（run-S7zhrU）。覆盖两客户端和桌面轮次、外部端点保全、迟到 spawn 句柄、核验期间退出、排队 MCP 重启拒绝以及失败继续清理。
- 冻结源码 Mac release 构建通过（46.2 MB）。Swift applicationShouldTerminate 返回 terminateLater，经 MethodChannel 等待 Dart 收尾结果后才回复；失败保留应用并显示错误。
- 原生公共入口实际加载 Kev Q8_0、Laya Q8_0（PID 14537/14542），启动真实 MCP，await shutdown 后 TCP 监听不可连接，ps 查询两个受管 PID 均已消失；重复调用复用同一 Future。
- 原生脚本 exit 0，最后两实例 stopped，模型大小与修改时间不变。证据 .tooling/implementation/live-manager-lifecycle.jsonl；源码清单 lifecycle-source-sha256.txt。

## 实际窗口与 Codex

最终 release 应用 PID 28227，通过模型库运行弹窗启动 Kev 与 Laya，选择官方 b11381。两席实际 typed-ready，受管 PID 28983、29303，委员会实际点击选择两席。

- MCP 连接应用自己的 54842 端口，不创建另一套模型。关窗前原 SDK 客户端返回 `8fdc02e48a64f8f29988eb52ae7e1680`；点击原生关闭按钮后，同一客户端返回 `dab63469ea1b8610f2221ec22e3a0b37`，均为两席 ensemble、同一 PID、真实概率与原始响应。
- 新 Codex CLI 0.160.0 在关窗后连接并实际调用，返回 `5170e95356167de48c31aa08c1c80357`，两席 PID 仍为 28983、29303。最终回复使用该 request_id、两模型名称、原始综合评分、票数和分歧给出建议。客户端沿用 `--approve-for-me` 独立自动审查，没有改全局配置或令工具免审批。
- 第二次关窗，同一 SDK 客户端再返回 `17b075b1ed1a7e20af4d9aabb094510b`。重开窗口保留两席与结果；随后原客户端返回 `dcf2bab4a6e70469b55884fb02c42862`，ps 核对应用与两模型 PID 均未改变，没有重复加载。
- 点击原生 `Quit JevManager`（Cmd+Q 对应操作）后，ps 核对 28227、28983、29303 均消失，54842 TCP 连接失败。LM Studio 应用保留，其原 1234 服务在前后均返回 401（鉴权仍启用，未改令牌），没有被 JevManager 退出关闭。
- 四次 SDK 结果的文本 JSON 均与 structuredContent 深度相同，两席均在最早返回前派发；真实 Codex 的模型回复使用其实际 request_id。

原始证据为 `.tooling/implementation/gui-mcp-client.jsonl`、`gui-lifecycle-processes.jsonl`，以及 `/private/tmp/jevmanager-gui-closed-codex-20261005/` 的实际 CLI events 和 final。公开摘要为同目录 `results/gui-lifecycle.json`。

本轮先前旧应用在原生重编译后黑屏并挂起，已只停止其核验过的应用及直属受管子进程，之后重新启动最终构建完成上述验收；该旧进程的强制收尾不计作正常退出成功。首次失败的 shutdown 在同一 Graph 内保留失败结果与封口状态，不虚报退出成功或自动重新开放服务。

`run-desktop.sh` 现先核对同一路径的应用是否运行，再允许构建。实际打开应用后调用该脚本，返回 1 并提示先 Cmd+Q，未启动构建、binary mtime 不变；随后正常退出。此保护避免重复使用脚本时替换正在运行的 framework，不自动结束用户的模型或应用。
