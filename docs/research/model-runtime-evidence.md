# 现成决策模型与 Mac 引擎证据

核查日期：2026-10-04。范围：零训练、现成权重、typed decision 概率接口。只读取一手模型卡、HF API 文件元数据和作者/引擎源码；没有下载权重、安装依赖或运行模型。因此下文的“支持”是文档和源码证据，所有候选的本机验收仍为 **未执行**。

## 结论与候选矩阵

四个家族都有可下载资产，但应以“特定资产 + 固定引擎 + 读出协议”准入。建议先验证 Kev 小模型的完整接口和 Laya multilingual 的中文表现；StartLux 需单独处理非商业许可证，JevK5 4B 留作较大模型候选。这是验证顺序，不能据此填满三个委员会席位或保证精度、排名、总内存小于 5 GB。

| 候选 | 完整推理资产与机制 | Mac 路径 / HTTP | 中文与许可证 | 准入状态 |
|---|---|---|---|---|
| Kev-0.8B | 原作者仓库是 **LoRA adapter + pointer head**，还需固定 Qwen 基座。ggml-org 新转换把合并权重、head、模板和温度装进一个 GGUF | 当前主线 llama.cpp 原生 `/v1/systemone`；原作者也有 MLX 实现 | 原模型卡明确 **English**；adapter/head/base Apache-2.0 | 英文先行；中文不得靠 Qwen 底座能力推断。[原卡](https://huggingface.co/jaredpalmer/kev-0.8b/blob/bf75a6a8848ea6960ff2ed108d9ed44c2941174f/README.md)、[转换卡](https://huggingface.co/ggml-org/Kev-0.8B-GGUF/blob/e551e319d483ff57e1ff208924b349d397cffc1c/README.md) |
| Laya multilingual | mmBERT encoder + decision head；原始 safetensors 完整包存在。mys GGUF 是 ggmlc 的完整程序格式 | ggmlc `laya` runner 有 macOS arm64 Metal 路径，`serve` 提供 `/v1/systemone` | 卡列 `zh`，宣称 100+ 语言；**发货温度全为 1，未校准**，typed-decisions 零样本弱、score 有退化限制；Apache-2.0 | 中文实验候选；必须验证三个 primitive，不能只测 routing。[原卡](https://huggingface.co/convaiinnovations/laya-multilingual/blob/1720e3e3357cfe1e281542e223f8273b0890ca34/README.md)、[runner 文档](https://github.com/monatis/ggmlc/blob/5490a13661d95add025ec1b111adbc88234a9b4f/examples/laya/README.md) |
| StartLux-Decision-0.8B | 官方完整 Qwen3.5 权重及 Q8/Q4 GGUF；对 option-letter logits 做按题型温度缩放 | 原作者 MLX；或 llama-server **加作者 `gguf_server` wrapper**，由 wrapper 提供 `/v1/systemone` | HF language 仅列 `en`，此次未找到中文任务证据；权重 **CC BY-NC 4.0**，代码 Apache-2.0 | 非商业实验候选；商业分发资格另确认。[权重卡](https://huggingface.co/startlux-models/StartLux-Decision-0.8B-Q8_0-GGUF/blob/50adbd33032110de2454d01328cfb26a2ba4f113/README.md)、[作者源码/许可证](https://github.com/StartLuxLabs/StartLux-Decision/tree/c61bfab3bb4fa3ae9d155d457247a7fd0a299a24) |
| JevK5 4B v0.3 | 原作者仓库提供已合并完整权重及 GGUF；A–P 字母概率读出，宽 choice 另做多轮合并 | llama-server + 作者 `JevK5GGUF`/HTTP server；wrapper 对 `/completion` 返回的 logprobs 重归一化 | HF language 仅列 `en`，此次未确立中文泛化证据；Apache-2.0，作者 NOTICE 另披露训练数据来源条款 | 较大候选；不能把聊天输出或普通 next-token softmax 当其决策概率。[卡](https://huggingface.co/alibiserikbay/JevK5-GGUF/blob/ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a/README.md)、[读出源码](https://github.com/allebee/jevk5/blob/f26426d16f59e8bbe1470e5b162cc89329e29b29/jevk5/gguf.py) |

## 可固定下载清单

以下 bytes / SHA-256 来自 HF `?blobs=true` 的文件清单；是下载体积，不是峰值 RAM。每行只取一个精度，不能下载整个 quantization 仓库。引擎、依赖和临时编译空间另计。

| 资产 / 必要文件 | 固定 HF revision | bytes / SHA-256 |
|---|---|---|
| `ggml-org/Kev-0.8B-GGUF` / `Kev-0.8B-Q8_0.gguf`；决策 head 与 tokenizer 已嵌入 | `e551e319d483ff57e1ff208924b349d397cffc1c` | `812406304`；`27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0` |
| `mys/laya-multilingual-GGUF` / `laya_multilingual_q8_0.gguf`；ggmlc 格式 | `3b645ae5428115fa5fd1c453070d22c3ce4b987d` | `361712736`；`757c1a4b1f0f41824113dde76d6cd06b0881d37b796103a338de77f9f9b935c3` |
| `startlux-models/StartLux-Decision-0.8B-Q8_0-GGUF` / `StartLux-Decision-0.8B-Q8_0.gguf` | `50adbd33032110de2454d01328cfb26a2ba4f113` | `811843200`；`dd2bcf3ca81737c5a22e9a781c46e5389fc572a015ce7f36227722da0ba21457` |
| `alibiserikbay/JevK5-GGUF` / `jevk5-4b-v0.3-Q8_0.gguf` | `ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a` | `4482402720`；`aea433883bc7ed399f2fbd539e53d2eac7caf71a946fe6650995a413979d4a30` |

可追溯清单：[Kev API](https://huggingface.co/api/models/ggml-org/Kev-0.8B-GGUF/revision/e551e319d483ff57e1ff208924b349d397cffc1c?blobs=true)、[Laya API](https://huggingface.co/api/models/mys/laya-multilingual-GGUF/revision/3b645ae5428115fa5fd1c453070d22c3ce4b987d?blobs=true)、[StartLux API](https://huggingface.co/api/models/startlux-models/StartLux-Decision-0.8B-Q8_0-GGUF/revision/50adbd33032110de2454d01328cfb26a2ba4f113?blobs=true)、[JevK5 API](https://huggingface.co/api/models/alibiserikbay/JevK5-GGUF/revision/ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a?blobs=true)。

完整性补充：

- Kev 原资产固定 `bf75a6a8848ea6960ff2ed108d9ed44c2941174f`：`adapter_config.json`、`adapter_model.safetensors`（43338624 bytes）、`head.pt`（2103999）、tokenizer 文件；上述五文件合计 `65434349` bytes。仍需 `Qwen/Qwen3.5-0.8B-Base@dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68` 的 config/index/权重/tokenizer。基座单个 safetensors 就是 `1746942600` bytes。ggml-org 的 [`.src_sha`](https://huggingface.co/ggml-org/Kev-0.8B-GGUF/blob/e551e319d483ff57e1ff208924b349d397cffc1c/.src_sha) 和 [转换日志](https://huggingface.co/ggml-org/Kev-0.8B-GGUF/blob/e551e319d483ff57e1ff208924b349d397cffc1c/convert.log) 记录该来源；不能只下载 adapter 就标“就绪”。[原文件清单](https://huggingface.co/api/models/jaredpalmer/kev-0.8b/revision/bf75a6a8848ea6960ff2ed108d9ed44c2941174f?blobs=true)、[基座清单](https://huggingface.co/api/models/Qwen/Qwen3.5-0.8B-Base/revision/dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68?blobs=true)
- Laya multilingual 原包固定 `1720e3e3357cfe1e281542e223f8273b0890ca34`：`model.safetensors`、`config.json`、`encoder/config.json`、`rl_agent_config.json`、`tokenizer/tokenizer.json`、`tokenizer/tokenizer_config.json`，合计 `678201774` bytes；不可用普通 AutoModel 的生成接口代替作者的 sequence/head/postprocess。[文件清单](https://huggingface.co/api/models/convaiinnovations/laya-multilingual/revision/1720e3e3357cfe1e281542e223f8273b0890ca34?blobs=true)
- StartLux wrapper 还需同 revision 的 `decision_config.json`、tokenizer 文件与 `startlux_decision` package；prompt、题型温度和宽选项算法在 package 中。[wrapper 源码](https://github.com/StartLuxLabs/StartLux-Decision/blob/c61bfab3bb4fa3ae9d155d457247a7fd0a299a24/startlux_decision/gguf_server.py)
- JevK5 wrapper 固定作者源码 `f26426d16f59e8bbe1470e5b162cc89329e29b29`，v0.3 4B 使用 `temperature=1.22`、`knockout_temperature=0.93`；默认配置可能属于旧 v0.2，不能省略版本绑定。[配置与运行说明](https://huggingface.co/alibiserikbay/JevK5-GGUF/blob/ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a/README.md)

## 引擎与格式边界

**llama.cpp 固定核查源码：`836d57176dc699a726c55418e4f96b8ca628e1bf`（MIT）。** 这不是“任何已安装版本”。[Kev 转换器](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/conversion/lev.py#L151) 检查 adapter/head，合并 LoRA，写入 `decision.type=kev` 和 pointer 输出；[Laya 转换器](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/conversion/bert.py#L678) 写入 ModernBERT decision head 与模板。[server](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L32) 读取 `<architecture>.decision.type`、`systemone` 模板及题型温度；Kev/Laya 的 choice 上限为 255，而 HTTP score 限 2–10 级。Kev 的日期事实预处理尚未移植，不能承诺与原作者所有行为完全相同。[转换器限制](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/conversion/lev.py#L167)

`POST /v1/systemone` 接受 `state` 和 questions map；`choice` 返回选项概率、argmax 和 confidence，`score` 返回期望级别、legend 和概率，`noul` 返回 P(true)，`usage.output_tokens=0`。无 streaming；无效请求 400，非决策模型 501。温度缩放不保证适合用户数据。这些规则只适用于核查的主线实现。[固定版 server 文档](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/README.md#typesafe-compatible-api-endpoints)

必须区分以下资产：

- **ggml-org Kev 是 llama.cpp 决策 GGUF；mys Kev 不是。** `mys/kev-0.8b-GGUF@802386c0ea4f0ea3e559978a245c1ceecab2002a` 明示加载进 llama.cpp 会失败，包含 `ggmlc.decision` 程序。[mys 模型卡](https://huggingface.co/mys/kev-0.8b-GGUF/blob/802386c0ea4f0ea3e559978a245c1ceecab2002a/README.md)
- **当前 llama.cpp 已支持 Laya 决策，不能再笼统称“不支持 Laya”。** `ggml-org/Laya-GGUF@da4b4753d62197659d8c90103cd4c43bef9afea6` 的 Q8 文件 `449397600` bytes，是 **English 根模型**转换；不代表所有 multilingual 转换通用。[转换卡](https://huggingface.co/ggml-org/Laya-GGUF/blob/da4b4753d62197659d8c90103cd4c43bef9afea6/README.md)
- mys multilingual 为 ggmlc 格式；`Weidows/laya-multilingual-GGUF` 是 **encoder-only GGUF + 外置 head safetensors + HF tokenizer**；`meshllm/laya-multilingual-F16-GGUF` 明示依赖其固定 llama.cpp patch queue。三种都不能因后缀一致互换。[Weidows 卡](https://huggingface.co/Weidows/laya-multilingual-GGUF/blob/6235959603bf3d316379404b9130a10b8a406446/README.md)、[MeshLLM 卡](https://huggingface.co/meshllm/laya-multilingual-F16-GGUF/blob/bcc99560232b5a5c91cb14d46b9496acbeae2c43/README.md)
- ggmlc 固定源码 `5490a13661d95add025ec1b111adbc88234a9b4f`，作者提供 Metal 设备选项和 Mac binary；其当前 server 已有 `/v1/systemone`，不应只照旧卡写 `/api/decide`。[server 源码](https://github.com/monatis/ggmlc/blob/5490a13661d95add025ec1b111adbc88234a9b4f/examples/laya/src/server.cpp#L351)

Ollaya 可以作为管理/接口复用的对照：固定源码 `929a0491f18d2f5105941c65e723e0a28c308556` 已有 pull/list/load/stop、typed HTTP 和 `ollaya mcp`，权重绑定 revision 与 sha256；ONNX 模型与 GGUF 模型使用不同 runner，Metal 不代表所有模型都走 GPU。它还已有桌面管理界面，值得先比较重复建设成本，但本报告不替项目选择栈。[作者 README](https://github.com/ollaya-dev/ollaya/blob/929a0491f18d2f5105941c65e723e0a28c308556/README.md)

## 未证实项与验证门槛

2026-10-04 HF 官方 API 搜索 `StarLux-Decision-0.8B`、`JevM5` 无匹配；网页精确名称检索亦未确立作者资产。**StartLux** 是已证实拼写，不能把 JevM5 自动替换成 JevK5；无匹配不等于证明不存在。[StarLux 检索](https://huggingface.co/api/models?search=StarLux-Decision-0.8B)、[JevM5 检索](https://huggingface.co/api/models?search=JevM5)

目录准入至少需要：固定 repo/revision/文件/hash/许可证；完整 head/tokenizer/calibration；能绑定到固定引擎的格式证据；真实 typed 三题型响应和概率归一化；空输入、超长输入、宽选项与错误响应；中文否定/选项顺序/领域样例；目标 Mac 的冷启动、峰值内存和延迟。上游 benchmark、转换 parity 和 Mac 声明均是作者证据，未成为本机验收。委员会只能在已通过这些门槛的模型之间比较，不能用英文模型数量替代中文可用性。
