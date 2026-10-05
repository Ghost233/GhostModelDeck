# LM Studio 下载、共享目录与引擎集成证据

核查日期：2026-10-04。作为首版模型管理需求的补充；引擎尚未选定。本轮没有扫描用户模型目录、修改软件设置、调用本地服务、启动引擎或下载权重。模型资产的固定 revision 与兼容性见 [模型研究](./model-runtime-evidence.md)。

## 三种证据应分开

1. **公开受支持接口**：LM Studio 官方文档明确提供 CLI、原生 REST API、runtime 管理、模型目录设置和 HF 下载。
2. **本机小文件实测**：观测到 LM Studio 官方域名上的 HF proxy 路径，仓库清单与 README 可访问，内容与 HF 直连一致。
3. **尚无文档保证**：未确立该 proxy 是可供第三方长期依赖的公开下载 API；未验证大文件、Range/续传、鉴权、速率限制、LM Studio 的 decision 接口及实际运行能力。

## 已确认的官方管理接口

| 需求 | 一手事实 | 对 JevManager 的含义 |
|---|---|---|
| 使用现有 LM Studio 下载能力 | `lms get` 接受模型名和 HF 完整 URL，下载进入 LM Studio 当前模型目录；`--gguf`、`--mlx` 可限制格式 | 可以设计“交给 LM Studio 下载”的路径，但下载成功仍需对照固定资产 manifest 验证。[CLI get](https://lmstudio.ai/docs/cli/local-models/get) |
| 下载任务状态 | LM Studio 0.4.0 起原生 v1 REST：`POST /api/v1/models/download`、`GET /api/v1/models/download/status`；下载请求公开字段为 `model`、可选 `quantization` | 公开请求没有单独的 `revision`、任意输出目录或 proxy selector 字段；不得假设这些都能由该 API 控制。[下载 API](https://lmstudio.ai/docs/developer/rest/download)、[API 总览](https://lmstudio.ai/docs/developer/rest) |
| 自定义/共享目录 | My Models 可改变模型目录；默认布局为 `~/.lmstudio/models/<publisher>/<repo>/<file.gguf>` | 用户选同一根目录有公开依据；共享文件不要求共享执行引擎。不要由默认路径推断用户当前实际路径。[目录设置](https://lmstudio.ai/docs/app/basics/download-model)、[导入布局](https://lmstudio.ai/docs/app/advanced/import-model) |
| 已有模型识别 | `lms ls --json` / `--detailed`；REST `GET /api/v1/models` 含 key、publisher、architecture、format、quantization、size_bytes、loaded_instances 等 | 可以用于 LM Studio 侧清单对账；它没有公开“decision head 完整”或“systemone 可用”标志。[CLI ls](https://lmstudio.ai/docs/cli/local-models/ls)、[REST list](https://lmstudio.ai/docs/developer/rest/list) |
| 引擎管理 | `lms runtime ls/get/select/remove/update`；选择具体 runtime 版本。官方 CLI 源码按模型格式记录 engine name/version 与 selection | 关联 LM Studio 时应经其公开 CLI/SDK，记录 provider 与精确 engine version；不能把捆绑 runtime 直接当独立 `llama-server` 启动。[runtime 文档](https://lmstudio.ai/docs/cli/runtime/runtime)、[固定源码 list](https://github.com/lmstudio-ai/lms/blob/1b7181be21f1e898e0ac32b197d04eed6c2cf06d/src/subcommands/runtime/list.ts)、[select](https://github.com/lmstudio-ai/lms/blob/1b7181be21f1e898e0ac32b197d04eed6c2cf06d/src/subcommands/runtime/select.ts) |

源码快照：`lmstudio-ai/lms@1b7181be21f1e898e0ac32b197d04eed6c2cf06d`，package version `0.4.0`；这不是用户已安装版本。[package.json](https://github.com/lmstudio-ai/lms/blob/1b7181be21f1e898e0ac32b197d04eed6c2cf06d/package.json)。CLI `import` 默认 **移动** 文件，也提供 copy/hard-link/symbolic-link/dry-run；共用现有目录的第一步应直接建立清单，不默认导入、迁移或复制。[import 文档](https://lmstudio.ai/docs/cli/local-models/import)

## “LM Studio 代理”确有对应功能

官方 **0.3.9 Build 2** 发布说明加入 “Use LM Studio's Hugging Face proxy”，用途是改善不能直接访问 HF 的情形；当时入口为 App Settings > Developer。不能将旧发布说明中的位置当作当前安装版 UI 的保证。[官方发布说明](https://lmstudio.ai/blog/lmstudio-v0.3.9)

官方 bug tracker 的用户原始错误日志记录了 `https://search.lmstudio.ai/v1/hf-proxy/api/models/.../tree/main`；这是公开的使用观察，**不是维护者发布的稳定协议说明**。[原始 issue #1770](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1770)

本机在 **2026-10-03 19:44:38 UTC（2026-10-04 03:44:38 CST）** 进行三个无鉴权、有限长度 GET：

| 请求 | 结果 |
|---|---|
| [官方域名 proxy 的固定 Kev revision 文件清单](https://search.lmstudio.ai/v1/hf-proxy/api/models/ggml-org/Kev-0.8B-GGUF/tree/e551e319d483ff57e1ff208924b349d397cffc1c?recursive=true&expand=false) | HTTP 200；998 bytes；JSON |
| [同 proxy 的固定 revision README](https://search.lmstudio.ai/v1/hf-proxy/ggml-org/Kev-0.8B-GGUF/resolve/e551e319d483ff57e1ff208924b349d397cffc1c/README.md) | HTTP 200；558 bytes；text/plain |
| [HF 直连的同一 README](https://huggingface.co/ggml-org/Kev-0.8B-GGUF/resolve/e551e319d483ff57e1ff208924b349d397cffc1c/README.md) | HTTP 200；558 bytes；与 proxy 内容 SHA-256 相同 |

两个 README 的 SHA-256：`1edd1ad2f02ec011ff1d82da6ba14b406dd2517817302b32a38485d149a7e4d3`。**未请求 GGUF 或任何权重。** 这足以证明源不是虚构且小文件通路在核查时可用，不能证明第三方产品可永久复用、下载吞吐、Range、续传或 LFS/Xet 大对象表现。

产品可以保留“LM Studio 代理”下载源选项的需求，并显示证据/验收状态；在公开契约和大文件验收完成前，不应称“正式支持的稳定镜像”。另一条可评估路径是交由 LM Studio 自己下载并使用它的 proxy 设置；本轮未验证该路径的程序化控制与固定 revision 保真。无需用户再提供名称或 URL。

## 模型识别必须检查内容，不能只认文件名

以下为从一手格式与源码推导的目录准入方案，尚未实现或运行验证：

- 用户明确选择模型根目录；记录真实文件路径、size、格式和 manifest 来源，不由 `Kev`、`merged`、`GGUF` 字样认定可运行。LM Studio 列表作为旁证，不能替代文件完整性和 head 校验。
- llama.cpp decision GGUF 检查 `general.architecture`、`<architecture>.decision.type`、`tokenizer.chat_template.systemone` 与题型温度；Laya 还需要 decision block/head 参数。Kev 转换器将 pointer q/k 输出写入 classifier；普通 Qwen 架构相同也可能没有这些内容。[decision metadata 读取](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/common/common.cpp#L1203)、[server 初始化](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L32)、[Kev 转换](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/conversion/lev.py#L173)
- `ggmlc.decision` 与 llama.cpp decision metadata 属不同格式。原始 adapter/head、encoder-only GGUF + 外置 head、完整 llama.cpp GGUF 分别需要不同 manifest；缺失必要配套文件时标“资产不完整”。[ggmlc recipe](https://github.com/monatis/ggmlc/blob/5490a13661d95add025ec1b111adbc88234a9b4f/examples/laya/README.md)、[encoder/head 分拆实例](https://huggingface.co/Weidows/laya-multilingual-GGUF/blob/6235959603bf3d316379404b9130a10b8a406446/README.md)
- metadata 和 tensor 布局只能表明“已识别候选”。最终就绪还需将实际文件与固定 revision/hash 对账，并通过选定引擎的 typed 请求验证；不同量化或 head/tokenizer 不能因显示名称一致合并成同一个资产。

## 引擎选择仍需能力证据

| 备选 | 已有证据 | 尚未确立 |
|---|---|---|
| LM Studio 默认/内置 runtime | 官方支持加载、卸载、格式/版本选择、聊天/embedding API | 此次官方 API 清单中未找到 `/v1/systemone`，也未验证 decision graph/head；不能从“基于 llama.cpp”推导主线新增 endpoint 已移植 |
| 自己管理官方 llama.cpp 主线 | 固定源码 `836d57176dc699a726c55418e4f96b8ca628e1bf` 有 Kev/Laya typed endpoint | 待选择包含该功能的确切发行构建、macOS arm64 binary/hash，并在目标 Mac 验收 |
| ggmlc / 作者 wrapper / Ollaya | 对特定资产已有 Metal 或 typed API/MCP 一手证据，详见模型报告 | 不是通用 GGUF 互换保证；各模型与引擎组合仍需单独验收 |

后续探测应记录实际 executable/provider、版本和监听地址；对已确认兼容模型发送同一组 `choice/score/noul`，校验 answers map、完整概率、归一化和 `output_tokens=0`，并验证 400/404/501 等实际错误行为。主线 llama.cpp 对非决策模型返回 501；LM Studio 的错误契约必须实测，不可套用。原生 LM Studio 的 MCP 功能是让本地聊天模型调用工具，也不能证明它能把 decision 引擎作为 MCP 服务暴露。[LM Studio API 清单](https://lmstudio.ai/docs/developer/rest)、[主线 typed API](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/README.md#typesafe-compatible-api-endpoints)

本轮结论止于研究；大权重下载与续传、目录扫描、实际启动、中文质量与资源占用均留待后续工单。
