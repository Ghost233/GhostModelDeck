# 引擎启动参数：真实 GUI 与原生运行记录

日期：2026-10-09。来源规格：[引擎启动参数配置](/Users/ghost233/Ghost233Code/GhostModelDeck/docs/requirements/engine-launch-configuration-spec.md)（#44、#51）。状态：**1340构建的运行证据及新构建两项P2复验已取得；最终集成交付仍在进行。**

本记录整理 Root 实际操作的构建 app，源码为 `1340af9714ee2a78cde2c167e100ef4e5e8409f8`。不是后来 Splash 增补或 UI P2 修复后的新构建。整理者没有重跑 GUI、native 模型或检查，没有修改 lib/test、容器、用户服务或 Git。33 条故事的逐项证据类型及开放项见 [acceptance-plan.md](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/acceptance-plan.md)。

## 四个真实 GUI 运行组合

总记录为 [four-combinations.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/four-combinations.json)。模型来自用户已授权的既有 Kev 与 standard Qwen GGUF，没有用 synthetic 模型或仅帮助输出替代加载/参数生效。

| 登记与模型 | 保存选择及实际结果 | 原始记录 |
| --- | --- | --- |
| managed JEV + Kev | 默认 form ctx2048，raw `-c 1024`，同时尝试覆盖 model/alias/host/port。真实 UI Ready，native `/props` ctx1024，b11381；JEV choice HTTP200、有实际概率/用量。PID10422、port52883，随后 UI stopped/port关闭。 | [默认保存](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-jev-default-save.json)、[props](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-jev-props.json)、[choice](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-jev-decision.json)、[收尾](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-jev-completion.json) |
| linked JEV + 同一 Kev | 具体外部登记的模型独立完整配置ctx1536、raw空，受管默认保持。native `/props` ctx1536、实例alias绑定，实际choice结果；port53809。 | [独立保存](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/linked-jev-independent-save.json)、[运行](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/linked-jev-running.json)、[停止](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/linked-jev-stopped.json) |
| managed standard + Qwen | 模型独立 **form{}、raw空**，执行仅软件管理参数，未回退注入软件ctx4096。native实际默认ctx32768、b11146；文本“OK”、completion_tokens2、Ready；port54566。该32768来自props观察，未预设。 | [空配置](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-standard-empty-save.json)、[运行](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-standard-running.json)、[停止](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/managed-standard-stopped.json) |
| linked standard + 同一 Qwen | 另一具体登记保存ctx768，native props实际ctx768、b11146，文本“OK”、completion_tokens2、Ready；port55831。 | [运行](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/linked-standard-running.json)、[停止](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/linked-standard-stopped.json) |

真实生效依据是原生 props 与业务响应，未将“收到 argv”“进程尚在”“--help 成功”当成 Ready。各 JSON 的 model/alias/port 保留实际归属。更完整 argv/PID/generation 对照由已有 native driver 与 SDK04 记录提供，不给本轮 GUI JSON 补造未单列的数据。

## 运行中保存、错误与重启

[linked-jev-save-while-live.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/linked-jev-save-while-live.json) 记录 next ctx2048 已保存，已有实例仍ctx1536、同alias/port53809，继承/独立往返内容保持。这是实际 GUI 的不自动重启证据；SDK04另有真实PID/gen/命令/下一start完整49断言，来源同1340，不能与 GUI 记录混称一条流程。

[semantic-error.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/semantic-error.json) 记录 form `--ctx-size not-an-integer` 可保存、预览保留并显示 soft notice。实际 native **exit1**，UI显示 `stoi: no conversion`、failed且无Stop按钮，未用 UI 提前拒绝语义代替引擎诊断。

[lexical-error-save.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/lexical-error-save.json) 与 [lexical-start-blocked.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/lexical-start-blocked.json) 记录实际已保存 `--ctx-size "u`，位置12引号未闭合、preview隐藏、Run禁用、没有新增Ready。原生零spawn矩阵沿用N46，未把该GUI字段“无新增Ready”改写为独立PID统计。**requested `--ctx-size "unfinished` 未完整进入：焦点丢失使actual仅为 `--ctx-size "u`；此项是开放P2，不计连续输入成功。**

[normal-exit.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/normal-exit.json) 记录 app91241 正常退出、四模型端口关闭、任务配置保持。[restart-configuration-restored.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/restart-configuration-restored.json) 记录同旧构建重新打开、两条linked登记、保存的默认/模式与实际raw保持；词法原文修复为空，form768回读。该记录没有宣称修复了焦点或已经运行新的候选。

## 解除关联与显式恢复

[unlink-history.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/unlink-history.json) 记录标准外部登记被解除，历史含完整ctx768与raw，外部文件仍存在，SHA为 `41df13c126456f8e5fab2057c86a790067a85ea1dfd8fbc0071cc45fbba56262`。

[relink-no-auto-restore.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/relink-no-auto-restore.json) 记录同一外部path产生新ID，默认保存项不存在，UI preview4096，旧history768；没有按path/同family自动套用。[explicit-restore.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/explicit-restore.json) 记录用户明确恢复到新登记，whole default/model map恢复ctx768，历史保留，外部binary SHA保持。

