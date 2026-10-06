# GhostModelDeck 首期最终 Code Review（Standards / Spec 双轴）

日期：2026-10-07（Asia/Shanghai）· 审查范围 `git diff 0c5b344...HEAD`（首期 #13–#19，65 commits、124 文件、+37066/−672）· 评审时 HEAD `7992e1c`，评审后缺陷修复至 `485b2c6`。
方法：两轴由独立子代理并行执行（避免上下文互相污染），父代理汇总，不合并、不重排两轴发现。

## Standards

**硬性违规：未发现。** 对照 docs/engineering.md：E02（I/O 边界校验，public_gateway `_readChat`、`OmlxReceipt.fromJson`、sdk_service `StartupModelSet.load`）、E03（`unawaited` 带归属注释与 catchError）、E04（beginShutdown→stop→close 释放链完整，含 recycle 准入闩）、E06（GUI/SDK/MCP/HTTP 共用同一业务入口）、E12（maclauncher_sdk 固定并留 lockfile）均落实；CONTEXT.md 术语同步符合 domain 规范。E01 属工具强制项，由容器门禁兜底（最终 run-2McLae / run-MYE6s1 / run-y8HUgP 全绿）。

**基线坏味道（判断项，按严重度）：**

1. Primitive Obsession + Repeated Switches — `lib/public_gateway.dart` 对 `error.kind.name` 字符串 switch；`lib/llama_engine.dart:449` `timedOut` 与 `lib/omlx_engine.dart:258` `timeout` 对同一概念命名分叉，靠双写 case 兜底。→ 共享请求失败类型或单一映射表。
2. Divergent Change — `lib/omlx_engine.dart`（2324 行）单类承担安装校验/删除/池监管/管理面 HTTP/推理 SSE 五类变更原因；`lib/llama_engine.dart`（2276 行）同构。→ 对应 E09 建议级按职责拆分。
3. Duplicated Code — 两引擎 SSE 解析/取消、serial 队列、seal-drain 形状平行重复；catalog link 与 sdk_service 的随机 ID 生成重复。
4. Middle Man — `lib/engine_catalog.dart:46` `installationId => id` 纯别名。
5. Data Clumps — `EngineRegistration` 六可选字段混族（oMLX 收据混入通用登记类型）。→ 家族化密封类型。
6. Mysterious Name / 硬编码 — `lib/omlx_engine.dart:298` `builderPath` 硬编码上游构建者绝对路径，供应链门禁语义未自释；上游换构建机将误拒。
7. Message Chains — `lib/library_page.dart` `_runRow` 三层穿透取 legacy 实例。
8. 魔法数 — `lib/public_gateway.dart` `publicId.length != 68` 未命名。

**处置**：均为判断项、非阻断；作为后续重构候选如实记录，首期不强制修复（仓库 E09 本身为建议级）。

## Spec

对照 docs/spec.md（A01–A12）与 issue #13–#19 原文；用户批准的模型加载禁令范围收缩（A06 原生端到端、A09 真实 MacLauncher 联调、A10/A11 带载复测）不计缺陷。

**(a) 规格要求但只部分实现（1 项，已修复）：**
- usage 保留不完整（spec.md「保留真实文本、usage、finish reason」）：公开报文仅回传 `completion_tokens`，上游 `prompt_tokens`/`total_tokens` 被丢弃。→ 立案 #24，TDD 修复：`TextResult` 保留完整上游 usage 图、网关非流式与 SSE 结束帧原样透传。RED run-8QukGT（2 失败，Actual 仅 `{'completion_tokens': 5}`）→ GREEN run-Fs8IHc（29/29）→ 全量 405（run-y8HUgP）。提交 d03b4f9 + 485b2c6。

**(b) 范围蔓延：未发现。** 全部变更可映射至 #13–#19 与验收期缺陷 #20–#24。

**(c) 低严重度记录（不阻断，如实保留）：**
1. 公开端口冲突后网关 failed 为同进程终态、无重试入口（`lib/public_gateway.dart:283-285`）；spec.md「公开端口冲突明确失败」已满足且不漂移，但与失败恢复精神不完全一致。A06 原生链路未验。
2. 口径提示：网关自身 SSE `: keep-alive` 注释帧（断连检测）与 #23 关闭的 oMLX 上游 keepalive chunk 不同层；引用 A07「零 keepalive 帧」时指上游帧。

## 汇总

- Standards：硬性违规 0；判断项坏味道 8（最重：双引擎超时枚举命名分叉；omlx_engine 单类发散变化）。已记录为重构候选。
- Spec：部分实现 1（#24，已修复回归）；范围蔓延 0；低严重度记录 2（如实保留）。
- 最终门禁绑定：`.tooling/gmd-final-gate-verification-final.json` PASS @ 485b2c6（67 Dart 输入 / 405 全量 / 三 ONLINE 归档，基线推进说明见 `.tooling/gmd_verify_final_gates_r1.py` 文件头）。
