# #51 真实 Mac SDK 启动参数验收

状态：**执行中，当前整体未通过**。2026-10-09（Asia/Shanghai）。规范为[引擎启动参数配置 #44](https://github.com/Ghost233/GhostModelDeck/issues/44)，验收为 [#51](https://github.com/Ghost233/GhostModelDeck/issues/51)。当前执行源码 `39fb02768ac74135be7f15901fac2daf90814fca`。本报告只覆盖本次SDK子验收，不代替root实际GUI及33条总验收。

唯一harness为 `.scratch/engine-launch-delivery/stage51/native-sdk-acceptance_test.dart`。外部server仅使用任务自有真实Unix socket；完整生产 LauncherInferenceService/StartupModelSet/EngineCatalog/LlamaEngine.startRuntime/配置选择与ManagerLifecycle保持真实，进程实际由NativeEngineProcessIO执行。记录包装只观察实际argv、stdout/stderr、PID、exit和signals，不假造Ready或替代核心。没有访问用户MacLauncher默认socket、已安装app、AppSupport或改变HOME。

使用正确项目 `.tooling/pub-cache` 与 `.tooling/config`，hostFlutter `test --no-pub`复用同锁已在线hostbuild通过的依赖；不是离线补验，不重复容器601门禁。registry/startup/model-route/socket位于唯一任务目录，加载原Kev Q8_0（812406304字节，SHA `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`），关联既有b11381真实二进制，不下载/修改模型或engine文件。

## 当前有效结果与未关闭问题

`native-sdk-run03`完成39条主要业务断言：整份独立配置表单2048+文本`-c 1024`由实际SDK onStart产生真实Ready/PID85742，Native argv与实例命令相同，实际 `/props.default_generation_settings.n_ctx=1024`。重复start没有多spawn；default改768及切继承后PID/generation/Ready/原命令/实际ctx1024不变，独立副本保留。显式recycle保持同一SDK socket并关闭第一轮端口；下一start为新PID85757、实际ctx768。SDKdispose只关连接，第二实例仍Ready、原命令和ctx768不变。

**整体实际exit1，outcome.passed=false**：正常ManagerLifecycle.shutdown返回state stopped，两模型已exit0/SIGTERM且请求归零，但gateway仍running，第二轮gateway端口63786仍接受连接。公开stop()复用第一recycle的已完成 `_stopping` future；成功start没有清除该缓存，因此第二listener没有teardown。产品问题已交root唯一gateway/lifecycle owner；当前不追加native run或改产品。39条主行为不是完整验收通过。

原始body failure为null，两个cleanup failure分别为gateway状态及端口检查。全部14个真实child的stdout/stderr/exit已保存，两次模型child为index9/13，均exit0、只SIGTERM、无SIGKILL。清理失败按原样保留，没有因最后Flutter进程结束而将listener资源缺陷记为通过。

完整当前证据均在 `.scratch/engine-launch-delivery/stage51/`：

- `native-sdk-run03/outcome.json`、`events.jsonl`、`child-0-stdout.bin/child-0-stderr.bin`至`child-13-*`；实际props、独立/继承registry与最终任务配置同目录。
- `native-sdk-run03-host.json`与`-host.stdout/-host.stderr`记录命令、正确环境、实际exit和日志SHA；`native-sdk-run03-harness-source.dart`保留执行输入。
- host `native-sdk-run03-host-inputs-before.json/-after.json`及body `native-sdk-run03/source-inputs-before.json/-after.json`固定全部lib Dart、pubspec、lock及harness，48项前后一致；linked engine全常规文件及Kev完整SHA前后未变。

## 原始工具失败

run01记录脚本在Flutter前用错误command索引计算harness SHA，exit1，未连接SDK/启动child/创建evidence；修复仅在ignored runner，原记录保留。run02 Flutter编译exit1：HttpClient cascade被箭头函数解析为字符串的setter，harness未进入body、无native child；拆开赋值后才运行run03。原host日志、精确harness副本和标明重建方式的39fb全源指纹保留，未将这两次记为通过。

后续只有产品owner定点复现/修复、受影响与完整门禁及正确Mac产物/source确认后，才用新exclusive目录精确重跑同一SDK用例。完整实际exit0、所有业务与cleanup断言、child/端口正常释放、无SIGKILL及前后源一致共同满足时才闭合此子验收。33条current evidence map在任务目录 `acceptance-plan.md`；root GUI仍为待提供的独立证据。
