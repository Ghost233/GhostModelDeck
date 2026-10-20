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

## 当前状态

Standards 硬性违规 0、P3 判断 1；Spec 首审 4 项，加补核 1 项，共 5 个 P2。修复均已冻结并通过对应受影响回归；最终完整门禁 `run-kmiKaK` 的 1155 项全部通过，已提交候选复审仍待完成。
