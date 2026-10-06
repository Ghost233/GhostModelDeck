# GhostModelDeck 公开网关 usage 完整透传验收（#24）

日期：2026-10-07（Asia/Shanghai）· 分支 main（验收基线 HEAD `7992e1c`，修复提交 `d03b4f9`）· 串行容器 `ghostmodeldeck-checks-r33b`

## 缺陷与依据

docs/spec.md:104 要求公开网关「保留真实文本、usage、finish reason」。缺陷前行为：

- `lib/chat_protocol.dart`：`TextResult.parse` 与 `TextStreamDecoder` 解析上游 usage 时仅保留 `completion_tokens`，`prompt_tokens`/`total_tokens` 被丢弃。
- `lib/public_gateway.dart`：公开非流式响应与 SSE 结束帧的 usage 只含 `{'completion_tokens': ...}`。

## 修复内容（commit `d03b4f9`）

- `lib/chat_protocol.dart`：`TextResult` 新增 `final Map<String, Object?> usage`，`parse()` 与 `TextStreamDecoder.finish()` 用 `Map<String, Object?>.from(usage)` 保留整个上游 usage 图；`outputTokens` 兼容字段保留，既有校验不变（未新增对 prompt/total 的强制要求，避免拒绝合法上游）。
- `lib/public_gateway.dart`：非流式响应与 SSE 结束帧改为透传 `result.usage`。
- `test/public_gateway_test.dart`：新增两测试（上游 usage `{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}`，公开非流式响应与 SSE 结束帧须原样保留三者）；`_GatewayIO` 新增可配置 `textUsage`；两条固化缺陷行为的既有断言（:462、:525 原样为 `{'completion_tokens': 2}`）改为期望完整三者（4/2/6）。

## TDD 证据

| 阶段 | 命令 | run id | 结果 |
| --- | --- | --- | --- |
| RED | `test test/public_gateway_test.dart --plain-name "full upstream usage"` | run-8QukGT | 2 个新测试均失败，Actual `{'completion_tokens': 5}`，精确呈现 prompt/total 被丢弃 |
| GREEN | `test test/public_gateway_test.dart` | run-Fs8IHc | 29/29 通过（含 2 新测试与 2 条更新断言） |

## 门禁（SERIAL `ghostmodeldeck-checks-r33b`，基线 403）

| 闸门 | run id | 实际结果 |
| --- | --- | --- |
| `format --output=none --set-exit-if-changed lib test benchmarks` | run-2McLae | `Formatted 67 files (0 changed)`，exit 0 |
| `analyze` | run-MYE6s1 | `No issues found!`，exit 0 |
| `test` | run-y8HUgP | `All tests passed!`，405 通过（= 403 基线 + 2 新增），exit 0 |

格式写回说明：首轮 format 检查（run-WmhksO）报 2 文件需格式化；容器为 tar 拷贝执行、写回不传播宿主机，故在容器内 `dart format` 后经 base64 拷回两文件，重跑 format 检查得 0 changed，后续闸门均在此终态上执行。原始归档在 `.tooling/container-tests/run-{8QukGT,Fs8IHc,2McLae,MYE6s1,y8HUgP}`。

## 交接状态

工作树干净；修复提交 `d03b4f9`（源码+测试），本说明为单独 docs-only 提交。未执行 push 与 issue 操作。
