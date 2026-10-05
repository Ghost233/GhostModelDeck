# #14 模型包切片验证

## 范围与事实变化

本切片基于 main `6f2567fb7d736c267d3a0b6e62b7c8ed0d39798d`，使用已有公开业务入口，不建立第二套模型管理、不增加依赖、模型调用或测试专用业务入口。不修改旧源、用户模型资产、主题或导航；#13 迁入记录保持冻结。此报告不代表整份规格完成，也不关闭工单。

- [模型库](../../lib/model_library.dart)：普通 Safetensors 的扫描闭包补齐 `special_tokens_map.json`、`added_tokens.json`、`vocab.json`、`merges.txt` 等 tokenizer 资产，并纳入存在的 `generation_config.json`、`vocab.txt`、`tokenizer.model`、`chat_template.jinja`。文本/二进制 companion 不按 JSON 解析。收据检查过的全部文件现在回传到 `LibraryArtifact.files`，使 verify、删除预览、确认后删除及 in-use 检查使用相同闭包；GGUF 旁路 companion 也不再丢失。
- [HF 浏览器](../../lib/hf_model_browser.dart) → [远端包](../../lib/model_package.dart)：公开 `selectRepository` 获取固定 commit 的真实 `config.json` 字节；以清单大小和有则校验的 SHA256/Git blob hash 验证后解析整型 `quantization.bits/group_size`。只读取有限数量、大小受限的 native 配置，JEV 专用配置路径不变。配置缺失、损坏、哈希不符或字段无效时不伪造量化信息。单组配置证据显示 `4bit · group 64`，仓库名称含 mlx/4bit 不是证据；原文件名量化 token 仍仅作展示标签。
- [本地包](../../lib/local_model_package.dart)：使用扫描得到的配置量化信息；无索引多组资产不共用一个未经确认的量化标签。没有改成自动合并混精度。
- [模型库](../../lib/model_library.dart)：普通 GGUF chat 需要自身非空 `tokenizer.chat_template`；`tokenizer.chat_template.systemone` 不能替代它。JEV decision 的 SystemOne/choice/score/noul 温度、Pointer/scorer tensor 检查保持原路径。
- 既有 revision、GGUF 分片、`weight_map` 解析、无覆盖安装、Range/ETag、取消、来源记录、删除确认及多 owner in-use 机制复用，未重写 [下载器](../../lib/model_downloader.dart)。
- 接管审阅补齐了收据身份隔离：共享 config/tokenizer 不能单独匹配另一个模型的收据。以实际结构识别出的全部核心权重路径锚定收据，且不依赖权重文件后缀；再展开该模型的文件闭包。公开扫描/删除预览用例先复现 B 资产错误包含 A 权重（[红灯日志](../../.tooling/container-tests/run-PfTf27/result.log)，exit 1），修复后库/包 25 项全部通过（[绿灯日志](../../.tooling/container-tests/run-y33cU5/result.log)，exit 0），两个索引变体共享配置仍各自只管理自己的权重；取消删除后都保留。

## Fixture 来源与证据边界

