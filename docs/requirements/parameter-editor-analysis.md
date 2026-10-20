# 参数编辑界面分析

## 范围与依据

2026-10-20，用户要求本版本同时改进 llama.cpp 和 Splash 的参数编辑，先分析 LM Studio 截图。用户进一步明确：Splash 主要使用当前自定义版本，面向用户的可调参数均须通过配置界面完成设置，用户无需手填已知 CLI 参数。折叠高级区同样使用可视化控件。

本文记录截图分析和当前源码事实。生成默认值的作用范围与保存后的生效时机已由用户确认，见 [ADR 0010](../adr/0010-instance-generation-defaults.md)。drafter 已确认的决定见 [ADR 0009](../adr/0009-explicit-drafter-configuration.md)。用户已选择 A 方案，正式实施见 [参数编辑规格](parameter-editor-spec.md)。本文不是已完成实施或验收的证明。

Splash 的事实来源是本机 `/Users/ghost233/Ghost233Code/GhostSplash` 自定义版本。llama.cpp 已核对本机 b11146、b11381 和 b11457 的帮助与固定提交源码。当前分析只读取源码和帮助，没有启动或停止模型服务。

## 截图中的编辑方式

| 参数类型 | 截图示例 | 对应控件 |
| --- | --- | --- |
| 连续数值 | 温度、Top P、Min P、草稿概率阈值 | 同步的滑块和数值输入框 |
| 整数 | Top K、CPU 线程、草稿长度 | 整数输入框；适合时增加步进和滑块 |
| 可选参数 | 响应长度限制、重复惩罚、存在惩罚 | 启用控件与数值分开，按状态显示关联项 |
| 固定枚举 | 上下文溢出策略 | 下拉选择 |
| 字符串列表 | 停止字符串 | 可添加、移除的列表 |
| 结构化对象 | JSON Schema | 格式选择与有校验的对象编辑器 |
| 模型资源 | 草稿模型 | 本地选择、清除和兼容性状态 |

设置、采样、结构化输出和投机解码分别折叠。数值、启用状态和不可用原因直接可见。截图中的数值不作为 GMD 的引擎默认值或参数范围。

截图中的对话笔记属于会话内容。保存预设属于参数组合管理。它们与单项参数控件分别评估。

## 改造前 GMD 的缺口（分析基线）

- `lib/engine_launch_configuration.dart` 只有 llama.cpp 的 6 个基础启动表单项和 Splash 的 4 项，未覆盖完整可调参数。
- `lib/engine_launch_editor.dart` 与 `lib/model_run_dialog.dart` 的基础表单统一生成普通文本框。枚举、布尔值、资源路径和列表缺少对应控件。
- `lib/chat_protocol.dart` 的 `TextRequest.messages` 只表达生成长度、温度和 Top P。生成长度被限制为 1～4096，默认发送 32。
- `lib/public_gateway.dart` 的公开 Chat 请求白名单拒绝 Top K、Min P、惩罚、停止字符串和结构化输出等字段。
- `lib/llm_playground_page.dart` 的表单只有少量数字项。其 JSON 编辑器通过同一个公开网关提交，请求同样受白名单限制。

界面和请求适配需要同时补齐。启动配置负责模型与运行资源，生成配置负责每次请求使用的参数。GMD 内部处理不同引擎的字段与传输方式，用户通过配置界面操作。

## 自定义 Splash 的启动与运行参数

`server/serve_options.py` 的共享声明包含 40 项选项。下表列出全部共享声明，以及单独声明的基础启动字段。实际默认值和联动约束须同时核对 Python 与原生实现。

