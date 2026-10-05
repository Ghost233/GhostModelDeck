# 2026-10-05 委员会故障与常驻保护验收

对应 [#17](https://github.com/Ghost233/JevManager/issues/17)。通过桌面和 MCP 共用的 CouncilController 入口，没有替代综合算法。

## 真实模型

复用共享模型库中已固定修订、完整哈希和来源核验的 Kev Q8_0 与 Laya Q8_0，使用官方受管 b11381 引擎。本轮模型为英文合成请求，不代表中文效果验收。

1. 两席真实推理，PID 78445 / 78482：`ok / ensemble`，整轮 54,261 µs，保留两份概率与综合值。请求 ID `16568b46b45b8a5ca85166f6950c3363`。
2. 主动停止本次创建的 Laya 后，保留原席位选择，再咨询：`partial / single_model`，两席分别 `ok / not_ready`；aggregate_scores、top_choices、votes、disagreement 全为 null。请求 ID `96407e56684494d41d52fa2937162811`。
3. 每请求取消 token 在咨询前取消：`failed / none`，两席均 `cancelled`，没有有效建议。请求 ID `b8d700934a31ca0a13b91802088a2d6b`。
4. 随后再次真实咨询：Kev 仍 PID 78445、ready，并成功返回；已停止席位仍明确 not_ready，没有冷启动补席。请求 ID `1dd8dea631b5d1e1104c04b745e43671`。

原生脚本 exit 0：`.tooling/implementation/live-council-failures.dart`；完整原始 DTO 与 provenance 保存于同名 `.jsonl`。最后只清理本次受管实例，两个状态均 stopped；模型大小和修改时间保持不变。

## 容器边界验证

在途取消、另一并发轮继续、10 秒整轮截止、晚到隔离、非法响应与 HTTP/身份错误边界由外部推理 HTTP 可控替身通过同一真实业务入口验证；最终完整 94 项测试通过（run-Zyk3YV），静态检查无问题（run-7kNSmL）。实际默认 10 秒测试通过（run-Hrq7RD）；11 类非法响应及恢复（run-BbbxM9）、在途双轮只取消一轮且同 PID 后续成功（run-uEqhzU）、晚到封存（run-5bS4Ay）、桌面取消（run-NA7t6k）均通过。本记录的预取消原生案例不冒充在途取消证明。
