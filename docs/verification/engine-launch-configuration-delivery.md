# 引擎启动参数配置交付入口

规范：[引擎启动参数配置：文本优先、模型独立配置与最终命令预览规格](https://github.com/Ghost233/GhostModelDeck/issues/44)。本记录只报告实际证据，不表示整份规格已经完成。

2026-10-08 开始交付，用户明确授权基线提交、阶段及集成分支、阶段 PR 合入集成分支；总 PR 交付为 ready，合入 main 仍需明确要求。沿用同一 checkout，不创建额外 worktree。没有启用 Goal 硬预算或执行截止。

## 当前状态

- 当前实施：[打通引擎默认表单参数的编辑、预览与启动](https://github.com/Ghost233/GhostModelDeck/issues/45)，负责人 Ghost233，执行者 `/root/implement_45`，协调者 `/root`。
- 固定总基线与第一阶段基线：`d0d14efe5b90f9b1fe25aace9403df03f9fd581e`。已有显示名、SDK 菜单栏接入及确认规格分为三个提交，已从本地 main 推送并核验实际远端相同。
- 第一阶段分支：`codex/engine-launch-defaults`；集成分支：`codex/engine-launch-configuration`；总 PR 目标：main。
- 阶段候选以阶段提交及工作记录中的 SHA 为标识。五条定点场景已通过：表单保存/重建恢复、模型运行预览/复制/实际 argv、保存与清空仅影响后续手动启动、管理页即时预览/复制、受管 JEV/标准/关联登记项隔离及重建恢复。
- merger 首核对与增量核对、Standards/Spec 双轴首审均为 0 项发现。修正预览冗余 I/O 后，原两个失败定点与受影响模块 43 项均通过；最终格式检查 92 文件零改动、分析零诊断、全量 548 项测试、Mac 构建及真实 JEV 检查均退出码 0，输入未变化。复盘无本阶段未关闭的已确认 P0/P1/P2，复审确认记录增量后才合入集成分支。
- 产品候选 `3223f3deacf2d6f4c87daae84e951f8015de9cca` 的首审报告及复盘保存在 `.scratch/engine-launch-delivery/stage45/`。已确认本阶段 P0/P1/P2 均为 0；阶段 PR 与工单验收仍以实际集成及远端记录为准。
- 有效作业、每次输入指纹、真实退出码及下一动作在 `.scratch/engine-launch-delivery/delivery.json` 和 `checks/*/result.json` 更新；恢复时先核对作业结果，不因原会话句柄失效重开作业。

## 真实路径证据

最小预检经真实公开关联/模型核验/启动路径加载现有 Kev，达到 Ready 并具备 choice、score、noul 能力；正常停止后模型端口释放，所有本次进程退出。证据：`.scratch/engine-launch-delivery/native-preflight/outcome.json`，退出码 0。

第一阶段真实引擎检查保存上下文 `2048` 后预览并启动同一 Kev，实例记录的 argv 与真正传给 NativeEngineProcessIO 的数组相同，真实 `/props` 回报运行上下文为 2048。运行中再次保存默认值，PID、Ready 状态和原命令保持不变；结束后停止该实例并验证端口释放。最终证据：`.scratch/engine-launch-delivery/native-stage45-final/outcome.json`、`native-stage45-final-inputs.json`、`native-stage45-final.exit`，退出码 0。该检查不代替最后阶段的完整桌面、SDK、真实 llama.cpp/JEV 验收。

使用原有 `Kev-0.8B-Q8_0.gguf`，812406304 字节，SHA-256 `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`；只加载本次实例，未替换已安装应用或修改模型文件。

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
