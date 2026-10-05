# 领域文档

当前采用单上下文。根 CONTEXT.md 是术语表；相关 ADR 按需位于 docs/adr/。保留已有 CONTEXT.md，不创建空的 CONTEXT-MAP.md 或 ADR。

## 探索前读取

- 先读取根 CONTEXT.md；输出、工单和测试使用其中的领域词汇。
- 读取与当前工作相关的 docs/adr/。若以后出现 CONTEXT-MAP.md，按其指针读取相关上下文。
- 不存在的领域文件静默跳过；术语或真实架构取舍明确时再使用 domain-modeling 按需补充。
- 新术语在确定时更新术语表；实现细节留在规格/代码，不放入 CONTEXT.md。
- 若工作与现有 ADR 冲突，指出具体 ADR 和冲突，不静默覆盖。
