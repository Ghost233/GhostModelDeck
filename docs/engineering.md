> 工程要求继承自 JevManager，现用于 GhostModelDeck；产品范围以新项目规格为准。来源实现和验证记录不表示新能力已经通过验收。

# 工程规范

适用于 GhostModelDeck 的 Dart、Flutter、原生桥接及检查脚本。**必须**是验收要求；**建议**可按具体问题调整并说明原因；**按需**在出现对应复杂度或实测问题时采用。

产品行为以 [规格](spec.md) 与来源工单为准，术语以 [CONTEXT.md](../CONTEXT.md) 为准。本文记录工程选择，界面规则见 [设计规范](design.md)。遇到冲突先指出具体条目，再作范围明确的决定。

## 编码与模块边界

| 规则 | 强度 | 要求与核验方式 |
| --- | --- | --- |
| E01 语言基线 | 必须 | 命名与导入遵循 Effective Dart；格式交给 `dart format`，静态规则以根 `analysis_options.yaml` 为准。通过格式与分析检查。 |
| E02 类型与外部数据 | 必须 | 接口声明明确类型；外部 JSON、文件元数据和推理响应在 I/O 边界校验后形成有类型的数据。核对非法输入测试，避免将 `dynamic` 传播到业务逻辑。 |
| E03 异步归属 | 必须 | 调用方等待需要完成的工作；有意后台执行用 `unawaited` 表达，并落实错误处理和生命周期归属。核对失败、取消及晚到结果的行为。 |
| E04 资源所有权 | 必须 | 进程、连接、订阅和临时文件有明确创建者与释放入口。自动释放处理本应用拥有的运行资源；共享模型文件的手动删除遵循规格。核对重复关闭及外部资源保留。 |
| E05 界面边界 | 必须 | Widget 处理展示、输入、布局、焦点与局部交互状态；文件操作、下载状态、推理实例和委员会计算由业务模块负责。审查调用路径。 |
| E06 共用业务入口 | 必须 | 桌面、HTTP API、MCP 与 SDK 使用同一业务控制和运行实例；委员会核心保持纯 Dart，各入口只负责界面或协议适配。通过共用入口的行为测试核验。 |
| E07 状态归属 | 必须 | 每种业务状态有一个权威来源，界面观察它并提交操作。局部输入可用 `State`；可观察状态可用现有 `Listenable`/流。新增状态管理库需说明现有方案解决不了的问题。 |
| E08 依赖传入 | 建议 | 从应用组装入口通过构造参数传入业务依赖。共享状态由明确的所有者维护，便于测试和生命周期管理。 |
| E09 按职责拆分 | 建议 | UI 按页面或功能聚合，共享业务与 I/O 模块按职责组织。按修改需要拆分现有文件；目录迁移作为独立改动评估。 |
| E10 增加抽象 | 按需 | 重复业务逻辑或过大的界面状态处理出现后，再提取领域模块或 use-case；外部边界及实际需要替换的实现使用接口。说明抽象服务的具体调用方。 |
| E11 性能措施 | 按需 | 大列表使用惰性构建；CPU 工作、重绘或状态更新影响交互时，先测量，再选择 isolate、重绘隔离等措施，并用相同场景对比。 |
| E12 依赖变更 | 必须 | 说明新增包解决的问题及 SDK/平台兼容性，在选定的宿主机或容器环境联网解析依赖并保留 lockfile。实验性 API 先验证固定 SDK 与平台支持，再决定是否采用。 |

状态管理与目录结构服务于这些边界。MVVM 是组织 UI 与状态处理的参考；无需为每个功能复制一套三层目录。

## 修改与检查流程

1. 确认本次行为、适用规则及可观察的成功标准；涉及领域行为时按 `docs/agents/domain.md` 读取术语与相关 ADR。
2. 在现有业务入口实现修改。缺陷先复现，行为变更补充相应测试；文档或纯视觉调整使用链接、截图和交互检查验证。
3. 本次产品与检查平台统一为 **macOS arm64 宿主机**。使用固定 Flutter 3.47.6（`5fc346839b5d0eef006ed8404392afb4dfae428d`）、Dart 3.13.5、现有 lockfile 和联网依赖解析；格式、静态分析、完整业务/widget 测试及真实 Mac 构建均在该宿主机执行。Linux、Windows、macOS Intel/x64 不属于本次适配或验收范围，运行时只准备 macOS arm64 版本。

