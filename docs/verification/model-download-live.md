# macOS 真实模型资产下载验收

日期：2026-10-04。对应 spec #10 的下载部分与 ticket #12；本文不表示完整规格、GUI 流程或推理验收完成。

## 范围与入口

用户已为当前任务授权 Mac 桌面和引擎的真实集成例外。使用已有原生构建解析的 package config 与 `/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart`（3.13.5 stable，macos_arm64），执行 `.tooling/implementation/live-download.dart`。该脚本直接调用生产 `HfModelBrowser.selectRepository` / `setFileSelected` 和 `ModelDownloader.download`；真实公网 HTTP、真实文件系统、生产暂存与安装记录参与验收。没有本机 unit/widget 测试、依赖安装或替代 curl 下载器。

每次浏览在线 API 的固定 commit，校验清单，再选择单个文件；没有下载全仓库或多个精度。用户已在工作流选定并保存的正式模型库为 `/Users/ghost233/.lmstudio/models`。下载操作取得此目录快照。既有共享资产不被覆盖、移动或删除，LM Studio 与其既有实例保持运行；本段验收不启动模型、不训练。

## HF 权重下载

运行时间：08:34:33–08:55:45Z（本地 16:34:33–16:55:45）。实际 Dart PID `14444`，工具运行 session `36567`，最终退出码 **0**。日志 `/private/tmp/jevmanager-live-direct.jsonl` 每 10 秒输出生产状态、当前文件和字节数。

**Kev 与 Laya 均完成实际安装、生产完整性校验和独立读回哈希。**

| 所选资产 | 固定 revision | 上游 bytes / SHA-256 | 状态 |
|---|---|---|---|
| `ggml-org/Kev-0.8B-GGUF/Kev-0.8B-Q8_0.gguf` | `e551e319d483ff57e1ff208924b349d397cffc1c` | `812406304` / `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0` | 完整安装与读回校验通过 |
| `ggml-org/Laya-GGUF/Laya-Q8_0.gguf` | `da4b4753d62197659d8c90103cd4c43bef9afea6` | `449397600` / `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2` | 完整安装与读回校验通过 |

Laya 是官方英文根模型，与 multilingual 资产不同。两行数据由本次线上生产浏览入口再次确认；不能由资产文件名推断兼容、中文效果或推理就绪。

Kev 08:47:22Z 完整接收后进入 `verifying`，08:47:26Z 进入 `installed`，08:47:31Z 独立读取正式文件，再次确认 bytes 与上述完整 SHA-256。正式文件与安装记录如下：

```text
/Users/ghost233/.lmstudio/models/ggml-org/Kev-0.8B-GGUF/Kev-0.8B-Q8_0.gguf
/Users/ghost233/.lmstudio/models/.jevmanager/installations/79ebf77092328c2d617e3734bb38aa0357c626872a319acdbd5c031771c4ab8c.json
```

Laya 08:47:32Z 开始实际传输，08:55:39Z 完整接收后进入 `verifying`，08:55:42Z 进入 `installed`，08:55:45Z 独立读取正式文件，再次确认 bytes 与上述完整 SHA-256。正式文件与安装记录如下：

```text
/Users/ghost233/.lmstudio/models/ggml-org/Laya-GGUF/Laya-Q8_0.gguf
/Users/ghost233/.lmstudio/models/.jevmanager/installations/4fcf558bf6849e98fac8c04f2454ddf437f1afc15a3a5578c6c7bdd2cd86e9b5.json
```

两份记录均含 `version:1`、各自固定 commit、`source:hf`、`sourceEndpoint:https://huggingface.co`、`license:apache-2.0`、实际 bytes/sha256 与 `upstreamVerified:true`。每份记录只含所选 Q8 文件；两份暂存 stage 已由生产安装流程删除。整个顺序下载没有失败或中断，两个正式权重共 **1,261,803,904 bytes**。

## HF 与 LM Studio 代理的小文件对照

固定文件 `ggml-org/Kev-0.8B-GGUF@e551e319d483ff57e1ff208924b349d397cffc1c/README.md`，线上 API 标明普通 Git blob `047436a6ea21fbd2ee5b3215b13d6109ba442fcf`、558 bytes。

两次均从在线 HF API 构造相同生产选择，通过 `ModelDownloader` 分别使用 `hf` 与 `lmStudio` 来源，得到 `downloading → verifying → installed`。生产下载器验证 Git blob；脚本再从正式安装文件读回 SHA-256：

