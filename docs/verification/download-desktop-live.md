# 桌面下载链路验收

2026-10-04，Mac 原生 release 应用 JevManager。使用生产 Flutter 页面与真实 HF/文件系统，通过 CUA 操作，没有替代下载器。

1. 在 HF 搜索页输入 `ggml-org/Kev-0.8B-GGUF`，收到 6 个文件，显示固定 commit `e551e319d483ff57e1ff208924b349d397cffc1c` 和 `apache-2.0`。
2. 勾选 Q8 与 README，页面显示已选 2 个；取消 Q8，只保留 README，进入下载页。
3. 保存的模型库路径是 `/Users/ghost233/.lmstudio/models`，选择 HF 直连，点击“下载所选”。AX 状态观察到“下载中”、`README.md`、`0 B / 558 B` 与“取消”按钮。
4. 完成后显示“文件安装完成”、`558 B / 558 B`。正式文件独立读回 SHA-256 为 `1edd1ad2f02ec011ff1d82da6ba14b406dd2517817302b32a38485d149a7e4d3`，与此前固定文件证据一致；安装记录保留 repo、commit、来源和校验。

实际模型权重的完整下载与读回校验见 [模型资产下载验收](model-download-live.md)。本次 GUI 小文件验收证明按钮和状态链路，不宣称代理完整大权重安装或模型推理已通过。

原生目录选择器此前已将同一路径保存到用户 Application Support 的 settings.json；选择和保存不会搬迁既有模型。