2026-10-09 用户进一步统一本次执行方式：不新建或恢复容器，不以 Linux 容器作为默认检查或必需前置。旧容器日志只保留为历史证据，不代替当前宿主门禁。

新增 `scripts/test-host.sh` 统一准备及检查入口：先通过显式 `GMD_FLUTTER_SDK`、`GMD_TEST_PYTHON`、`JEV_LAYOUT_FONT` 核验实际工具链、字体摘要及规范临时目录，在线解析依赖并记录准备清单；后续定点及完整门禁复用同一准备结果。字体和布局断言全部保留，不因缺依赖跳过；SDK 字体使用实际 Mac SDK 路径。

```sh
export GMD_FLUTTER_SDK=/Users/ghost233/flutter
export GMD_TEST_PYTHON=/Users/ghost233/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
export JEV_LAYOUT_FONT="$PWD/.tooling/check-fonts/NotoSansCJK-Regular.ttc"
./scripts/test-host.sh prepare
./scripts/test-host.sh check
```

改动 `scripts/` 下的 shell 脚本时，必须先 `bash -n` 静态检查；含副作用的脚本（打包、发布、环境准备）合并前必须完成一次真实干跑并核验产物。变量展开紧邻非 ASCII 字符时必须加花括号（macOS 自带 bash 3.2 会把全角字符字节并入变量名）；依赖 `trap` 清理的脚本须在 trap 内保存并恢复退出码。

宿主机检查记录固定 SDK 版本、源码 HEAD 及实际待测内容指纹、执行命令、环境、日志和真实退出码，保留主错误与清理错误。`format --output=none` 只检查，不改写工作区。切换执行环境后不能冒用另一环境的结果。

检查按联网模式执行；用户明确要求不使用离线模式。外网故障保留具体请求、超时阶段与失败结果，诊断恢复后重跑，不以缓存离线结果替代正式检查。新增 git 依赖或提升 git ref 后，先核对实际检查环境能否获取固定提交；遇到网络故障再采用经过核验的缓存准备，不沿用旧兼容层的 DNS/复制限制。

源文件改写使用固定 Dart SDK。固定 #66 候选后，先关闭已确认的原始失败，再集中完成完整门禁、真实模型完整 400 题 HTTP、独立原评分及退出/历史验收。新失败先定点处理，通过后完成必要回归，不反复冻结相同内容。运行记录见 [测试场交付](verification/playground-benchmarks-delivery.md)。

## 测试与完成证据

- **必须**从公开业务入口验证输入、输出、状态与资源变化；替身接缝遵循 [已确认的测试边界](spec.md#已由用户确认的测试边界)。
- **必须**给并发、超时、取消和生命周期修改提供确定性的行为证据。真实模型、桌面窗口与 Codex 接入需要各自的原生验收，容器测试不能替代。
- **必须**在结果中说明检查范围与限制。新增 lint 暴露已有问题时保留诊断，修复按明确范围进行；规则抑制需在对应位置解释必要性。
- **建议**为重要架构取舍按需记录 ADR，包含问题、选择、代价和验证。小型实现选择留在代码或变更说明中。

## 依据

查阅日期：2026-10-05。官方建议提供依据；本项目的要求强度由本文确定。

- [Effective Dart](https://dart.dev/effective-dart)：语言约定。
- [flutter_lints](https://pub.dev/packages/flutter_lints)：官方应用 lint 基线，具体版本由 `pubspec.yaml` 与 lockfile 固定。
- [Flutter 架构建议](https://docs.flutter.dev/app-architecture/recommendations)：职责分离、数据流和条件性建议。
- [Flutter 架构示例](https://docs.flutter.dev/app-architecture/case-study)：UI 按功能与数据按职责组织的示例。
- [Flutter 仓库风格指南](https://github.com/flutter/flutter/blob/master/docs/contributing/Style-guide-for-Flutter-repo.md)：按需参考；框架仓库的特殊政策不自动成为应用要求。
