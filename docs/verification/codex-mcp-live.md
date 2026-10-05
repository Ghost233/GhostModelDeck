# 2026-10-05 Codex HTTP MCP 实测

对应 #18；Codex CLI 的真实发现、两模型调用与结果消费已通过。当前桌面聊天热导入未作为已验证能力。

## 已验证

- 原生 release 桌面构建 46.1 MB 成功，MCP 页面显示实际 `http://127.0.0.1:54842/mcp`、运行状态、进行中咨询数量与可复制配置。模型未加载时服务已启动。
- 独立原生验收使用同一公共业务与 MCP 模块，加载固定修订且完整/source 核验的 Kev Q8_0、Laya Q8_0，PID 11059、11198；模型 ready 后开启仅 loopback 的 `55397/mcp`。它是单独的验收进程，不能替代 GUI 共享实例验收。
- Codex CLI 0.160.0 使用临时进程配置，服务端实际收到 initialize、initialized 与 tools/list；实际协商版本为 **2025-06-18**。
- Codex 尝试 consult_jev_council，但 mcp_tool_call 完成状态为 failed：`MCP tool call requires approval, but approval policy is never`。服务器未收到 tools/call，因此不能称为模型调用与结果消费通过。CLI exit 0、turn.completed 不能替代成功工具事件。
- 原生桌面应用的实际 SDK 客户端调用通过：2025-06-18，未加载模型时返回 `failed / none`、空席位、空综合，文本 JSON 与 structuredContent 相同。请求 ID `c92ee58d78f46532af55e9799fb2165f`。这是空委员会边界验证，不替代 Codex 多模型消费验收。
- 独立验收服务器停止后两模型仍 ready；随后仅清理本次创建的两个实例，最终 stopped、模型大小与修改时间不变。

## 实际消费通过

最初的非交互 CLI 无法请求审批。定向只读核对发现，用户 config.toml 没有显式 approval_policy 字段；不能把 CLI 的有效 never 值说成用户明确配置。后续改用 CLI 公开的 `--approve-for-me`，让调用经过独立自动审查，保留 workspace-write 沙盒、既有模型与用户全局配置；没有指定单工具免审批，也没有使用 bypass 参数。此前单工具免审批授权问题已由这一审查路径替代。

实际 Codex 0.160.0 线上记录：initialize、initialized、tools/list、tools/call，协商 2025-06-18。唯一 mcp_tool_call 从 in_progress 到 completed，error 为 null；CLI exit 0、turn.completed，未出现 turn.failed。

- request_id：50023de99389e00f12f824debbe0fd0c；status ok、scope ensemble。
- Kev 原始 refund 概率 0.984969867788542；Laya 为 0.9647118078314689；综合为 0.9748408378100055，investigate 为 0.025159162189994512。
- top_choices 为 refund，票数 2/0，分歧 0。整轮 74,908 µs；两席派发均早于第一席完成。
- 原始 JSON text 解码与 structured_content 完全相等，综合值可与两份真实概率逐项对账。Codex 最终回答复述同一 request_id、模型名、状态、完整综合与票数，并基于实际结果建议 refund，明确综合评分不代表正确率。
- 常驻 PID 98077/98082 与连接前相同。Codex 退出及 MCP 停止之后，真实进程观察器仍报告两席 ready；最后仅清理本次受管实例，均 stopped，模型大小与修改时间不变。

原始失败记录仍保留在 /private/tmp/jevmanager-mcp-acceptance-20261005/。成功合成记录位于 /private/tmp/jevmanager-mcp-auto-review-20261005/；安全协议元信息与原生模型 provenance 在 .tooling/implementation/live-council-mcp-auto-review.jsonl，核对摘要为 codex-mcp-success-summary.json。不记录认证头或个人上下文。

## 冻结实现的容器验证

完整 104 项测试通过：run-PetlTI；静态检查无问题：run-mtQiK6。实际三个协议版本 2026-07-28、2025-11-25、2025-06-18 均由真实 SDK 客户端覆盖；Host/Origin 与 OPTIONS、1 MiB 普通和分块请求上限、非法输入、单席/零席、文本与结构化一致、请求取消隔离、停止/drain 保全桌面轮次与驻留实例均已通过。测试不是 Codex 真实消费的替代证据。

冻结 MCP 源 SHA-256：29fb1743322972f8723f48044ab48c108a5b583533f2281ac6bdabfe74600137。
