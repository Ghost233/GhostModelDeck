# 标准 LLM：llama.cpp 与 oMLX 运行契约证据

调查日期：2026-10-05（Asia/Shanghai）。对应 [核实 llama.cpp 与 oMLX 的标准 LLM 运行契约](https://github.com/Ghost233/GhostModelDeck/issues/2)。

范围：首期标准 LLM 的模型管理与本地 API 服务；保留 JEV 专用能力。OCR、生图、生视频及其他引擎后续适配不在本调查内。本文只提供决策证据，不锁定安装、打包、默认并发或版本策略；没有安装引擎、下载模型或在 Mac 上运行验收。

## 可复核研究基线

| 引擎 | 官方发布与不可变源码 | macOS arm64 运行依据 |
|---|---|---|
| llama.cpp | [v0.5.0 发布](https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0)，[7fe450e19305b828c199d602c23a8337aaa1f03b](https://github.com/ggml-org/llama.cpp/commit/7fe450e19305b828c199d602c23a8337aaa1f03b) | 原生 `llama-server`；CMake 构建，macOS 默认启用 Metal。[构建文档](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/docs/build.md) |
| oMLX | [v0.7.0 发布](https://github.com/jundot/omlx/releases/tag/v0.7.0)，[4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40](https://github.com/jundot/omlx/commit/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40) | 官方要求 Apple Silicon、macOS 15+、Python 3.11–3.13；提供 DMG、Homebrew、源码安装及前台 `omlx serve`。[固定 README](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/README.md) |

这些是本次研究候选，不是首期已决定的实施版本。oMLX 此版本固定 `mlx==0.32.2` 和 `mlx-lm@94cdcae13b266c337bcaca09b97b9c5a9c0e2cde`，但其他依赖仍有范围约束；固定 oMLX 源码不等于已经固定整个运行环境。[依赖声明](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/pyproject.toml#L41)

## 已核实的官方契约

| 关注点 | llama.cpp | oMLX |
|---|---|---|
| 加载单位 | 指定本地 GGUF 的单模型进程；也提供多模型 router 模式 | 指定模型目录的进程，内部发现并管理多个 MLX 模型 |
| 加载与卸载 | 单模型路径可随进程启动/退出；router 专有 `/models/load`、`/models/unload`，不能套到单模型模式 | 管理 API：`POST /v1/models/{model_id}/load`、`.../unload`；加载请求等待完成，卸载会停止该模型的引擎 |
| 模型身份 | `GET /v1/models`；单模型时是一项，支持显式 `--alias` | 普通本地目录以模型文件夹名称注册；`GET /v1/models` 列 API 身份，`GET /v1/models/status` 提供加载状态与路径 |
| 就绪 | 单模型 `/health`：加载中 503，就绪 200；需同时核对模型身份 | `/health` 在启动 pinned 预加载期间 503，完成后 healthy；仍需核对目标模型 `loaded`、`is_loading` 和路径 |
| 文本 chat | `POST /v1/chat/completions`，非流式与流式 | 相同 chat 路径，非流式与 SSE；流式含结束标记及预填充 keepalive |
| 并发与回收 | server slots 与 continuous batching；停止进程与睡眠/router 卸载是不同生命周期 | 可配置并发、LRU 与 TTL；自动回收避开使用中的模型，手动卸载不同于自动回收 |

llama.cpp 表内依据：[固定 server 文档](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/README.md)、[router 路由仅在对应模式注册](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/server.cpp#L187)。文档明确不保证完整 OpenAI 规范一致，chat 效果还取决于受支持的 chat template。router 或睡眠模式下不能直接沿用单模型 `/health` 的就绪解释。

oMLX 表内依据：[本地目录身份](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/model_discovery.py#L1729)、[健康检查](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L2895)、[管理加载/卸载](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L3463)、[chat 路由与流式实现](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L3997)。管理端点与推理端点使用不同认证依赖，不能假定某个推理凭据也有管理权限。

**状态细节：** oMLX `list_models` 的注释虽写有 load status，实际 [ModelInfo](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/api/openai_models.py#L523) 没有 `loaded` 字段；加载状态来自 [EnginePool.get_status](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L3926)，应通过 `/v1/models/status` 读取。`/health` 为 healthy、模型出现在 `/v1/models`，均不能单独证明指定模型已经加载。

oMLX [自动 LRU](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L2486) 跳过 pinned/活动模型，[TTL](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L4003) 也跳过活动模型。管理卸载走 [立即停止与内存回收等待](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L2954)；不能解释为保证完成在途请求。停止服务会 [关闭整个模型池](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L3899)。这些源码意图尚不构成真实 Mac 回收时间或内存上限保证。

## 模型包完整性

- **GGUF 官方事实：** 分片加载器从 `split.count` 读取分片数、按分片命名构建路径并加载其余文件；不能把某个分片当成完整模型包。[加载器](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/src/llama-model-loader.cpp#L595)；chat 层读取模型提供的模板或显式覆盖模板。[模板来源](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/common/chat.cpp#L767)
- **MLX 官方事实：** 对应 mlx-lm 加载模型配置、`model*.safetensors` 权重和 tokenizer；tokenizer 可能依赖 JSON、SentencePiece、tiktoken、文本及 Jinja 等文件，不能只下载 safetensors。[模型加载](https://github.com/ml-explore/mlx-lm/blob/94cdcae13b266c337bcaca09b97b9c5a9c0e2cde/mlx_lm/utils.py#L444)、[tokenizer 文件模式](https://github.com/ml-explore/mlx-lm/blob/94cdcae13b266c337bcaca09b97b9c5a9c0e2cde/mlx_lm/utils.py#L586)。oMLX 有缺失编号权重分片检测，但这不是所有配置、tokenizer、资产哈希的完整校验。[发现检查](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/model_discovery.py#L1121)
- **实施推论：** HF 模型安装记录应固定仓库 revision、选定变体及所需文件清单/完整性；本地导入还应记录真实路径与文件身份。引擎支持的架构、量化和 chat template 必须分别验证。模型名称、目录名或格式后缀不足以证明兼容性；GGUF 与 MLX 应是各自可验证的模型资产，不能假设两者能直接互换。

## 安装与外部关联边界：待人决定

官方已提供可选运行方式：llama.cpp 原生 binary/source；oMLX DMG、Homebrew、源码环境。前台 `omlx serve` 支持独立 `--base-path`；`--max-concurrent-requests` 文档默认 8。[CLI 参数](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/cli.py#L1213)、[数据目录参数](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/cli.py#L1338)。官方 `omlx start/stop` 会管理 app 或 Homebrew 服务。[运行说明](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/README.md)

实施推论：受管实例可由 GhostModelDeck 启动明确路径的进程，使用独立数据目录与 loopback 端口，并记录进程归属；接入实例只连接用户提供的地址、凭据与模型身份，停止接入不应变成停止别人的进程。安装/更新引擎、共享现有 oMLX 服务、单模型与 router 模式、并发默认值及管理卸载权限都留给对应 HITL 决策。API 模型 ID 与“HF revision + 文件身份”的模型安装 ID 应建立映射，不能混用。

## 最小真实验证门槛（尚未执行）

1. 在一台目标 macOS arm64 机器记录 OS、芯片、RAM、引擎完整 revision/build 信息及运行环境；为两引擎各选一个固定 HF revision 的小型文本模型包，核验全部必要文件。记录安装方式，保持本地资产推理路径可在断网时启动。
2. 启动受管实例：验证加载期间、就绪、模型身份不符、端口被占用与进程异常退出。oMLX 再验证发现但未加载、加载失败和手动卸载后状态；不得用 `/health` 或模型列表代替模型就绪。
3. 对实际 API 模型 ID 发送同一简单文本 chat，分别验证非流式与 `stream:true` 的增量、终止、错误和客户端断开后的资源释放；记录原始 HTTP/SSE 与服务日志。每个引擎都验证错误模型/请求的真实响应，不要求它们返回相同错误格式。
4. 在选定内存预算下至少发两个重叠请求，观察并发/排队行为；停止、卸载、重载后验证模型状态、端口/PID、活动内存与后续生成。持久 KV 磁盘缓存与模型资产应独立记录，内存回收不等于删除它们。
5. 若验收包含 Codex 等具体外部客户端，另做该客户端的真实请求验证。chat 成功不能证明 Responses、tool calling、JSON schema、认证与全部客户端行为兼容；这些能力只按实际选定范围逐项宣称。

待证实项：实际部署包可复现性、最低可用 OS/机器组合、选定模型架构及模板、内存峰值与卸载耗时、断开/卸载并发行为、真实外部客户端兼容性。本研究只能关闭“官方契约调查”，不能关闭这些实现验收或替人选择生命周期方案。
