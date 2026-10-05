# JEV typed 协议实施前核验（#15 / #19）

核查日期：2026-10-05。范围：一手固定源码与官方文档，供实现/验收准备；**本轮未运行测试、引擎或模型，未安装/下载权重、调用 LLM CLI、修改 Git/issue**。只新建本笔记；不表示模型质量、概率校准或真实三题型已验收。#14 正在并行修改代码，**#15 实施前必须重新核对 #14 完成后的模型包、入口、指纹与运行代码结构**，本文本地行号是读取快照。

## 版本与证据等级

- JEV 协议固定在 `ggml-org/llama.cpp@836d57176dc699a726c55418e4f96b8ca628e1bf`（既有研究/探索记录对应 b11381）。以下 D/H/R/W/E 引用均为该提交的原始文件与精确行号；读取 raw 内容并按原文件换行计数，不以浮动 main 代替。[既有引擎研究](<model-runtime-evidence.md#L38-L40>)；本次亦读取仓库外[探索记录](</tmp/gmd-issue15-exploration.md#L15-L21>)，其安装观察没有在本轮重新运行核验。
- 标准 LLM 候选 `7fe450e19305b828c199d602c23a8337aaa1f03b` **不能视作同一 typed 能力版本**：对应[原始 decision 文件](https://raw.githubusercontent.com/ggml-org/llama.cpp/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/server-decision.cpp)本次 HTTP 404；完整[路由源码:1–557](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/server.cpp#L1-L557)、[context 源码:1–5558](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/server-context.cpp#L1-L5558)及[README:1–2138](https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/README.md#L1-L2138)全文检索均没有 `systemone`。这是固定源码差异，不是本机二进制/模型执行结果；不要整体换版后仍宣称保留 JEV Ready。
- 已查阅 [TypeSafe introduction](https://docs.typesafe.ai/introduction#typesafe-primitives) 与 [intent-routing](https://docs.typesafe.ai/patterns/intent-routing#step-2-route-to-the-optimal-handler)：前者描述三 primitive/同 state 独立多题，后者示例由代码消费 choice/score/confidence 控制分支。它们是**未固定提交的在线文档能力**，无可靠源码行号；不构成本地 SDK、服务/凭据存在证据，不采用云 SDK，不把示例 `0.5` 当普适阈值，也不移植其延迟宣传。固定本地实现以以下源码为准（含 clef 联合判断例外）。

## 精确协议表：POST `/v1/systemone`（固定源码意图）

| 项 | 请求/校验 | 真实格式化响应 | 一手证据 |
|---|---|---|---|
| 公共 envelope | `state` 必须存在且非 null；`questions` 必须为非空 object，键为题 ID，每题 object；`instructions` 必须存在且非 null；`type` 只能为三题型。文档说 state/instructions 为 string/object/array；parser 本身不逐项限制这些 JSON 类型，也不拒空字符串/空题 ID。 | `model`, `answers`（按题 ID 的 object）, `usage:{input_tokens,output_tokens:0}`；每 answer 有 `type`。 | [D:138–162][D-request]；[R:1678–1689][R-request]；[H:5498–5528][H-answer] |
| `choice` | `criteria` 必填非空 object：选项 ID → 描述，描述可 null；源码不要求描述为 string，也不拒单选/空选项 ID。模型上限不同，Kev/Laya 为 255；本地业务 2–255 是更严规则，不应称为上游统一要求。 | `{type:"choice",choice:<最高概率选项ID>,probabilities:{<ID>:number,...},confidence:number}`；不是数组。并列时 `max_element` 取内部顺序第一项，不据此声称语义优先。 | [D:164–176,200–202][D-request]；[D:98–125][D-model]；[D:743–752][D-answer] |
| `score` | `criteria` 必填 **2–10 元素 array**，最低级别在前；parser 按位置构造字符串 ID `"0"`…`"n-1"`，无自定义数值范围/权重字段；元素保留 JSON 值。`legend` 是响应字段，不是请求字段。 | `{type:"score",score:Σ(i×p_i),legend:{"0":<原描述>,...},probabilities:{"0":number,...},confidence:number}`。`score` 为连续期望索引，范围 `[0,n-1]`，不是整数 mode、0–1 归一化分数或真实正确率。 | [D:177–184][D-request]；[D:754–763][D-answer]；[R:1688,1716–1720][R-request] |
| `noul` | `criteria` 可缺省/null，若给则必须 object；只读取 `"false"`/`"true"` 描述，缺失项置 null；额外键未被 parser 拒绝但不会增加答案选项。 | **只有 `{type:"noul",noul:number}`**，无 `probabilities`、`confidence` 或 `legend`。Kev/Laya 返回 true 的概率；LEV 分支返回九级 rating 的归一化期望，不能推广所有模型都用相同 head。 | [D:185–195][D-request]；[D:726–740][D-answer]；[D:19–20](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L19-L20) |
| 多题与无 stream | 同一 state 可混合题型。Kev/Laya 每题独立任务；clef 一次 joint task。源码未设置显式 questions 数量上限；不是无限资源承诺。README 明示不支持 streaming，handler 等待全部结果，并不读取 `stream`。 | 返回一次完整 answers；一个任务报错即 error，不返回局部 answers；连接终止直接返回，不能补造完整成功。不要把传 `stream:true` 必定 400 当已证实行为。 | [R:1674,1691–1695][R-request]；[H:5464–5496][H-tasks] |
| 模型身份/usage | typed handler 未用请求 `model` 校验目标；请求携带 model 不证明路由到目标。需应用绑定 owned run/真实 props，响应 model 必须匹配当前代次 alias。 | `model=meta->model_name`：有 alias 时取首 alias，否则模型配置名称/文件名；`input_tokens` 累加非 joint 各任务 prompt token 数（含变体），joint 取一次，不是标准 Chat usage，也不等于去重后的物理算力/费用。 | [H:1439–1448][H-model]；[H:5454–5458][H-tasks]；[H:5498–5528][H-answer] |

## 错误与概率：不要把成功 JSON 当合法意见

- 非 decision 模型在解析请求前返回 501 `This model is not a decision model`；不支持图像/缺 projector 也 501。参数校验 `invalid_argument` 与 `common_json_error` 经 wrapper 映射 400；其他异常 500。错误结构为 `error:{code,message,type}`，不是成功 answer；全局还定义 401/403/404/503，不应说 typed 只会 400/501。[H:5446–5461][H-tasks]；[W:54–83][W-error]；[E:36–77][E-error]；[R:1802](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/README.md#L1802)
- 上游读 head/logits，按模型 metadata 温度（缺省 1）softmax，必要时平均变体；并非由生成文本“自报 confidence”。choice confidence 为 `(p_max−1/n)/(1−1/n)` 的非负值；score confidence 用相对 mode 距离，**二者都不是正确率**。上游检查 NaN scores，但不能代替客户端对最终数值有限性/范围/归一化校验；不修补非法概率来伪装成功。[D:641–720][D-prob]；[R:1724–1726][R-prob]
- Laya 文档明确长问题/选项截断，以及 prompt 必须适合 `--ubatch-size`；题型字段合法不等于输入语义完整或真实运行可用。[R:1693–1695][R-request]

## 当前真实缺口（静态读取，不是测试结果）

- [DecisionRequest](<../../lib/decision_protocol.dart#L6-L35>)仅 `String state/instructions`、非空 string 描述的 `Map<String,String> options`，固定单题 `council_choice/type:choice`；未表达 score rubric、noul criteria、任意题 ID/混合多题或 JSON state。扩展范围应明确，不要求把上游所有宽松输入照搬为业务契约。
- [DecisionResult.parse](<../../lib/decision_protocol.dart#L52-L105>)核对响应 model、choice type、`output_tokens==0`、选项精确覆盖、有限 `[0,1]` 且 sum 容差 `0.0001`、choice 在候选中并保留 raw/elapsed；**尚未核对 choice 是否 argmax，不读取/校验 confidence/input_tokens，也未校验 answers 精确题集合**。score/noul 类型会被拒，不能声称三题型 Ready。后续补齐各自校验规则，不以 choice-map 强行解析 noul。
- [委员会公共入口](<../../lib/council.dart#L214-L229>)同样只接受 choice；[等权综合](<../../lib/council.dart#L247-L301>)仅计 `ok` 席位，成功数≥2才输出 aggregate/votes/disagreement，1席为 singleModel 无 aggregate，0席为 failed/none；不是已经实现 score/noul 综合。

## #15 / #19 的关键验证注意点（待实施/执行，不新定业务模型）

1. **分能力准入**：固定资产字节/指纹、安装版本、实际 alias/路径和运行代次；普通 Chat Ready 不得进入 JEV 席位。choice/score/noul 各需真实调用报文及题型证据；健康状态或单题 choice 不替代三题型验收。[规格](<../spec.md#L89-L114>)
2. **I/O 确定性校验**：choice 精确候选集/概率/argmax（保留并列策略）；score 精确索引集/legend 与请求逐级对应，有限 score∈`[0,n-1]`、合法概率及期望一致（容差另明确）；noul 有限∈`[0,1]`，保留原始 scalar，不要求不存在的 probabilities/confidence。模型/type/题ID/usage 必须绑定；缺失、不合法、生成文本不进入成功集。是否严格拒绝额外响应字段/缺 confidence 等，需要实现明确，不能以本文替代规格决定。[上游输出][D-answer]；[既有严格概率校验](<../../lib/decision_protocol.dart#L72-L101>)
3. **原等权规则的数学边界**：对相同候选集合（score 须相同有序 rubric）的合法分布按成功席位数 `k` 做 `q_i=Σp_si/k`，非负、≤1，sum 误差至多原容差；不要除以全部选中席位数，也不要再 softmax 或用 confidence 加权。[现有算法](<../../lib/council.dart#L247-L262>)。score 应原样报告每席 scalar/legend/分布，若后续确定聚合则说明是分布均值后的期望，而非校准值。noul 应原样报告 scalar；`1−noul` 只能标注**客户端推导补值**而非上游原始 probability 字段。是否聚合 scalar、如何定义 score/noul 分歧仍需 #19 明确；不可伪造 choice 投票、置信度或统一校准率。[三题型输出][D-answer]；[领域评分含义](<../../CONTEXT.md#L55-L61>)
4. **失败/覆盖可观察**：保持全成功/partial/单成功/零成功及席位数、每席身份/耗时/raw/error/status；成功≥2才按已有规则综合，0成功不输出默认零分布，失败席不占综合分母。多题请求上游没有局部成功答题契约，若未来应用实现 per-question partial 必须明确为应用层规则，不臆造 server 语义。[H:5489–5528][H-answer]；[本地覆盖状态](<../../lib/council.dart#L247-L301>)与[席位错误映射](<../../lib/council.dart#L321-L357>)
5. **取消/晚结果**：对外可观察请求取消、截止、失效代次与清理；不得让迟到结果恢复 Ready 或污染下一轮；既有轮次封存/排空逻辑应保留。[轮次逻辑](<../../lib/council.dart#L361-L436>)；[测试约束](<../spec.md#L134-L138>)。这些是代码/规格事实，未宣称本轮执行通过。

## 未解决 / 未验证

本机发布包是否与固定源码一致、Kev/Laya 的真实三题型/混合题报文、错误码实测、输入截断/上下文边界、输入 tokens 观察、并发/超时/取消/零成功及 MCP 文本与结构化同算法均未执行。精度/中文泛化/校准/峰值内存/延迟/委员会收益未测；不能由 temperature metadata 或合法概率推断。score/noul 的委员会聚合/分歧展示与新增校验容差需实施切片明确；#14 完成后结构与本地行号必须重读。旧证据不能计作新项目验收。[验收矩阵及证据要求](<../spec.md#L148-L169>)

[D-request]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L138-L206
[D-model]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L98-L125
[D-answer]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L724-L765
[D-prob]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-decision.cpp#L641-L720
[H-tasks]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-context.cpp#L5446-L5496
[H-answer]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-context.cpp#L5489-L5528
[H-model]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-context.cpp#L1439-L1448
[R-request]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/README.md#L1674-L1720
[R-prob]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/README.md#L1724-L1726
[W-error]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server.cpp#L54-L83
[E-error]: https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/tools/server/server-common.cpp#L36-L77
