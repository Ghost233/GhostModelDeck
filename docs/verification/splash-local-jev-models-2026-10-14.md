# 本地 Splash 与全部本地 JEV 模型短测试

2026-10-14。用户要求继续测试本地所有 JEV 模型是否能直接在本地 Splash 运行。测试完成：6 种模型中，3 种在本地新二进制、关闭 compact 后加载及公开 HTTP 短请求通过；3 种被当前引擎明确拒绝。没有模型题集作业，没有修改应用代码、模型权重或 Splash 源码，没有提交或发布新版本。

## 实际范围

读取正式 GMD 配置中的三个模型库目录并只扫描元数据，覆盖 Julia-1、Kev-0.8B、Kev-4B、Laya、InnerJev-4B、StartLux。StartLux 另有同名副本，记录其路径但不重复加载同一种变体。InnerJev 的 mmproj 是配套文件，不作为独立 JEV 模型；本次是文字请求。

Splash 源目录为 `/Users/ghost233/.codex/worktrees/qwen4b-quantized-ffn/GhostSplash`，Git HEAD 为 `3f43aa2460f59330e658fdc89945d72ce92d538c`，该目录有其他会话的未提交修改，全部保留。实际测试二进制为该目录下 `build/compact-public-20261014/splash`（当天编译，arm64），实际 Python 使用该目录已有 `.venv/bin/python`；二进制路径、SHA、时间和服务入口 SHA 保存在 `engine.json`。

没有将“源码目录已关联”当成新二进制已生效。默认 `build/splash` 仍为旧二进制，真实启动控制用例在加载前报 `unexpected argument --ane-ffn-share`，端口已关闭。它不能配合当前这套参数使用。

## 参数及准备

初始沿用用户此前选择的普通 CLI 可表达部分：上下文 36864、内存 32G、SSD 缓存 0、并发 1、Q4H、ANE share 0.5／最小 512 行、lookup 开、compact 开、fast top-k 关、请求 60 秒。当前源码新增了 compact 排名文件要求，使用同目录已有 `compact-rankings/qwen35-248320-dev-seed.splash`。矩阵实验入口专用的量化 FFN／零 FP16 缓存和 splits=16 没有假装成为普通服务参数。

权重均为原路径的只读文件。测试配套在 `.scratch/splash-jev-all-20261014/models/` 生成，仅从 GGUF 元数据生成配置和 tokenizer，匹配的 4B 使用已有 Standard DFlash 的文件链接；未执行使用前兼容性 model-check 或重算完整权重 SHA。原生服务读取所选真实文件，健康后核对 `/status` 的实际模型名、PID 和端口。

## 最终结果

| 模型 | 量化 | 加载及接口 | 实际结果／拒绝原因 |
| --- | --- | --- | --- |
| Julia-1 | Q8_0 | 不支持 | `modern-bert` 元数据转换不支持；原生 `serve-native` 同样退出 70，报模型类型不在支持范围 |
| Kev-0.8B | Q8_0 | 不支持 | 原生服务拒绝隐藏维度 1024；当前布局不是该 0.8B 布局，未达到 Ready |
| Kev-4B | Q4_K_M | compact 关后通过 | 约 7.02 秒就绪；文本 OK；choice／score／noul HTTP 200；选择 B（绿色） |
| Laya | Q8_0 | 不支持 | 与 Julia 相同，当前引擎不支持 `modern-bert`；原生退出 70 |
| InnerJev-4B-Full | Q2_K | compact 关后通过 | 约 7.02 秒就绪；文本 OK；三种 JEV 接口 HTTP 200；选择题返回 A（红色），该题预期 B（绿色） |
| StartLux-Decision-4B | Q4_K_M | compact 关后通过 | 约 8.02 秒就绪；文本 OK；三种 JEV 接口 HTTP 200；选择 B（绿色） |

一次 Systemone 请求同时包含三种题型，状态为“背景原为红色，用户要求改为绿色”。独立核对响应模型名、题型、有限概率、概率之和、noul 范围及非空文本；通过的是加载和协议可用性，不是模型成绩评测。Splash 该接口使用候选 token logits，源码声明为未校准的条件选项分数；Kev 专用 cls 决策头没有被本次验收为通过。

## 原失败与定点诊断

