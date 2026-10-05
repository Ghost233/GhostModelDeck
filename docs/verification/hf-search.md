# HF 搜索与文件浏览验收

工单：[紧凑桌面里的 HF 搜索与文件浏览](https://github.com/Ghost233/JevManager/issues/11)
规格：[JevManager 首版](https://github.com/Ghost233/JevManager/issues/10)
状态：切片验收通过；整份规格的集成验收与三份独立审查仍待后续完成。

## 工具链与执行边界

- Mac：Flutter 3.47.6（5fc346839b5d0eef006ed8404392afb4dfae428d），Dart 3.13.5；SDK 位于用户指定的 ~/flutter 与 ~/dart。
- 容器：Socktainer 上下文，现有 arm64 node:22-bookworm 基础镜像，4 GB 内存，无宿主目录挂载。Flutter 源码固定同一 commit，Dart 和 Linux arm64 引擎由该 SDK 官方脚本取得。
- 已实测容器内普通 Flutter CLI 的缓存 app-JIT 快照在重启后崩溃。直接执行同一 SDK 的官方 flutter_tools.dart 可运行版本查询、依赖解析和 Flutter 行为测试；scripts/container/bootstrap-flutter.sh 固定这一入口。崩溃根因尚未确定。
- 容器初始化对 HF 的独立联网请求超时。已取得 SDK 与项目依赖；HF 替身业务测试与实际 Mac/HF 联调分别验收。
- 通用行为测试使用 scripts/test-container.sh，由容器主进程运行；源码归档与导出日志均对账 SHA-256。

## 容器行为证据

- 第一个测试先因正式 hf_model_browser.dart / HfModelBrowser 不存在而失败，再在同一 HF HTTP 边界测试下通过。
- 三个新增行为分别取得红灯再通过：关键词检索、固定 revision 的文件选择、仓库地址直达。
- 完整 11 个测试通过：检索、元数据/文件/哈希/大小映射、直达、空搜索、HTTP 失败、空仓库、缺少固定 commit、revision 切换清空选择、失败重试、过期搜索与 revision 响应保护。
- flutter analyze 无问题。测试均从生产 HfModelBrowser 入口经过真实 HTTP 编解码，仅 HF 服务由容器内 HttpServer 控制。
- 完整测试证据：.tooling/container-tests/run-BNDGVf/result.log；静态检查：.tooling/container-tests/run-4XjbDb/result.log。源码及日志已校验 SHA-256。
- 2026-10-04 本机对真实 HF 搜索 API 的只读请求成功；该请求仅证明当前网络/API 可达，不代替桌面实际操作验收。

## Mac 实际操作

- 正式 lib/main.dart release 构建成功，产物 build/macos/Build/Products/Release/JevManager.app（42.0 MB）；构建日志位于 .tooling/implementation/11-native-build.log。
- 在正式应用中输入 kev-0.8b，真实 HF 返回 23 个仓库；选择 ggml-org/Kev-0.8B-GGUF 后展示 6 个实际文件、apache-2.0 和固定 commit e551e319d483ff57e1ff208924b349d397cffc1c。
- 文件表展示 BF16 GGUF 1.41 GiB、Q8_0 GGUF 774.8 MiB；选中 Q8_0 后显示已选 1 个 / 774.8 MiB。
- 使用实际原生键盘输入 ggml-org/Kev-0.8B-GGUF，可直接取得该仓库与上述真实文件列表。
- 新界面只有紧凑导航、搜索、仓库/文件表格，没有方案选择器、教程或模拟状态。以上操作未发生旧原型的强制 semantics 崩溃。
- 原生 UI 自动化的 AX 点击/值设置不能代替真正的输入焦点；最终仓库直达证据使用截图坐标点击和原生按键取得。尝试拖动窗口未证明尺寸发生变化，不把该操作记为缩放通过。

## 后续集成边界

- 此切片不包含下载、资产兼容性识别、引擎或 MCP；格式列只表示文件后缀。
- 整份规格完成后进行三份独立审查，修复 P0/P1/P2，再创建 PR。