```text
558 bytes
SHA256 1edd1ad2f02ec011ff1d82da6ba14b406dd2517817302b32a38485d149a7e4d3
installationId 3d9245865af0428fc7f2a28954dfc958cf65d09d7475f6829f97b3af9d4c26b0
```

| 来源 | 独立临时模型库 | 实际时间 UTC | 结果日志 |
|---|---|---|---|
| HF `https://huggingface.co` | `/private/tmp/jevmanager-hf-small.H3NfGZ` | 08:35:58–08:35:59 | `/private/tmp/jevmanager-live-hf-small.jsonl` |
| LM Studio `https://search.lmstudio.ai/v1/hf-proxy/` | `/private/tmp/jevmanager-proxy-small.ymlMpe` | 08:34:54–08:34:55 | `/private/tmp/jevmanager-live-proxy-small.jsonl` |

每个模型库都有 `.jevmanager/installations/<installationId>.json`，记录各自真实来源端点、固定 commit、bytes、本地哈希和 `upstreamVerified:true`。小文件只是文件安装，不能作为完整模型或大权重能力证明。

## 代理大权重与真实 Range

另选全新临时模型库 `/private/tmp/jevmanager-proxy-range.40YLcw`，通过生产入口请求相同固定 Kev Q8 权重；没有借用正式库文件、伪造 HTTP 服务或预置片段。

08:35:29–08:35:34Z 的实际序列：

1. 第一次生产下载收到 **1,056,659 bytes** 后调用公开 `cancel()`；状态 `cancelled`，片段保留，没有正式安装记录。
2. 暂存 `download.json` 记录 `acceptsRanges:true`、`totalBytes:812406304`，以及强 ETag `"d2e820c01921392617be89e0b254095d85c6a8c4570c67da6a32c7cf44dbcb8d"`。
3. 第二次生产 `download()` 读取相同暂存身份与真实偏移。生产 `_receive` 自动发 `Range: bytes=1056659-` 和该 ETag 的 `If-Range`；只有 HTTP 206、相同 ETag、Content-Range 的起点/总长和内容长度校验通过后才继续写入。
4. 总片段增长到 **3,154,110 bytes** 后再次公开取消。实际新增 **2,097,451 bytes**；未发生 `restartRequired` 或 `failed`。脚本输出 `acceptedResume:true`，退出码 0。

日志：`/private/tmp/jevmanager-live-proxy-range.jsonl`。保留文件：

```text
/private/tmp/jevmanager-proxy-range.40YLcw/.jevmanager/downloads/79ebf77092328c2d617e3734bb38aa0357c626872a319acdbd5c031771c4ab8c/files/Kev-0.8B-Q8_0.gguf.part
```

这验证了当前网络下代理对真实 812 MB 权重请求提供传输与生产续传条件。**没有通过代理下载完整权重或校验其最终哈希，不能称代理完整大权重安装通过。** 片段仍是暂存资产，不能被扫描或加载为模型安装。

## 复现

使用已有 Mac 集成构建解析好的 `.dart_tool/package_config.json`，从仓库执行；正式目录须为用户已选定的模型库，临时来源验证使用新目录：

```sh
/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart \
  --packages=.dart_tool/package_config.json \
  .tooling/implementation/live-download.dart direct \
  /Users/ghost233/.lmstudio/models
```

其他模式为 `hf-small`、`proxy-small`、`proxy-range`。`direct` 在已有同 ID 安装记录时会由生产入口拒绝覆盖记录；不要为了重复验收删除共享安装或自动重新下载。

## 剩余验收

本页已完成两份 HF 权重的真实下载、安装标记与独立读回哈希，HF/代理固定小文件对照，以及代理真实大权重的取消/Range 续传。代理完整大权重安装与最终哈希仍未执行。

页面目录选择/持久化、真实 GUI 按钮/进度、扫描发现、推理加载、typed decision 与委员会并发均由对应后续验收给出，不能由本页代替。

2026-10-05 后续：[代理完整模型包验收](proxy-package-live.md) 使用当前模型包入口向全新空目录完整传输 Laya Q8_0 并独立全量校验，补齐本页当时尚未执行的代理完整安装限制。本文原始单文件操作与旧 GUI 记录保留为历史证据，当前操作以模型包和变体为入口。