固定真实模型清单来源为 [验收模型调查](../research/acceptance-model-fixtures.md)：MLX `mlx-community/Qwen2.5-0.5B-Instruct-4bit`，revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`；GGUF `Qwen/Qwen2.5-0.5B-Instruct-GGUF`，revision `9217f5db79a29953eb74d5343926648285ec7e67`。本切片没有下载完整真实模型，后续 #19 汇总执行。

[固定配置 fixture](../../test/fixtures/hf_mlx_qwen2_config_a5339a4.json) 为该 MLX 固定 revision 的真实 config 字节：[公开固定来源](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/resolve/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3/config.json)。783 B，SHA256 `b045e57ea90b8f1b35f89f954b176a5c1faa02bd0af2c89bcec191239d66cef4`；测试锁定这两个值。`bits=4/group_size=64` 来自配置，而不是仓库名。测试另用 Git blob hash 检验取得的配置，并证明错误 blob、字符串 bits、无 quantization 时不显示配置量化标签。

[九资产 I/O fixture](../../test/fixtures/mlx_package.dart) 是按固定清单文件角色构造的微型结构性 Safetensors + index + tokenizer 文档：

```text
model.safetensors
config.json
model.safetensors.index.json
tokenizer.json
tokenizer_config.json
special_tokens_map.json
added_tokens.json
vocab.json
merges.txt
```

它的权重只有一个 F32 tensor，不是真实 Qwen 4bit 权重；config 中 4bit 是包元数据场景，不是实际 tensor 精度验证。测试对这些 fixture 的真实字节逐文件生成大小/SHA256，用真实 loopback HTTP、真实临时目录和公开业务入口驱动，不替换包解析/下载/扫描/校验/删除业务逻辑。GGUF 使用既有 [结构 fixture](../../test/fixtures/decision_gguf.dart)，ordinary-template 测试也构造实际 GGUF 字节。它们只能证明本切片的 I/O、结构/来源/完整闭包管理，不证明真实模型质量、完整 Qwen 架构 tensor、引擎兼容、真实 HF/代理网络可用性或时延。

## 公开红 → 绿用例

业务入口为 `HfModelBrowser.selectRepository`、`ModelPackage.discover`、`selectVariant`、`ModelDownloader.downloadPackage`、`ModelLibrary.scan/verify/prepareDeletion/delete(confirmed: ...)`、`ModelUseRegistry.update` 及 `LocalModelPackages.discover`，复用 [包测试](../../test/model_package_test.dart)、[浏览器测试](../../test/hf_model_browser_test.dart)、[库测试](../../test/model_library_test.dart)。

| 切片 | 首次红灯 | 最小修复后绿灯 |
| --- | --- | --- |
| MLX 九资产下载 → scan → verify | [run-v9j2Hy](../../.tooling/container-tests/run-v9j2Hy/result.log)，exit 1：下载九项但 scan 只回传五项 | [run-ENWeH0](../../.tooling/container-tests/run-ENWeH0/result.log)，exit 0；删除/损坏扩展 [run-16DIeU](../../.tooling/container-tests/run-16DIeU/result.log)，exit 0 |
| 普通 GGUF 嵌入 template 与 SystemOne 区分 | [run-und5G4](../../.tooling/container-tests/run-und5G4/result.log)，exit 1：缺普通 template 仍 complete | 最终全量回归包含该 ordinary-template 用例，见下方权威检查 |
| 固定 config 量化证据 | [run-9vbOcU](../../.tooling/container-tests/run-9vbOcU/result.log)，exit 1：实际 null | [run-OoLMzK](../../.tooling/container-tests/run-OoLMzK/result.log)，exit 0；真实 config fixture/错误 blob 后续组合 [run-SfcU9h](../../.tooling/container-tests/run-SfcU9h/result.log)，exit 0 |
| 本地包也显示实际 config 量化 | [run-Z4oS0T](../../.tooling/container-tests/run-Z4oS0T/result.log)，exit 1：期望 `Safetensors · 4bit · group 64`，实际 `Safetensors · 变体 1` | 后续 [run-SfcU9h](../../.tooling/container-tests/run-SfcU9h/result.log)，exit 0 |
| 收据中 GGUF companion 的 verify/delete 闭包 | [run-KdgFS5](../../.tooling/container-tests/run-KdgFS5/result.log)，exit 1：2 项收据只回传1项 | [run-SfcU9h](../../.tooling/container-tests/run-SfcU9h/result.log)，exit 0 |

### 已通过的失败/保护路径

- 公共九资产测试：固定索引仅下载引用的权重，不下载旁置 `unused-Q8.safetensors`；每项实际大小/SHA256、收据文件集合与扫描集合一致。架构未核验仍 `unknown`，引擎仍 `awaitingVerification`。
- `verify` 发现同长度 vocab 内容损坏；删除 merges 后不保留伪造的上游来源验证。删除预览列出九项并精确统计字节；取消确认不删文件。两个 owner 持有共享 vocab，逐个释放，最后释放前一直阻止整个闭包删除。GGUF 外置 template 也参与同样保护及最终删除。
- 同一个 `downloadPackage` 入口覆盖 missing HTTP404、等长度权重 SHA256 错误、截断 HTTP 断网、现有 companion 冲突、index 引用不存在的权重、无索引混精度拒绝。前五项没有发布权重或成功收据，已有用户 sentinel 和冲突正式文件内容保留；混精度在任何 HTTP 请求前拒绝。[组合日志](../../.tooling/container-tests/run-RxNj4u/result.log)：34 tests，exit 0。
- 取消后真实 `.part` 前缀保留且无正式权重；关闭并重建 downloader 从同一包恢复，发送实际 `Range`/`If-Range`，接受匹配的 `206 Content-Range`/ETag，最终累计字节等于九项实际总和，完整九项收据保留 `source=lmStudio` 和固定 revision，scan 完整来源验证通过。[日志](../../.tooling/container-tests/run-u5Ie1u/result.log)，exit 0。初版 fixture 忘记 `Accept-Ranges: bytes`，被既有实现正确判为 `restartRequired`，见 [run-NFcSqL](../../.tooling/container-tests/run-NFcSqL/result.log)，exit 1；修正的是 HTTP fixture，不是绕过续传保护。
- 原 JEV、GGUF 分片/量化、index、无覆盖/复用、删除/in-use 等既有测试纳入全量回归；不能将回归通过解释为真实模型兼容验收完成。

## 完整性、格式与 Ready 边界

格式是实际文件结构/扩展与现有扫描证据；量化标签是文件名提示或已校验 config 元数据，不等于权重逐 tensor 精度鉴定，更不等于引擎 Ready。收据证明固定来源、文件集合、大小和哈希；普通 native `config.json` 即使存在且可解析，架构必要 tensor 尚未核验仍 `unknown`。普通 GGUF 自身 template 的检查与 JEV SystemOne 分开，均不绕过引擎实际加载。正式资产扫描不搬迁、不覆盖；下载冲突拒绝。删除必须走显式确认，并对完整文件闭包实施多 owner in-use 保护。

## 权威检查与未执行项

使用用户指定独立容器 `ghostmodeldeck-checks-r24b`，docker context `socktainer`，串行运行原脚本；未创建、删除、重启容器。源码经本机 Dart format 后，以容器检查为权威。

保存的终端原始日志包含 Flutter 进度行尾随空格，按字节原样保留；Git 空白检查对源码、测试、Markdown 与 JSON 执行，仅排除本目录下的原始 `.log` 证据，不放宽 Dart 格式/静态检查。

子代理异常退出后，主线程实际读取其最后三份日志（run-t5NNqn、run-wo5rIb、run-Obo2S3，均 exit 0，161 项测试），没有把进度消息当作最终报告。随后公开回归发现共享 companion 错配收据、扩大权重删除范围的风险，按红 → 绿修复，并重新运行全部权威检查：

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| format | 55 文件、0 改动，exit 0 | [日志](ghostmodeldeck-model-packages-logs/format.log)；run-3u9kOD |
| analyze | No issues found，exit 0 | [日志](ghostmodeldeck-model-packages-logs/analyze.log)；run-GJYbDP |
| 完整测试 | 162 项全部通过，exit 0 | [日志](ghostmodeldeck-model-packages-logs/test.log)；run-STlF4O |
| Mac Release | 实际构建成功，46.2 MB，exit 0 | [日志](ghostmodeldeck-model-packages-logs/macos-release.log) |
| 真实 HF MLX 元数据/配置 | 固定 revision 在线取得，4bit/group64，Safetensors indexed 可下载变体，exit 0 | [原始记录](ghostmodeldeck-mlx-metadata-preflight.json) |

真实元数据检查通过生产 `HfModelBrowser.selectRepository` 和 `ModelPackage.discover`，固定 revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`，不是替代 curl 查询；还未下载索引所引用的完整权重，不能把 indexed 选择列表八项误报为已安装九项。

未执行：真实固定 GGUF/MLX 完整权重下载及真实权重 hash 核验、真实 HF/LM Studio proxy 完整传输、真实引擎加载/Chat/SSE/Ready、输出质量、新构建原生交互和人工删除 UI 交互；归后续对应切片/#19，不用 I/O fixture、元数据查询或 Release 构建代替。此次没有修改 UI。
