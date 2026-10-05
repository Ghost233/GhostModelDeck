# LM Studio 接入的行为验证

日期：2026-10-04。对应 [#14](https://github.com/Ghost233/JevManager/issues/14)。本记录是容器行为测试和只读 CLI 观察；真实模型加载、接口探测与卸载由主线程另行验收，不能由替身响应推断支持。

## 公共入口与真实接缝

桌面使用 `LmStudioProvider` 的 `refresh`、`confirmModelLibrary`、`load`、`probe`、`decide` 和 `stop`。`EnginePage` 使用同一入口，不自行实现另一套推理或所有权逻辑。

测试只替换外部 CLI 进程响应，HTTP 使用真实 loopback `HttpServer`。模型库是实际 `ModelLibrary`；资产夹具是临时目录中的有效 GGUF 结构，经过公开扫描与完整内容核验，不 mock 模型库或内部校验器。夹具不证明真实权重可推理。

`DecisionRequest` 冻结上下文、问题和稳定候选 ID；响应必须对应所选实例、覆盖相同候选 ID、为有限的 `[0,1]` 数值、总和误差不超过 `0.0001`、选择属于候选集合，并且 `usage.output_tokens` 为零。概率保持原值，不修补、重归一化，也不从普通聊天、score 或 confidence 合成。

## 红绿与最终检查

| 行为 | RED | GREEN |
| --- | --- | --- |
| 真实 CLI / 默认 runtime / 模型和实例发现 | `run-UTM5qb`：公共模块未实现 | `run-E7e9CQ` |
| 401、404、typed choice 与严格实例响应 | `run-e7JIIS`：公共入口未实现 | `run-vIhLpK` |
| 精确本地加载、受管归属、运行文件保护和精确停止 | `run-8pbCVT`：加载入口未实现 | `run-DIZyFI` |
| 等待响应期间实例被替换 | `run-VM5aNG`：错误接纳旧响应 | `run-L5hQ5K` |
| 紧凑引擎页面和接入实例操作 | `run-utOOgL`：页面未实现 | `run-Wggo10` |
| 旧 CLI 缺少 device 字段时的保守使用保护 | `run-6rBQ0R`：错误允许删除预览 | `run-AkACoW` |
| 等待响应期间出现重复实例 ID | `run-I4HPbn`：错误接纳歧义响应 | `run-D66qxq` |
| 已有接入 / 不确定实例运行期间修改关联目录 | `run-2s2cqx`：错误允许解除原目录保护 | `run-DPcunB` |

另有现成行为验收覆盖聊天、score、错模型、错候选、负概率、范围外概率、未归一化、非数值、无效选择、非零生成 token、HTTP 501、真实 HTTP 断连，以及 CLI 加载超时后出现实例、清单失败与之后确认实例不存在。`run-W1hmWt` 的 9 项本票测试全部通过。

最终全仓容器测试 `run-DPcunB`：**60 项通过**，包含主线程新增的引擎导航与模型包文案。随后仅对本票五个文件执行容器 Dart formatter，逐文件 base64 导出并核对 SHA-256；容器静态分析 `run-c0NEeJ`：**No issues found**。日志位于 `.tooling/container-tests/<run-id>/result.log`。

格式化后的生产源码 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `lib/lmstudio_provider.dart` | `431fc14f2256548eb33e97c9a1bd6e71879b267d3c893836ba6409cabe349180` |
| `lib/decision_protocol.dart` | `837245bb3dfb5c22e84a486964d12b4c19f4c0793a6ba44e84009fa4945fbdbb` |
| `lib/engine_page.dart` | `76804463b80008729e0b4378b4e99b9c658675cf175cc2a24f6756e9e049ea8a` |

## 所有权和状态的实际含义

- 发现现有实例仅标为接入。标识前缀、模型显示名、同名路径或一次 load 返回值都不能授予归属。
- 用户必须明确关联 LM Studio 模型库目录。CLI 清单只有相对路径，不能自行假设它采用默认目录。
- 受管加载要求完整且已全内容核验的决策资产、唯一明确本地清单记录、精确格式 / 路径 / 大小匹配，以及经验证 CLI commit `69d945a`。调用公开 CLI 的版本限定 `--exact --local` 路径，使用全新高熵标识；成功退出和事后实例身份一致才标为受管。
- 冷加载预算为 120 秒，独立于默认 10 秒决策 HTTP 预算。超时或失败后重新发现；无法确认创建归属的实例保持接入，不自动卸载。无法完成清单核验时保留文件使用保护。
- `stop` 先重新发现，仅对当前仍能确立归属的单个精确标识调用 unload。发现不存在或身份改变会撤销归属；停止用户原有或不确定实例会被拒绝。不会停止 LM Studio 应用、daemon 或 HTTP 服务。
- 归属只在当前 JevManager 进程内有效。重启后的已加载实例重新作为接入。CLI 没有不可变实例引用，因此无法证明另一个进程在两次观察之间用相同 ID 和路径卸载并重建的连续性；本实现不宣称解决了这个公开 CLI 限制。
- Runtime 列表是安装版本与格式默认选择，不能归到某个已加载实例。实例 runtime 版本保持未知；CLI commit 也不是 LM Studio 应用版本。未获得应用版本事实时显示未知。
- HTTP 401/403 是需要认证；404/501 是实际 typed 路由或能力缺失；连接异常 / 超时与无效响应分别呈现。实际返回符合契约的分布后才就绪。令牌只在内存和隐藏输入框中使用，不自动读取凭据、不写入磁盘或日志、不更改 LM Studio 认证设置。

引擎页面没有初始化教程；文件、模型和实例状态直接可访问。接入实例没有停止按钮，原始成功响应按需展开。补充引擎仅为回调入口，未实现的引擎不会显示成功。

本 worker 的只读原生观察：`lms --version` 为 `CLI commit: 69d945a`，`runtime ls` 显示当前默认 GGUF runtime `llama.cpp-mac-arm64-apple-metal-advsimd@2.50.0`，`ps --json` 返回空数组。没有执行原生 load/unload 或权重推理。固定 CLI 契约研究见 `/private/tmp/jevmanager-lmstudio-cli-contract.md`；真实验收将单独记录。
