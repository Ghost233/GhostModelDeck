# llama.cpp 双候选归档与原生版本预检

检查日期：2026-10-06，Asia/Shanghai。#15 仍未完成；这是 M3 的先行证据，不是安装、模型 Ready 或最终验收。

## 固定来源与字节

| 候选 | 固定 commit | 归档字节 | 归档 SHA-256 |
| --- | --- | ---: | --- |
| semantic tag `v0.5.0` 对应的构建 `b11146` | `7fe450e19305b828c199d602c23a8337aaa1f03b` | 11189714 | `1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711` |
| 保留 System One 的构建 `b11381` | `836d57176dc699a726c55418e4f96b8ca628e1bf` | 11925693 | `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341` |

官方归档：[b11146](https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-bin-macos-arm64.tar.gz)、[b11381](https://github.com/ggml-org/llama.cpp/releases/download/b11381/llama-b11381-bin-macos-arm64.tar.gz)。均由联网下载取得；检查固定大小、完整 SHA-256、成员路径和符号链接边界。原生探针使用独立临时目录的完整包布局，不登记进应用安装目录、不接管外部进程。

## 实际版本与超时结果

当前 [引擎实现](../../lib/llama_engine.dart) 的 `_version(File binary)` 要求 10 秒内成功退出，并匹配构建号、commit 前 9 位及 `Darwin arm64`。本次没有修改该门槛。

- `b11381` 的 `--version` 在该门槛内退出 0，实际输出：

```text
version: 0.5.0-dev (build 11381, commit 836d57176)
built with AppleClang 21.0.0.21000101 for Darwin arm64
```

- `b11146` 首次及随后两次 10 秒探针均超时；后两次只有 `initializing ...`。探针只终止并回收各自创建的进程，没有终止其他服务。
- 一次自有进程的 1 秒栈采样定位到 `common_params_parse → common_params_parser_init → llama_supports_rpc → ggml_backend_registry → ggml_metal_device_init → ggml_metal_library_init → _dispatch_group_wait_slow`；工作线程位于 `newLibraryWithSource` 和 Metal compiler XPC 等待。采样宿主为 macOS 27.0.1 (26A434)。这证明采样时等待位置在 Metal 库初始化/编译，不证明永久死锁，也不能据此归咎网络。
- 保持相同二进制与目录的一次 120 秒**诊断预算**最终在 **14.364464 秒**退出 0，输出如下。它仍不满足原来的 10 秒门槛，不能算正式安装准入通过。该结果是在前面多次终止尝试后获得，不是全新 GPU 缓存下的冷启动耗时。

```text
0.00.000.078 I srv  llama_server: initializing ...
version: 0.5.0-dev (build 11146, commit 7fe450e19)
built with AppleClang 21.0.0.21000101 for Darwin arm64
```

特别注意：semantic tag 是 `v0.5.0`，实际二进制却报告 `0.5.0-dev`；M3 必须分别保留语义标签、构建来源和观察到的版本，不能改写实际输出或伪装版本。也不能把 `b11381` 全局替换掉，再宣称仍支持 typed JEV。此前 [typed 协议预检](../research/jev-typed-protocol-preflight.md) 的能力差异仍成立。

固定源码 [server.cpp](https://raw.githubusercontent.com/ggml-org/llama.cpp/7fe450e19305b828c199d602c23a8337aaa1f03b/tools/server/server.cpp) 中，`common_init()`、stream session GC 启动与 `initializing ...` 日志在参数解析前执行；真实栈进一步确认本次解析路径触发 Metal 初始化。不能仅依据文件名或 HTTP 健康响应推断推理能力。

## 证据与后续

摘要及原始 stderr 见 [冻结证据](ghostmodeldeck-llama-native-version-preflight.json)。本地完整归档布局、JSONL 与栈采样另保存在项目的 `.tooling/engine-artifacts/`（不提交大型归档）；这些本地数据不是另一次验收。

本次未执行：应用安装/卸载、两个版本同时登记与运行、模型加载、文本/JEV 请求、SSE、GUI 或 Release 端到端验收。M2 的独占联网容器未被占用或改写。正式实现需用公开业务入口的红绿测试处理实际版本身份及有界初始化策略，再做原生安装与推理验证；延长本次诊断预算不能替代这一步。