1. 第一轮保留所有原失败。Julia／Laya 为架构拒绝，Kev-0.8B 为尺寸拒绝；三个 4B 均先进入权重加载，随后出现原生 EOF。
2. 只以 Kev-4B 复现并启用引擎自带 crash trace，捕获原生退出码 70。具体错误不是笼统的 EOF，而是 `memory_audit / category_exceeds_plan`：shared-decode 实际 296,698,240 字节，大于规划的 154,747,264 字节。InnerJev 和 StartLux 同类实际值为 363,544,960 字节。
3. 日志显示 compact 数值验证已通过；问题发生在其后运行时内存分类审计。没有增大预算冒充解决，也没有关闭或放宽内存审计。
4. 只将 `--compact-draft-head on` 改为 `off`，其余参数、权重、配套和二进制不变。Kev-4B 原场景就绪及短请求通过；再对受同一影响的 InnerJev／StartLux 使用相同变更，均通过。三个通过实例的内存审计为 `valid=true / error=none`。

因此，原始 compact-on 参数在这份当前本地二进制上仍不可用；当前可复现的直接运行组合是本地新二进制加 compact-off。原始失败不能被最后控制脚本退出 0 覆盖。

## 资源及文件核对

所有加载测试逐个执行，仅本次实例使用独立随机端口、HOME 和 TMPDIR。三个通过服务均正常退出 0，端口关闭，没有强制清理；所有模型权重的大小、mtime 和 ctime 与测试前一致，二进制 SHA 未变。

正式 GMD（PID 61160）、原有 Splash Python／native（62141／62237）及 llama.cpp（62198）仍在，没有被停止或替换。没有新建分支、worktree、容器或子代理，也没有更改正式保存的模型／引擎参数。

## 证据位置

`.scratch/splash-jev-all-20261014/` 保存 inventory、prepared、engine、第一轮 results、独立 summary、各模型原始日志／请求／响应、旧默认控制用例，以及 compact-off 结果。崩溃跟踪保存在该目录的独立 profiles 下；完整 JSON 不进入 GMD 界面。

准备脚本首次因括号错误退出 1，没有执行模型操作；原日志保留，修正后准备退出 0。`run.exit=0` 只代表六项原始结果已收齐，不代表第一轮六项通过；通过／不支持的业务结论以上表、独立协议核对和原生退出结果为准。

## 后续：应用到当前 GMD 配置

用户随后要求将当前 GMD 参数改用本地 Splash。通过正式 GMD 界面完成关联、引擎默认参数和两个已有实例的保存；这一配置操作发生在上述模型测试之后。

GMD 的 Splash 源码关联入口要求原生程序位于 `build/splash`。原仓库该文件仍为旧版，因此新增运行目录 `.tooling/splash-qwen4b-local-20261014`：`server`、`install` 和 `.venv` 链接到用户的 `qwen4b-quantized-ffn/GhostSplash`；`build/splash` 及同目录 metallib 链接到已测试的 `build/compact-public-20261014`。未覆盖用户原仓库中的文件。此目录是运行布局，不是新的引擎实现。

Qwen3.5-4B-UD-Q4_K_XL 和 Kev-4B-Q4_K_M 均保存为该 Splash 引擎，沿用原实例 ID、资产及公开模型名。引擎默认值及两份实例配置一致：上下文 36864、最大内存 32G、KV 为 Q4H、队列大小 1、磁盘缓存 0、ANE share 0.5／minimum rows 512、prompt lookup on、compact draft head off、fast top-k off、关闭 Web UI、请求超时 60 秒；实例 JEV 预算也为 60 秒。Qwen 使用已有模型目录，Kev 使用 2026-10-13 已准备的完整模型目录。未重算权重摘要。

`model.safetensors` 是 SmolLM2-135M-Instruct-8bit 的 Llama 架构，不属于当前 Splash 支持的布局，完整保留其 oMLX 配置。委员会配置未修改。

实际持久化 JSON 经生产 `SplashInstallation.fromJson`、`EngineLaunchConfiguration.fromJson` 和 `LaunchInstance.fromJson` 解析，固定 Dart SDK 命令退出 0。独立核对两份配置与默认值、模型目录链接、实例及公开名、未涉及实例逐字一致。原 GMD、原 Qwen Splash 和 Kev llama.cpp 进程仍在；保存配置用于下次启动，没有声称当前进程已经切换。没有新开模型或题集。

配置前后备份、解析检查及核对结果位于 `.scratch/gmd-splash-config-20261014/`。Flutter 包装入口首次因 SDK cache 的沙箱写权限退出 1，改用同一固定 SDK 内的 Dart 可执行程序完成解析；该环境失败不计为验证通过。
