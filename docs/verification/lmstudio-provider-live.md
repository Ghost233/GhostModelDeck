# LM Studio 公开接口联调

2026-10-04。此处逐项区分公开 CLI/界面观察、HTTP 认证结果与后续生产业务入口验收。

## 实现前只读观察

- 安装应用公开 bundle 信息：LM Studio `0.4.25+1`；公开 CLI `--version`：commit `69d945a`。两者不是实际实例的 runtime 版本。
- `lms server status --json`：既有服务 running=true、port=1234；`lms ps --json`：空数组。没有停止该既有服务。
- `lms runtime ls`：selected GGUF `llama.cpp-mac-arm64-apple-metal-advsimd@2.50.0`；这是格式默认项，不代表已运行实例的精确版本。
- `lms ls --json` 可见 Kev Q8 和 Laya Q8 的实际相对路径与大小，原始清单位于 `.tooling/implementation/lmstudio-current-models.json`。
- `GET http://127.0.0.1:1234/api/v1/models`：HTTP 401，error.code=invalid_api_key，要求 Bearer token。没有读取凭据、关闭认证或将此结果称为不支持。
- CUA 只读打开正式 LM Studio 的 My Models，底部模型目录明确为 `/Users/ghost233/.lmstudio/models`。该本次观察可支持后续明确关联；程序不能仅从相对路径或默认值推断实际根。既有下载继续运行，未暂停或改动。

以上不证明真实模型已加载、typed 接口可用或 JevManager 实例归属。后续必须通过正式 LmStudioProvider 入口分别记录。

## 真实生产入口发现的兼容性失败

正式 `ModelLibrary.scan` / `verify` 核对完整来源与内容后，`LmStudioProvider.refresh` / `confirmModelLibrary` / `load` 调用公开 CLI 的精确模型路径、新实例标识和 2048 context；没有替换引擎或模型文件。

- Kev：14:12 UTC 首轮加载未确认；在外部 CLI 接缝加入仅该笔退出码/错误的定向探针后，14:15 UTC 重现。真实 load exit=1，错误 `done_getting_tensors: wrong number of tensors; expected 322, got 320`。
- Laya：14:20 UTC 同一生产入口 load exit=1，错误 `check_tensor_dims: tensor 'blk.28.ffn_up.weight' has wrong shape; expected 1024, 5248, got 1024, 4096, 1, 1`。

本轮默认 selected GGUF runtime 为 2.50.0；公开接口没有逐实例 runtime 映射，因此记录为当前默认运行组合，不能据此断言其他 runtime 或 LM Studio 全部不支持。两份文件先前均有正确的上游完整 SHA；加载错误不能替代源内容损坏证据。

两轮随后未发现成功创建的模型实例；Kev 后独立公开 `lms ps --json` 为 `[]`。未到达模型级 typed 概率请求，不能将已观察到的 HTTP 清单认证要求当成这两次加载失败原因，也不能声称模型已经就绪。

原始反馈与定向诊断保存在 `.tooling/implementation/live-lmstudio-provider-first-red.jsonl`、`live-lmstudio-provider-diagnostic.jsonl` 和 `live-lmstudio-laya-diagnostic.jsonl`。

## 最终诊断回归

明确非零 CLI 失败且确认实例不存在时，产品现在保留经脱敏、控制符清理和限长的具体加载错误；超时、不确定实例及清单失败仍采用保守归属和文件保护。公共入口先失败后通过：CLI 诊断 run-ElXf7N → run-3pcRSJ，本地模型变化 run-JF4axZ → run-b8fGmu。最终 **62 项**容器测试通过（run-couZYd），分析无问题（run-pG4oeJ）。最终 provider SHA-256 `90f6a9112bb2699e1da81fc26fe98f282aa0a2bb923461be4926ea4aab390025`。

去掉定向调试插桩后，正式入口分别在 **14:28:28 UTC** 和 **14:28:39 UTC** 重跑，准确保留上述 Kev/Laya 错误，原先模糊消息不再出现。接受负向结果的验收脚本只在特定预期错误、实例清单未变、原模型大小/修改时间未变同时成立时通过；两个终态退出码均为 0。这不表示加载成功或 typed 就绪。原始日志 `.tooling/implementation/live-lmstudio-kev-final.jsonl` 与 `live-lmstudio-laya-final.jsonl`。

最终 release `.app` 构建成功（43.8 MB，`.tooling/implementation/lmstudio-final-native-build.log`）。通过 CUA 实际关联已核对的 LM Studio 目录，选择、核验、加载 Kev，正式页面显示已连接/CLI commit/已关联，以及完整的 `加载失败…expected 322, got 320`，实例列表为空。没有把错误显示为已就绪。CUA 本次管道中断后 reset 恢复，重新获取界面确认结果；未使用其他 UI 控制通道。

后续的[官方引擎探测](official-engine-probe.md)已独立证明固定 b11381 可以加载两份资产并返回合法真实概率；它不等于 LM Studio 支持，也不表示补充引擎已经接入桌面。该接入在 #15 完成。
