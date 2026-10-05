# 模型包选择：LM Studio 参考

2026-10-04 用户明确要求：模型选择、下载以模型文件夹/完整包为单位，具体使用文件由内部处理，不让用户逐文件勾选。

## 实际 UI 观察

读取本机 LM Studio 0.4.25+1，打开 Model Search。选择 `lmstudio-community/Qwen3.5-0.8B-GGUF` 后，Download Options 是模型变体下拉框：GGUF + 模型名 + Q4_K_M/Q6_K/Q8_0 + 包大小。下载是一个 Download 按钮，没有要求用户勾选 tokenizer、projector 或每个分片。当前 Q8_0 显示 1019.19 MB；未触发下载、加载或改变现有下载任务。

同一次观察中 `ggml-org/Kev-0.8B-GGUF` 显示包级别 Kev 0.8B / 812.41 MB，并识别已下载适用资产。

通过真实 [HF 文件元数据](https://huggingface.co/api/models/lmstudio-community/Qwen3.5-0.8B-GGUF?blobs=true) 核对上述包大小：固定 commit `26bab2c9369648924251c0ebb3dae012f5147707` 中，Q8 权重 `811843040` bytes，加唯一 projector `mmproj-Qwen3.5-0.8B-BF16.gguf` 的 `207345952` bytes，共 `1019188992` bytes，与 UI 的 1019.19 MB 匹配。没有下载该模型权重。这一实际例子说明包级下载需要内部带上配套资产，projector 本身不作为独立可选模型。

## 官方证据

- [lms get](https://lmstudio.ai/docs/cli/local-models/get)：以模型名搜索/下载；多量化仓库可选择 `@quantization`；保存在 LM Studio 模型目录。
- [模型列表](https://lmstudio.ai/docs/developer/rest/list)：模型记录可有 variants 与 selected_variant，显示模型级别而非分片列表。
- [应用基础](https://lmstudio.ai/docs/app/basics)：Discover 下载模型，模型加载器选择已下载模型。权重可能由一个或多个文件构成。

## 本项目采用的边界

模型库按模型目录/包展示，格式和量化在模型内部选择。下载搜索保留任意 HF 仓库入口，用户选择模型及变体后，内部解析该变体的完整权重、分片和必要配套资产，固定 revision，并写入同一模型目录。文件清单仅放详情，保留诊断/确认删除时的精确文件范围。

整包表示一个完整可识别变体，而不是把所有不相关量化、训练检查点和样例一起下载。无法确定文件关系时显示未支持/无法确认完整包，不能假装已就绪或让用户补选必需文件。
