# 阶段 B 监控数据与分钟窗口证据

2026-10-17。来源为规格 #102、#107 和 #108。此记录只描述已取得的增量证据，阶段完整门禁、固定提交审查及 PR 状态统一见[当前交付入口](scenario-runtime-controls-delivery.md)。

## 数据来源

Splash 原生执行并行宽度来自 `memory_plan.budget.maximum_batch_width`，不使用 `http.requests.capacity`。已只读核对本机 GhostSplash 的 `EngineMemoryPlan::toStatusJson`、原生 Ready 和状态输出调用链。只看 breakdown 序列化函数会漏掉外层 budget；实际现有服务的状态响应发现并纠正了这一处路径遗漏。原字段假设及原始检查记录保留。

Splash 的阶段累计 token 与 `prefill_wall_ms`、`decode_wall_ms` 来自 requests metrics，转换成秒后使用；不借用包含预热的 model_lifetime 时间。

llama.cpp 使用原生 slots 数量和阶段计数。分钟窗口读取累计处理 token 与阶段累计秒数，不使用全会话速度 gauge。[llama.cpp 原生 metrics 文档](https://github.com/ggml-org/llama.cpp/blob/b11381/tools/server/README.md#get-metrics-prometheus-compatible-metrics-exporter) 明确区分这些计数、耗时和全会话均速字段。该链接是字段依据，不作为引擎版本或 commit 的启动限制。

oMLX 的全池累计量不能赋给池中的每个模型；现有响应未提供可信实例累计或阶段耗时时，相应值保持 —。已知的所选模型请求阶段仍按实例显示，不伪造零值或借用其他模型的数据。

## 统计语义

每个实例的每个运行代次独立保存 prefill／decode 两个窗口。首个有效观测只作基线；后续使用最近六十秒内阶段 token 增量除以对应阶段耗时增量。窗口边界落在两个观测之间时按观测时间线性插值，因此它是基于原生计数采样的分钟统计。

每秒保留最新观测并保留首基线和必要的边界锚点，每阶段最多 64 个点。没有绘图历史、曲线或展开详情。计数回退、时钟回退、超过六十秒没有有效观测时重新建立基线。缺字段或读取失败立即显示 —；有明确耗时但 token 增量为零时保留真实零值。

旧运行代次、旧页面及取消后的迟到响应在写入窗口前被丢弃。保存参数不会重置仍在运行的实例，实际重启产生新身份后重新统计。

## 可控时间与页面检查

- `run-YcEK8x`：三个可控时间场景通过，覆盖旧工作排出、边界插值、不同阶段耗时加权、初始基线、零值、字段缺失、失败、计数回退、长间隔、时钟回退以及跨实例／代次／隐藏页面隔离。
- `run-InNGK2`：监控三模块 18 项通过，原有分页、字体、迟到和取消断言保留；原 125 次刷新资源检查改为验证有界分钟缓冲和正确结果，没有减循环次数。
- `run-S8KKGi`：原生终态请求尚未清理时被错误计入执行的精确原失败；完成、取消、失败请求被排除后 `run-rHxZLR` 原用例、原生槽位和身份绑定读取三个定点用例通过。此前夹具容器类型错误另行保留，没有当作产品红灯。
- `run-LOydwU`：十个受影响文件静态分析通过；`run-GEpGZy`：监控与 Splash／llama.cpp 引擎六模块 124 项通过。

## 现有原生服务只读短验收

`run-OZVB5I` 使用生产 RuntimeTelemetry、RuntimeMonitorSource 和 RuntimeMonitorController，对现有 Splash PID 66319、端口 8009 做三次 `GET /status`。响应的进程、服务实例、模型和 transport epoch 连续匹配，前后进程均存在。没有启动、停止或重启现有模型，也没有发送推理请求。

实际原生并行宽度为 4，HTTP 接收容量为 1；阶段累计耗时字段能够进入生产解析与分钟控制器。该次短窗口中输出 token 增加 72，decode 阶段累计时间增加约 2.036 秒，计算得到约 35.4 token/s；prefill 没有新的阶段耗时，因此显示 —。这些值仅证明真实数据链路与缺失语义，不作为模型性能基准。

机器证据位于 `.scratch/scenario-runtime-delivery-20261016/`：原响应文件 `existing-splash-status.json`、三次观测与结果 `existing-monitor-native-result.json`、只读短验收脚本 `existing_monitor_native_test.dart`。该验收覆盖真实数据解析和控制器，不能代替 #111 最终原生窗口与整体集成验收。
