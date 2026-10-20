# 参数编辑独立审查记录

两轴分别审查固定基准至已提交候选，不以一轴结论抵消另一轴。首审后由单一实现者集中修复，修复后再核对增量及受影响路径。

## Standards

审查候选：`401f34d076bb3cf64eceb3097b4370c22c779ec7`。基准：`6c96dcf31021e8a5207ad352b01d7d038df2b83b`。提交：`401f34d feat: add A parameter editor and explicit drafter configuration`。

比较命令：`git diff 6c96dcf31021e8a5207ad352b01d7d038df2b83b...HEAD`。

硬性违规：0。坏味道判断：1，最高 P3，非阻塞。

- **[P3] 可能存在 Duplicated Code：重复搭建同一测试运行图。** [seed64_generation_test.dart:302](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/test/seed64_generation_test.dart#L302) 与 [generation_runtime.dart:34](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/test/fixtures/generation_runtime.dart#L34) 都创建 Splash 来源、备用 llama 引擎、catalog、实例、路由和网关；两者的关闭顺序也相同。原始 seed 报文需要专用发送逻辑，但无需复制整个资源生命周期。今后调整准备或释放顺序时，两份夹具必须同步修改，容易让 seed 测试与采样、思考测试使用不同环境。最小修复：seed 测试复用已有 `GenerationTestRuntime.create(start: ...)` 和 `close()`，仅保留发送原始 JSON 的局部辅助函数。这是坏味道基线的判断项，不是仓库硬性规则。

覆盖配置元数据与解析、编辑器、实例状态、生成默认值、公开 HTTP 与测试场、草稿资源保护、Splash 准备、鉴权脱敏和相关测试接缝。已对照 AGENTS.md、engineering.md、design.md、CONTEXT.md、spec.md 测试边界、ADR 0009/0010 及 llama.cpp 范围调整。未发现 E02～E07 的新增边界或归属违规；格式和分析事项按要求跳过。

本审查只读源码，未重复运行测试、真实模型或原生窗口验收。主线程提供的门禁结果未独立复现。uint64 测试运行序列化与路径输入焦点疑点已转交 Spec/功能核对，不计入本轴发现。

## Spec

候选：`401f34d076bb3cf64eceb3097b4370c22c779ec7`。基准：`6c96dcf31021e8a5207ad352b01d7d038df2b83b`。命令：`git diff 6c96dcf31021e8a5207ad352b01d7d038df2b83b...HEAD`。提交：`401f34d feat: add A parameter editor and explicit drafter configuration`。

已对照 42 条故事、13 个当前切片及 82 项验收要求。llama.cpp 采用用户批准的官方参数适配范围；不要求逐模式真实配对，也不以草稿活跃度拒绝 Ready。

- **[P2] 短测把合法 uint64 种子编码成字符串。** [model_launch_test.dart:126](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/model_launch_test.dart#L126) 注入生成默认值，131 行仍用 `jsonEncode`。`ExactGenerationSeed.toJson()` 返回字符串，公开网关明确拒绝字符串种子。Splash 高半区种子可以保存并正常调用，却无法从 A 面板“测试运行”。[保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121) 要求“温度与随机种子的精确输入、适用滑块和合法范围与原生契约一致”。改用已有 `encodeGenerationRequest`。

- **[P2] 路径中间编辑会重置光标。** [parameter_value_field.dart:528](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/parameter_value_field.dart#L528) 未绑定 `_focus`。每次输入触发父重建，91 行都会重写控制器文本。插入已有路径中间后，光标跳至末尾。[在 A 面板配置加载资源并验证下次启动生效](https://github.com/Ghost233/GhostModelDeck/issues/119) 要求“连续输入、粘贴、中间编辑、搜索和切组保持值与光标”。绑定同一焦点节点并补公开编辑回归。

- **[P2] Splash 准备期间没有文件保护。** [splash_engine.dart:1821](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/splash_engine.dart#L1821) 执行外部准备时，尚未登记使用文件；818～825 行直到准备返回才加入 `_preparing`。在准备 I/O 暂停时，模型库删除入口仍可删除目标或草稿分片。父规格要求“目标和草稿全部分片共用既有在用保护”；[选择原始 Splash 草稿并完成实际短生成](https://github.com/Ghost233/GhostModelDeck/issues/123) 同时要求公开回归。外部准备前持有文件使用登记，成功、失败和取消后释放。

- **[P2] 修改模式即可确认未经重选的旧来源。** [model_run_dialog.dart:679](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/model_run_dialog.dart#L679) 对任意草稿变更清除 `_legacyDrafter`。打开旧 llama.cpp 配置后，只改模式就保留旧路径并允许保存、检查和启动。父规格要求“用户须重新选择本地来源或明确关闭”，且“旧线索不能自动成为已确认来源”。只在用户确认来源或明确关闭时清除标记。

未发现 P0/P1 或未要求的新增行为。其余要求已核对实现与证据索引；本次未重跑测试、模型或窗口。真实 Splash、compact、认证及桌面结果沿用冻结证据；未把 ANE 效果、性能或逐请求命中扩大为验收要求。以上 4 项修复前，Spec 轴不通过。

## Spec 补核：短测试覆盖值


固定候选：`401f34d076bb3cf64eceb3097b4370c22c779ec7`。本次仅用 `git show` 和 `git grep` 核对已提交内容，未读取后续未提交实现，未运行测试或修改源码。原 4 项报告保持原样。

**[P2] “测试运行”没有解释固定的 32-token 覆盖。** [model_launch_test.dart:121](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/model_launch_test.dart#L121) 固定发送 `max_tokens=32`。第 126 行的合并顺序使这个值覆盖面板中设置的长度上限或明确关闭。唯一调用入口是 [model_run_dialog.dart:317](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/model_run_dialog.dart#L317)。第 755 行按钮只显示“测试运行”，周围没有说明或 Tooltip。[parameter_editor.dart:27](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/parameter_editor.dart#L27) 仍说明“关闭后由引擎按上下文决定”。成功提示位于 [model_launch_test.dart:174](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/lib/model_launch_test.dart#L174)，也没有解释 32 的来源。

父规格 [parameter-editor-spec.md:104](https://github.com/Ghost233/GhostModelDeck/blob/401f34d076bb3cf64eceb3097b4370c22c779ec7/docs/requirements/parameter-editor-spec.md#L104) 规定：“用户主动发起的短测试可以使用明确展示的单次覆盖值。”[配置思考、模板和 Splash 调度并验证下一次请求](https://github.com/Ghost233/GhostModelDeck/issues/131) 的 AC6 同时要求：“显式短测试的覆盖值可以解释。”固定短测本身在范围内，但隐蔽覆盖不满足该限定，因此属于明确缺失，等级为 P2。

最低修复：在实际测试按钮附近显示本次 `max_tokens=32`，说明临时实例会自动停止，保存值保持原样。说明使用与请求构造相同的实际值。模板思考当前仍按配置发送，第 126 行没有强制关闭思考；提示须如实表达这一点。

本补项与初始报告共计 5 个 P2，后续在新提交候选中逐项复审。

## 首审修复后的门禁

Standards 硬性违规 0、P3 判断 1；Spec 首审 4 项，加补核 1 项，共 5 个 P2。修复均已冻结并通过对应受影响回归；最终完整门禁 `run-kmiKaK` 的 1155 项全部通过，随后对已提交候选执行以下复审。

## 阶段复审

### Standards

阶段 R2：基准 `6c96dcf31021e8a5207ad352b01d7d038df2b83b`；已提交候选及核对时 HEAD 为 `929780c1858868722e2c37f314f2b2921db42169`。总比较命令 `git diff 6c96dcf31021e8a5207ad352b01d7d038df2b83b...HEAD`；提交为 `401f34d feat: add A parameter editor and explicit drafter configuration`、`929780c fix: preserve exact test inputs and drafter preparation ownership`。

硬性违规：0。新增坏味道判断：0。沿用首审 P3 判断：1，非阻塞。

复用 `stage-standards-401f34d.md` 的完整覆盖，逐块核对 C1→C2 的 9 个源码/测试文件、3 个文档及其实际调用路径；两轮联合覆盖基准→C2 的全部 62 个变更文件。标准沿用 AGENTS.md、engineering.md E01～E12、design.md、CONTEXT.md、spec.md 已确认测试边界、ADR 0009/0010 和 llama.cpp 范围调整；这些标准文件本轮未变。当前树未发现 CODING_STANDARDS 或 CONTRIBUTING 文件。完整 12 项坏味道基线均作为判断项考虑，跳过工具已强制的格式/分析事项。

修复核对（Standards 视角）：

- E02/E06：[lib/model_launch_test.dart:134](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/model_launch_test.dart#L134) 复用既有精确请求编码器，经公开网关验证精确 seed，没有新建第二套协议入口。
- E05/E07：[lib/parameter_value_field.dart:89](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/parameter_value_field.dart#L89)、`:531` 共用同一焦点节点，局部输入归属清楚；禁用时同步外部清空值。
- E03/E04：[lib/splash_engine.dart:1783](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/splash_engine.dart#L1783)、`:1821`、`:1827` 对每项准备持有独立 owner；外部准备前登记资源，启动前转交 `_preparing`，finally 释放；停止及退出等待已准入任务。相应测试从公开模型库删除和引擎入口验证并发、失败、取消、晚到与收尾，替身限定于进程 I/O。
- E07：[lib/model_run_dialog.dart:85](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/model_run_dialog.dart#L85) 缓存配置与来源确认状态；[lib/parameter_editor.dart:787](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/parameter_editor.dart#L787) 仅明确来源操作或关闭触发确认，模式和调优不改来源权威状态。
- [lib/model_launch_test.dart:15](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/model_launch_test.dart#L15) 与 [lib/model_run_dialog.dart:744](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/model_run_dialog.dart#L744) 共用实际短测上限常量，避免请求与展示产生重复真值。

**保留 [P3] 可能存在 Duplicated Code。** 固定 C2 的 [test/seed64_generation_test.dart:302](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/test/seed64_generation_test.dart#L302) 与 [test/fixtures/generation_runtime.dart:34](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/test/fixtures/generation_runtime.dart#L34) 仍重复搭建和释放同一运行图；今后生命周期变更需同步两份夹具。最低修复仍为复用 `GenerationTestRuntime.create/close`，仅保留原始 JSON 发送辅助函数。这是首审判断项，非硬性规则，本轮不阻塞。

本报告只读固定提交，未运行测试、模型或窗口验收；门禁与原生结果由主线程提供，不声称独立复现。此为阶段复审，不代替集成后的总跨流程审查。

### Spec

已断言最终工作树 HEAD 为 `929780c1858868722e2c37f314f2b2921db42169`。基准为 `6c96dcf31021e8a5207ad352b01d7d038df2b83b`，审查命令为 `git diff 6c96dcf31021e8a5207ad352b01d7d038df2b83b...HEAD`。提交为 `401f34d feat: add A parameter editor and explicit drafter configuration`、`929780c fix: preserve exact test inputs and drafter preparation ownership`。

复用首审及短测补核的 42 条故事、13 切片和 82 项验收覆盖，完整检查 C1→C2 的 9 个源码/测试文件、3 个文档及受影响调用路径。代码证据均来自 C2 的 `git show`。

五项 P2 均关闭：

- **精确 seed。** [model_launch_test.dart:134](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/model_launch_test.dart#L134) 使用统一公开编码器。满足 [保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121) AC3“合法范围与原生契约一致”。公开短测断言精确数字、边界拒绝及临时实例收尾；原生 GUI 的 uint64 最大值短测也已成功。
- **路径光标。** [parameter_value_field.dart:531](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/parameter_value_field.dart#L531) 绑定原有焦点节点。满足父规格第 72 行“连续输入、粘贴和中间编辑保持正常焦点与光标行为”。公开 A 编辑回归覆盖中间插入、连续粘贴、取消及保存重开。
- **准备资源保护。** [splash_engine.dart:1838](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/splash_engine.dart#L1838) 在外部准备前登记独立文件使用者，finally 释放；1799 行在释放前移交启动保护。满足第 152 行“目标和草稿全部分片共用既有在用保护”。回归覆盖分片、失败、取消、并发、移交及退出等待。
- **旧来源确认。** [parameter_editor.dart:794](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/parameter_editor.dart#L794) 仅由来源动作或明确关闭确认；组合缓存保留未确认状态。满足第 94 行“用户须重新选择本地来源或明确关闭”。模式、调优及切换组合均不能绕过。
- **短测覆盖说明。** [model_run_dialog.dart:745](https://github.com/Ghost233/GhostModelDeck/blob/929780c1858868722e2c37f314f2b2921db42169/lib/model_run_dialog.dart#L745) 明示本次 32 token、思考模板沿用配置和临时实例停止，使用请求同一常量。满足第 104 行“明确展示的单次覆盖值”及 [配置思考、模板和 Splash 调度并验证下一次请求](https://github.com/Ghost233/GhostModelDeck/issues/131) AC6。原生浅色 100% 和深色 150% 均已观察可见。

要求缺失或部分实现：0；范围蔓延：0；错误实现：0。剩余 P0/P1/P2：0，当前阶段 Spec R2 通过。

已核对四项有效红灯、152 项关联回归、1155 项完整门禁和 34 项布局证据。9 个增量源码/测试与冻结输入一致；157 项生产输入与 C2 Git blob 全部一致，产物为 arm64。两组真实 Splash 和原生窗口结果保持原观察边界。未增添 ANE、性能或 Schema/思考命中实测门槛，未把 llama.cpp 未知活跃状态升级为致命判断。本审查未重跑测试或模型；[在原生桌面完成配置、调用与退出并交付最终候选](https://github.com/Ghost233/GhostModelDeck/issues/127) 后续集成、工单及总 PR 交付和总审查仍由主线程完成。

## 当前结论

Standards：硬性违规 0，保留 P3 判断 1；Spec：五项 P2 全部关闭，剩余 P0/P1/P2 为 0。运行候选固定为 `929780c`，后续仅记录验收结论的文档提交不改变产品输入。集成后的总 diff 与跨流程审查另行执行，阶段报告不代替总审查。
