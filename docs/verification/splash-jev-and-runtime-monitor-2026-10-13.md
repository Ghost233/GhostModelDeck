# Splash JEV 短测试与运行监控交付清单

## 唯一当前状态

2026-10-13。Splash 测试、默认参数和运行监控已完成开发与验收。用户现已授权提交及正式发布，并手动选择 0.1.8。发布进度统一记录在 [0.1.8 发布验收](release-0.1.8.md)。

| 项目 | 当前状态 |
| --- | --- |
| 候选 | GMD main `1c1bb0964ede0d649d7b09879c98c2b0945925e4`；Splash `3f43aa2460f59330e658fdc89945d72ce92d538c` |
| 有效作业 | 无；run-F2IDyI 的 980 项完整门禁已结束并通过 |
| 未关闭问题 | 无本次已确认范围的未关闭 P0/P1/P2；指纹、复审、原生接口与资源收尾均完成 |
| 下一动作 | 核对版本相关检查与正式入口构建，再提交、推送并发布 0.1.8 |

## 范围

- 保留当前 0.1.7 正式版及其配置和服务。使用新的本地测试应用与独立配置目录、端口和测试实例。
- 参考 `/Users/ghost233/.codex/worktrees/qwen4b-quantized-ffn/GhostSplash`。测试 Kev、StartLux 的加载、短文本和原生 `/v1/systemone`；Qwen3.5-4B 作为同布局对照。每个仅做短请求，不跑题集。
- 按 `INFERENCE_PARAMETERS.md` 的 Qwen3.5-4B 选定参数设置 Splash 默认配置。区分实际 CLI 可设置值、模型配套资产和实验入口专用值。后者不能假装已在服务生效。
- 新增左侧独立“运行监控”页面。汇总所有保存实例，展示当前并发、运行、排队、prefill、decode、token 数量和平均 tokens/s，提供速度曲线。
- 监控读取引擎实际状态。引擎缺少的字段显示未提供；请求失败、过期、实例停止分别表达。监控不启动模型，不改变启动参数。
- 页面分批展示，曲线样本有上限；隐藏页面停止轮询，同一实例不重叠请求。完整 JSON 留在文件，不塞进 UI。
- 主线程推进；仅 macOS arm64、固定 SDK 和 lockfile；不创建子代理或容器。开发验收阶段未发布；后续按用户明确授权发布 0.1.8。

## 工作分类

- **未实现：** 无；运行监控、三个状态适配和 Splash JEV HTTP/MCP/委员会接线均已完成。
- **未验证：** 无；本轮所有约定验收完成。
- **已验证待提交：** 本轮源码、测试和交付记录。980 项完整门禁及 150 项受影响检查、实际 arm64 构建和接口验收通过；当前尚未提交或推送。
- **历史问题：** 首次旧二进制启动失败，不算模型支持失败，也不算通过。旧黑屏与字体记录留在原交付文档，不重新列为本轮待办。

## 原始证据

证据目录：`.scratch/splash-jev-20261013/`。

- `model-compatibility.json`：三个真实 GGUF 的架构、原生 model-check 命令及退出结果。
- `assemblies.json`：实际目标权重与 Standard DFlash 的路径、SHA-256 和独立 assembly。
- `original-native-failure/`：首次服务均在加载前退出 1，原因为原生参数不识别。控制脚本正常收尾不表示业务测试通过，三个端口均已关闭。后续成功证据单独保存在 `native-results.json`。

用户已选择独立运行监控页面。默认参数入口存在两项差异：量化 FFN／零 FP16 缓存、历史 splits=16 由实验入口控制，普通服务尚不能完整表达；用户已选择先复用可用 CLI 项，不扩展 Splash 实验参数入口。用户也已授权接通 GMD 的 JEV HTTP/MCP 和委员会，保持短接口验收，不跑模型题集。

## 新增完成证据

- 当前 Splash 源码在 `.tooling/splash-reference-20261013` 编译成功，实际 native 为 arm64；原目录构建和源码保持。首次旧二进制不支持参数的失败归档在 `original-native-failure/`。构建工具误用 `engine` 目标的退出 2 单独保留，改用实际 `all` 入口后退出 0。
- Kev、StartLux、Qwen3.5-4B 顺序短 HTTP 均为 200：文本均返回 OK，choice 均为 B，概率分别为约 0.99199／0.99986／0.99359。三个测试进程正常退出 0、端口关闭。原始请求与响应在 `native-results.json`。这只验证短接口兼容性。
- 本地 GMD 测试应用使用独立 bundle ID、配置目录及随机 HTTP/MCP 端口；不连接外部启动器。测试入口差异留在 `.scratch/splash-jev-20261013/test-main.dart`。实验安装路径为 `.tooling/splash-experimental-20261013`，源代码链接到用户指定 worktree，native 链接到本次独立编译。
- 默认保存 Q4H、context 36864、memory 32G、queue 1、ANE share 0.5／minimum rows 512、lookup on、compact on、fast top-k off、cache disk 0、request timeout 60。保留配对 Standard DFlash。实际 ANE 状态为 split、share 0.5、minimum_rows 512。缺少匹配模型排名文件，compact 实际回退完整 head；没有冒用 Qwen 的排名文件。量化 FFN、零 FP16 缓存和历史 splits=16 仍属于服务 CLI 无法表达的已确认差异。
- 新测试 GMD 已启动 StartLux；身份与就绪 GET 均 200，见 `gmd-startlux-running-identity.json`。Kev 的原始分类拦截在私有 profile 的 `instance-errors/failure-1791883345766453.log`；定点 red `run-7dPsrJ` 退出 1，修复 green `run-k3M5dk` 退出 0，受影响三模块 `run-th4pxs` 42 项通过。修复后 GUI 已显示 Kev 运行中，GMD 公开文本返回 OK／200／0.20 秒，见 `gmd-kev-http-result.json`。
- 初版 GMD 决策路由有效请求仍 404 的原始证据在 `gmd-kev-systemone-valid-request.json`。用户据此授权补齐接线，该 404 不计通过。更早少 instructions 的 400 为测试请求构造错误，也保留。
- 新监控和 Splash JEV 定点 `run-9XbWvW` 14 项通过：HTTP/MCP 原生与委员会共用路由，真实错误、超时、取消、失效身份；监控读取、过期拒绝、分页、四实例并发读取、120 点上限、隐藏停止与晚到结果。后续修订与新增布局检查纳入 run-yv1GOh。

