# SDK 菜单栏显示许可接入

2026-10-08，按用户要求核验 MacLauncher 上游 main 为 `268f88ef5ff47dbafe88200d5cddd090983ad313`，更新根 Git 依赖及 lockfile。应用通过 SDK 声明 `setEntryManaged`，由既有 MethodChannel 调用实际 NSStatusItem：true 暂时隐藏，false 归还自身显示控制。仅在实际应用成功时确认；不改变窗口、Dock 或业务运行，不持久保存 Launcher 的临时约束。

| 检查 | 实际结果 |
| --- | --- |
| 最新固定 SDK 在线解析 | exit 0，仅 SDK Git ref 改变，包版本仍为 0.1.0。 |
| 菜单栏许可定点测试 | exit 0，3 项通过：真实 Unix socket 请求/确认、模型与业务保持运行、原生拒绝及非法参数、在途隐藏后的断连归还顺序。 |
| 最终格式检查 | exit 0，90 文件、零改动。 |
| 最终静态分析 | exit 0，零诊断。 |
| 最终全量应用测试 | exit 0，543 项通过。 |
| 完整 Mac Release 构建 | exit 0，生成 Ghost Model Deck.app。 |
| 原生 NSStatusItem 探针 | exit 0，隐藏与恢复均按实际 isVisible 确认，激活策略未改变。 |

原生探针使用实际 AppDelegate.swift，仅移除 @main 后与独立测试入口编译；创建的是本次测试自己的 NSStatusItem，不操作已安装应用。源文件 SHA 为 `54fbe52fa312f950441d570fa175bb7c14c6a8bc2dfc92abe30f78e10764fe8e`。真实 SDK 请求与原生 API 分别验收；未在当前已安装应用中自动操作 Launcher 项目开关。

容器第一次依赖准备因宿主 SDK bare Git 缓存的 uid 被保留而失败（定点检查 exit 69，Git exit 128）。修正本次容器缓存的 ownership 并移除传输附带的 AppleDouble pack 元数据后，定点及完整检查通过。独立原生探针首次编译缺少 framework 头文件搜索路径，补齐后通过；产品 Mac 构建此前已通过。原失败、修复后的日志、退出码和最终源码 SHA 清单保存在 `.tooling/sdk-menu/`。测试容器已停止。

本次源码与构建仍在工作区，未更新线上 v0.1.3 发行包。
