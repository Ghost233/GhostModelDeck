# A 方案参数编辑验收

2026-10-20。来源为用户确认的 Q1～Q9、[参数规格](../requirements/parameter-editor-spec.md)、[ADR 0009](../adr/0009-explicit-drafter-configuration.md) 和 [ADR 0010](../adr/0010-instance-generation-defaults.md)。用户明确选择 A 分组侧栏，未另行说明选择原因。

## 实现与验证入口

正式界面为 Flutter 原生控件。实例配置和引擎启动默认值使用同一分组编辑器；实例生成默认值与公开 HTTP 测试场使用同一套生成字段。布尔、枚举、数值、路径、列表和 JSON 对象提供对应控件，高级区同样提供控件。命令文本保留原有调优项优先级；软件管理的来源和草稿模式单独受控。

生成参数在请求准入时合并：单次显式值 → 保存实例默认值 → 原生引擎默认值。加载身份不包含生成默认值。公开 JSON、SSE 和测试场仍通过同一请求路径，省略生成上限时不补入 32 或 4096。

草稿模型采用显式来源。Splash 检查原始 safetensors 和分片索引，调用选定二进制的 `model-check`，在 GMD 目录内引用原始文件。llama.cpp 检查所选 GGUF 及全部分片，并要求启动后 `/slots` 实际报告推测解码启用，防止服务就绪但草稿初始化失败的原生回退。运行状态属于原运行实例，保存下一次启动的来源不会改变已运行实例的观测。

compact 预检查覆盖 `SPLCHD02`、词表大小、精确文件长度、完整排列和容量约束。启动后的原生 compact 验证及正常完整 head 回退分别显示，不推导逐 token 颜色。

## 宿主机检查

固定工具链为 Flutter 3.47.6 / Dart 3.13.5，macOS arm64；字体、依赖锁和源码指纹由 `scripts/test-host.sh` 记录。当前源码基于 `6c96dcf`，包含工作区未提交改动。原有 `.gitignore`、`lib/model_library.dart` 和 `test/model_library_test.dart` 改动保留。

- 配置、原生启动状态、JSON/SSE 默认值、可视化请求参数、目录选择和关闭资源的定点回归均有通过记录。
- `run-Xb6UtR`：66 个界面与布局用例通过，包含深浅主题、100%/150% 文字大小、保存/取消、原生输入焦点、文本优先和启动取消。
- `run-kTpmk6`：实际 HTTP 请求编辑回归通过，覆盖非法数值不崩溃、停止字符串、Schema 元数据保留和取消响应长度限制。
- `run-q5gZfD`：运行中修改来源仍显示原来源，原生未实际启用则拒绝就绪；HTTP 控件回归通过。
- `run-FCa2Ey`：96 项参数识别、生命周期、引擎页、oMLX 配置、HTTP 和 Splash 准备回归通过。
- 最终 Mac 构建退出 0，应用大小约 52 MB；主程序、`App.framework` 和 `FlutterMacOS.framework` 三份 Mach-O 均为 arm64。记录见 `.tooling/parameter-editor-build-final/`。
- `run-izMTMd`：完整 `scripts/test-host.sh check` 退出 0，格式 225 文件无变化、静态分析无问题、1080 项测试全部通过。标准报告与完成标记均通过核验，`source_unchanged=true`。
- 最终待测指纹为 `ba8b6c14987a788a876493786caeabfbdebaee01a6f9e45b5e904357344254a4`；构建输入指纹为 `956f07b593ac263e60e6136c8e9b5aa286c2cf8a34520885d10f63766a4ae888`，由排序后的输入摘要映射计算。原始身份记录为 `.tooling/parameter-editor-source-identity.json`。

原始检查材料在 `.tooling/host-tests/`。布局截图在 `.tooling/parameter-editor-a-native/`，由真实 Flutter widget 绘制及固定字体生成；这些截图不代表已经安装或替换 `/Applications` 中的应用。新增文件选择通道已通过真实 Swift/Mac 构建，测试使用系统通道替身验证选择结果；尚未在独立新应用窗口操作 NSOpenPanel。

## 两份原始 Splash 草稿的真实检查

所选引擎为 `/Users/ghost233/Ghost233Code/GhostSplash`，原生二进制 SHA-256：`311ead4c092fb33eb0eb0fe1d6d91934ef8d1e43b45f31814f3049cad7b2148a`。通过生产准备程序执行，两个进程退出码均为 0：

| 目标模型 | 草稿来源 | 检查结果 |
| --- | --- | --- |
| `unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-UD-Q4_K_XL.gguf` | `z-lab/Qwen3.5-4B-DFlash` | 原始 BF16 safetensors 文件检查及原生配置兼容性通过 |
| `mlx-community/Qwen3.8-27B-4bit` 三片 safetensors | `incoai/Qwen3.8-27B-DFlash2` | 原始 BF16 草稿、目标分片引用及原生配置兼容性通过 |

以上路径均位于 `/Users/ghost233/.lmstudio/models`。准备结果仅在 `.tooling/parameter-editor-real/assemblies/` 创建引用；所选目标和草稿权重的大小、纳秒修改时间在检查前后保持一致。原始结果为 `.tooling/parameter-editor-real/qwen35.json`、`qwen38.json`。

这些是文件与原生配置检查，未进行真实张量加载或生成验收。未发现可直接作为所选独立草稿使用的 llama.cpp GGUF；现有带 MTP 名称的目标 GGUF 不能仅凭名称认作匹配草稿。尚未提供真实 compact ranking 文件，因此没有开展真实 compact 加载及回退验收。测试中的原生进程/HTTP 替身只证明 GMD 的拒绝和状态逻辑，不代替这些真实模型验收。

未下载、转换或改写权重，未运行性能测试，未停止现有应用或推理服务。

## 原型留存

完整 A/B/C 原型、截图和已确认要求留存在 `codex/prototype-parameter-editor-a`，作为选择 A 的一手设计来源。该分支仅用于归档，不承担集成；主工作区不切换分支，不提交原有用户改动。正式实现仍留在当前主工作区，未发布、未替换已安装应用。
