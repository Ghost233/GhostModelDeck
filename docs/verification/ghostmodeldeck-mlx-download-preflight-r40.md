# 固定 MLX 包实际下载失败与 HTTP 重定向诊断

日期：2026-10-06（Asia/Shanghai）。对应首期资产准备，不是 #16 或 #19 通过报告。此处记录**实际失败**，不把研究元数据或诊断字节当作完成安装。

## 实际生产入口结果

使用生产 `HfModelBrowser → ModelPackage → ModelDownloader`，正常 HF 联网，固定 `mlx-community/Qwen2.5-0.5B-Instruct-4bit@a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`，选择 indexed Safetensors 变体。新的自有临时库为 `/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-real-mlx-r40-BobJGc`，不修改用户模型或来源项目。

任务 `bash-256` 已收集，exit **1**，2.429 秒；metadata origin 为 online。取得 `added_tokens.json` 与 `config.json`，累计 1,388 B，随后在 `merges.txt` 失败：**`来源返回了压缩内容，无法验证文件字节`**。状态 failed、installation_id=null。没有下载完整权重或九项包，没有扫描通过，没有引擎加载/Ready。生产校验未放宽，失败记录保留。

原始记录：`.tooling/gmd-live-mlx-assets-r40.{dart,log,json}`。选择时为八项元数据文件，下载器应在读取索引后展开权重；本次在索引之前失败，不能把选择时 total=11,533,877 B 当完整九项资产总量。

## 两条实际 HTTP 路径与固定内容身份

只读诊断使用相同固定 `merges.txt` URL，`HttpClient.autoUncompress=false`：

| 路径 | 请求策略 | 最终响应 | wire / 解码字节 |
| --- | --- | --- | --- |
| 与生产相同的自动重定向 | 初始 `Accept-Encoding: identity` | 200、gzip、CloudFront hit | 716,838 / 1,671,853 |
| 有界手动重定向 | 每跳都重设 identity | 307 → 200，未编码 | 1,671,853 / 1,671,853 |

两者解码后 SHA256 均为 `8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5`，Git blob 均为冻结清单的 `31349551d90c7606f325fe0f11bbb8bd5fa0d7c7`。诊断中的 gzip 解码**没有接入下载器或写入其暂存文件**，不作为绕过生产验证的安装。

固定 Dart SDK 的 `/Users/ghost233/flutter/bin/cache/dart-sdk/lib/_http/http_impl.dart:2308-2311` 为每次新请求预设 `Accept-Encoding: gzip`；`:3091-3116` 自动重定向复制旧头时仅复制新请求中不存在的头。因此初始 identity 不覆盖重定向新请求的已有 gzip。这与两条实际网络结果一致，原因定位到重定向请求头处理；本次不是 pub get/DNS 故障，也不是已证明的 oMLX 模型不兼容。未改 SDK、网络配置或产品代码。

后续修复须从公开下载业务重现：真实 loopback 307 与按实际 Accept-Encoding 压缩的 final response，然后最小实现每跳 identity；保持有界跳数、取消、Range/If-Range、固定 commit、长度、Git blob/SHA 校验和残留保护。不能仅去掉压缩拒绝、自动解压后沿用压缩 Range 字节语义，或靠改模型 revision 避开。修复后重跑完整固定九项资产下载/扫描及正式联网检查。

## 分开完成的模型卡/许可证准备

四项固定证据正常 HTTPS 下载成功，并独立重算 SHA256：

- MLX README：748 B，`8cd48183a9d10279e02291f12f03a2db5585c222a0cf77f97dca3c87f79bd5e1`。
- MLX 上游 LICENSE：11,343 B，`832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e`；许可证固定 revision `7ae557604adf67be50417f59c2c2f167def9a775` 不代表已证实的转换输入 revision。
- GGUF README：4,856 B，`fa1fede7f775a20f111cc098c00900092020572ce78976970a5b0ad9ca211999`。
- GGUF LICENSE：11,343 B，同上许可证摘要。

证据位于独立临时目录 `/private/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-fixture-legal-r40-soq__qpo`。固定 URL、实际路径、完整原始结果见[冻结 JSON](ghostmodeldeck-mlx-download-preflight-r40.json)。来源差异及资产清单继续以[fixture 研究](../research/acceptance-model-fixtures.md)为准。许可证取得不是本工具作出的法律结论或分发授权。

## 记录与检查边界

确定性 curator 对账实际失败字段、两条 HTTP 内容身份，并再次读取四份法律证据字节验证长度/摘要，exit0；冻结 JSON 保留三份原始结果和其摘要。仅新增这两份证明文档；没有修改 implementer 的 runtime/chat/tests，也没有占用其 SERIAL 容器。Dart/Flutter 完整检查不因此重跑，当前实现子代理仍在执行 SSE 最终联网检查。此报告不关闭任何工单，不宣称模型兼容、Ready 或 Release 验收。
