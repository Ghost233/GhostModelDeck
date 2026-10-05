# 共享模型库：Mac 真实文件系统验收

Kev 实跑时间为 **2026-10-04 09:25:06 UTC**。**生产默认清单、Kev 选择性全量指纹/上游核验与有界保全检查通过；未加载引擎，不表示推理实例就绪。** 下方同时保留 09:04:11 UTC 的失败证据与其保全范围；文末补充最终源文件在 13:28:38 UTC 的 Laya scorer 修复验收。

使用已保存且明确选定的 `/Users/ghost233/.lmstudio/models`。原生集成例外范围内，用已有 Dart SDK 3.13.5 stable（macos_arm64）及原生构建已解析的 `.dart_tool/package_config.json` 运行 [live-library.dart](../../.tooling/implementation/live-library.dart)。直接调用生产 `ModelLibrary.scan` 和 `verify`；没有本机 unit/widget 测试、依赖安装、伪造文件、复制/移动/删除模型或停止 LM Studio。

Kev 验收当时生产 `lib/model_library.dart` 内容 SHA-256：`9d05d1de1bf4333f965d2df285afcc502008621b0acb41cb5bdc8f0d808c5c92`。该轮修复前内容 SHA-256：`433626842fa9888cedf9970c9418be32b2801da314c1ad2bafd16e372b668e80`。

## 最终成功证据

同一脚本、同一已保存共享根、同一生产 `scan/verify` 接缝，退出码 **0**。默认清单 **2194 ms**，返回 **165 个资产 / 243 个被代表文件**：unknown 159、decision 2、chat 4；结构状态 unknown 160、complete 3、incomplete 1、corrupt 1。全部 165 个引擎能力仍为 `awaitingVerification`，全量内容指纹和已核验来源资产各为 0。

只对所选 Kev 调用 `verify([id])`，**5083 ms** 后成功返回一个资产：

| 项目 | 实际结果 |
| --- | --- |
| 格式 / 架构 / 决策类型 | GGUF / qwen35 / kev |
| 结构状态 | complete |
| 文件大小 | 812406304 bytes |
| 全量内容 SHA-256 | `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0` |
| 指纹类型 / 指纹状态 | fullContent / fingerprintsVerified=true |
| 上游来源核验 | sourceVerified=true |
| repo / 固定 revision | ggml-org/Kev-0.8B-GGUF / e551e319d483ff57e1ff208924b349d397cffc1c |
| 许可证记录 | apache-2.0 |
| 引擎能力 | awaitingVerification |

其他 **164 个资产**保留基础清单，完整指纹资产数 0、已核验来源数 0。没有把无关文件的前缀指纹升级为全量内容 SHA。

最终有界保全基线包括 **263 个既有普通文件 / 355378620302 bytes（约 331 GiB）**，每轮实际读取的保全前缀共 **133780 bytes**。路径集合、大小、UTC 修改时间与最多 512 字节实际前缀前后相同：移除/新增/变化均为 0。canonical 快照 SHA-256 前后均为：

```text
ae353d4ee13736951d2d433a2e8b3cd32275363a06fbd2f8cb555af51f6843e7
```

该摘要覆盖逐项路径、大小、修改时间和实际前缀值；不是全部 331 GiB 内容 SHA。它不能排除前缀之外且不反映于大小/修改时间的外部修改。两次实跑之间 LM Studio 完成了较大分片，所以最终文件数/总大小比早先基线增加；本次操作自身的前后基线完全相同。

最终仍观察到 `downloading_...00003-of-00003.gguf.part`，大小 `9171928926` bytes、修改时间 `2026-10-04T08:58:09.290347Z`，在该轮前后相同。本轮没有亲自观察到持续增长，因此并发写入下的因果保证来自下述容器对照回归，不能只用这次稳定的原生窗口作证明。

## 诊断与容器回归

原生失败命令已在修复前实际复现两次。随后在 `ModelLibrary.scan → verify` 公共接缝建立真实临时文件回归：所选完整 GGUF 保持稳定；独立 Dart isolate 持续覆写另一个真实 64 KiB 文件，明确先收到 writer-active 阶段信号，维持 30 秒超时上限，没有私有文件系统替身。

- RED 两次：`run-SnlI4m` **12 ms**、`run-8elA5o` **6 ms**；均得到同一 group-change 异常和 `文件在扫描期间变化，请重新扫描`。
- GREEN：`run-epsf7R` **7 ms**；无关文件修改时间确实推进，所选资产完成全量指纹核验。
- 排序假设：整库核验触及无关写入文件；基础/全量资产分组漂移；manifest 匹配歧义。无 manifest 的最小场景仍变红，排除了第三项作为必要原因；原有稳定根选择性核验回归覆盖第二项。只限制所选范围使持续写入回归变绿，支持第一项。

最小修复只将选择性 `verify` 的实际文件探测/分组限定于所选文件。仍保留全根目录项以核对关联安装记录的必要文件存在性，保留所选文件的真实全量 SHA、前后大小/修改时间、真实文件/规范路径、分组变化检查；不读取无关传输文件。仅替换所选清单行，其他行保留原基础快照。原始原生脚本随后重跑成功，见上方最终证据。未加入生产 DEBUG 插桩。

