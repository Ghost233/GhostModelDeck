# 正式官方引擎管理原生验收

2026-10-04，最终 `LlamaEngine` 源 SHA-256 `0418df7bb02aaf483bd8959cda4b1754b4f36cc923e67c37c4fd34eeef51823c`。使用正式 `ModelLibrary`、`ModelUseRegistry` 与 `LlamaEngine` 的应用业务入口；没有以一次性引擎探测替代生产管理验证。

容器全仓 72 项通过（run-Fv23j7），静态分析无问题（run-it3pjZ）。发布目录失败保全、HTTP 下载/full SHA/版本、两提供方共享在用保护、props/概率/进程失败与退出均有公共入口行为覆盖。

## 真实安装与双实例

脚本 `.tooling/implementation/live-official-provider.dart` 读取已保存模型库，实际扫描并全量核验 Kev/Laya 的来源和内容。复用下载时已验证的官方 archive，通过 `install(verifiedArchive: ...)` 正式安装到：

`/Users/ghost233/Library/Application Support/JevManager/engines/llama.cpp`

正式安装耗时 5121 ms，实际 `--version` 为 `0.5.0-dev (build 11381, commit 836d57176)` / Darwin arm64，完整 archive SHA `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341`。每个正式 `start(id)` 都重核验文件、运行自己的子进程、比对实际 `/props`，且严格 typed 概率成功后才返回 ready。

| 模型 | 实际 PID | 独立 endpoint | 加载至 typed ready |
| --- | ---: | --- | ---: |
| Kev Q8 | 86767 | http://127.0.0.1:61386 | 8172 ms |
| Laya Q8 | 86783 | http://127.0.0.1:61432 | 5663 ms |

安装后两个真实实例同时驻留。相同 `DecisionRequest` 并发调用两个正式 `decide`，本次总耗时 26 ms，各调用 24/17 ms；两个原始结果与此前独立探测一致，稳定候选 refund/investigate 的概率分别为 Kev 0.9904589808039479/0.009541019196052226 与 Laya 0.9362442233096444/0.06375577669035551，输入 49/50、生成输出 0。

这只是正式提供方的两次真实请求，脚本没有委员会综合算法；委员会入口在 #16 实现。耗时仅为一次英文规则案例的观察，不称基准、中文质量或委员会收益。

## 在用保护与收尾

每个实例运行时，正式 `prepareDeletion([artifactId])` 都被在用保护拒绝。停止第一实例后，第二模型仍受保护；停止第二实例后，仅生成删除预览成功，没有删除模型。

两个实例最终状态 stopped，`stopManaged` 收尾成功，脚本退出 0。模型实际大小和修改时间前后相同；完整哈希/来源证据记录于 ready 日志。随后对精确 PID 的只读 `ps` 未返回进程；LM Studio `ps --json` 仍为空，既有服务仍 running=true / port1234。

完整业务结果与实际 props：`.tooling/implementation/live-official-provider.jsonl`。

## Mac 构建与桌面验收

正式 release `.app` 已构建成功（44.0 MB），日志 `.tooling/implementation/official-provider-native-build.log`。锁屏只暂停 CUA 按钮验收，后台业务验收与构建照常完成；用户解锁后继续由代理操作。
