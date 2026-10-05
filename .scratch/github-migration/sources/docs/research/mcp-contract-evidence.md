# MCP 接入与委员会工具契约证据

核实日期：2026-10-04。范围：标准 Flutter 桌面、macOS 优先、允许 Mac 原生推理、首个客户端 Codex、通用候选项咨询。本文是供审阅的接口草案；传输、SDK、状态格式与聚合规则尚未由用户选定。本轮仅查文档、源码与本机 CLI 元数据，没有注册 MCP、修改客户端配置或运行服务。

## 1. 协议基线必须先固定

`initialize → notifications/initialized → tools/list → tools/call` 对应 **2025-11-25 及以前的握手协议**。该版要求客户端先发 `initialize`，协商版本与能力；成功后通知就绪，HTTP 后续请求携带协商版本头。[2025-11-25 Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)

当前官方规范是 **2026-07-28**，原文依据：“There is no negotiation handshake.” 版本与客户端能力改为逐请求 `_meta`；服务器必须实现 `server/discover`，客户端可以先发现，也可以直接调用并处理版本不支持错误。新版 HTTP 删除协议会话与独立 GET 流，完成结果增加 `resultType: "complete"`。[Versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)、[Discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)、[HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)、[Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)

**建议，未决：**首版用目标 Codex 实际可验证的版本作基线，优先评估能服务旧握手客户端的实现。不能把“最新版 SDK”直接等同于目标客户端兼容；若采用双版本服务器，分别验收两套线上报文，不向旧握手结果混入新版字段。[兼容矩阵](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#compatibility-matrix)

## 2. 传输与生命周期选项

| 选项 | 启动与结束的责任 | 对 Flutter 常驻委员会的影响 |
| --- | --- | --- |
| stdio 直接服务器 | MCP 客户端启动子进程。旧版关闭时客户端关闭 stdin，等待退出，必要时发 SIGTERM/SIGKILL。 | 若它也持有模型，模型进程生命周期会跟随连接；多个客户端可能启动多个副本。 |
| stdio 轻量适配进程 | Codex 启动适配进程；适配进程转发到 JevManager 管理的常驻服务。 | 建议适配进程退出只结束连接，常驻服务继续由 JevManager 管理；要另行约定本地内部 IPC 和服务未运行错误。 |
| 本地 Streamable HTTP | MCP 服务器独立运行，可以处理多个客户端连接。 | 适合由 JevManager 统一加载模型、管理服务，再供 Codex 连接；需要端口、就绪状态与本地认证策略。 |

表中第一、三行的传输事实来自 [2025-11-25 Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)，stdio 关闭规则来自 [Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#shutdown)。第二行及“多个模型副本”是据启动责任推导的设计选项，不是 MCP 自动提供的能力。

旧版 HTTP 每条消息单独 POST；客户端接受 JSON 或 SSE，GET 流可返回 405；会话 ID 是可选能力，若返回则后续请求须携带。新版 HTTP 使用逐请求元数据，不能套用旧版 `MCP-Session-Id`、GET/DELETE 会话语义。[旧版 HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http)、[新版 HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)

两版 HTTP 都要求检查传入 Origin，非法 Origin 返回 403；本地服务应仅绑定 loopback，并实施适当认证。stdio 的 stdout 只能输出换行分帧的 MCP JSON，日志走 stderr。[旧版传输边界](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[新版安全边界](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#security-endpoint)

**倾向建议，未决：**常驻模型由 JevManager 持有时，本地 HTTP 的生命周期最直接；stdio 适配进程可减少 Codex 连接侧的端口配置。允许 Mac 原生推理不要求选择其中任何一种。首版无需同时实现两种。

MCP 端点（如 `/mcp`）处理协议与工具调用；`/v1/systemone` 是待模型 API 工单核实的内部推理接口，不是 MCP 规范规定的路径。建议适配层验证候选项、调用已验证的模型适配器、整理委员会结果；不能把 Codex MCP URL 指向普通推理 REST 路径。[MCP 工具调用](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#calling-tools)

## 3. Dart 与官方 SDK 证据

| 候选 | 可追溯证据 | 对选择的限制 |
| --- | --- | --- |
| MCP 官方 TypeScript / Python SDK | 官方 SDK 名录列为 Tier 1。 | 可作独立适配进程的候选，但会增加另一套运行时；仍须固定 SDK 发布版并接入验收。 |
| Dart 项目 `dart_mcp` | pub.dev 发布者为 `labs.dart.dev`，包自称 experimental；发布版 **0.5.2**，2026-06-29，Dart `^3.7.0`。发布 README 标 stdio 支持、Streamable HTTP 不支持。 | 适合评估 stdio；不能把开发分支 HTTP 能力归到该发布版。 |
| 社区 `mcp_dart` | **2.4.2**，2026-09-03，Dart `^3.4.0`；维护者文档声明 stdio、HTTP、2025-11-25/2026-07-28 双版本与跨语言互操作测试。 | 官方 SDK 等级尚未授予；声明及上游测试不是本机 Codex 验收。 |

来源：[MCP 官方名录](https://modelcontextprotocol.io/docs/2026-07-28/sdk)、[`dart_mcp` 发布说明](https://pub.dev/packages/dart_mcp/versions/0.5.2)、[发布元数据](https://pub.dev/api/packages/dart_mcp)、[`mcp_dart` 发布说明](https://pub.dev/packages/mcp_dart/versions/2.4.2)、[发布元数据](https://pub.dev/api/packages/mcp_dart)。**官方名录没有 Dart；“Dart 项目维护”不能写成“MCP 官方 Dart SDK”。**

固定源码依据：`dart_mcp` 快照 [`cdf9ad1cb50f148f8dd332eaea765e79e5d9b475`](https://github.com/dart-lang/ai/commit/cdf9ad1cb50f148f8dd332eaea765e79e5d9b475) 的 [pubspec](https://github.com/dart-lang/ai/blob/cdf9ad1cb50f148f8dd332eaea765e79e5d9b475/pkgs/dart_mcp/pubspec.yaml) 是 **0.6.0-wip**；[changelog](https://github.com/dart-lang/ai/blob/cdf9ad1cb50f148f8dd332eaea765e79e5d9b475/pkgs/dart_mcp/CHANGELOG.md) 已记录 HTTP、新协议及破坏性修改。`mcp_dart` 的 `v2.4.2` 指向 [`3f551cb4c624135111bede4c163d851971497a6e`](https://github.com/leehack/mcp_dart/tree/3f551cb4c624135111bede4c163d851971497a6e)；[该版 changelog](https://github.com/leehack/mcp_dart/blob/3f551cb4c624135111bede4c163d851971497a6e/CHANGELOG.md) 记录 stdio/流消息默认 10 MiB 上限的安全修复，证明近期维护，但不证明部署质量。

**建议，未决：**若优先纯 Dart 与 HTTP，可先验证固定的 `mcp_dart 2.4.2`；若优先官方 MCP SDK，可评估独立 TypeScript/Python 适配进程。不要为获得未发布功能默默依赖 `dart_mcp` main。

## 4. Codex 接入事实与证据边界

OpenAI 当前官方页面明确支持 stdio、Streamable HTTP、HTTP bearer token/OAuth，按同一 Codex host 共享 MCP 配置；stdio 用 `command/args/cwd`，HTTP 用 `url`，凭据可引用环境变量。该页面称桌面入口为 ChatGPT desktop app，具体本机 UI 与版本仍需后续确认。[官方 MCP 接入文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

以下是互斥的审阅模板，未写入任何配置；路径、端口均为占位值：

```toml
# 方案 A：Codex 启动适配进程
[mcp_servers.jev_council]
command = "/absolute/path/jev-mcp"
args = ["stdio"]
```

```toml
# 方案 B：连接已运行的本地服务
[mcp_servers.jev_council]
url = "http://127.0.0.1:<port>/mcp"
bearer_token_env_var = "JEV_MCP_TOKEN"
```

官方还提供 `startup_timeout_sec`（默认 10 秒）、`tool_timeout_sec`（默认 60 秒）、工具 allow/deny list 与 `required`；CLI 可 `codex mcp add ... -- <command>` 或 `--url <url>`，`/mcp` 可查看连接。建议初始化和工具发现不等待全部模型冷加载，推理预算在实现前明确。[官方配置说明](https://learn.chatgpt.com/docs/extend/mcp?surface=cli#configure-with-configtoml)

本机只读记录：`codex --version` 返回 **codex-cli 0.156.1**；`codex mcp add --help` 列出 `--url`、stdio command、`--bearer-token-env-var`。它们仅证明这个本机 CLI 暴露相应参数，不能证明桌面 app 版本、实际协商的协议、HTTP/stdio可连通、`outputSchema` 校验或模型实际使用工具。未读取个人配置/密钥，也未查配置中的服务器。官方支持文档没有给本机版本提供协议兼容结论，后续必须记录线上握手或逐请求元数据。[官方接入文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

## 5. `consult_jev_council(state, options)` 最小草案

2026-10-04 用户进一步明确：多个 Jev 类决策模型必须对同一请求并发判断，综合结果经 MCP 返回给大模型。以下研究阶段 schema 只覆盖单席意见与故障，已由 [确定委员会语义与真实验收标准](../../.scratch/jevmanager/issues/06-council-acceptance.md) 的答案补充取代；实现以该工单为准，不可继续使用缺少综合和分歧字段的草案作为最终契约。

以下全部是待审阅的产品契约，并非模型 `/v1/systemone` 的真实 schema。建议 v1 的 `state` 先用文本，`options` 用稳定 ID 与文本；需要结构化状态时再由用户选择。调用只咨询已配置席位，不选择、执行候选行动或临时下载模型。

工具定义使用 `name: "consult_jev_council"`，描述明确“向本地已配置席位咨询候选项并返回各席位排序及故障，不执行候选行动”。若实现符合上述边界，建议标注 `readOnlyHint: true, openWorldHint: false`。标注只是提示，不替代服务器验证。[工具定义与 annotations](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#data-types)

建议 `inputSchema`：

```json
{
  "type": "object", "additionalProperties": false,
  "required": ["state", "options"],
  "properties": {
    "state": {"type": "string", "minLength": 1},
    "options": {
      "type": "array", "minItems": 2,
      "items": {
        "type": "object", "additionalProperties": false,
        "required": ["id", "text"],
        "properties": {
          "id": {"type": "string", "minLength": 1},
          "text": {"type": "string", "minLength": 1}
        }
      }
    }
  }
}
```

另作语义校验：文本不得全空白，候选 ID 不重复；请求大小必须符合所选模型上下文与传输预算，具体上限待模型证据确认。候选文本是数据，不赋予文件读取或执行权限。

建议 `outputSchema`，同时约束成功、部分失败与失败结果：

```json
{
  "type": "object", "additionalProperties": false,
  "required": ["schemaVersion", "requestId", "status", "seats", "error"],
  "properties": {
    "schemaVersion": {"const": "1"},
    "requestId": {"type": "string", "minLength": 1},
    "status": {"enum": ["ok", "partial", "failed"]},
    "seats": {
      "type": "array",
      "items": {
        "type": "object", "additionalProperties": false,
        "required": ["seatId", "modelRef", "status", "ranking", "error"],
        "properties": {
          "seatId": {"type": "string", "minLength": 1},
          "modelRef": {"type": "string", "minLength": 1},
          "status": {"enum": ["ok", "unavailable", "timeout", "error", "unsupported"]},
          "ranking": {"type": ["array", "null"], "items": {"type": "string"}, "uniqueItems": true},
          "error": {"anyOf": [{"$ref": "#/$defs/error"}, {"type": "null"}]}
        }
      }
    },
    "error": {"anyOf": [{"$ref": "#/$defs/error"}, {"type": "null"}]}
  },
  "$defs": {
    "error": {
      "type": "object", "additionalProperties": false,
      "required": ["code", "message", "retryable"],
      "properties": {
        "code": {"type": "string", "minLength": 1},
        "message": {"type": "string", "minLength": 1},
        "retryable": {"type": "boolean"}
      }
    }
  }
}
```

语义约束：成功席位的 `ranking` 是输入候选 ID 的完整排列、`error=null`；失败席位 `ranking=null`，保留故障。全部配置席位成功为 `ok`；至少一席成功但存在故障为 `partial`；无有效结果或参数无效为 `failed`。`modelRef` 指向实际模型及修订/产物标识，不能只写席位昵称。席位集合来自应用配置，不隐含“三席”或特定聚合算法。

建议 `tools/call` 的 `result` 带 `structuredContent`、`content`、`isError`：`content` 的 text 序列化同一 JSON，使不读取结构化字段的客户端仍能理解；`partial` 明确失败席位且 `isError=false`，`failed` 为 `isError=true`。发布 `outputSchema` 后，所有结构化结果都须符合它。[旧版结构化结果与错误](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#structured-content)

错误分层：错误 JSON-RPC 结构、未知工具走协议 error；有效 `tools/call` 中的重复候选、API失败或业务错误走工具执行错误，可建议 `INVALID_INPUT`、`COUNCIL_UNAVAILABLE`、`TIMEOUT`、`UNSUPPORTED_MODEL_OUTPUT`，不暴露凭据、内部堆栈或用户状态全文。[规范 Error Handling](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#error-handling)

草案不返回伪造的 `probability/confidence`，不把排序序号、投票占比或任意 score 称作概率。若模型返回分数，待对应 API 的语义、量纲与校准证据核实后另审字段；无法从真实输出可靠得到排序时返回 `unsupported`。综合返回已是首版要求；多数票、加权排名或校准概率融合的具体方式仍待选择，最终契约必须同时保留各席位意见、综合结果与分歧。

## 6. 后续验收清单：目前均未执行

先记录桌面客户端/CLI、服务器与 SDK 的精确版本、模型修订和所选传输，再保存脱敏的线上请求/响应。源码、包评分、上游 CI 和配置存在均不能代替下列本机证据。

| 阶段 | 2025-11-25 握手基线验收项 |
| --- | --- |
| initialize | 客户端发送支持版本与 clientInfo；响应同 ID、协议版本、serverInfo、`capabilities.tools`；客户端能接受响应版本，再发 `notifications/initialized`；不支持版本时有明确失败。 |
| tools/list | 请求返回包含精确工具名、描述、上文 input/output schema；仅支持一个工具时可不分页；调用发现与结果不依赖模型已加载。 |
| tools/call | 有效输入得到同 ID 的 result；结构化结果符合 schema，text 与其一致；排序 ID、席位状态、模型来源关系正确。 |
| 故障 | 重复 ID、空白状态、未知工具、单席故障、全席故障、超时分别验证；部分结果不能被描述成全体成功。 |
| 生命周期 | Codex 连接/断开、适配进程 EOF、桌面关闭/后台运行、常驻服务重启后重连均检查；确认没有额外模型副本或孤儿进程。 |
| HTTP 边界 | 真实 JSON/SSE响应、Origin拒绝、loopback绑定、认证失败、协商版本头；若启用会话，检查会话头及404后的重新初始化。 |
| Codex实调 | 配置后检查 `/mcp` 状态，再用明确“调用 consult_jev_council”的提示完成一次真实咨询；确认客户端发现、实际调用与消费结果，不能仅以服务器列表有名字判通过。 |

前三项依据 [Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) 与 [Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)，HTTP 项依据 [Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)，Codex入口依据 [OpenAI文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。其余是上述产品草案的验收要求。

最小握手版测试请求示例（省略传输头；这些不是执行结果）：

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"acceptance-client","version":"0.1.0"},"capabilities":{}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"consult_jev_council","arguments":{"state":"优先缩短交付时间，预算固定。","options":[{"id":"a","text":"缩小首版范围"},{"id":"b","text":"增加并行人力"}]}}}
```

若目标客户端实际选择 **2026-07-28**，改测 `server/discover` 或直接请求；每个请求携带该版 `_meta`，HTTP匹配版本头、`Mcp-Method` 与调用名头，完成结果含 `resultType`；不再要求 initialize、会话或 GET 流。工具业务 payload 可保持对象，以兼容旧版对象型 `structuredContent`。[新版 Discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)、[新版 HTTP 报文](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#request-metadata)、[新版 Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)

仍需选择：HTTP或stdio适配、SDK、桌面关闭后是否常驻、文本或结构化state、席位与聚合策略、单席/整轮推理预算、本地认证与日志保留。仍需证据：本机Codex协议版本与真实工具调用、`/v1/systemone`输入输出及模型排序语义。
