# GhostModelDeck 首期验收环境基线

观察日期：2026-10-05。用于 [确定首期回归验收与可实施规格的交接标准](https://github.com/Ghost233/GhostModelDeck/issues/8)。本轮仅执行只读查询，未运行 GhostModelDeck 的依赖解析、构建、测试、模型或桌面联调。

## 宿主机

| 项目 | 当前观察 | 证据入口 |
| --- | --- | --- |
| 系统 | macOS 27.0.1，build 26A434 | `sw_vers` |
| 架构与设备 | arm64，MacBook Pro Mac17,8，Apple M5 Pro | `uname -m`；过滤后的 `system_profiler SPHardwareDataType -json` |
| 内存 | 64 GB，68,719,476,736 bytes | `sysctl -n hw.memsize` |
| Xcode | 27.0，build 27A266a | `xcodebuild -version` |
| Xcode 选择 | `/Applications/Xcode.app/Contents/Developer` | `xcode-select -p` |
| Flutter | 3.47.6 stable，revision `5fc346839b5d0eef006ed8404392afb4dfae428d` | `~/flutter/bin/cache/flutter.version.json` 与 Git HEAD/tag |
| Dart | 3.13.5 | `~/flutter/bin/cache/dart-sdk/version` 与 `~/dart/version` |

当前 shell 的 PATH 不直接提供 flutter/dart；已有 SDK 位于用户目录，构建使用 `~/flutter/bin/flutter` 的绝对入口。没有调用 Flutter CLI 初始化或下载缓存，也没有记录序列号、硬件 UUID 或凭据。

## 容器检查环境

- Docker context 为 `socktainer`；`docker info` 可查询 Linux/aarch64 API，Apple container status 为 running。
- 已有预编译运行时为 Apple container 1.2.0、Socktainer 1.2.1，与 [Socktainer 运行时约定](/Users/ghost233/.codex/skills/socktainer/references/runtime.md) 一致。本轮没有启动、恢复或替换运行时。
- 来源脚本指定的 `jevmanager-flutter-dev` 容器当前 running，基础镜像标签 `docker.io/library/node:22-bookworm`，本地镜像 ID 为 `sha256:b937e94e9d34b951780aeada17bebd8f979de53ea3cadba193e7dec85dc3be8f`，架构 linux/arm64。这个 ID 是当前本地镜像观察，不冒充可拉取的 registry manifest digest。
- 容器可读 Flutter 3.47.6 / revision `5fc346839b5d0eef006ed8404392afb4dfae428d`、Dart 3.13.5 与 `/workspace/ready`。缓存 channel 为 `[user-branch]`，Git revision 与宿主及来源 bootstrap 固定值一致。
- 来源：[测试脚本](https://github.com/Ghost233/JevManager/blob/ff97c9a5b1c7ed164abe6f6906c03cacd65a4d3e/scripts/test-container.sh)、[Flutter bootstrap](https://github.com/Ghost233/JevManager/blob/ff97c9a5b1c7ed164abe6f6906c03cacd65a4d3e/scripts/container/bootstrap-flutter.sh)。新项目实施时使用隔离的检查副本/容器，不覆盖来源正在使用的测试工作区；重新记录实际镜像与运行版本。

## 检查边界与证据限制

通用依赖解析、format、analyze、Dart/widget 测试按 [工程规范](../engineering.md) 在容器执行；macOS Release 编译、原生窗口、真实引擎、HTTP/MCP 与启动器 SDK 联调在宿主执行。

来源 pubspec 的 Dart `^3.13.5` 与当前 SDK 相符，MacLauncher SDK 的 `^3.13.0` 声明也相容。版本相符不表示新依赖解析或插件/构建缓存已验收。

来源 JevManager HEAD 为 `ff97c9a5b1c7ed164abe6f6906c03cacd65a4d3e`，工作区干净。Kev/Laya + 官方 b11381 是来源已验证组合；其 150 项历史测试与旧截图不计作 GhostModelDeck 通过。本轮未复测模型、许可证状态、签名身份、插件完整性或新的 `.app`。
