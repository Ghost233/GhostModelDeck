# 2026-10-05 中文决策对照

使用仓库既定的 12 个中文合成案例，通过实际 CouncilController 入口同时咨询 Kev Q8_0 与 Laya Q8_0。没有训练或改动权重，也没有另写综合算法。

| 来源 | 正确首选 | 有效返回 | 并列 |
| --- | ---: | ---: | ---: |
| Kev | 12/12 | 12/12 | 0 |
| Laya | 8/12 | 12/12 | 0 |
| 等权委员会 | 11/12 | 12/12 | 0 |

委员会在“缺少必需决策头”案例选错，而 Kev 单独正确。四个案例出现席位分歧。候选重排配对中，Kev 和综合首选保持 billing，Laya 从 billing 改为 returns。该数据没有支持“多模型一定更好”；它也不是泛化效果、模型独立性、概率校准或真实业务正确率的证据。

## 延迟与资源

每个来源 12 次实际热咨询。模型已做启动能力探测；没有清理系统文件缓存。

| 来源 | P50 | P95 | 最小—最大 |
| --- | ---: | ---: | ---: |
| Kev | 72.54 ms | 214.58 ms | 55.39—310.67 ms |
| Laya | 71.00 ms | 138.25 ms | 46.01—202.22 ms |
| 整轮委员会 | 78.80 ms | 252.01 ms | 55.56—312.41 ms |

分位数采用样本区间内线性插值（Python statistics.quantiles 的 inclusive 方法）；每组仅 12 个样本。

新引擎进程启动到 ready：Kev 9.093 s、Laya 4.659 s，包含资产重核验和真实能力探测。此处“进程冷启动”不等于清空操作系统缓存，也不等于未经就绪探测的首 token 延迟。

按 Darwin `ps rss` 在 ready 后及每个案例完成时采样，观测到的最大值：Kev 1,249,264 KiB、Laya 584,672 KiB。它们是进程驻留页采样，不能当作总 GPU 分配、绝对峰值或整台机器内存占用；这些未测量。推理进程 CPU 百分比的原始 ps 采样随结果保留，不推导硬件利用率或并发加速倍数。

## 版本与证据

- 资产：ggml-org/Kev-0.8B-GGUF，修订 e551e319d483ff57e1ff208924b349d397cffc1c；ggml-org/Laya-GGUF，修订 da4b4753d62197659d8c90103cd4c43bef9afea6。均 Q8_0、完整内容哈希与来源核验通过。
- 引擎：官方 llama.cpp b11381，0.5.0-dev，commit 836d57176；本机报告 Apple M5 Pro MTL0，启动配置选择该设备，具体 GPU 分配未量测。
- 可运行入口：benchmarks/run_native.dart。案例 SHA-256 为 c0e3c7ac17becdee2944a7a8daf8d2eb16538dd9e32ddf61dc14d1162a4e7971；本次 Council 源 SHA-256 为 04682939d43add0423751fd139da9a1e2c583240e711eb590f66b603681694f3。
- 请求、原始概率、综合、票数、分歧、实例身份和时序在 benchmarks/results/2026-10-05/chinese.jsonl，摘要在同目录 summary.json。文件路径前缀替换为 ${MODEL_ROOT}，其余结果字段保留。原始本机记录仍在忽略的 .tooling/implementation/live-chinese-benchmark.jsonl。
- 原生脚本 exit 0；结束后仅清理本次受管实例，两份模型大小与修改时间不变。

此独立数据与 [Codex 实际消费](codex-mcp-live.md)、[实际桌面生命周期](manager-lifecycle-live.md) 分别验收，不能互相替代。后两项现已完成；整体交付状态见 [完整核对](delivery-audit.md)。
