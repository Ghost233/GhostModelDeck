# Splash 本地引擎接入规格

状态：实施中，真实验收未完成。

规范工单：[Splash 本地引擎接入：启动参数、模型绑定与文本运行](https://github.com/Ghost233/GhostModelDeck/issues/57)。配置 [#58](https://github.com/Ghost233/GhostModelDeck/issues/58)、Runtime [#59](https://github.com/Ghost233/GhostModelDeck/issues/59)、集成与验收 [#60](https://github.com/Ghost233/GhostModelDeck/issues/60)。

来源：2026-10-09 用户要求“把splash引擎也支持了吧 /Users/ghost233/code/Splash”。范围延续引擎默认参数＋模型独立参数、文本优先及最终预览，增加本地 Splash 关联、明确本地模型绑定、文本运行和现有 HTTP/SDK 共用入口。原 #44 排除 Splash 的历史规格不改写；本增补独立跟踪。未授权发行、替换用户 Splash 代码或停止用户现有服务。

## 运行边界

- 首期关联本地现成 source 或 packaged Splash；读取实际 Python/server/native 文件身份、版本及 help。普通关联/启动不调用 make、安装环境或在线模型 prepare。
- 使用现有 `server.server MODEL_DIRECTORY --tokenizer ... --model ... --binary ...` 启动层。模型绑定到一份本地完整 target/config/draft/tokenizer 目录（优先现有 verified assembly），并记录实际文件身份；模型名与 assembly/native/tokenizer/host/port/alias 等由软件管理，不能由高级参数替换。
- 本地模型资产需 Splash 特定识别与验证；不把任意 GGUF/Safetensors、JEV 资产或草稿模型单独当成可运行 Splash target。兼容性由实际 model-check、Ready 和短文本调用确认。
- 每个具体引擎登记项×模型资产有独立运行与配置；所有 GUI/HTTP/SDK 调用同一 EngineRuntime owner。普通启动不隐式下载；缺资产显示可操作错误，尚无匹配目标不得记成通过。
- /health 不代表 Ready，需核对 /ready、/status 的模型/PID/transport 与 /v1/models 的原生 identity；JSON+SSE 沿现有 TextRequest/decoder。仅 textGeneration，不扩图像、Responses、Anthropic 或 JEV 概率。
- 正常 stop/shutdown 拒绝新启动、排空/取消请求并回收本应用创建的 Python/native 资源；用户已有 Splash 服务（当前 PID9606，port8008）保持归属外部。

## 参数

- `EngineFamily.splash` 独立 family，初始常用表单全空，使用引擎自身默认；先提供 --max-context、--max-memory、--kv-format、--queue-size。
- 内置识别覆盖软件管理字段和上述常用参数；可选 actual help 补充其它选项。文本优先、未知保留、原文不变；context/memory 的 K/M/G 与 auto 等按真实 Splash 规则作软提示，不阻塞语义。
- 最终 command 用真实 Python executable + 软件管理的 server.server 启动前缀及实际 local binding，由同一 composer 生成预览与 argv；runInShell=false。软件管理字段从 raw 执行数组剔除并说明实际值。
- 保存仅用于下一启动，运行中不自动重启。继承/完整独立/独立空、解绑历史/显式同family恢复沿用现有规则；旧 schema/family 兼容且原子验证。
- 解除关联后保留默认启动配置、模型覆盖模式和原来源，恢复仍只作用于启动参数。Splash 模型包绑定属于具体登记项与模型资产；新登记项须重新绑定并核验当前安装与模型包，不因路径、名称或启动配置恢复自动取得旧绑定。外部模型包保留在原位置。

## 验收

- 配置 parser/composer/持久化/恢复/错误测试，生产业务保持真实，替身只限现有外部 Process/HTTP I/O。
- 同一真实 GUI/SDK/Gateway 路径能选择 Splash，看到预览/实际命令，实际本地模型 Ready、短文本 JSON/SSE、正常停止父子进程/端口。
- format/analyze/全部测试和 Mac release build。真实模型输入不足或用户已有服务资源冲突，单独记录缺口及所需协调，保持验收开放。
