# 阶段三原生接口策略验收

2026-10-12，用户确认按源码声明直接转发 `/v1/systemone`，实际不支持时保留真实失败。本文件记录已取得证据；执行清单只有 [当前交付入口](playground-benchmarks-delivery.md)。没有运行新的真实模型评测集。

| 核对 | 实际结果 | 证据 |
| --- | --- | --- |
| 固定宿主环境 | macOS arm64；Flutter 3.47.6 / Dart 3.13.5、原 lockfile、原 SHA 核验字体；在线 prepare 退出 0 | run-G64I1T |
| 普通公开 HTTP／SDK MCP | 原生混合返回及 usage 保持；501 错误不补概率；取消释放并能再次调用；停止后拒绝调用 | run-rbcavG，3 pass / exit 0 |
| 最终完整门禁 | 886 项全部通过；格式 171 文件零改动、分析零诊断；697 输入前后及当前一致；真实完成标记与整体退出 0 | run-6UlogP |
| 对应当前 App | 35.68 秒、退出 0、源码输入未变；主程序、App.framework、FlutterMacOS.framework 均 arm64 | native-source-policy-arm64-build.json |
| 实机发现和使用 | GUI 选择已有源码安装，Qwen 作为代表性文本模型；唯一 llama.cpp 实例、65536 context／1 槽；HTTP 与 MCP 可发现命名来源 | native-source-policy-real-instance.json |
| 上游真实不支持 | 上游 HTTP 501 not_supported_error；GMD HTTP 502 engine_error 和 MCP isError 保留“This model is not a decision model”；随后文本 HTTP 200，返回 OK | native-source-policy-real-live-2.json |
| 停止／失效 | GUI 正常停止实例；发现撤销；HTTP 503 model_not_ready，MCP 同码；20 份配置、历史头及旧日志摘要保持 | native-source-policy-real-stopped.json |
| 增量审查 | 主线程核对标准与规格；原四个 P2 已关闭，新路径没有新增 P0/P1/P2 | stage3-native-policy-incremental-review.json / .md |

SDK 固定提交为 `5fc346839b5d0eef006ed8404392afb4dfae428d`；源码引擎原构建提交 `27f475a3bc4f7d2e63017b6caf55ec8cb4804790`，本批直接复用其 27 份已核验产物指纹。引擎类型是 llama.cpp，Qwen 与 StartLux 是模型。源码声明不保证所有模型支持概率，不是模型成绩或校准验收。

首次接口脚本在 GUI 仍启动时发现为空，真实退出 1，保存在 native-source-policy-real-live.json；未作为通过，未重复启动实例。新增测试最初字段引用错误 run-UEVNC0、lint 错误 run-1ZQNyj 保留，原诊断定点修复后再执行上述门禁。原观看关闭、Finder、历史与资源重启证据未受本次策略影响，直接复用。旧黑屏根因仍未确认。

宿主原始命令／日志／输入在 `.tooling/host-tests/<run>/`；实机、构建及审查完整收据在 ignored `.scratch/playground-benchmarks/implementation/`。本批没有正式发布、tag、版本号修改或子代理；#73 仍在阶段三集成后实施。
