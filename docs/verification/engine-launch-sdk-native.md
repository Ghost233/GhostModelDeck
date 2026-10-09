# #51 真实 Mac SDK 启动参数验收

状态：**本次真实 Mac SDK 子验收通过**。2026-10-09（Asia/Shanghai）。规范为[引擎启动参数配置 #44](https://github.com/Ghost233/GhostModelDeck/issues/44)，验收为 [#51](https://github.com/Ghost233/GhostModelDeck/issues/51)。最终执行源码 `1340af9714ee2a78cde2c167e100ef4e5e8409f8`。本报告不代替root实际GUI及33条总验收；那些独立证据在此checkpoint仍待root提供。

唯一harness为 `.scratch/engine-launch-delivery/stage51/native-sdk-acceptance_test.dart`。外部server仅使用任务自有真实Unix socket；完整生产 LauncherInferenceService/StartupModelSet/EngineCatalog/LlamaEngine.startRuntime/配置选择与ManagerLifecycle保持真实，进程实际由NativeEngineProcessIO执行。记录包装只观察实际argv、stdout/stderr、PID、exit和signals，不假造Ready或替代核心。没有访问用户MacLauncher默认socket、已安装app、AppSupport或改变HOME。

使用正确项目 `.tooling/pub-cache` 与 `.tooling/config`，hostFlutter `test --no-pub`复用同锁已在线hostbuild通过的依赖；不是离线补验，不重复容器601门禁。registry/startup/model-route/socket位于唯一任务目录，加载原Kev Q8_0（812406304字节，SHA `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`），关联既有b11381真实二进制，不下载/修改模型或engine文件。

## 最终完整通过结果

唯一有效最终作业为 `native-sdk-run04`：hostFlutter真实exit0，`outcome.passed=true`，49条业务及清理断言通过；original failure为null、cleanup failures为空、host stderr为空。source1340af已包含root对旧gateway缓存缺陷的定点修复及真实公开socket回归，相关/full602、格式97/analyze零诊断和正确Mac构建均已通过；本worker没有重复这些容器门禁。

整份独立配置（表单ctx2048+原文`-c 1024`）经实际Unix socket onStart启动原Kev，真实PID91148/Ready，Native argv/executable与该实例不可变命令相同，实际 `/props.default_generation_settings.n_ctx=1024`、alias属于该实例。重复start不增加spawn。default改768后独立内容仍完整保留；切继承不改变当前PID/generation/Ready/原命令或实际ctx1024。显式recycle保持原SDK连接，第一轮端口关闭；下一onStart为新PID91176，实际ctx768，旧实例命令仍为原值。SDKdispose只断连接，第二模型PID/Ready/命令和实际ctx768仍保留。

随后完整生产ManagerLifecycle.shutdown真实stopped：gateway与MCP均stopped、没有live模型/活动请求；全部14个真实child退出0，其中两个模型仅SIGTERM，无任何SIGKILL或流错误。六端口64926/64920/64921/64950/64945/64946在正常shutdown后实际拒绝连接，任务SDK server/订阅关闭。不是依靠Flutter VM退出回收这些资源。

host及body共48项全部lib Dart/pubspec/lock/harness源输入前后一致，harness SHA `870c5acf49576caea2dd7140a3df8fb7949309642ed0afc91c2c9863942088ef`。Kev full SHA与原值相同，linked安装全部常规文件SHA未变。任务配置快照、实际props与完整child stdout/stderr/exit/signals均持久保存；唯一临时registry目录保留供核对，不包含用户AppSupport改动。

最终证据均在 `.scratch/engine-launch-delivery/stage51/`：`native-sdk-run04-host.json/-host.stdout/-host.stderr`、`native-sdk-run04-harness-source.dart`、`native-sdk-run04-host-inputs-before.json/-after.json`，以及 `native-sdk-run04/outcome.json`、`events.jsonl`、`source-inputs-before.json/-after.json`、`engine-inputs-before.json`、`props-1024.json/props-768.json`、registry/config快照和14对 `child-0-*`至`child-13-*` 输出文件。host stdout SHA `b390971a120dea5ba7088d4dc66c9e10aadd474d6593eeb157f5491214c3c405`；host空stderr SHA `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`。

## 保留的真实产品失败与修复

`native-sdk-run03`完成39条主要业务断言：整份独立配置表单2048+文本`-c 1024`由实际SDK onStart产生真实Ready/PID85742，Native argv与实例命令相同，实际 `/props.default_generation_settings.n_ctx=1024`。重复start没有多spawn；default改768及切继承后PID/generation/Ready/原命令/实际ctx1024不变，独立副本保留。显式recycle保持同一SDK socket并关闭第一轮端口；下一start为新PID85757、实际ctx768。SDKdispose只关连接，第二实例仍Ready、原命令和ctx768不变。

该轮**整体实际exit1，outcome.passed=false**：正常ManagerLifecycle.shutdown返回state stopped，两模型已exit0/SIGTERM且请求归零，但gateway仍running，第二轮gateway端口63786仍接受连接。公开stop()复用第一recycle的已完成 `_stopping` future；成功start没有清除该缓存，因此第二listener没有teardown。root唯一gateway/lifecycle owner以公开socket RED→GREEN和受影响/完整门禁修复，正式提交1340af后才执行run04。run03没有被覆盖或改成通过，39条主行为不是完整验收通过。

原始body failure为null，两个cleanup failure分别为gateway状态及端口检查。全部14个真实child的stdout/stderr/exit已保存，两次模型child为index9/13，均exit0、只SIGTERM、无SIGKILL。清理失败按原样保留，没有因最后Flutter进程结束而将listener资源缺陷记为通过。

完整当前证据均在 `.scratch/engine-launch-delivery/stage51/`：

- `native-sdk-run03/outcome.json`、`events.jsonl`、`child-0-stdout.bin/child-0-stderr.bin`至`child-13-*`；实际props、独立/继承registry与最终任务配置同目录。
- `native-sdk-run03-host.json`与`-host.stdout/-host.stderr`记录命令、正确环境、实际exit和日志SHA；`native-sdk-run03-harness-source.dart`保留执行输入。
- host `native-sdk-run03-host-inputs-before.json/-after.json`及body `native-sdk-run03/source-inputs-before.json/-after.json`固定全部lib Dart、pubspec、lock及harness，48项前后一致；linked engine全常规文件及Kev完整SHA前后未变。

## 原始工具失败

run01记录脚本在Flutter前用错误command索引计算harness SHA，exit1，未连接SDK/启动child/创建evidence；修复仅在ignored runner，原记录保留。run02 Flutter编译exit1：HttpClient cascade被箭头函数解析为字符串的setter，harness未进入body、无native child；拆开赋值后才运行run03。原host日志、精确harness副本和标明重建方式的39fb全源指纹保留，未将这两次记为通过。

最终run04满足实际exit0、所有业务/cleanup断言、child/端口正常释放、无SIGKILL及前后源一致，该子验收已闭合，没有再次执行相同input/environment作业。33条current evidence map在任务目录 `acceptance-plan.md`；root GUI仍为独立待提供证据。参数生效与资源结论仅限本次已固定的引擎、模型、源码和配置，不作性能或其他客户端/模型保证。