## 执行与资源

开发验收没有运行真实评测题集，也没有子代理或容器。正式 0.1.7 应用 PID 865 保留；所有模型请求发往本次私有测试服务。GMD 启动验收期间，主线程实际 sleep 300 后收取唯一 Kev 作业。后续发布进度见 0.1.8 发布记录。

- 受影响检查 run-yv1GOh 保留真实布局超时及中断清理错误；raw command exit 为 0，但完成标记缺失/失败，wrapper 退出 1，不计通过。后续 run-j3wWwV 保留惰性列表最后一行未滚动的原始断言及清理错误。
- 根因位于新增 widget 测试：真实文件资源不能在虚拟时钟中准备/收尾；惰性列表需要正常滚动才能读取最后一行。使用已有 tester.runAsync 边界，并保持全部字体、布局、分页及停止轮询断言。原失败用例 run-qr0jjy 通过；完整受影响集合 run-82DlaU 150 项、静态分析和 diff 检查通过。
- Splash 当前概率路径为最终 prompt 位置的真实候选 token logits，再由原生接口 softmax。没有核验或接入 Kev 的专用 cls 输出头；本次不声称与其他引擎读出完全等价。GMD 不改写概率或做模型成绩评估。

## 最终原生短验收

最终 GMD 本地测试版 build 退出 0，三项二进制均 arm64。最新候选从 GUI 启动同一 Kev 配置，监控显示已注册 3、运行 1、并发 0/1、排队 0、三个 token/请求计数初值 0，普通启动没有自动推理。展开后曲线与两项图例、纵轴上限可见。

- `final-native-http-mcp.json`：真实 GMD HTTP 三题型 200；手写 MCP 客户端缺少 2026 请求 `_meta`，真实 400 保留，不算产品通过。改用 lockfile 固定的 mcp_dart 2.4.2 后 `final-mcp-sdk-result.json`、`final-mcp-sdk.exit` 为成功／0，未重跑已通过的 HTTP。
- GUI 保存 `splash-interface-check`，仅引用本次 Kev 实例，预算 60 秒；真实 HTTP 与 MCP 均成功，见 `final-council-http.json`、`final-council-mcp.json` 及各退出码。单席只验证新增引擎接线，不冒充独立多模型准确率评测。
- `independent-protocol-comparison.json`：原生 HTTP/MCP answers 全等，委员会两通道结果全等，原生与单席委员会 probabilities 全等；逐项复核 argmax、概率和、score 加权值与 noul 有限范围。委员会 confidence 采用既有综合规则，与原生定义分别保留。
- 按用户明确要求，已向 Observer 会话回复：开发现场不提供其测试服务，请自行查找另一份 Ghost Model Deck。不会为对方加载、交接或更换本次实例。

## 固定内容审查

主线程对当前 12 份应用模块核对来源规格和工程边界；原 llama.cpp 路由保留，新增 Splash 使用身份绑定的通用决策接口。预算、取消、停止与原始失败均在既有资源所有者闭环。监控只读取状态，不接收推理任务；按 20 实例／8 请求分页，历史限 120 点。已确认范围内没有未关闭 P0/P1/P2；完整门禁已收取并通过，见下方最终验收。固定 SHA 记录在 `fixed-content-review.json`。

真实普通聊天 `monitor-real-chat.json` 返回 200、192 output tokens；窗口摘要显示累计处理输入 1065、输出 192、13 请求，以及当时平均 prefill 910.0 / decode 243.6 tokens/s。这些是当前引擎会话数据，未作为模型排行榜或优化基准成绩。

## 最终验收

- `run-F2IDyI`：199 份文件格式无变更，静态分析无问题，980 项完整测试成功完成；各原命令和检查入口均退出 0，标准报告 passed/successful_completion 为 true，没有失败记录。
- 723 份输入在前后及当前工作区全部匹配。固定 12 模块复审 SHA 同样匹配；最终本地构建与接口验收覆盖同一代码，没有后续应用修改。
- 用户指定 GhostSplash worktree 仍干净；实验构建原生为 arm64，原源码/原构建未覆盖。正式 GMD PID 865 保留，本次不代表另一会话负责的正式服务验收。
- 通过 GUI 正常停止本次私有 Kev 实例，界面回到“已保存”；所属 Python/native 进程清零，之后公开接口真实返回 503 model_not_ready。配置和本地测试应用保留；桌面工具的一次 native pipe 启动故障由重置连接恢复，不算产品失败。
- 真实远端 main/dev 经 Ghost233 身份只读核对，与本地 main/dev 及 origin refs 全部同为 `1c1bb0964ede0d649d7b09879c98c2b0945925e4`；当前分支没有 behind。本次源码与文档尚未提交、推送或发布，没有分支操作或备份。
- 完整收据在 `.scratch/splash-jev-20261013/completion.json`，原始失败与成功证据全部保留。测试场原生题目、固定 submodule、完整规模和文件/Finder 入口均未改动；本轮真实模型题集运行数为 0。
