# Flutter macOS 构建与原生引擎打包边界

调查日期：2026-10-04。输入约束：标准 Flutter 应用、macOS 优先；项目依赖、测试和服务在容器中运行，目前仅原生推理引擎有宿主例外。本报告只查官方资料和工具存在性，未安装依赖、构建、运行应用、测试项目或扫描模型目录。

## 结论

标准 Flutter 可交付真正的 macOS `.app`：保留 Dart UI 与 Flutter 生成的 Xcode Runner，由原生 `NSWindow` 承载 `FlutterViewController`。官方把 macOS 目标限定为 **On macOS only**；Linux 容器不能成为受支持的 macOS release 构建环境。现有“只允许原生推理引擎”的例外尚不覆盖 Flutter macOS 编译和桌面验收，需在实施这些步骤前明确范围。[Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)、[平台构建边界](https://docs.flutter.dev/platform-integration)、[官方 Runner 模板](https://raw.githubusercontent.com/flutter/flutter/stable/packages/flutter_tools/templates/app/macos.tmpl/Runner/MainFlutterWindow.swift)

## 项目形态与容器边界

采用应用模板 `flutter create --platforms=macos <目录>`，形成共享 Dart 代码、`pubspec.yaml`、测试和 `macos/Runner.xcworkspace` / Runner 原生代码；已存在 Flutter 项目可通过 `flutter create --platforms=macos .` 补充平台目录。生成目录与编译应用是两件事：工具源码按平台参数及 feature flag 渲染模板。**实施推断**：可先在 Linux 容器准备标准模板与共享代码，但本机容器中的实际 SDK/模板生成路径仍未验证。[桌面创建命令](https://docs.flutter.dev/platform-integration/desktop)、[create 工具源码](https://raw.githubusercontent.com/flutter/flutter/stable/packages/flutter_tools/lib/src/commands/create.dart)、[Runner 工程设置](https://docs.flutter.dev/deployment/macos)

| 工作 | 可执行位置与验证边界 |
| --- | --- |
| Pub 依赖解析、静态检查、纯 Dart 单元测试、Flutter widget 测试 | 按项目规则放 Linux 容器；适用于共享逻辑和替身接口。widget 测试使用简化 UI 环境，不能证明完整桌面行为。[测试分类](https://docs.flutter.dev/testing/overview) |
| 原生插件、文件选择器、macOS API、真实推理进程 | unit/widget 测试没有插件的宿主代码；须另做 macOS 集成或桌面验收，不能把 mock 通过算作平台通过。[插件测试限制](https://docs.flutter.dev/testing/plugins-in-tests) |
| `.app` release 编译、Xcode 原生依赖与打包 | macOS＋Xcode；官方命令为 `flutter build macos`，随后可打开 `macos/Runner.xcworkspace`。[macOS 构建](https://docs.flutter.dev/platform-integration/macos/building)、[工具链设置](https://docs.flutter.dev/platform-integration/macos/setup) |
| Sandbox、签名、Gatekeeper、窗口/退出、Metal 引擎联合验收 | 在实际 Mac 产物上验证；Linux 测试不能证明这些 macOS 约束满足。[App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)、[发行验证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) |

当前官方文档说明 Flutter 3.44 起 Swift Package Manager 默认启用，尚不支持 SwiftPM 的插件会回退 CocoaPods。故不能提前断言宿主无需原生依赖解析，也不应不看插件就安装 CocoaPods；应先固定 Flutter 与依赖版本，再列出需要在 Mac 下载/解析的包与缓存范围。[SwiftPM 应用指南](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)

## 引擎进程与 bundle 路径

- 长驻推理引擎或 stdio MCP 用 `Process.start`，保留 `Process`、读取两路输出并观察 `exitCode`；不消费 stdout/stderr 会留住资源，输出超过 pipe 缓冲还可能阻塞。短时非交互命令用 `Process.run`，结果到完成时返回。使用绝对 executable 路径和参数数组，`runInShell` 保持默认 `false`，显式设置工作目录，避免依赖 Finder 启动时的 PATH。[Process.start](https://api.dart.dev/dart-io/Process/start.html)、[Process 类](https://api.dart.dev/dart-io/Process-class.html)、[Process.run](https://api.dart.dev/dart-io/Process/run.html)
- `normal` 模式不保证父应用退出时终止子进程；Dart 文档明确父进程调用 `exit` 后子进程会继续运行。`detached` 更允许脱离父进程，并且没有退出码；因此应用管理的引擎不应靠 detached 或父退出自动收尾。`kill()` 默认发送 SIGTERM，返回 `true` 只证明信号成功送达，应继续等待 `exitCode`。[Process.start](https://api.dart.dev/dart-io/Process/start.html)、[Process.kill](https://api.dart.dev/dart-io/Process/kill.html)
- Mach-O helper 推荐放 `Contents/MacOS/`；Apple 的 Copy Files → Executables / Code Sign On Copy 正是这一方案。framework/dylib 放 `Contents/Frameworks/`，数据放 `Contents/Resources/`。不要把推理 executable 当普通 Flutter asset 随意放入资源目录后声称完成原生打包；代码位置错误可能到公证阶段才失败。[嵌入 helper](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)、[bundle 内容位置](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
- 路径可由 Runner 经 `Bundle.main.url(forAuxiliaryExecutable:)` 找到 helper，再把绝对路径交给 Dart；动态库按已配置的 bundle 目录解析。`Platform.resolvedExecutable` 给出当前实际执行文件的绝对路径，可作诊断或路径推导依据，但 release、debug 和测试运行方式仍需分别验证。[Bundle helper URL](https://developer.apple.com/documentation/foundation/bundle/url(forAuxiliaryExecutable:))、[Dart executable 路径](https://api.dart.dev/dart-io/Platform/resolvedExecutable.html)

## Sandbox、模型目录与网络

Flutter macOS 模板默认启用签名和 App Sandbox，**这不是用户已经选定的发行状态**；是否保留 Sandbox 待决定。以下权限与书签约束适用于保留 Sandbox 的方案。出站 HTTP，包括连接已有本机引擎服务，需要 `com.apple.security.network.client`；需要监听连接时还要 server 权限。debug/profile 默认的 server 权限用于 Flutter 工具通信，release 并不自动带有它，必须分别核查 DebugProfile 与 Release entitlements。[Flutter macOS 权限](https://docs.flutter.dev/platform-integration/macos/building)

嵌入的命令行工具必须继承父应用 Sandbox。helper 的 Sandbox entitlement 仅为 `com.apple.security.app-sandbox=true` 和 `com.apple.security.inherit=true`；主应用不能设 inherit。额外 entitlement 或开发阶段自动注入的 `get-task-allow` 可能使继承 helper 出错，需按 Apple 指南配置与实际验收。[Apple helper 指南](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)、[Sandbox 继承规则](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)

可配置模型目录、共享 LM Studio 模型目录，应分开两种操作：**已有资产扫描/导入**可使用只读权限；**新下载直接写入共用目录**需要读写权限。若保留 Sandbox，通过标准文件夹选择取得所选目录及其子项访问，分别配置 `com.apple.security.files.user-selected.read-only` 或 `com.apple.security.files.user-selected.read-write`。若还要跨应用启动持续访问容器外目录，应保存 **security-scoped bookmark**，下次解析、处理 stale bookmark 并在使用目录期间开启作用域，结束后关闭；仅保存路径字符串不能代替 Sandbox 授权。helper 的目录继承或书签传递须在签名应用内验证，不能仅因 Flutter 能读就认定引擎可读。只读导入可作为最小权限建议，但不是已经确认的共享目录规则；用户可以选择将新下载直接写入已授权的共用目录。若最终采用无 Sandbox 的直接发行方案，不把 security-scoped bookmark 当作普遍前提，仍须验收实际文件权限。本轮不选路径、不扫描目录、不认定模型格式与某引擎兼容。[Sandbox 文件及跨进程书签](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、[Flutter 文件权限](https://docs.flutter.dev/platform-integration/macos/building)

Apple 明确：用户所选文件权限不能让应用运行位于 bundle、Sandbox container 或 app group container 之外的程序；`user-selected.executable` 是写 executable 的权限，不能当作任意外部程序启动许可。因此“管理本机既有引擎的 HTTP 服务”与“从任意 LM Studio/llama.cpp 安装目录启动 binary”是不同路径，后者不可在默认 Sandbox 下直接承诺。[Sandbox executable 限制](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

## 签名、发行与下载代码

嵌套代码须由内向外签名，签名后 bundle 视为只读；签名时不应靠 `codesign --deep` 掩盖组件配置。Hardened Runtime 默认启用 library validation，动态加载的 library 必须由 Apple 或与主 executable 同 Team ID 签名，除非明确采用对应例外。是否需要例外取决于实际引擎，不能预先关闭检查。[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/)、[Library validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)

Mac App Store 要求 Sandbox、自包含安装包，2.4.5(iv) / 2.5.2 限制下载或安装增加/改变功能的代码；也不允许未经同意在用户退出后继续保留子进程。不能据此设计一个“App Store 版本首次启动下载任意引擎 binary”的默认方案。模型权重与 Mach-O executable 应分开处理，但把文件叫“模型资源”不构成对任意资源包或 remote code 的审核豁免。[App Review Guidelines 2.4.5、2.5.2](https://developer.apple.com/app-store/review/guidelines/)

直接发行的正规流程是 Developer ID 签名、为应用及命令行目标启用 Hardened Runtime、有效时间戳、提交 Apple 公证并 staple ticket；本地开发签名不等于完成发行。直接发行不套用 Mac App Store 的更新渠道规则，但下载代码仍须满足 Sandbox、签名/Gatekeeper 等实际约束；不能修改已签名 `.app` 内的 helper 来更新它。[Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[签名 bundle 不可变](https://developer.apple.com/library/archive/technotes/tn2206/)

## 关闭窗口与退出

当前 Flutter stable 的 AppDelegate 模板把 `applicationShouldTerminateAfterLastWindowClosed` 返回值设为 `true`，即最后窗口关闭触发应用终止。`AppLifecycleListener.onExitRequested` 可异步允许/取消可取消的退出；强制终止并不保证回调，且 hidden/inactive 不是退出事件。**最小实现建议**：保持模板行为；正常退出时停止本应用启动的引擎、等待退出后再允许应用终止；强杀/崩溃后的恢复另行验收。若以后要求“关窗口仍推理”，须明确产品行为和进程所有权，不能悄悄改成常驻。[AppDelegate 模板](https://raw.githubusercontent.com/flutter/flutter/stable/packages/flutter_tools/templates/app/macos.tmpl/Runner/AppDelegate.swift)、[退出回调](https://api.flutter.dev/flutter/widgets/AppLifecycleListener/onExitRequested.html)、[生命周期限制](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)

## 本机只读证据与未实测项

| 检查 | 2026-10-04 结果 |
| --- | --- |
| `command -v flutter dart` | 当前 PATH 未发现；不代表全盘不存在 SDK |
| `command -v xcodebuild xcrun clang codesign` | 均位于 `/usr/bin/` |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` |
| `xcodebuild -version` | Xcode 27.0，Build version 27A266a |
| `xcrun --find notarytool` | `/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool` |

这些只证明 CLI 可定位及 Xcode 可返回版本，不证明选定 Flutter 与 Xcode 兼容、许可证/SDK/插件完整、签名身份可用或 `.app` 可运行。本轮没有执行 `flutter doctor`、`flutter --version`、`pub get`、编译、进程/Sandbox 测试或签名。Linux 容器 SDK、arm64 helper、书签跨进程、发行签名及窗口退出流程均未实测。先前硬件及容器状态读取被沙盒拒绝，不能推出机器内存大小或运行时停止。

## 下个 HITL 的最少决定

1. **明确 Mac 工具链例外的范围**：后续若要交付/验收 `.app`，需要允许在指定目录准备固定版本 Flutter SDK 与 macOS artifacts、解析构建所需 Dart/SwiftPM（必要时 CocoaPods）依赖、运行 `flutter build macos --release` / Xcode 编译，以及运行实际 Mac 桌面应用、原生插件和引擎联合验收。共享 Dart/widget 测试继续放容器。构建不自动授权桌面测试；应一起列明或分别授权。若不增加例外，只推进容器中的源码与共享测试，不能宣称 Mac 交付验证完成。[官方 Mac 工具链](https://docs.flutter.dev/platform-integration/macos/setup)、[构建与插件限制](https://docs.flutter.dev/testing/plugins-in-tests)
2. **在实现 binary 管理/发行前确定范围**：先做本机开发验收，还是面向直接发行/App Store；需要随包签名的 helper、连接用户已有服务，还是下载/启动外部引擎。这个决定影响 Sandbox、引擎更新和签名方案；现在不代选渠道或关闭 Sandbox。签名凭据使用、公证上传与公开发行须在具体产物可审查后按用户要求办理。[发行流程](https://docs.flutter.dev/platform-integration/macos/building)、[App Store 限制](https://developer.apple.com/app-store/review/guidelines/)

窗口默认行为可作为最小方案；共享目录只读导入与读写下载是不同操作，权限应跟随用户选择。它们不是本轮新增的常驻后台运行或个人目录访问授权。
