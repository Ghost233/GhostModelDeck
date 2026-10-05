# 首期小型标准 LLM 验收模型资产

调查日期：2026-10-05（Asia/Shanghai）。对应 [核实首期小型标准 LLM 验收模型资产](https://github.com/Ghost233/GhostModelDeck/issues/10)。只读 HF 模型卡、API 元数据和少量配置/许可证文本；没有下载权重、扫描用户模型库、安装或运行模型。

## 建议最小 fixture

| 用途 | 发布者仓库与固定 revision | 选定资产 | 精确大小 |
|---|---|---|---:|
| llama.cpp 文本 LLM | [Qwen/Qwen2.5-0.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/9217f5db79a29953eb74d5343926648285ec7e67)，`9217f5db79a29953eb74d5343926648285ec7e67` | `qwen2.5-0.5b-instruct-q4_k_m.gguf`，Q4_K_M 单文件变体 | 491,400,032 B（约 469 MiB） |
| oMLX 文本 LLM | [mlx-community/Qwen2.5-0.5B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/tree/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3)，`a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3` | MLX 4bit、group_size 64；下表完整运行资产集合 | 289,598,797 B（约 276 MiB） |

两仓库 API 均报告 `private=false`、`gated=false`，license 为 `apache-2.0`。两种格式来自同一 Qwen2.5-0.5B 模型家族，适合验证首期模型管理、显式加载与 Chat/SSE；这不证明固定引擎实际兼容、两份量化资产输出一致或质量足以用于日常工作。[GGUF 固定 API](https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/revision/9217f5db79a29953eb74d5343926648285ec7e67?blobs=true)、[MLX 固定 API](https://huggingface.co/api/models/mlx-community/Qwen2.5-0.5B-Instruct-4bit/revision/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3?blobs=true)

## 固定文件清单与完整性

GGUF fixture 只选择 Q4_K_M，不下载同仓库其他量化/FP16。其 LFS SHA256 为 `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`。同 revision 的 `LICENSE`（11,343 B）与 `README.md`（4,856 B）作为许可证/来源证据保留；三项合计 491,416,231 B。模型卡建议直接使用单个 GGUF 文件；所选名称不是分片名，仓库清单也没有该变体的其他分片或 projector。真正的 GGUF 结构、嵌入 tokenizer/template 与 tensor 完整性仍需下载后解析验证。[固定模型卡](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/9217f5db79a29953eb74d5343926648285ec7e67/README.md)、[固定文件 API](https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/revision/9217f5db79a29953eb74d5343926648285ec7e67?blobs=true)

MLX fixture 保留全部九项运行资产，不裁剪可能用于 tokenizer fallback 的文件；不声称每次加载都会读取每一项。下表来自固定 revision 的 API，Git blob ID 用于追踪非 LFS 文件，**不是裸文件 SHA256**。

| 文件 | 字节 | HF 内容身份 |
|---|---:|---|
| `model.safetensors` | 278,064,920 | LFS SHA256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153` |
| `config.json` | 783 | Git blob `e3c0e76e4e54c951f36d49e3042347b58382136e` |
| `model.safetensors.index.json` | 44,209 | Git blob `8831428421e282132532f717fcaba43f8c7f5445` |
| `tokenizer.json` | 7,031,673 | Git blob `d24314ef7f0afd1b678c2e24c767e19f24f86b0e` |
| `tokenizer_config.json` | 7,308 | Git blob `482ccbc1096b0e9400e86e33f189681c2aebdab9` |
| `special_tokens_map.json` | 613 | Git blob `ac23c0aaa2434523c494330aeb79c58395378103` |
| `added_tokens.json` | 605 | Git blob `482ced4679301bf287ebb310bdd1790eb4514232` |
| `vocab.json` | 2,776,833 | Git blob `4783fe10ac3adce15ac8f358ef5462739852c569` |
| `merges.txt` | 1,671,853 | Git blob `31349551d90c7606f325fe0f11bbb8bd5fa0d7c7` |

另保留该 revision 的 `README.md`（748 B）作来源证据；`.gitattributes` 属仓库存储配置，未列入运行资产。`model.safetensors.index.json` 的 628 个 tensor 映射只引用 `model.safetensors`，没有待补齐的权重分片；其 `metadata.total_size=277996288` 是 tensor 数据量，不等于上表文件长度。[固定索引](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/blob/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3/model.safetensors.index.json)

本次实际读取的小文件裸内容 SHA256：`config.json` 为 `b045e57ea90b8f1b35f89f954b176a5c1faa02bd0af2c89bcec191239d66cef4`；索引为 `54001cb4c11197119c206dde28e7be08e5872aab6c6d271aed339ec77e84f870`；`tokenizer_config.json` 为 `f7c61e32b7a17d19bf8e7037dcb74079a833e53ea9801f24008cac68458f03b7`。权重 SHA256 来自 LFS 元数据，尚未通过本机权重字节重算验证。

## 模型来源、许可证与模板

- **来源差异保留：** GGUF 的 `base_model` 指向 `Qwen/Qwen2.5-0.5B-Instruct`。MLX 模型卡正文称从该 Instruct 模型、使用 mlx-lm 0.18.1 转换，但 YAML `base_model` 写的是 `Qwen/Qwen2.5-0.5B` 预训练模型。两模型卡没有固定转换输入权重 revision，不能声称已证实使用同一批输入权重；MLX 是 community 发布的转换资产。[固定 MLX 模型卡](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/blob/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3/README.md)
- **许可证证据：** GGUF 仓库自带 LICENSE；MLX 仓库没有 LICENSE 文件，其 license_link 指向 Qwen Instruct。此次把该上游许可证证据固定在 revision `7ae557604adf67be50417f59c2c2f167def9a775`：11,343 B，SHA256 `832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e`。[固定上游 LICENSE](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/7ae557604adf67be50417f59c2c2f167def9a775/LICENSE)。此 revision 是许可证证据位置，不是已证实的转换输入 revision。
- **MLX 配置/模板：** `model_type=qwen2`、`architectures=[Qwen2ForCausalLM]`、4bit/group_size 64；tokenizer 配置具有使用 `<|im_start|>`/`<|im_end|>` 的 Jinja chat template 和 `add_generation_prompt` 分支。按 JSON 解码后的模板 UTF-8 字节计算 SHA256 为 `d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4`。[固定配置](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/blob/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3/config.json)、[固定 tokenizer 配置](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/blob/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3/tokenizer_config.json)
- **GGUF 模板证据限制：** 固定仓库 API 的 `gguf.chat_template` 同样计算出上述模板哈希，但其 `gguf.totalFileSize=1266425696` 对应仓库 FP16 文件，并非选定 Q4_K_M 长度；因此这是仓库级模板证据，不能代替选定文件嵌入字段验证。API 报告 context_length 8192，而模型卡/MLX 配置写 32768；首期小上下文验收不要据此承诺整个宣称窗口。[固定 GGUF API](https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/revision/9217f5db79a29953eb74d5343926648285ec7e67?blobs=true)

## 后续真实验收条件

主线程已只读核验目标机为 M5 Pro/64GB arm64、macOS 27.0.1，Flutter 3.47.6/Dart 3.13.5、Xcode 27.0。研究引擎基线为 llama.cpp `v0.5.0/7fe450e19305b828c199d602c23a8337aaa1f03b` 与 oMLX `v0.7.0/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40`；启动器 SDK 基线 `bc7262f4`。这些环境信息不等于本 fixture 已运行通过。

授权实际验收时，下载必须指定上述模型仓库完整 revision，核对文件清单、长度、权重 LFS SHA256，并为其余实际下载字节建立 SHA256 清单；保留模型卡/许可证证据。解析选定 GGUF 的 tokenizer/template/tensor 结构，验证 MLX 索引引用文件和 tokenizer 配套完整，再用固定引擎在本机真正加载。可先以小上下文与短输出验证非空文本 Chat、合法 SSE 增量/终止、明确模型身份、显式启动/卸载、未启用拒绝及断网启动；不要求两量化格式逐字回答一致。下载大小也不等于推理内存峰值。

当前未验证：本机权重哈希、GGUF 内嵌模板、固定引擎/系统组合加载与生成、峰值内存、并发/取消/回收及实际 API 路由行为。JEV 回归继续使用来源已实际验证的 Kev/Laya 与官方 b11381，不在本次重新研究或下载。元数据已足够固定这组小型验收候选，实际兼容性必须由上述真实验收确认。