## 修复前真实清单（保留）

默认 `scan(Directory('/Users/ghost233/.lmstudio/models'))` 用时 **2742 ms**，返回 **166 个资产 / 243 个被代表文件**。这是一轮实测，没有据此声称延迟分位数、内存或长期吞吐。

| 维度 | 实际结果 |
| --- | --- |
| 类型 | unknown 160；decision 2；chat 4 |
| 结构完整性 | unknown 159；complete 3；incomplete 1；corrupt 3 |
| 引擎能力 | awaitingVerification 166 |
| 全量内容指纹资产 | 0 |
| 来源已核验资产 | 0 |

Kev 按实际字节与 metadata 识别为 `GGUF / qwen35 / decision.type=kev`，结构状态 `complete`。文件为 `/Users/ghost233/.lmstudio/models/ggml-org/Kev-0.8B-GGUF/Kev-0.8B-Q8_0.gguf`，实际大小 `812406304` bytes。此轮只有明确标记的基础清单与 `16777216` 字节前缀指纹；`files[].sha256=null`、`fingerprintKind=inventory`、`fingerprintsVerified=false`、`sourceVerified=false`。记录关联的 repo/revision 为 `ggml-org/Kev-0.8B-GGUF@e551e319d483ff57e1ff208924b349d397cffc1c`，许可证字段为 `apache-2.0`。

## 修复前有界保全证据（保留）

生产操作前后，对 **261 个既有普通文件**逐项记录并比较：绝对路径、实际大小、UTC 修改时间、最多 **512 字节**的实际前缀内容。总大小 `263836497710` bytes；每轮实际保全前缀共 `132756` bytes。没有链接记录。

前后路径集合、大小、修改时间和所读前缀均相同：**移除 0、新增 0、变化 0**。排序后上述完整快照的 canonical JSON SHA-256 前后均为：

```text
50581a305c0dbc9ba9b3929d30e3d51eaee32c785c2045a478f3e927500af60d
```

这是有界保全检查，**未计算或证明全部约 246 GiB 文件内容的全量 SHA-256，也不能排除前缀之外且不反映于大小/修改时间的外部修改**。快照中的原始前缀在脚本内存中逐项比较；报告只记录汇总与快照摘要。

排除 `.jevmanager/`、本任务新增的 `ggml-org/Kev-0.8B-GGUF/` 和 `ggml-org/Laya-GGUF/`，避免把新增应用记录或并发下载增长当作扫描修改。还明确排除观察到的 LM Studio `downloading_*.gguf.part`，不停止、不改动它们。并发任务位于 `nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF/`，本次前后观察为：

| 临时分片 | 前大小 | 后大小 |
| --- | ---: | ---: |
| 00001-of-00003 | 17595458922 | 17867293609 |
| 00002-of-00003 | 17829552073 | 18084885993 |
| 00003-of-00003 | 9171928926 | 9171928926 |

第一次尝试在调用任何生产扫描之前就观察到分片写入，故将其单独列为并发传输范围。上述增长不作为扫描修改证据。本次没有观察到临时分片完成后的新增正式文件。

## 修复前 Kev 选择性核验失败（保留）

只选择 Kev 清单 id `716b7180cc1f3edee55fc48795aa6371ff89cf654a17ac0aa47857742940c1a4` 调用 `verify([id])`。**7451 ms 后失败**：

```text
verify: 所选资产文件组已变化，请重新选择并核验
library.state.error: 文件在扫描期间变化，请重新扫描
```

这次选择性入口重新扫描了整个共享库；无关的 LM Studio 临时传输在扫描期间变化，引发全局中断。它没有返回 Kev 全量 SHA/sourceVerified 结果，因而不能声称生产 ModelLibrary 已完成 Kev 上游来源核验，也不能以失败后空清单的计数证明其他资产状态。

该失败已经通过上方范围隔离修复与原始重现命令重跑收口。引擎准入仍须检查成功返回的全量 SHA、来源与结构状态，并实际验证引擎/实例能力；文件清单或来源校验不表示推理实例就绪。本记录不替代 root 后续的原生 UI 验收。

## 重现命令

```bash
/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart \
  --packages=.dart_tool/package_config.json \
  .tooling/implementation/live-library.dart
```

脚本确认已保存目录精确匹配所选共享根，保存操作前后有界快照，在 stdout 输出实际 JSON 结果，并在保全差异或选择性核验失败时以非零状态退出。

## Laya 标量 scorer：真实文件补充验收

原生 GUI 曾将已下载、上游哈希匹配的 Laya Q8 标成 `incomplete`，诊断为 `决策 head 或 scorer 尺寸不符`。对实际文件只读 2 MiB，解析了 1,784,629 字节 GGUF 文件头及 201 个 tensor；读取前后大小/修改时间相同。实际 embedding 为 1024，30 个 block 中末两个为决策 head；两个 head 的 QKV 均为 `[1024,3072]`，FFN 上投影 `[1024,4096]`、下投影 `[4096,1024]`，均符合已有检查。实际 `token_types.weight=[1024,3]`，但 `cls.output.weight=[1024]`（BF16）、`cls.output.bias=[1]`。

