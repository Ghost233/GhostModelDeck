# Splash 临时未就绪的定点修复

## 当前结果与范围

源码修复、受影响检查及 0.2.0 发布前完整门禁已通过，q14 的 JEV 阶段定点重试通过。用户已选择 0.2.0，提交与正式发布正在收尾。当前运行的正式 GMD 仍是原已编译版本；其已保存的 failed 状态没有被本轮清除。没有重启 GMD、Qwen、Kev 或独立 27B 模型，也没有重新执行完整 36 条。

源码基点为 `c30cd3c75a1f4c99e10087dbbbb0122ca251aab4`。本次只修改 `lib/splash_engine.dart`、`test/splash_engine_test.dart` 和 `test/splash_decision_routes_test.dart`。最终文件摘要及检查回执在 `.scratch/gmd-splash-config-20261014/repair-verification.json`。

## 原失败与修复

Sentinel 原完整 36 条记录的 q14 在 14:34:41 返回 `503 model_not_ready`，消息为 `Splash Ready身份失效：Instance of '_SplashLoading'`。后续 18 次 JEV 调用在 GMD 路由层被拒绝。实际 Kev 服务随后恢复 ready，PID 和代次未变，但 GMD 已将实例设为 failed 并取消接收请求。

定点测试通过真实 GMD HTTP 路由和受控外部 Splash HTTP 服务复现该状态变化：修复前期望 ready、实际 failed，宿主运行 `run-97zAN9` 退出 1。第一份错误消息断言失败也保留在 `run-dT6FWQ`，没有改写原结果。

修复将 `_SplashLoading` 作为本次请求的 `notReady` 错误返回“暂时未就绪”，不改变实例状态、不取消整个实例，也不自动重试本次请求。后续请求仍执行实际健康与身份核对。

PID、模型、server ID、端口或原生运行代次失配继续使实例 failed。已经获取的身份信息先于 `/status` 的临时 ready 标志校验，避免同一响应中的错误身份被临时未就绪掩盖。超时及取消处理保持原契约。

## 宿主检查

使用固定 Flutter 3.47.6、Dart 3.13.5、现有 lockfile 和已有宿主准备清单；没有重新准备字体或切换容器。

| 检查 | 回执 | 实际结果 |
| --- | --- | --- |
| 原失败定点用例 | `run-l5B7Nq` | 退出 0 |
| Splash 运行模块、公开决策路由、引擎目录相关三个测试文件 | `run-6pA8JK` | 60 项通过，退出 0 |
| 三个修改文件静态分析 | `run-PARLGq` | 无问题，退出 0 |
| 修改文件格式检查、`git diff --check` | 收尾命令 | 退出 0 |

回归覆盖 `/ready` 503、`/status` 未就绪，决策调用前后，HTTP/MCP 恢复，JSON/SSE 文本恢复，以及 PID／模型／server ID／代次失配（包括同时未就绪）。恢复使用原实例、原 PID，未发生自动重启；真正身份失配后，即使后续探针重新匹配，也不自动解除失败。现有超时、取消、进程归属和生命周期检查全部保留。

随后按用户选择的 0.2.0 执行唯一一份发布前作业：统一准备、全仓格式与静态分析、1003 项完整宿主测试（`run-yXSnmE`）、发布入口回归、macOS arm64 构建及 DMG 打包预检均退出 0。最终源码仍与门禁快照一致，lockfile 未变化。主程序、App.framework、FlutterMacOS.framework 实际架构均为 arm64，应用版本0.2.0，DMG与manifest校验通过。作业、日志及回读结果在 `.scratch/release-0.2.0/`。产物回读首次误用打包目录作为仓库根而找不到状态文件，纠正为绝对路径后通过；该工具错误保留，未重跑门禁或构建。

## q14 真实定点复验

当前正式 GMD 无法热加载源码，且重启会影响受管模型。因此使用独立临时验证入口：固定 Dart VM 的诊断镜像接口仅将现有 Kev 的捕获身份填入生产 `SplashEngine` 对象，调用未替换的生产 `decideBatch` 方法。它不调用启动入口，不取得现有进程的生命周期所有权，不允许停止进程；HTTP 仍发到原 Kev 端口 64837。测试场公开路由由上述受影响测试覆盖，这个诊断入口不是已更新的正式 GMD。

Sentinel 原分析器、HTTP 客户端、诊断驱动和题集文件摘要与原 36 条记录一致；执行原驱动的 `--diagnostic-case q14`，保留 30 秒阶段和 65 秒单题预算。

1. `q14-fixed-v1`：实际执行 1 次 Qwen 与 1 次 Kev 调用，Qwen HTTP 200，Kev 遇到真实临时未就绪，驱动退出 1。这次失败保留，不计通过。结束时修复后的运行对象仍为 ready、活动请求 0，同一 Kev PID／server ID／原生代次未变，未再次永久失效。
2. `q14-jev-retry-v2.json`：复用上述已成功的 Qwen 原始响应字节，校验分析器再次生成的 LLM 请求和 JEV 请求与记录逐字相同；只新增 1 次真实 Kev HTTP 调用。HTTP 200、响应完整，分析完成，`failure_loop` 预期与实际均为 `attention`，退出 0。没有再次执行 Qwen 推理，也没有更换模型。

两个临时验证入口均正常退出 0、端口关闭。Kev HTTP PID 49559、原生 PID 49619、server ID `7a2fa6f755ed4f2640a252f4` 保持，原生重启计数 0。Qwen 继续使用 PID 62141／62237。

本轮只验证 q14，不将单题结果声明为完整 36 条通过。正式 GMD 的旧代码和已锁定失败状态仍需在后续获准更新应用时处理。本次没有修改模型参数、保存配置或正式发行包。

所有诊断脚本、原响应、失败及重试回执保存在 `.scratch/gmd-splash-config-20261014/`。诊断脚本的 Flutter 分析平台不提供 `dart:mirrors`，初次静态检查失败；固定 Dart VM 实际支持该库，真实运行成功。首次 Dart CLI 另因遥测配置的沙箱写权限退出 255，改用命令级 `--suppress-analytics` 后运行。两项工具环境失败均未计入模型或产品通过结果。