| 分组 | 参数 | 控件与主要约束 |
| --- | --- | --- |
| 网络 | `host` | 字符串；当前 GMD 管理监听地址 |
| 网络 | `allowed-host`、`allowed-origin` | 可增删列表；origin 支持 `*` |
| 网络 | `api-key` | 掩码输入；当前 GMD 尚未管理该字段 |
| 网络 | `no-webui` | 开关 |
| 内存 | `max-memory` | 自动或正整数与 K/M/G 单位；仅降低原生自动预算 |
| 上下文 | `max-context` | 自动或正整数，可选 K 单位；Python 范围至 262144，仅降低自动容量 |
| 缓存格式 | `kv-format` | `int8`、`bf16`、`q4h`、`q4_0`、`q4_0_unrotated` 选择 |
| 状态格式 | `state-format` | `fp32`、`bf16` 选择 |
| 空闲释放 | `idle-release` | 关闭或正时长与 s/m/h 单位；原生默认 10 分钟 |
| SSD 缓存 | `max-cache-disk` | 自动、关闭或容量输入 |
| SSD 缓存 | `max-cache-disk-writes` | 不限或每日写入容量 |
| SSD 缓存 | `persistent-cache` | 开关 |
| SSD 缓存 | `cache-dir` | 目录；启用持久缓存时，当前 GMD 分配自己的运行缓存目录 |
| 模型标识 | `served-model-name` | 模型别名列表，当前 GMD 管理 |
| 模型标识 | `announce-served-name` | 开关，依赖模型别名 |
| 思考默认值 | `default-reasoning-effort` | `none`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max` 选择 |
| 思考预算 | `thinking-token-budget` | 非负整数或继承原生默认来源 |
| 思考结束文字 | `thinking-end-text` | 字符串；分词后须为 1～64 个 token |
| 请求限制 | `max-request-size` | 正容量；默认 128 MiB |
| 图像限制 | `max-image-pixels` | 65536～4194304 整数 |
| 请求限制 | `request-timeout` | 不限或正时长与 s/m/h 单位 |
| 请求限制 | `queue-size` | 正整数；默认 32 |
| 调度 | `decode-share` | 非负有限数；原生默认 0.5 |
| ANE | `disable-ane` | 开关 |
| ANE | `ane-ffn-share` | 自动或 0～1 数值；0 表示关闭 |
| ANE | `ane-ffn-minimum-rows` | 整数；Python 与实际原生编译上限共同约束 |
| ANE 功耗恢复 | `ane-power-recovery` | 开关 |
| ANE 功耗参考 | `ane-power-reference` | 关闭、自动或正瓦数 |
| ANE 功耗恢复 | `ane-recovery-idle-watts` | 非负有限数；默认 0.05 W |
| ANE 功耗恢复 | `ane-recovery-max-power-percent` | 0～100；设置后覆盖绝对瓦数阈值 |
| 提示查找 | `prompt-lookup` | 开关 |
| 提示查找 | `prompt-lookup-min-match` | 2、3、4 选择 |
| 草稿优化 | `compact-draft-head` | 开关；需要草稿模型与 ranking 文件 |
| 草稿优化 | `compact-draft-capacity` | 512～98304，且为 256 的倍数 |
| 草稿优化 | `compact-draft-ranking` | 本地文件选择；检查原生格式与词表匹配 |
| 编码器 | `encoder-submit-batch-size` | 1、2、4 选择 |
| 编码器 | `encoder-option-queries` | 开关；按模型用途显示适用性 |
| 通用采样优化 | `fast-topk` | 开关；实际快速路径要求 Top K 为 1～32 且 Min P 为 0 |
| 电源 | `allow-idle-sleep` | 开关 |
| 基础启动字段 | `MODEL_DIRECTORY`、`tokenizer`、`model`、`binary`、`port` | GMD 管理的运行资源和身份，显示归属与状态 |

来源：`GhostSplash/server/serve_options.py:348` 的 `ServeOption` 与 `:375` 的选项集合，`GhostSplash/server/server.py:1642` 的基础启动字段。

联动约束包括：compact 开启须提供 ranking；ANE 最小行数依赖 FFN share；功耗恢复百分比依赖有效功耗参考；缓存目录依赖持久缓存；持久缓存和每日写入预算不能配合关闭磁盘缓存。表单应直接解释这些关系。

ANE 行数的 Python 上限是 8192，原生还受编译期 `SPLASH_PREFILL_TOKEN_BUDGET` 约束，源码默认是 2048。界面不能把 Python 范围直接当作当前二进制能力。分析时 GMD 还显式传入 `default-reasoning-effort=none`，默认值来源需要在配置中准确表达。

## 自定义 Splash 的生成参数

以下参数由请求传入或作为请求默认值保存。原生 HTTP 与启动 CLI 的差异由 GMD 适配。

| 分组 | 参数 | 控件与主要约束 |
| --- | --- | --- |
| 采样 | `temperature` | 滑块和数值框；0～2，原生默认 1 |
| 采样 | `top_p` | 启用状态、滑块和数值框；正数至 1，默认 0.95 |
| 采样 | `top_k` | 整数输入；0 或 -1 关闭，原生默认 20 |
| 采样 | `min_p` | 启用状态、滑块和数值框；0～1，原生默认 0 |
| 惩罚 | `repetition_penalty` | 启用状态和正有限数；原生默认 1 |
| 惩罚 | `presence_penalty`、`frequency_penalty` | 启用状态、滑块和数值框；-2～2，默认 0 |
| 随机性 | `seed` | 随机或整数输入；保留原生 64 位语义 |
| 停止 | `stop` | 最多 4 个非空停止字符串的列表 |
| 停止 | `ignore_eos` | 开关；与部分结构化和工具约束互斥 |
| 输出长度 | `max_completion_tokens`、`max_tokens` | 限制开关和正整数；省略时按剩余上下文决定 |
| 思考 | `reasoning_effort` | 继承或原生枚举选择 |
| 思考 | `thinking_token_budget` | 继承、不限或非负整数 |
| 思考 | `preserve_thinking` | 继承或布尔选择 |
| 思考 | `chat_template_kwargs.enable_thinking` | 继承或布尔选择 |
| 模板 | `chat_template_kwargs` | 对象编辑器；已知键提供控件，其余键按模板与保留键规则检查 |
| 结构化输出 | `response_format` | 文本、JSON 对象、JSON Schema 选择；Schema 提供有校验的编辑器 |
| 调度 | `priority` | 前台、普通、后台选择 |
| 调度 | `timeout` | 继承或正秒数；不能超过服务预算 |
| 缓存隔离 | `cache_salt` | 共享缓存或非空隔离标识 |

来源：`GhostSplash/server/frontend.py:74`、`:499`、`:616`、`:882`、`:1085` 和 `:1138`；结构化输出规则位于 `GhostSplash/server/tool_schema.py:829`。

`model/messages`、多模态内容、工具定义、流传输选项和 Responses 会话字段属于协议载荷，不能混同为普通模型调优字段。当前 Splash 只允许 `n=1`，不支持开启 logprobs 或非空 logit_bias，界面不能显示虚假的可启用状态。

## 引擎差异与界面事实

- llama.cpp 的重复惩罚字段为 `repeat_penalty`，Splash 为 `repetition_penalty`。GMD 需要适配字段名。
- llama.cpp 可通过启动参数设置部分生成默认值，Splash 的采样项通过 HTTP 请求传入。用户界面都应支持直接配置。
- 当前自定义 Splash 的超长 prompt 会报错。它没有 LM Studio 截图中的可选中间截断或消息裁剪策略。若要增加跨引擎统一策略，需要另行决定处理层和行为。
- Splash 草稿长度遵循编译执行约定，没有通用运行时最大和最小草稿长度参数。
- Splash 已提供草稿生成数、接受数和循环次数等聚合统计。公开输出没有逐 token 的接受或拒绝标记，不能用聚合数量推导截图中的逐 token 着色。
- `ServeOption` 已含参数名、分组、类型、枚举、默认来源和帮助信息，可用于构建已知参数清单与基础控件。中文文案、软件管理归属、模型适用性、联动关系和原生编译约束仍需补充。

## 已确认的产品行为

用户确认生成设置按实例保存默认值，测试场和 HTTP 单次请求的显式值优先于实例默认值，实例默认值优先于引擎默认值。运行中保存生成默认值后，从下一次请求生效。模型加载和 drafter 资源配置继续在下一次启动生效。

用户明确 Splash 的启动与运行配置按当前自定义版本已有 CLI 参数提供，本次不追加 CLI 未提供的统一上下文裁剪或中间截断行为。生成设置仍由现有原生请求接口应用，CLI 和 HTTP 的差异由 GMD 内部处理。
