# #34 原生 JEV 合法 JSON 输入验证

日期：2026-10-08。来源：[贯通原生 JEV 合法 JSON 输入](https://github.com/Ghost233/GhostModelDeck/issues/34)、[协议规格](../requirements/protocol-converters-and-playground.md)、[命名路由补充规格](../requirements/jev-model-routing-and-council-profiles.md)、ADR 0001/0002。实施基线 `ee4ac0ef2b25acef22ee55725c67b3f647ddd590`，本地分支 `codex/jev-json-input`。

## 固定契约与实施

按 [llama.cpp 固定原生解析器](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L137-L201) 接受非 null 的 JSON state/instructions，包括文本、数字、布尔、数组、对象及空文本/空容器；嵌套成员和描述允许 null。choice 使用 1–255 个应用有效候选 ID，score 使用 2–10 项有序数组，noul 保留 criteria 省略、显式 null 或对象的区别，并保留对象中的额外内容。实际模型更小的选项上限继续由引擎明确报错，应用不截断或补造候选。

固定 [parse_state](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L225-L268) 支持的无图像扩展 images 可省略、null 或空数组，应用透明保留。非空 images 明确拒绝，未扩展图像能力。未获固定上游支持证据的顶层或题目字段明确拒绝并指出字段；不称 seed/temperature/cache_prompt 等为该原生接口支持，不静默删除字段。任务内容内部的 debug 等键属于 JSON 内容，完整保留；顶层应用 debug/stream 由协议适配层校验和处理，不发送给引擎。

生产 DTO 在构造时递归校验、复制并冻结 state、instructions、choice 描述、score 级别、noul criteria 和扩展。HTTP、MCP、软件调用共用 JevModelRequest 与 DecisionBatchRequest，无平行 raw 解析器。LlamaEngine 原有受管准入、身份/代次、能力、许可、取消和停止边界不变，唯一请求 body 允许 Object? 值，以原有 toSystemone 发送。

score legend 按 JSON 语义比较：对象键顺序无影响，数组保序，布尔/文本/null 等值不能互相替换。原生 ScoreAnswer 保存经校验的实际 legend，而不是重建输入投影，并深冻结其嵌套成员；原 confidence 与用量保留。委员会单候选 choice 的原生 confidence 为 1，避免分母为零。旧文本构造和 MCP options 便利方式保持可用。

保留应用 256 KiB 请求、1 MiB 响应、32 题、255 choice 候选及非流式上限，无新增依赖或自动模型加载。

## 公开接缝与验收证据

测试使用真实 ModelLibrary、EngineCatalog、LlamaEngine、CouncilController/JevModels、PublicGatewayServer 和 CouncilMcpServer；入站是真实 loopback HTTP 与 McpClient。只替换外部引擎进程/HTTP 与必要临时文件 I/O，不 mock 业务 controller、parser 或聚合。CouncilRuntimeIO 在实际读取 HttpRequest UTF-8 body 后记录已发送 JSON；不把重新序列化的 DTO 当作发送证据。外部响应 oracle 为已知固定值，只适配受管 alias，不根据生产解析或聚合函数生成期望。

| 验收 | 证据 |
| --- | --- |
| 必填 model、两来源合法 JSON | jev_json_input_test 的 quick 单席、hard 双席、native-kev，通过 HTTP 与 MCP 完整往返；模型绑定精确核对，原有路由与能力测试回归。 |
| 三题型与混合批量 | C0 保留中文/斜线问题 ID、对象/数组 instructions、null 描述、结构化 score legend、noul 省略及额外键；2/10 级 score 和单候选 choice 均覆盖。 |
| JSON 类型与扩展 | state/instructions 的字符串、数值、布尔、数组、对象、空值容器；choice/score 描述含 null；noul 省略/null/空对象/缺分支/额外键；images 省略/null/[] 各来源均对账。 |
| 明确拒绝 | 缺字段、非法 questions/criteria、未知题型/字段、非空图像、非法 debug/stream、空 ID、33 题、256 候选均返回错误，无 answers 和无引擎咨询；Dart 入口拒绝非有限数、非字符串键、非 JSON 对象及循环引用。 |
| 实际发送与输出 | 逐项比较 collector 中真实 JSON，仅替换 model alias、移除应用 envelope；HTTP 正常结果与 MCP structuredContent 相等，MCP TextContent 与同次 structuredContent 相等。原生直接保留 confidence=0.37 的固定例；usage 13/26/13 不按问题数估算。 |
| 稳定深快照 | /props 外部 I/O 屏障暂停身份检查；此时编辑嵌套 state/instructions/criteria/images，完成后真实出站保持旧内容；DTO getter、序列化返回的嵌套容器与结果 legend 不能改写快照。另由 LlamaEngine.decideBatch 直接验证 score/noul 深快照。 |
| 原有路径与资源 | 原文本调用、MCP single 默认说明、命名路由、委员会算法/生命周期、生产页面和引擎模块回归；引擎/MCP 活动请求归零，受管实例没有新建或被杀。 |

结构化 legend 保持 JSON 值进入标准输出；现有软件页面用 JsonEncoder/SelectableText 展示结果，不对 legend 调用 toString。完整 JSON 编辑器与实际桌面复杂输入交互属于后续 #36/#37；本切片未借此创建第二个测试场。容器结果不证明真实模型模板对空文本/任意 JSON 的推理能力，也不替代 Mac 原生模型和完整 Release 验收。

## 红 → 绿与原始失败

每个 run 目录保留 source.tar.gz、job.sh、result.log 和 exit。完整哈希及最终源码文件清单见[源码与运行清单](ghostmodeldeck-native-json-input-r34-source.json)。

| 运行 | 真实结果与处理 |
| --- | --- |
| run-CeHxoL | exit1：C0 HTTP 返回400，images 被旧字段白名单拒绝；证明合法原生复杂输入未贯通。 |
| run-RGucBM | exit1：DTO 放宽后 _request 的 Map<String,Object> 参数编译失败；在唯一 HTTP body 边界改为 Object?。 |
| run-BlItlQ | exit0：C0 三来源 HTTP/MCP 首轮通过。 |
| run-dQDH8m | exit1：单候选委员会 NaN 导致 HTTP 未完成，测试30秒真实超时并失败；未把超时/清理算作通过。 |
| run-6bhtH5 | exit0：仅补单候选 confidence=1 后原失败用例通过。 |
| run-egwt1A | exit0：9 个聚焦集成用例通过。 |
| run-cTfB32 | exit1：受影响模块104通过、2失败；旧 MCP 负例把合法数字 state/空白描述列为非法，新增 debug 用例误把两个实际调用的随机 ID/耗时要求一致。 |
| run-93R9jx | exit0：修正过期向量，debug 比较各自同次载荷，原2个失败用例定点通过。 |
| run-fxC9Qy | exit0：9 个变更 Dart 文件格式化，5个改写；以 base64 与 SHA256 校验导出并写回宿主后再验证。 |

全部检查使用独占 ghostmodeldeck-checks-r33b、固定 Flutter/锁文件与联网 pub get，分钟级工作由现有容器主进程 job runner 执行。没有 timeout 包裹正式门禁，没有并发重复同一长作业，没有触发 GitHub 写入或远端 CI。

## 最终门禁

全部正式门禁覆盖同一最终源码输入，指纹为 `67f075abb8a58b53a3c33fe79f7f5ef41c24e5e7b8a35fa0c3cea88529a8847d`，89 个 lib/test/benchmarks 与 pubspec/lockfile/analysis_options 文件。逐文件 SHA256 和每次归档/原日志 SHA256 在上述源码清单；三个最终门禁归档逐文件比较均一致。验证仅覆盖本次归档的源码输入，原始失败不被覆盖或记作通过。

| 命令（均带 GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b） | 目录 | 真实 host/job exit 与结果 |
| --- | --- | --- |
| `./scripts/test-container.sh test test/jev_json_input_test.dart test/decision_protocol_test.dart test/jev_protocol_test.dart test/jev_models_test.dart test/council_test.dart test/council_mcp_test.dart test/council_page_test.dart test/llama_engine_test.dart` | run-C80efy | 0/0，106项通过 |
| `./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks` | run-L2eeoc | 0/0，81 files、0 changed |
| `./scripts/test-container.sh analyze` | run-DuZYfm | 0/0，No issues found、0诊断 |
| `./scripts/test-container.sh test` | run-Wot5NX | 0/0，468项通过、0失败 |

在最终报告前两次正常 merge 本地集成分支 codex/jev-protocol-playground，均返回 Already up to date；集成与实施基线均为 ee4ac0ef2b25acef22ee55725c67b3f647ddd590，没有 rebase/cherry-pick/reset/stash。GitHub/远端业务由主线程负责，本工作树只生成本地候选。全部原始 run 目录另已校验复制到 `/private/tmp/ghostmodeldeck-implementation-context/stage34-gate-evidence/`，避免以后清理工作树丢失忽略的运行证据。
