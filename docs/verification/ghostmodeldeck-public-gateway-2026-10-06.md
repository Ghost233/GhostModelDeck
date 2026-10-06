# GhostModelDeck 公开网关（#17 G1）验收报告

日期：2026-10-06
分支：main（基线 HEAD 149987d）
范围：统一文本 Chat 与 SSE 本机 API 公开切片（SOURCE+SERIAL）

## 交付物

- `lib/public_gateway.dart`（新，780 行）：`PublicModelRoutes` 公开路由身份层 + `PublicGatewayServer` HTTP/SSE 网关。未拆分 `public_models.dart`——两类合计单一职责（公开身份与公开传输），拆分只会增加跨文件跳转。
- `lib/chat_protocol.dart`：`TextMessage`（system/user/assistant，内容非空）与 `TextRequest.messages`（temperature 0–2、top_p (0,1] 可选）；旧 `TextRequest(...)` 单 prompt 构造保留为 factory（temperature: 0），旧错误文案逐字不变。
- `lib/engine_runtime.dart`：`EngineRuntime` 接口上调 `streamText(instanceId, request, {timeout, cancellation})`。
- `lib/llama_engine.dart` / `lib/omlx_engine.dart`：`streamText` 真实 SSE 实现（@override、timeout 参数、取消时 `HttpClient.close(force: true)`，不伪造终止帧）。
- `lib/manager_lifecycle.dart`：`gateway` 关机步骤（beginShutdown 封闭准入 → stop 排干在途），顺序位于 MCP 之后、engines 之前。
- `lib/main.dart`：最小接线（构造 routes/gateway、启动、dispose、LibraryPage 传参）。
- `lib/library_page.dart`：公开 API 行（启用开关、复制 `http://127.0.0.1:54841/v1` 与公开 model ID、状态呈现），仅在单个 chat artifact 时出现。
- `test/public_gateway_test.dart`（新，27 测试）。
- 本文档。

## 公开契约

- 固定端口 54841（生产默认常量 `PublicGatewayServer.defaultPort`；测试注入任意端口）；`bind` 冲突显式抛 `StateError`，禁止随机回退；54842 属 MCP 未挪用。
- 公开 model ID：`gmd-<artifactId>`，派生自模型库稳定 artifact 身份，跨重启不变；不泄露原生 alias 与内部端口；冲突显式拒绝（409 route_conflict）。
- 端点：`GET /v1/models`（仅 enabled+ready）、`POST /v1/chat/completions`（stream 与非 stream）。
- Admission 栅栏：未知（404）、未启用（404）、冷/未就绪（503）、无效或不支持字段（400，含 18 例矩阵）一律显式拒绝且零上游转发、零加载。
- SSE：真实分帧（delta/role 首帧）、finish_reason、usage（stream_options include_usage）、`[DONE]` 终止；上游错误不伪装成功（首帧前 502/500 JSON，中途断流无 [DONE]）。
- 客户端断开：SSE 心跳注释帧（`: keep-alive`，生产默认 15s，测试注入 100ms）使 dart:io HttpServer 在下一次写时发现死连接（最小 repro 证明 response.done 不会在 destroy 时主动触发，只有写才暴露），随后取消上游并释放许可。
- 公开报文不含凭据与内部细节（错误体仅 type/message/status）。
- 请求体上限 1MiB+8 → 413；非本机 Host → 403。
- 登记持久化：`public_models.json`（schema 1）；损坏文件 `load()` 显式抛 `StateError('公开模型登记文件无效')` 且保持未加载态可重试。

## 门禁证据（串行容器 ghostmodeldeck-checks-r33b，最终内容绑定）

| 门禁 | run id | 结果 |
|---|---|---|
| format `--output=none --set-exit-if-changed lib test benchmarks` | run-4ftDyo | 65 files, 0 changed |
| analyze | run-OXNM2v | No issues found |
| test | run-eFoq0x | 379 passed（基线 352 + 27 新增，只增不减） |

RED→GREEN 证据：RED run-knfexY（编译失败：PublicModelRoutes/PublicGatewayServer/TextRequest.messages 不存在）；GREEN run-jej2VC（27/27）；门禁第一轮 format 写回后按纪律重跑 analyze+test（run-VkLPs5 暴露 desktop_layout 回归：_omlxEngine 未初始化，已修复）。

## 测试清单（27 新增）

- TextRequest 公开协议扩展（旧构造逐字段不变、messages 透传、无效输入矩阵、旧文案原样）
- EngineRuntime 流式接口类型上调
- PublicModelRoutes（ID 派生、持久化 schema 1、损坏显式失败、decision kind 拒绝、unknown 拒绝、listModels 过滤、resolve 404/503/409 零上游、重启保 ID 撤旧代次）
- PublicGatewayServer（端口冲突显式失败、GET /v1/models、非流式端到端+上游体断言、SSE 分帧/DONE/parity、不支持字段 18 例零上游、unknown/disabled/cold 零加载、上游 500→502、SSE 首帧前 500→500 JSON、中途断流无 DONE、客户端断开取消上游释放许可、413/403、lifecycle shutdown 顺序 gateway-stopped 先于 engine-killed）

## 替身边界

替身仅位于既有外部 I/O 接缝：`_GatewayIO` 实现 `EngineProcessIO`（run/start）与 `EngineChild`（记录 kill 事件 'engine-killed'）；上游为真实 loopback `HttpServer`（detachSocket 确定性持有/释放，不用 sleep 计时）；并发/取消用 Completer 信号。业务模块（routes/gateway/engines/lifecycle）全部真实。

## 未证事项

- 真实原生引擎进程（llama-server/oMLX）端到端未测——纪律禁止原生模型加载；引擎侧由既有引擎测试 + 本切片 I/O 接缝测试覆盖。
- 心跳 15s 默认值在生产代理下的调优未实测。
- GUI 行仅 widget 测试覆盖既有布局（desktop_layout_test 回归修复后通过）；未做人工 macOS 运行验证。