这里是同版本解除/新登记/显式恢复，不是旧→新引擎版本升级。没有合法已核验的物理旧→新目标时，版本升级/刷新使用E49公开可控安装I/O、typed身份/参数来源及已有native证据，并明确保留实机升级分支缺口。同模型不同量化也没有本轮实机组合：同Kev跨具体登记和两个不同asset不是量化对；对应隔离矩阵由E47真实业务＋外部I/O证据覆盖。

## oMLX 配置边界

[omlx-configuration-save.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/omlx-configuration-save.json) 记录 form max-concurrent-requests2、raw3，覆盖标红、preview仅配置参数3、`configurationOnly=true`。该oMLX未安装，实际help状态为 `unavailable_builtin`，保存与限制文案成立，未宣称本次当前help成功、Ready、参数实际生效或生产模型加载。Splash属于用户新增#57独立规格，其运行验收不由本记录覆盖。

## 用户配置恢复和资源归属

[配置备份manifest](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-user-config-backup/manifest.json) 在操作前记录六个存储文件的存在状态：仅原 `download-preferences.json` 存在（21B、SHA `aba22022a8a9d38c9e8c7506a8ecbb30dfeccda46854d0e7ee9ac1364c4ee52c`）。任务创建settings/engines，最后写入指纹见 [task-written-config-latest.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/task-written-config-latest.json)。

[configuration-restoration.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/configuration-restoration.json) 确认 own app 全退出，四ports52883/53809/54566/55831关闭，原文件未变、原存在/不存在状态复原。仅确认由任务创建的settings/engines被可恢复移动到 [task-created-after-acceptance](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-user-config-backup/task-created-after-acceptance)，没有移动原有用户配置。原startup-models/jev/public的None状态复原；installed managed engine文件和模型权重留在原地。

Root随后已追加 [model-files-after.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/model-files-after.json)：Kev812406304B/SHA `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`、Laya449397600B/SHA `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2`、Qwen491400032B/SHA `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`，fullSHA均匹配。另 [engine-files-after.json](/Users/ghost233/Ghost233Code/GhostModelDeck/.scratch/engine-launch-delivery/stage51/gui-records/engine-files-after.json) 记录74项关联指纹及两受管binary匹配；symlink身份采用`link:target`摘要。最初runner误将该摘要按file内容SHA比较而失败，原错误和更正已保留，不能说引擎曾变动，也不能抹掉原验证错误。

原用户配置已完全恢复；留存目录只有本轮自建settings/engines的可恢复副本，不列为用户备份未恢复。Root亦已在正常restart后实际查看合法ctx768 preview。用户外部 Splash 8008 服务不在本GUI验收归属内，未据本记录停止或修改。

## 两项P2的新构建复验

构建输入和实际退出记录为 `.scratch/engine-launch-delivery/builds/splash-core-final/result.json`，Mac release build实际exit0、inputs unchanged；当前源码尚未增加#60接线。完整格式零改动、分析零诊断及635项全量测试均退出0，分别为 `checks/splash-core-final-{format,analyze,test}/`。

Root打开该新构建，oMLX表单并发2，直接键盘输入完整 `--max-concurrent-requests "unfinished`。未闭合引号第27位错误出现后输入框仍保留焦点，文字完整、表单仍为2；随后按实际截图坐标以鼠标直接单击Save（没有先点击标题或取消焦点），原文与表单完整持久化。证据为 `gui-records/p2-current-mouse-save.json`，不把这份不能执行的配置误称参数生效。

同一新构建引擎页在真实b11146 CLI初始日志前缀存在的情况下，版本标签显示 `0.5.0-dev · 7fe450e19`，不再显示计时日志。两项旧P2的产品问题已通过公开Widget及实际Mac GUI复验；最初oMLX保存测试的遮挡是缺少实际pointer/caret滚动的输入替身造成，fresh mouse/touch对照和完整保存断言均保留在 `splash-ui-work/p2-diagnosis.md`。

最后正常菜单Quit，应用退出后逐文件核验本轮写入SHA，唯一新增engines配置可恢复移到 `gui-user-config-backup/p2-current-task-engines.json`；原业务文件存在状态与21B下载来源文件保持原状，没有启动模型。收尾记录为 `gui-records/p2-current-restoration.json`。

## 当前验收状态与开放项

两项旧UI P2均已关闭：Editor焦点经过公开TextInput有效RED/GREEN、100项相关回归和当前Mac鼠标完整输入/直接Save复验；标准版本标签经过真实Catalog/Widget有效RED/GREEN和当前Mac版本行复验。当前Core候选的635完整回归、零诊断分析、格式及Mac构建亦已通过，原始失败与修复证据保留在上述入口。

1. 双轴Core首审发现的Splash请求身份HTTP deadline/cancel P2已由同一Runtime owner有效RED/GREEN修复：JSON/SSE共用剩余期限与单请求取消，真实身份连接及时关闭、许可归零，Ready/peer保持；最终30 Runtime、107相关用例及零诊断分析有效。新源码完整门禁与Mac构建更新为 `splash-core-budget-final-*`，增量审查继续确认该修复。本节没有把绑定-only run02当作Native Ready。
2. 1340四格、SDK04及各阶段证据只在其实际输入边界内复用；最终#60候选需受影响SDK/GUI与跨入口审查。
3. 缺真实版本升级目标、同模型不同量化组合时保持上述可控I/O与Native证据类型边界；新增Splash Ready、实际JSON/SSE、SDK/Gateway及自有父子停止按其增补规格另验收。真实绑定/model-check已经run02通过，0serverStart不代替这些开放项。
