# Sentinel 与 GhostModelDeck 公开契约

核对日期：2026-10-09。主规格 [#62](https://github.com/Ghost233/GhostModelDeck/issues/62)，当前实施分支 `codex/playground-stage-1`，起点 `07729aec710cb5516e77ae853b152f529ab3b897`。本文只记录对接事实；预填、缓存和结构化生成的新接口单独规划。

## 入口、发现和认证

正常应用启动后，HTTP Base URL 是 `http://127.0.0.1:54841`；MCP Streamable HTTP 地址是 `http://127.0.0.1:54842/mcp`。监听停止、启动失败或端口冲突时不可用，客户端应按实际发现结果处理。服务绑定 IPv4 loopback，HTTP Host 必须为 `127.0.0.1` 或 `localhost` 及实际监听端口。

当前两个公开入口无需 Bearer/API key 配置。不要将模型提供商凭据放入请求 JSON。本地地址和端口不是远程服务配置。

`GET /v1/models` 返回 `{ "object": "list", "data": [...] }`，只列出当前公开可调用对象。本版本的识别方式：

| 条目 | 能力与调用入口 |
|---|---|
| `source: "native"` | 原生 JEV，`POST /v1/systemone` 或 JEV MCP 工具 |
| `source: "council"` | 命名委员会，`POST /v1/systemone` 或 JEV MCP 工具 |
| 无 `source`，`id` 为实际发现的公开 ID | 标准文本 LLM，`POST /v1/chat/completions` |

当前没有通用 `capabilities` 字段或 LLM MCP 工具；不要按名称猜测题型或引擎能力。LLM 的公开 ID 是模型资产标识派生的 `gmd-<64位标识>`；JEV 的 ID 是用户配置的唯一调用名，客户端将发现的 `id` 原样放入 `model`。MCP `list_jev_models` 只发现 JEV；另有 `decide_jev` 与 `decide_jev_batch`。

## 请求和输出

LLM 当前白名单为 `model`、`messages`、`stream`、`max_tokens`、`temperature`、`top_p`。`messages` 非空，每项仅 `role` 与字符串 `content`，角色只支持 system/user/assistant，内容不得为空。`max_tokens` 为 1–4096（省略默认 32），temperature 为 0–2，top_p 为 (0,1]。不支持的字段返回明确错误；客户端应保留错误而不是替用户删字段。

```json
{
  "model": "<从 GET /v1/models 选择的 LLM id>",
  "messages": [
    {"role": "system", "content": "Extract only the observed facts."},
    {"role": "user", "content": "<观察材料>"}
  ],
  "stream": false,
  "max_tokens": 256,
  "temperature": 0
}
```

普通成功响应为 `chat.completion`，包含公开 `model`、单个 `choices[0].message`、`finish_reason` 和引擎实际 `usage`。只将完整非空回答与 `stop`/`length` 结束视为完成；输入/输出 token 是实际结果字段，不推算缺失用量。

实际 LLM 预检也已通过：固定 Qwen2.5-0.5B Q4_K_M、任务独立公开端口，普通 JSON 回答如下。其公开 ID 为本任务资产目录派生 ID，预检结束后已停止实例，客户端仍须从持续运行服务重新发现。

```json
{
  "id": "chatcmpl-gmd-1",
  "object": "chat.completion",
  "created": 1791520677,
  "model": "gmd-d00227808ffc04a0de2d5a56103352a7b38e25bd51e2f63346e2bf0c577367ab",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I assist you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "completion_tokens": 10,
    "prompt_tokens": 35,
    "total_tokens": 45,
    "prompt_tokens_details": {
      "cached_tokens": 24
    }
  }
}
```

`stream:true` 返回 SSE 的 `data:` JSON 帧，文本来自 `choices[0].delta.content`，末帧带 finish reason/usage，结束为 `data: [DONE]`。公开请求不用发送 `stream_options`；网关向原生引擎请求 usage。增量文本是暂定结果，连接中断或没有 DONE 不能标记完整成功。

JEV 一个普通批量请求可以同时包含三种题型：

```json
{
  "model": "<从发现结果选择的 JEV id>",
  "state": {"request": "The user asks to change blue to green.", "facts": ["small change", true, 7]},
  "questions": {
    "action": {"type": "choice", "instructions": "Choose the requested action.", "criteria": {"keep": "Keep blue", "change": "Change to green"}},
    "applicability": {"type": "score", "instructions": "Rate applicability.", "criteria": ["Low", "Medium", "High"]},
    "requested": {"type": "noul", "instructions": "Was the color change requested?"}
  }
}
```

这是一项手动基础调用示例。实际接口支持 JSON state、复杂 instructions/criteria、1–32 个问题，JEV 请求上限 256 KiB；不支持 streaming。对象也必须具备请求所需题型的实际 Ready 能力。

2026-10-09 的最小真实模型预检中，上述题目调用临时 `native-kev` 返回如下实际标准输出（不是可持续在线对象的承诺）：

```json
{
  "model": "native-kev",
  "answers": {
    "action": {"type": "choice", "choice": "change", "probabilities": {"keep": 0.049806612020207655, "change": 0.9501933879797922}, "confidence": 0.9003867759595845},
    "applicability": {"type": "score", "score": 0.9335509933096584, "legend": {"0": "Low", "1": "Medium", "2": "High"}, "probabilities": {"0": 0.3319480860616391, "1": 0.40255283456706364, "2": 0.26549907937129735}, "confidence": 0.10382925185059522},
    "requested": {"type": "noul", "noul": 0.8463123936347369}
  },
  "usage": {"input_tokens": 136, "output_tokens": 0}
}
```

score 是有序级别上的实际评分，noul 为数值结果；不要把 confidence 当作判断正确率。委员会用相同 model/answers/usage 形状输出综合结果。默认调用不带 debug；需要本次诊断时显式 `debug:true`，诊断与默认性能调用分别记录。MCP 工具的 JSON 业务结果同时存在于 text content 与 structuredContent；工具错误遵循公开返回，不能当成有效决策。

## 错误、期限和取消

LLM 错误使用 `{ "error": { "type": ..., "message": ... } }`；JEV 错误使用 `{ "error": { "code": ..., "message": ... } }`，显式 debug 可能提供本次诊断。常见状态有 400 非法/不支持输入、404 未知或未启用对象、409 路由/能力冲突、503 非 Ready 或停止中、504 上游超时。LLM 上游失败通常为 502。客户端也要区分网络失败、非法响应、自己的 deadline、主动取消和业务拒绝。

客户端应设置独立 deadline。测试场当前候选默认 LLM 120s / JEV 30s，可配置并记录；这些值不延长服务端预算。当前文本网关采用引擎默认 30s，JEV 原生配置固定 10s，委员会采用其保存的 timeout。客户端的“超时”不等于服务端同样的超时来源。

当前阶段候选已修复普通 HTTP 非流式断开：服务端在等待推理期间拥有接受的连接，断开取消该请求；保留实际 HTTP 状态/JSON，完成后关闭连接。客户端可以使用自己的 HttpClient/AbortController 正常结束连接，不需进程内 lease 或特殊登记 header。HTTP/MCP 自动化已验证取消及并发无关调用隔离；候选尚未合入，当前已安装应用不能以该候选证据承诺旧非流式取消行为。

SSE 以真实流断开并通过服务端心跳观察失联，当前默认心跳 15s；不要承诺零延迟检测。MCP 使用标准取消通知/会话终止。客户端取消后封存已有输出，忽略晚到结果；不停止驻留模型、不取消其他客户端调用。明确退出应用会关闭公开服务并回收其自有受管运行资源。

## Ready 对象与用户准备

当前正常运行应用的实际发现仍为 `data: []`；没有持续可调用的 ID 可供 Sentinel 立即生成请求。需要用户在应用内选择已安装模型和合适引擎、显式启动并通过 Ready 核验；标准 LLM 还要启用公开访问。JEV 需要为原生模型或委员会保存唯一调用名；委员会成员都必须实际 Ready。客户端发现/推理不隐式安装、加载或启动模型。

本次预检的 Kev/Laya、quick/hard/native-kev 使用任务独立配置和临时公开端口；两个模型进程都已回收。它们证明生产管理/公开调用路径能执行，不能将名称、临时端口或记录当作常驻服务。固定 LLM 联调模型已在本任务独立缓存完整下载，实际 JSON/SSE、接收首段后的流式取消及生产退出收尾通过；其自有模型进程也已回收，仍不自动成为用户应用的持续服务。

独立 llama.cpp 服务对外呈现为 GhostModelDeck 登记的运行实例和公开模型 ID，客户端访问上述统一公开入口。当前不会向客户端暴露原生端口、alias、slot 身份或其他内部运行控制。

## 后续能力缺口

| 能力 | 当前公开支持情况 |
|---|---|
| 普通文本 JSON、SSE、实际 usage、finish reason | 已有公开 Chat 入口 |
| choice/score/noul 决策和命名委员会 | 已有 HTTP/MCP JEV 入口 |
| `n_predict:0` 或只预填 | 无公开契约；`max_tokens` 最小为 1 |
| `cache_prompt` 与缓存控制 | 无请求契约。usage 原样保留引擎可选 details；本次实际响应含 cached_tokens，但字段不是跨引擎必有值，缺失不补零，也不提供缓存控制/预填承诺 |
| `id_slot`、slot save/restore | 无公开入口或公开 slot 身份 |
| `response_format`、grammar、JSON Schema 约束生成 | 当前 Chat 白名单拒绝；无稳定公开契约 |
| LLM MCP | 当前未提供 |

这些需要单独明确生命周期、资源所有权、失败和验证后才能承诺；不要把内部 llama.cpp 支持情况或 prompt 提示词当作公开结构化输出/缓存能力。

事实指针：`lib/public_gateway.dart`、`lib/chat_protocol.dart`、`lib/jev_models.dart`、`lib/council_mcp.dart`；阶段证据见 [测试场交付](../verification/playground-benchmarks-delivery.md)。
