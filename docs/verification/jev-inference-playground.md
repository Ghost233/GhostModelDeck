# #36 JEV 推理测试场验证

日期：2026-10-08（Asia/Shanghai）。规格：[提供 JEV 推理测试场 #36](https://github.com/Ghost233/GhostModelDeck/issues/36)，父项 [#32](https://github.com/Ghost233/GhostModelDeck/issues/32)。固定阶段基线为 `6359dc14be4d426874ed83e30a65492a8140efce`；按普通 merge 核对 `codex/jev-protocol-playground`，结果为 Already up to date。本文不构成 #37 的真实模型、Mac 窗口或实际外部客户端验收。

## 实施与输入边界

[生产页面](../../lib/jev_playground_page.dart)由 [main](../../lib/main.dart) 传入现有 CouncilController、PublicGatewayServer 与 CouncilMcpServer。[测试场 adapter](../../lib/jev_playground.dart) 原生路径使用所选实例的受管 `decideBatch`；HTTP 使用当前 gateway URI，MCP 使用真实 SDK 客户端连接当前 endpoint。三种入口复用原有运行图，不启动或下载模型、切换实例、复制权重或创建第二套委员会计算。

完整 JSON 是唯一请求文档。表单只修改所编辑字段；复杂值保留并通过 JSON 编辑。模式切换、debug、模型选择与 JSON 编辑共享同一文档；无效原文保留，删除 model 不补默认值，未知调用名由实际本机协议返回错误。原生 alias、固定原生调用名和委员会名称分别表达。原生选择固定实例和 generation，入场再验证当前 Ready 快照及本次题型能力。

发送预览对应真实发送 JSON：原生只剥离应用 debug，保留实际 alias；HTTP/MCP 保留完整协议请求。默认输出为本次原生完整结果或实际收到的标准业务 JSON。debug 来自本次 DecisionIOTrace 或实际收到的协议 debug，保留来源、入场配置、实际请求与完整原始响应、转换结果及耗时；委员会包含各席和完整总结果。不读取共享 lastResult。展示和复制统一经 `sealDebugJson` 深冻结、脱敏，原始实际输入不因展示脱敏而被改写。

## 本机 HTTP 调用归属

Dart 非流式 HttpResponse 的 `done` 不保证客户端 FIN/RST 后立即完成。原始并发用例 `run-ompsBj` 失败；仅对测试场自有 socket 设置 SO_LINGER 的实验 `run-TWhGX9` 仍在 2.995 秒、接近 hard 的 3 秒业务截止时才排空。macOS 同样在 1 秒内仍有 `[2, 1]` 活动许可，原始实验真实退出码为 255。这些失败不记为主动取消通过；未保留 reset 实现。

[Gateway](../../lib/public_gateway.dart) 现在由现有 `_inflight` 归属生成 `PublicJevRequestLease`，在客户端连接前登记。一个不可构造的 lease 对象只控制本次调用；随机不透明 ID 通过专用 header 与一次真实 POST `/v1/systemone` 关联。未知、已释放、重复或错误使用的句柄明确拒绝；未带该 header 的外部请求保持原路径。没有新 HTTP 端点，也没有第二套业务管理。

测试场取消先取消自身 lease，再关闭自己的 HTTP 客户端，并等待 lease 排空。完成后的取消不能改变已完成业务结果；未连接、失败、部分请求体、页面离开/销毁和关闭服务时的登记也可释放。原始推理仍真实经过 HTTP 解析、命名模型解析、业务控制和协议返回。主动断连没有收到业务 JSON 时明确显示客户端取消、debug 不可用，不从服务器共享结果补出响应。

这一主动取消边界适用于拥有该 lease 的应用内调用。普通外部 HTTP 客户端只断连时仍沿用业务预算内排空的既有边界，不能据此宣称外部 HTTP FIN/RST 已实现立即取消。MCP 使用实际 SDK abort；默认 60 秒工具超时被禁用，业务预算由既有配置控制，并依次释放自身 session/transport/client。

## 公开验证

仅替换外部引擎进程/HTTP、必要文件与 Clipboard 平台 I/O；controller、models、LlamaEngine、gateway、MCP server/SDK client 和生产页面均为真实实现。

- 原生及真实 HTTP/MCP：quick、hard、固定原生名；choice/score/noul 混合批量；对象/数组/scalar、images null/空数组、noul criteria 省略/nullable、题 ID 顺序、confidence 与实际用量。
- 本次 default/debug、原生完整额外字段、配置入场快照、Loading→Ready 的同一 generation、深不可变投影、原生错误状态与 raw/debug 中的凭据脱敏。
- 缺少/未知 model、无效 JSON、能力不足、未 Ready、绑定歧义、单席/部分/零成功、实际业务错误与超时、发现。
- 三入口主动取消：取消的许可在业务截止前排空，另一个真实待决调用保持待决并随后成功；晚到不改变已返回或新请求结果，监听器和驻留实例保持运行。
- HTTP 登记前/连接/部分 body 的竞态，缺失/未知/重复句柄，完成后取消，错误及未连接 lease 的关闭清理；使用实际重复 HTTP 回复建立 partial-body 附着屏障，不使用 fake 协议 handler。
- 实际页面 A 成功→B 取消→C 成功、可选择/复制本次 JSON、三入口导航离开和销毁时排空自身许可及登记。
- 实际页面 900×560、预留生产侧栏 188、内容 647×502，dark/light 与文字缩放 1.0/1.5，包含编辑切换、长 JSON、预览、结果/debug/复制和错误状态可达性，无布局异常。使用 Noto CJK 字体；这属于 Flutter widget 渲染验证。

## P2 补充审查修正

初次实施候选 `91b793b63b79db9dafe33c8b47fa94af1add714f` 的双轴审查均为 0；文档补记候选 `bc6b5095ee91f0121bcdc005b3207ffc84af99ea` 随后的 Spec 补充审查确认 1 项 P2：通用 sealer 把合法题/候选 ID `api_key`、`authorization`、`cookie` 当作凭据字段，并从合法 score legend `Authorization: allow` 错误收集 secret，破坏标准输出、debug 和页面复制。该后续发现修正了此前的零发现结论，没有删除初审历史。

修正限于共享 `sealDebugJson` 的上下文投影。JEV 标识字典的 key 与明确的任务/描述、概率、legend、委员会 aggregate/votes 等数据分别保留，不凭标识名称或合法描述收集 secret；完整 raw JSON 先按结构处理，不再对原始整段 JSON 再做无上下文正则扫描。真实配置、headers/诊断/error 文本及未知凭据 extras 继续识别并脱敏，已知 secret 的回显仍隐藏；原始实际输入和 raw 文本格式不因展示投影被改写。保护 answer ID 不会把整个 answer 对象的凭据 extras 一并豁免。

公开红用例 `run-iCIvZY` 证实三入口成功答案被替成字符串，`run-AMMn6v` 证实实际页面预览/复制被破坏；其中独立测试类型错误也按原始非零结果保留。补充的 `run-f9G3Sk` 防止过宽的 opaque answer 保护漏掉真实凭据 extras。最终 `run-oyZPsi` 11 个定点用例同时覆盖原生与真实 HTTP/MCP quick/hard/固定原生名的 default/显式 debug、实际页面发送预览/结果/debug 复制、委员会每席/完整总结果、真实凭据、raw JSON/畸形 JSON/原始 header/error 文本与已知 echo，全部通过。

## 最终工程门禁

Socktainer 上下文；专用容器 `ghostmodeldeck-checks-r33b`，长任务由容器主 runner 执行，每次在线 pub get。固定 Flutter 3.47.6 / Dart 3.13.5；锁文件未改，mcp_dart 为 2.4.2。P2 修正后的主线程独立复核记录为 `/private/tmp/ghostmodeldeck-implementation-context/r36-p2-gates-independent.json`。98 个最终输入的 compact-JSON manifest 为 `97608b10207e458396f78cb9f36f3fcb2ec438c38d9e723cc9bae73dec7ea4a3`，逐行内容 manifest 为 `dd1191db163bb5eee141b6997d4c73e774c94e9bf495278b79d08b8e8ab7a923`。

原实施候选的 `run-tIpZZs`/`run-ybqFrf`/`run-bknR9h`/`run-NYaC59`（零诊断、66、90/0、517）为已执行的历史门禁，旧 compact-JSON `e0d81b108b96d76aed774c1148eb83ddfc221ce78ec21e4784be1e760d2ff10a` 与逐行 `c771669ed1d94693a0d058e70da35d48b14c150d933644f17e41152409549ffe` 不作为本次产品修正后的输入 hash。以下表格覆盖相同的 P2 修正后最终输入。

### 可复现的 manifest 字节编码

逐行 manifest 只读取源码归档中 `TarInfo.isfile()` 为真的 98 个成员。路径直接使用未规范化的 `TarInfo.name`，按 Python `(path, digest)` 元组排序；每行依次为小写十六进制 SHA-256、两个 ASCII 空格（`0x20 0x20`）、路径和 LF（`0x0A`）。最后一行也保留 LF；整体以 UTF-8 编码，不含 BOM。

以下 Python 代码对修正后最终全量测试归档生成 `dd1191db163bb5eee141b6997d4c73e774c94e9bf495278b79d08b8e8ab7a923`，在仓库根目录执行：

```python
import hashlib
import tarfile

with tarfile.open(".tooling/container-tests/run-8X3K05/source.tar.gz") as archive:
    entries = [
        (member.name, hashlib.sha256(archive.extractfile(member).read()).hexdigest())
        for member in archive
        if member.isfile()
    ]
manifest = "".join(f"{digest}  {path}\n" for path, digest in sorted(entries))
print(hashlib.sha256(manifest.encode("utf-8")).hexdigest())
```

独立复核的 compact-JSON manifest 使用同一 `path -> digest` 字典，按 `json.dumps(mapping, sort_keys=True, separators=(",", ":"))` 生成文本，再以 UTF-8 编码计算 SHA-256，结果为 `97608b10207e458396f78cb9f36f3fcb2ec438c38d9e723cc9bae73dec7ea4a3`。两种序列化已按 98 个文件逐一核对内容相同；不能用旧 `path + " " + digest + LF` 编码直接复现逐行 hash。

| 实际命令（均设置 GMD_TEST_CONTAINER） | 归档 run | 宿主/job 退出码 | 实际结果 |
| --- | --- | --- | --- |
| `./scripts/test-container.sh analyze` | `run-VgWQQ4` | 0 / 0 | No issues found |
| `./scripts/test-container.sh test test/jev_debug_test.dart test/jev_debug_protocol_test.dart test/jev_playground_test.dart test/jev_playground_page_test.dart test/jev_owned_http_test.dart test/jev_protocol_test.dart test/jev_json_input_test.dart test/council_page_test.dart` | `run-TbAa9t` | 0 / 0 | 76 tests passed |
| `./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | `run-uSFoec` | 0 / 0 | 90 files, 0 changed |
| `./scripts/test-container.sh test` | `run-8X3K05` | 0 / 0 | 524 tests passed |

归档位于本 worktree 的 `.tooling/container-tests/<run>/`，保留 `source.tar.gz`、`job.sh`、`result.log`、`exit`；`/private/tmp/ghostmodeldeck-implementation-context/implementation36-status.json` 记录各阶段命令、基线、源码 manifest、归档/日志 SHA-256 与真实退出结果。红→绿包含缺失公开入口、JSON 原生选择/焦点、配置快照、凭据错误状态、Ready 过渡、HTTP 取消及接收边界的原始失败；测试工具的 FakeAsync barrier/旧 UI 状态/nullable fixture/100-continue 假设错误另按原始失败保留，不计通过。

## macOS 有界回环证据

使用 `/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart`（3.13.5 macos_arm64），读取既有依赖配置并在任务临时目录中固定到本 worktree。`stage36-mac-owned-http.dart` 通过当前生产 adapter、controller、gateway 与实际本机 HTTP 驱动；只替换外部引擎 I/O，不启动真实模型或 GUI。

原实施候选的 `stage36-mac-owned-final.log` 记录 6 ms。P2 修正后最终源码的 `stage36-p2-mac-final.log`：真实宿主退出 0，本次 lease/许可 8 ms 排空；另一条待决请求和后续请求成功，两监听器仍 running，清理前驻留 kill 为 0，最终 owned registry/许可均为 0。脚本 SHA-256：`530576309522c4fb8d499f8df2d4b89c18017b34f406640fd54b2775bd14e900`；验证的 gateway SHA-256：`3244db601a61666914a37170c613890104c6e010d7993994f5b75fef0c1e1c3f`；adapter SHA-256：`c9b8eb5e7bfd14d7a363dd0ab455dcd6e12b71df7ef9bc87525a32f8a1839f75`。

修正后的共享 sealer SHA-256 为 `4f14eb970efdc16b8cdd5d839dd5dc01d08b83f0106498a1bb80b84da1b876c4`；Mac 有界回环使用这一版源码，gateway/adapter hash 保持上述值。

初次阶段审查、后续 P2 发现与会话/环境复盘见 [审查与复盘记录](jev-playground-review-and-retro.md)；文档补记之后的最终整体双轴复审由主线程执行。

## 未覆盖

本阶段未启动/下载真实 JEV 模型，未执行实际 Mac 窗口交互、Hermes/Codex 外部接入或完整 Release 验收。当前 Mac 窗口条件属于 #37 前置，由主线程单独处理；上述替身/回环、widget、格式和静态检查不能替代这些验收。此阶段仅本地提交候选，未进行 GitHub 写操作或 push。
