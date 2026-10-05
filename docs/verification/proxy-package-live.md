# LM Studio 代理完整模型包验收

2026-10-05，在用户授权的 Mac 原生下载联调范围内，使用当前生产 `HfModelBrowser.selectRepository` → `ModelPackage.discover` / `selectVariant` → `ModelDownloader.downloadPackage(source: DownloadSource.lmStudio)` 完成一次全新完整模型包传输。此前 [下载验收](model-download-live.md) 留下的“代理完整大权重及最终哈希未执行”限制，已由本次 Laya Q8_0 实测补齐。

## 结果与来源

本次进程 PID **41622**、工具 session **79473**，实际执行时间 **05:06:23.111–05:07:42.012 UTC**（北京时间 13:06:23–13:07:42），完整脚本耗时 **78,914 ms**，终态退出码 **0**。

| 项目 | 实际证据 |
| --- | --- |
| 仓库 / 变体 | `ggml-org/Laya-GGUF` / `GGUF:Laya-Q8_0` |
| 固定 revision | `da4b4753d62197659d8c90103cd4c43bef9afea6` |
| 元数据来源 | 在线生产 HF 浏览入口 `https://huggingface.co`，`metadataOrigin:online` |
| 下载来源端点 | `https://search.lmstudio.ai/v1/hf-proxy/`，`source:lmStudio` |
| 请求 URL | `https://search.lmstudio.ai/v1/hf-proxy/ggml-org/Laya-GGUF/resolve/da4b4753d62197659d8c90103cd4c43bef9afea6/Laya-Q8_0.gguf` |
| 完整必要文件集合 | 包解析为 `resolved`，仅 `Laya-Q8_0.gguf`；未选择 BF16、README 或全仓库 |
| 上游 / 实际 bytes | **449,397,600 / 449,397,600** |
| 上游 / 独立读回 SHA-256 | `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2`，一致 |
| 实际状态 | `verifying` → `downloading` → `verifying` → `installed` |
| 是否复用 | **否**；新建空目录，`freshEmptyRoot:true`、`sawTransport:true`、`reusedExisting:false` |
| 许可证 | 在线元数据及安装记录 `apache-2.0` |

05:07:36.821Z 完整接收后进入生产校验，05:07:39.427Z 安装完成；脚本随后从正式安装文件重新打开流，读取全部内容并与在线固定 metadata 和安装记录逐项比较。独立全量读回耗时 **2,582 ms**，在 05:07:42.011Z 通过。

结束前再用系统 `shasum -a 256` 独立读取同一正式临时文件，返回上述完整 SHA，命令退出码 **0**；helper 格式检查 `dart format --output=none --set-exit-if-changed` 也为退出码 **0**。

传输期间还保留了生产 `download.json` 回执：`totalBytes:449397600`、`acceptsRanges:true`，强 ETag 为 `"acb12df5d1292bef427034193bd085547f6feea44e29c5599d3584dff9a2543b"`。本轮一次完整接收，没有中断或恢复；真实取消/Range 续传由此前 [下载验收](model-download-live.md#代理大权重与真实-range) 的 Kev 片段证据提供。回执只记录代理入口、版本与响应条件；本轮没有额外采集 HTTP 重定向后的最终 CDN 主机或原始响应状态码。

## 保留的模型包与记录

新建临时模型库为 `/private/tmp/jevmanager-proxy-package-LZwiXP`。它与共享库独立，没有预置、复制、软链接或借用已下载权重。

正式安装文件：

```text
/private/tmp/jevmanager-proxy-package-LZwiXP/ggml-org/Laya-GGUF/Laya-Q8_0.gguf
```

正式安装记录：

```text
/private/tmp/jevmanager-proxy-package-LZwiXP/.jevmanager/installations/4fcf558bf6849e98fac8c04f2454ddf437f1afc15a3a5578c6c7bdd2cd86e9b5.json
```

记录为 `version:1`，含上述固定 revision、`source:lmStudio`、精确代理端点、完整文件集合、实际 bytes / SHA、相同 `upstreamSha256`、`isLfs:true` 与 `upstreamVerified:true`。安装成功后生产入口移除了自己的暂存 stage；正式临时模型包及安装记录继续保留供复查，没有自动删除模型。

仓库内证据：

- 脚本：[proxy-package-live.dart](../../.tooling/implementation/proxy-package-live.dart)
- 完整状态、在线元数据、独立读回及安装记录日志：[proxy-package-live.jsonl](../../.tooling/implementation/proxy-package-live.jsonl)
- 传输中复制保存的原始生产回执：[proxy-package-response.jsonl](../../.tooling/implementation/proxy-package-response.jsonl)

## 复现与检查范围

使用已解析的 `.dart_tool/package_config.json` 和既有 Mac Dart 3.13.5：

```sh
/Users/ghost233/dart/bin/dart \
  --packages=.dart_tool/package_config.json \
  .tooling/implementation/proxy-package-live.dart \
  > .tooling/implementation/proxy-package-live.jsonl 2>&1
```

脚本每次创建新的 `/private/tmp/jevmanager-proxy-package-*` 空目录，固定版本与必要文件清单验证成功后才调用生产下载器；11 分钟截止通过公开 `cancel()` 取消自己的任务并保存恢复片段，失败会返回非零退出码。本轮未到截止。

本次仅新增验收 helper 与证据，未改生产 `lib`、`test`、依赖、Git 或工单。helper 经过 Dart 格式化，真实执行编译及全链路通过；不运行容器或 Mac unit/widget 测试。没有触及 `/Users/ghost233/.lmstudio/models` 的任何文件或设置，没有停止 LM Studio，没有启动推理或训练。本结果证明当前网络下该固定 Laya 变体的完整代理传输、生产安装与全量哈希；它不是 Mac GUI 点击、其他模型/格式代理能力、推理就绪或委员会/MCP 的证据。
