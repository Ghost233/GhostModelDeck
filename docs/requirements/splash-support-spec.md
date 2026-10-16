# Splash 本地引擎接入规格

状态：本地接入已发布；2026-10-16 的自动运行目录变更验收见 [当前记录](../verification/splash-managed-models-2026-10-16.md)。

规范工单：[Splash 本地引擎接入：启动参数、模型绑定与文本运行](https://github.com/Ghost233/GhostModelDeck/issues/57)。配置 [#58](https://github.com/Ghost233/GhostModelDeck/issues/58)、Runtime [#59](https://github.com/Ghost233/GhostModelDeck/issues/59)、集成与验收 [#60](https://github.com/Ghost233/GhostModelDeck/issues/60)。

来源：2026-10-09 用户要求“把splash引擎也支持了吧 /Users/ghost233/code/Splash”。范围延续引擎默认参数＋模型独立参数、文本优先及最终预览，增加本地 Splash 关联、明确本地模型绑定、文本运行和现有 HTTP/SDK 共用入口。原 #44 排除 Splash 的历史规格不改写；本增补独立跟踪。未授权发行、替换用户 Splash 代码或停止用户现有服务。

## 运行边界

- 关联本地现成 source 或 packaged Splash；读取实际 Python/server/native 文件及可选 help。普通关联/启动不调用 make、安装环境或在线下载。
- 用户只选择模型、引擎与参数。运行或测试运行时，GMD 自动在应用持久数据目录的 `splash-models/` 中准备配置、分词器和模型文件引用；不提供手填运行目录的界面。保存实例不启动或准备模型。
- 使用现有 `server.server MODEL_DIRECTORY --tokenizer ... --model ... --binary ...` 启动层。模型权重通过链接引用已有文件，不复制或重新计算整份权重哈希。配置与分词器由所选引擎的本地适配器生成，运行目录独立于临时 worktree、测试目录与应用源码目录。
- 同一份模型与相同依赖复用准备结果；上下文等启动参数保存在实例中。并发启动共享同一次准备，源文件或生成规则变化后生成新目录，已有运行继续持有原目录。
- draft 可选。有 draft 时优先引用所选引擎稳定目录内的匹配文件，修复旧 worktree 引用；没有匹配的必需文件时如实报错，不静默换模型。主模型引用或已捕获的模型身份被改写仍报错。
- 本地模型资产需 Splash 特定识别与验证；不把任意 GGUF/Safetensors、JEV 资产或草稿模型单独当成可运行 Splash target。兼容性由实际 model-check、Ready 和短文本调用确认。
- 每个具体引擎登记项×模型资产有独立运行与配置；所有 GUI/HTTP/SDK 调用同一 EngineRuntime owner。普通启动不隐式下载；缺资产显示可操作错误，尚无匹配目标不得记成通过。
- /health 不代表 Ready，需核对 /ready、/status 的模型/PID/transport 与 /v1/models 的原生 identity；JSON+SSE 沿现有 TextRequest/decoder。保留已发布的文本及原生 JEV 直通能力，兼容性由实际接口返回确认。
- 正常 stop/shutdown 拒绝新启动、排空/取消请求并回收本应用创建的 Python/native 资源；用户已有 Splash 服务（当前 PID9606，port8008）保持归属外部。

## 参数

- `EngineFamily.splash` 独立 family，初始常用表单全空，使用引擎自身默认；先提供 --max-context、--max-memory、--kv-format、--queue-size。
- 内置识别覆盖软件管理字段和上述常用参数；可选 actual help 补充其它选项。文本优先、未知保留、原文不变；context/memory 的 K/M/G 与 auto 等按真实 Splash 规则作软提示，不阻塞语义。
- 最终 command 用真实 Python executable + 软件管理的 server.server 启动前缀及实际 local binding，由同一 composer 生成预览与 argv；runInShell=false。软件管理字段从 raw 执行数组剔除并说明实际值。
- 保存仅用于下一启动，运行中不自动重启。草稿测试只启动和停止其自有实例，不改写已保存配置及其他运行实例。
- 解除关联不保留引擎参数历史，也不提供恢复入口。已保存实例保留自身参数、公开名和原引擎引用，缺失时显示异常；重新关联使用新默认配置。外部模型和引擎文件保留。

## 验收

- 配置 parser/composer/持久化/恢复/错误测试，生产业务保持真实，替身只限现有外部 Process/HTTP I/O。
- 同一真实 GUI/SDK/Gateway 路径能选择 Splash，看到预览/实际命令，实际本地模型 Ready、短文本 JSON/SSE、正常停止父子进程/端口。
- format/analyze/全部测试和 Mac release build。真实模型输入不足或用户已有服务资源冲突，单独记录缺口及所需协调，保持验收开放。
