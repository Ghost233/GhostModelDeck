# 官方 llama.cpp 原生决策探测

2026-10-04。为了排除 LM Studio 当前默认 runtime 对两份决策资产的加载失败，自主执行官方构建的原生 Mac 探测。此处是独立引擎契约验收，尚不代表应用已管理该引擎、两席并发或 MCP 已完成。

来源为官方 ggml-org/llama.cpp 的 b11381 macOS arm64 archive。完整 archive SHA-256 `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341` 与下载时官方 asset digest 一致，解包前再次核对。实际 `llama-server --version` 返回 `0.5.0-dev (build 11381, commit 836d57176)`，AppleClang 21.0.0 / Darwin arm64。

脚本 `.tooling/implementation/probe-official-engine.dart` 在执行前独立核对每份实际模型完整 SHA，以进程句柄、唯一 alias、loopback 端口、公开 `/props` 的 alias/模型绝对路径绑定身份，再通过正式 `DecisionRequest` / `DecisionResult` 验证真实 `/v1/systemone` 响应。每份分别加载、调用、停止，尚未进行并发委员会咨询。

| 模型 | 固定来源 | 完整 SHA | 加载至健康 | 单次推理 | 规则案例输出 |
| --- | --- | --- | ---: | ---: | --- |
| Kev Q8 | ggml-org/Kev-0.8B-GGUF@e551e319d483ff57e1ff208924b349d397cffc1c | 27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0 | 5122 ms | 299 ms | refund 0.9904589808039479；investigate 0.009541019196052226 |
| Laya Q8 | ggml-org/Laya-GGUF@da4b4753d62197659d8c90103cd4c43bef9afea6 | c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2 | 514 ms | 161 ms | refund 0.9362442233096444；investigate 0.06375577669035551 |

输入为英文的“确认重复扣款，规则要求退款”，两个稳定候选为 refund/investigate。这是每模型一次功能探测，耗时来自该轮日志，不能据此称延迟基准、中文表现、正确率或校准质量。Laya 为 English root checkpoint，中文测试留待后续规格验收。

实际输入 token 分别为 49、50，输出 token 均为 0；响应含与对应进程 alias 严格一致的 model、完整同 ID 概率、有效选择和归一化结果。完整原始响应与 `/props` 保存在 `.tooling/implementation/probe-official-engine.jsonl`。

实际参数为 context/batch/ubatch 4096，parallel 1，GPU layers 99，host 127.0.0.1。父进程环境未继承 LLAMA_ARG_*；每次仍核验有效 `/props`，没有仅凭 argv 宣称身份。Metal 运行日志分别为 `official-kev-probe.engine.log` 与 `official-laya-probe.engine.log`。

两个测试子进程 PID 66817、66862 均由持有句柄的 finally 停止，实际退出码 0；整个探测脚本退出码 0。模型文件大小和修改时间前后相同。未停止 LM Studio 既有服务或其他进程。

公开 `--list-devices` 实际列出 `MTL0: Apple M5 Pro` 与 Accelerate。随后显式增加 `--device MTL0 --log-verbosity 3` 重验：两份模型再次返回同一概率/选择，输入 49/50、输出 0；Kev 加载至健康 1578 ms / 单次调用 44 ms，Laya 261 ms / 18 ms。PID 75785、75789 均退出 0，脚本退出 0，模型大小/mtime 未变。该轮是已读文件缓存条件下的一次功能重验，不能与首轮直接组成冷暖性能结论。原始记录 `probe-official-engine-metal.jsonl`；这里只记录显式设备选择，未取得逐层 GPU offload 数量或独立 GPU 利用率指标。
