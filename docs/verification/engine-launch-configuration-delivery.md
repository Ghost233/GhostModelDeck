# 引擎启动参数配置交付入口

规范：[引擎启动参数配置：文本优先、模型独立配置与最终命令预览规格](https://github.com/Ghost233/GhostModelDeck/issues/44)。本记录只报告实际证据，不表示整份规格已经完成。

2026-10-08 开始交付，用户明确授权基线提交、阶段及集成分支、阶段 PR 合入集成分支；总 PR 交付为 ready，合入 main 仍需明确要求。沿用同一 checkout，不创建额外 worktree。没有启用 Goal 硬预算或执行截止。

## 当前状态

- 当前实施：[保留升级与解除关联后的启动配置并支持手动恢复](https://github.com/Ghost233/GhostModelDeck/issues/49) 与 [提供 oMLX 参数保存与识别并明确当前运行限制](https://github.com/Ghost233/GhostModelDeck/issues/50)，均分配 Ghost233，执行者 `/root/implement_45` 与 `/root/engine_argument_grammar`，协调 `/root`。共享 checkout 按文件所有权与单一检查租约协调。
- 总基线 `d0d14efe5b90f9b1fe25aace9403df03f9fd581e`，main 本地与实际远端保持该 SHA，参数总 PR 尚未合入 main。
- 前三阶段 [默认启动配置与完整预览](https://github.com/Ghost233/GhostModelDeck/pull/52)、[文本优先与原生诊断](https://github.com/Ghost233/GhostModelDeck/pull/54)、[模型独立启动配置与当前版本参数识别](https://github.com/Ghost233/GhostModelDeck/pull/55) 已实际合入集成分支，#45–#48 已验收关闭。集成与第三阶段分支本地/实际远端均为 `09d5ff2f8b64be1c5452d67a9d98a6b809d05ef2`；第一、二阶段分支分别保留已同步的 `97c8ff6a22b096a97a38a409027cc563e022ed75`、`1f35464c09d8a0f16301925fec248f7b63002214`。
- 当前分支 `codex/engine-launch-lifecycle-omlx`，第四阶段基线 `09d5ff2f8b64be1c5452d67a9d98a6b809d05ef2`。总 PR [引擎启动参数配置、文本优先与模型覆盖](https://github.com/Ghost233/GhostModelDeck/pull/53) 目标 main，仍为草稿。
- 第三阶段最终95文件格式/零诊断分析/583项全量、Mac、JEV与标准各16条真实断言通过。首审两P2经20公开回归、复盘及双轴增量复审关闭，最终记录增量复审亦为0；实际 MERGED 与同步 hash 在 `stage47-48/integration.json`。
- 有效作业、每次输入指纹、真实退出码及下一动作在 `.scratch/engine-launch-delivery/delivery.json` 和 `checks/*/result.json` 更新；恢复时先核对作业结果，不因原会话句柄失效重开作业。

## 真实路径证据

第二阶段实现已冻结并完成所属 144 项测试和最终联网门禁：93 个格式文件零改动、分析零诊断、557 项全量测试通过。真实 JEV 验收 32 条业务断言通过：文本 `-c 1024` 覆盖表单 2048，软件管理字段保持真实路径/标识/监听，`/props.n_ctx=1024`；保存保持运行 PID 与原命令；非法整数到达原生进程并显示 stderr，未出现 Ready；未闭合引号可保存、位置10错误且无进程或实例创建。全部本次进程退出、端口释放。证据在 `.scratch/engine-launch-delivery/native-stage46/outcome.json` 与 `native-stage46.exit`，Mac 构建 `stage46-build.exit` 均为 0，输入未变化。第二阶段 merger 核对无发现，首审与复盘发现已完成下述定点修复及复审。

第二阶段首审 Standards 0，Spec 发现 1 个 P2：合成时丢失带引号、转义的选项形状值角色。以真实编辑/保存/启动链路复现后，词法保留来源，仅在已知参数等待值时使用，独立选项与缺值软提示保持。11 组成对边界和所属 145 项通过；修复后的最终格式/分析退出码 0，全量 558 项通过。实机增加 `--model "-weights.gguf" --alias "-dev"`，实际软件字段和上下文 1024 正确，32 条断言、全部进程与端口回收通过；最终证据为 `native-stage46-p2/outcome.json` 与 `native-stage46-p2.exit`，正确项目环境的 `stage46-build-p2-final.exit` 为 0。最终产品候选 `e92d5a6ff867650b2918280f8ef504532495ddd7` 已经 Standards/Spec 增量复审，首审 P2 关闭，新增 P0/P1/P2 均为 0。报告在 `stage46/standards-final.md`、`stage46/spec-final.md`；首审与增量合起来覆盖第二阶段基线至最终候选。有效门禁输入仍匹配，文档记录增量不改变构建输入。

构建命令曾误写 XDG 配置路径；按创建时间、大小和 SHA-256 确认后，仅清理本次产生的 `tool_state`；`config` 中还存在 SwiftPM 路径，因此保留该目录及上层目录。最终构建使用正确项目环境。

原生拒绝曾被内部退出取消状态遮蔽；修复仅区分意外启动退出与主动 stop/回收，成对测试保持取消优先。词法及 UI 等待的原始失败、容器恢复时未真正运行测试的环境失败，以及测试字面量静态提示均保留在 `checks/stage46-*/`，没有作为成功证据。

最小预检经真实公开关联/模型核验/启动路径加载现有 Kev，达到 Ready 并具备 choice、score、noul 能力；正常停止后模型端口释放，所有本次进程退出。证据：`.scratch/engine-launch-delivery/native-preflight/outcome.json`，退出码 0。

第一阶段真实引擎检查保存上下文 `2048` 后预览并启动同一 Kev，实例记录的 argv 与真正传给 NativeEngineProcessIO 的数组相同，真实 `/props` 回报运行上下文为 2048。运行中再次保存默认值，PID、Ready 状态和原命令保持不变；结束后停止该实例并验证端口释放。最终证据：`.scratch/engine-launch-delivery/native-stage45-final/outcome.json`、`native-stage45-final-inputs.json`、`native-stage45-final.exit`，退出码 0。该检查不代替最后阶段的完整桌面、SDK、真实 llama.cpp/JEV 验收。

使用原有 `Kev-0.8B-Q8_0.gguf`，812406304 字节，SHA-256 `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`；只加载本次实例，未替换已安装应用或修改模型文件。

## 第三阶段当前验证

模型启动覆盖按实际 `LocalModelVariant.id = artifact.id` 与具体登记引擎保存，整份表单及原文独立，继承时仍保留独立内容，空配置与未覆盖分别表达。公开 GUI 编辑/保存/重建/启动和真实 SDK Unix socket 用例已通过；SDK 沿现有 `runtimeFor → startRuntime` 读取同一选择，没有新增配置协议或运行管理器。登记 schema4 读取旧 schema1/2/3，全量解析成功后才注册，孤立登记键的配置保留供后继手动恢复。

当前版本参数识别使用引擎唯一的瞬时元数据，绑定核验路径及内容指纹。帮助补充名称、可靠别名、说明和值边界；未知/语义问题仍仅提示。同一内容读取或解析不足可沿用已观察规则并提示限制；身份失败清除动态规则且原启动门禁拒绝，回收/退出后的晚到结果被丢弃。20 条公开识别用例通过，最终11文件211项相关回归通过；两条分析info以必要花括号及等价测试字符串插值修复，实际输入和业务条件不变，原始失败均保留。

真实标准 llama.cpp 预检发现原关联核验按完整版本输出比较，初始化时间戳变化导致同一二进制被误判。定点红灯后复用已有类型化版本比较版本、build、commit、platform；无法解析时仍原文严格比较，原完整文件指纹、检查前后内容、架构及必需 help 门禁保持。四个真实身份字段、指纹、help 变化仍拒绝的成对回归通过。滚动旧用例的两次原失败均稳定重放；仅增加弹窗关闭前公开帧排空等待，原保存/位置/零启动断言保留，23 项所属文件回归通过。

更新后的 `native-stage47-48-p2-final/outcome.json` 与 `native-standard-preflight-p2-final/outcome.json` 分别完成现有 Kev/JEV 与标准 b11146/Qwen 的 16 条真实断言：独立上下文1024生效，软件字段正确，实际 argv 等于命令快照，默认变化与继承切换不重启或改原 PID/命令，独立内容可恢复，模型完整性未变；各10个本次 child 全退出、端口释放。两份47项源码输入仍匹配，真实退出码均为0。`builds/stage47-48-p2-final/result.json` 的最终正确项目环境 Mac 构建退出0、输入未变。最终容器格式检查95文件零改动、静态分析零诊断、全量583项通过，三个真实退出码均为0且输入未变，记录在 `checks/stage47-48-*-p2-final/`。双轴首审各发现一项P2：本次无调用旧读取方法已删除，同内容部分帮助重列动态别名的canonical关系已修复。真实保存/刷新/预览/启动成对RED→20用例GREEN及修复后最终门禁均通过；复盘在 `stage47-48/retro.md`。修复候选 `02f5ce86fccd9bdf82aed16a174a5da1185951c9` 已完成独立增量复审，两项首审P2均关闭，新增P0/P1/P2各0。报告 `stage47-48/standards-final.md`、`stage47-48/spec-final.md` 与首审共同覆盖第三阶段基线至修复候选。第三阶段已经由PR55实际合入集成分支，#47/#48已关闭。

标准权重恢复由用户明确同意，仅恢复原固定 revision `9217f5db79a29953eb74d5343926648285ec7e67` 的 Qwen 小模型到本次任务目录，491400032字节/SHA256 `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` 已全字节核对。curl退出0；原辅助脚本调用宿主Python3.9不支持的 `hashlib.file_digest` 而退出1，错误保留，兼容的流式SHA256独立验证退出0，不重新下载。该恢复不是本次验证生产下载器的证据。最初标准预检在时间戳误判处退出1、未加载模型，已保留；修复后新目录成功不覆盖旧结果。

## 第四阶段当前验证

配置生命周期使用 schema5 未关联历史及来源记录，兼容旧 schema1–4；默认配置与模型选择/独立内容整份保留，重启可查看具体模型身份、表单和原文。同路径重新登记产生新身份，初始配置保持不变，用户明确选择来源和目标才恢复。受管当前/下一本地固定 curated release 重建保留配置并刷新帮助；外部引擎变更仍要求原核验、重新关联，来源差异按真实版本字段比较，不把时间戳当升级。

解除关联的保存放在原 provider 串行边界内：等待已接受启动，检查无活跃实例，原子保存成功后才解除；Catalog 对新启动持 admission hold。真实写入失败与已接受但尚在身份 I/O 的启动成对回归均通过，失败保留磁盘及内存登记。family 不匹配的默认、模型及历史 payload 全量拒绝，不部分应用。

oMLX 共用配置、编辑器、文本优先及语法保存。family 显式标记，CPP旧payload保持；三个可靠资源字段初始空，当前预览只展示配置结果与不可执行限制。当前帮助在原私有CLI与完整签名/版本/manifest/清理/晚到守卫内取得，可选I/O失败仅提示；配置操作不启池、不载模型，不接通生产运行或Splash。

Merger 首轮确认oMLX登记未保留实际版本/参数来源的P2，以公开save→unlink→restart→history→restore红灯复现，最小字段及来源映射修复。有效CLI观测提供当前版本，未刷新/失败仍未知；已有configurationVersions用显式null保留未知参数来源，多次往返不伪造目标版本。所属11条公开配置回归通过，整数来源JSON整份拒绝。有限merger复核关闭P2，新增P0/P1/P2为0。

最终97文件格式零改动、静态分析零诊断、全量601项测试、Mac构建均真实退出0，输入未变。记录 `checks/stage49-50-*-final2/`、`builds/stage49-50-final2/result.json`。真实JEV/Kev与标准b11146/Qwen各23断言通过，包含保存/继承、解除、新身份不自动套用及显式恢复后再次Ready/n_ctx1024、实际argv一致；各23个本次child退出、两端口回收，47项源输入匹配。证据 `native-stage49-50/outcome.json`、`native-standard-stage49-50/outcome.json`。本阶段正式双轴审查尚待完成，第五阶段完整GUI/SDK/33条故事总验收仍未执行。

原九模块178pass/1旧oMLX文案失败不计整轮通过，精准同步规格限制文案后定点与整个页面5项通过。两个oMLX测试调度中断保留为invalid，即使runner取消退出0也未记通过；精确pump后有效model/help红灯与绿色均有原日志。四条分析info按必要花括号修正，无规则抑制；旧schema来源扩展误强绑定点修复，原业务断言保留。所有失败、副本与当前输入记录由stage49/stage50 handoff索引。

## 已记录的执行故障

第二条红测试最初在页面刷新 I/O 尚未完成时 pumpAndSettle 超时，未到产品断言，不计有效产品红。修正等待真实刷新后，同一用例在缺少完整命令处有效失败，随后最小实现通过；原始日志保留。

拆分历史基线的任务脚本最初缺少部分补丁末尾换行，其后又把被忽略的 Finder 元数据当作 Git 索引文件核对。两次均未提交失败候选。修正后逐个核对所有门禁输入，完成三个基线提交；保留参数工作区改动，不采用 stash/reset/clean 或文件搬移。

## 阶段顺序

完整回归第一次发现五个旧用例在选择引擎后超时。保留的容器失败副本全部 102 个输入指纹一致，单个原用例稳定重现；移除预览中的冗余文件解析，直接读取模型库已经验证的规范路径，真实启动仍保留所有核验。原测试与超时未变，两个原失败定点及受影响模块 43 项通过；构建和真实 JEV 证据按源码变更重新更新。

1. #45 引擎默认表单、保存、预览和启动。
2. #46 参数文本优先、受控字段、提示与实际错误。
3. #47 模型独立配置与 SDK；#48 当前版本识别，可在依赖满足后按文件所有权并行。
4. #49 配置生命周期；#50 oMLX 保存/识别与运行限制。
5. #51 全部 33 条故事、跨入口及真实引擎验收。

后继须等待相应前置验收及阶段审查集成；oMLX 生产运行和 Splash 适配保留既定后续范围。本次不发布正式版本或修改 v0.1.3 资产。
