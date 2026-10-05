# 模型包与共享目录验收

2026-10-04，按用户“参考 LM Studio，以模型目录/完整包选择，具体文件内部处理”的修订验收。真实生产入口与真实 Mac 文件系统参与，不以小文件模拟模型权重。

## 真实目录识别

`ModelLibrary.scan` → `LocalModelPackages.discover` 只读扫描用户已选择的 `/Users/ghost233/.lmstudio/models`。最后目录复验耗时 **2241 ms**，165 个底层资产聚合成 **12 个模型包**，其余 5 个资产保留只读详情。Kev、Laya 各为一行 Q8_0；原来被拆开的两套 Splash/Yuzu `.bin` 文件按实际 schema 3 manifest 聚合成目录候选，保持未知/未支持状态，不推断完整性或运行能力。

修复前实际目录只得到 10 个模型包；原因是错误要求 `format.magic`。真实 manifest 使用 `draft_layer_magic`、`target_layer_magic`、`vision_magic`。回归样本已改为真实形状，目录判定使用 model、format.name、schema 与非空资产声明；不拿 magic 字段声明当二进制兼容证据。

脚本 `.tooling/implementation/live-package-catalog.dart`，结果 `.tooling/implementation/live-package-catalog.json`。没有搬迁、覆盖或删除共享文件。

## 真实包级选择与只读复用

`.tooling/implementation/live-model-packages.dart` 使用在线 `HfModelBrowser` 固定 commit，再通过 `ModelPackage.discover` / `selectVariant` 选择 Q8_0，调用正式 `ModelDownloader.downloadPackage`。若尝试重新传输大权重，脚本会立即取消并失败；本次仅出现 verifying → installed，未进入 downloading。

| 模型包 | 固定 commit | 实际 bytes | 完整核验耗时 |
| --- | --- | ---: | ---: |
| ggml-org/Kev-0.8B-GGUF，Q8_0 | e551e319d483ff57e1ff208924b349d397cffc1c | 812406304 | 4768 ms |
| ggml-org/Laya-GGUF，Q8_0 | da4b4753d62197659d8c90103cd4c43bef9afea6 | 449397600 | 2751 ms |

两者沿用原正式安装 id，生产入口对完整内容与来源校验；文件大小和 mtime 前后相同。没有再次传输 1.26 GB 权重。之前首次真实下载及独立读回完整 SHA-256 的证据见 [下载验收](model-download-live.md)。本次脚本终态退出码 0，日志 `.tooling/implementation/live-model-packages.jsonl`。

## 容器行为证据

- 原下载器与新包级入口 15 项通过（run-CpozMI）：GGUF 整组分片、已有安装完整哈希复用、同大小损坏拒绝、旧 revision 拒绝、Safetensors/index/config/tokenizer/head，以及唯一/模糊 projector。
- 实际 Qwen 参考包元数据中 Q8 权重 + 唯一 projector 总计 1019188992 bytes；包级测试核对该实际总量，projector 不作为独立模型选择。没有下载这套 Qwen 权重。
- Widget 的模型/变体选择、只读文件详情、点击下载全套所选分片、切换 revision 时立即禁用旧选择，均通过（run-0PJPc6）。仅 HF 网络边界受控，真实业务入口和临时文件参与。

整套 **51 项**容器测试通过（run-8JJmKC）；静态分析无问题（run-EiPdfs）。最新 release `.app` 构建成功，43.4 MB，日志 `.tooling/implementation/model-package-native-build.log`。

## 实际桌面操作

CUA 操作正式应用：搜索真实 Kev 仓库，默认显示模型包与 GGUF/BF16，切换为 GGUF/Q8_0 后显示 774.8 MiB；没有文件勾选。点击一个“下载”按钮，观察“校验中”→“文件安装完成”，实际附属状态“已存在 · 完整内容校验通过”，没有重新下载权重。

模型库实际显示 12 / 12 个模型包。输入 Kev 后为 1 / 12；勾选整个模型目录、点击“删除模型”，确认框准确列出一个 Q8 文件、774.8 MiB 与完整路径；点击取消后模型仍存在，正式文件大小仍为 812406304 bytes。

现场发现的 Laya head/scorer 尺寸误判已修正。实际 tensor 与固定引擎源码证明 scorer 是单输出；对应 GGUF/Safetensors 回归先失败后通过，完整 51 项容器测试通过（run-eWZBC7），静态分析无问题（run-TU26Qi）。修正后的 release 构建成功，日志 `.tooling/implementation/laya-recognition-native-build.log`。

重新打开正式应用，在共享库中筛选 Laya，模型包显示“文件齐全 · 待核验”。通过桌面“核验”操作后显示“完整 · 待能力验证”；展开详情显示固定 revision `da4b4753d62197659d8c90103cd4c43bef9afea6`、modern-bert/laya、上游校验通过及完整 SHA-256 `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2`。本轮实际目录为 13 个模型包；共享目录由其他应用持续管理，数量不作为整库稳定性证明。以上证据不表示引擎、委员会或 MCP 验收完成。