固定版 llama.cpp 的 [classifier 默认参数](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/src/llama-hparams.h#L239) 为单输出；[ModernBERT 决策图](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/src/models/modern-bert.cpp#L242) 为三种问题类型分别执行标量 scorer，再拼接结果。三个类型不是 scorer 的输出宽度。[tensor loader](https://github.com/ggml-org/llama.cpp/blob/836d57176dc699a726c55418e4f96b8ca628e1bf/src/llama-model-loader.cpp#L804) 比较补齐末尾 `1` 的维度。因此本次只修正 scorer 的标量宽度与末尾单例轴比较，其他 head、tokenizer、模板、文件范围、来源及引擎状态检查保持不变。

公开 `ModelLibrary.scan` 的真实临时 GGUF 回归先在容器变红（`run-Wn1K2z`，期望 `complete`、实际 `incomplete`），修复后八个 library 用例通过（`run-I2LwuL`）。同一 Laya 回归还验证显式单例矩阵可接受，三输出 scorer 会被拒绝；没有扩大 FFN 准入规则。

**2026-10-04 13:28:38 UTC**，使用已有 Dart SDK 和项目 package config 运行只读诊断脚本：

```bash
/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart \
  --packages=.dart_tool/package_config.json \
  /private/tmp/jevmanager-laya-admission.dart
```

脚本确认已保存根仍为 `/Users/ghost233/.lmstudio/models`，调用生产默认 `scan`，再仅对实际 Laya id 调用 `verify`，退出码 **0**。本轮最终生产源 SHA-256 为 `0a8bf5dbc65a0025939d0d02d04510f934076c681f5cc05a0d61f9661ec32733`，包括对应 Safetensors 的两个尺寸字面量修正。

| 项目 | 实际结果 |
| --- | --- |
| 默认扫描 | 3239 ms；169 个底层资产 |
| Laya 基础清单 | GGUF / modern-bert / laya / complete；inventory，完整 SHA 空、来源未核验 |
| Laya 选择性核验 | 2827 ms；complete，诊断为空 |
| 实际文件 | `/Users/ghost233/.lmstudio/models/ggml-org/Laya-GGUF/Laya-Q8_0.gguf`，449397600 bytes |
| 全量内容 SHA-256 | `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2` |
| 指纹 / 上游来源 | fullContent；fingerprintsVerified=true；sourceVerified=true |
| repo / 固定 revision | ggml-org/Laya-GGUF / da4b4753d62197659d8c90103cd4c43bef9afea6 |
| 其他资产的全量指纹数 | 0 |
| 引擎能力 | awaitingVerification |

所选文件规范路径、大小、UTC 修改时间 `2026-10-04T08:55:39.967681Z` 与实际 512 字节前缀前后相同；前缀 SHA-256 为 `85147657b5fc4069831fca65c6856ad40fb6bf4fd7fb9c9bafeea5cf13bf6ad5`。本轮没有重做整库保全基线，不能以所选文件检查声称全部共享库字节被证明未变。未启动模型引擎、调用推理、修改权重或停止 LM Studio 传输。

此前 **13:11:16 UTC** 的同一原生公共入口也已通过：源 SHA-256 `940a2888c941cca990117d16cca4893c403c6951ea14360a8c61756ced4f2275`，默认清单 2937 ms / 170 个底层资产，Laya 核验 2688 ms。该轮 SHA、来源、能力状态及所选文件保全结果与最终轮相同；清单数是各轮实际观察值，不作为整库稳定性的证明。

对应原始 Safetensors 也存在相同维度差异：对[固定 multilingual 文件](https://huggingface.co/convaiinnovations/laya-multilingual/resolve/1720e3e3357cfe1e281542e223f8273b0890ca34/model.safetensors) 的两次 HTTP Range 请求均返回 206，只获取 8 字节长度及 17,504 字节文件头，没有 tensor 载荷。实际 `scorer.3.weight=[1,768]`、bias `[1]`，而 `type_emb.weight=[3,768]`。这提供对应原始文件检查的独立形状证据，不代表 multilingual 模型已加载、中文质量已验证或引擎就绪。

将上述形状按 hidden=1 缩小后写入真实临时 Safetensors 包，通过既有公开 `ModelLibrary.scan` 回归捕获 RED（`run-HRMvbb`，complete/adapter/missing/damaged 用例期望 `complete`、实际 `incomplete`）。生产仅将 `scorer.3.weight` 输出宽度和 bias 长度从 3 修正为 1，保留 `type_emb.weight` 的三个类型及所有其他检查；没有运行本机通用测试。

最终源的整套 51 项容器测试通过（`run-eWZBC7`），包含上述 Safetensors GREEN；静态分析无问题（`run-TU26Qi`）。正式 release 桌面重新构建并通过 CUA 实际核验 Laya，显示完整资产、上游来源通过及准确完整 SHA，能力仍为待验证。桌面证据见 [模型包验收](model-package-live.md)。
