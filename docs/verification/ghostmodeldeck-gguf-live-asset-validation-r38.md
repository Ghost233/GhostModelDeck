# 固定 GGUF 的真实下载与资产验证

日期：2026-10-06，Asia/Shanghai。作为 #15 后续真实加载与 #19 验收的资产准备，不关闭相关工单。

## 执行与结果

在宿主 Dart 3.13.5/macOS arm64 使用现有生产公共入口 `HfModelBrowser.selectRepository` → `ModelPackage.discover/selectVariant` → `ModelDownloader.downloadPackage`，从 HF 正常联网选择规格固定 revision，下载到本次新建的独立临时模型库。没有使用 curl 代替应用下载器、离线模式、用户既有模型目录或 M2 检查容器。

- 仓库：`Qwen/Qwen2.5-0.5B-Instruct-GGUF`。
- revision：`9217f5db79a29953eb74d5343926648285ec7e67`。
- 仅选择 `qwen2.5-0.5b-instruct-q4_k_m.gguf`，491,400,032 B；未下载其他量化。
- 元数据来源 `online`；下载器终态 `installed`，无错误、未触发预算取消。
- 下载及独立全字节重算 SHA-256 均为 `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`，与固定来源一致。
- 生产入口执行、下载和本探针全字节核验合计 490.492 秒；这是本次观测，不是普遍速度指标。
- 新命名空间安装收据实际写出，622 B；收据及完整路径/摘要见[冻结数据](ghostmodeldeck-gguf-live-asset-validation-r38.json)。本次选择不包含 README/LICENSE；其既有固定来源研究不冒充本次下载了这些文件。

随后用现有生产 `ModelLibrary.scan(root, verifyFiles: true)` 对实际文件进行结构解析和完整内容校验，得到唯一所选资产：`GGUF`、`qwen2`、`chat`、`complete`、`sourceVerified=true`、全文件指纹已验证、diagnostics 为空。引擎能力保持 **`awaitingVerification`**，不是 Ready。公共扫描结果的 `quantization` 仍为 null；本报告不把选定变体名称改写为扫描器已提取量化配置。

## 保留探针失败与修正

第一次扫描探针退出 1：`Bad state: Expected one actual downloaded artifact`。扫描器当时已返回完整 chat 资产，但探针把下载路径 `/var/...` 与扫描器规范化路径 `/private/var/...` 作字面比较，误判未找到文件。只对探针的预期文件路径调用 `resolveSymbolicLinks` 后重跑，成功；没有修改产品代码、减少结构检查或放宽完整性条件。原始失败和成功结果分别保留，错误与堆栈也纳入冻结数据。

## 明确未执行

未进行应用 GUI 下载、HF 代理来源、真实取消/恢复/冲突场景、应用内引擎安装、模型加载/文本或 JEV 推理、SSE、SDK/窗口和完整 Release 验收。临时库不是用户设置，未自动登记启动模型集合。后续重新使用时先核验文件仍存在、真实字节/摘要及结构，再沿生产显式加载入口执行；不能由下载成功或本次分类赋予 Ready。

本地探针、原始日志和完整 JSON 留在 `.tooling/`，大权重保留在本次自有临时目录，不提交大型文件。此处冻结数据记录的是实际执行时状态，不承诺临时目录永久保存。
