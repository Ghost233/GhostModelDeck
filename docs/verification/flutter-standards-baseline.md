# Flutter 规范启用检查

日期：2026-10-05。规范入口为根 AGENTS.md，工程与界面要求分别见 [工程规范](../engineering.md) 和 [设计规范](../design.md)。本记录验证规范与检查入口的启用，页面验收按设计规范另行执行。

## 环境与范围

- Socktainer 独立容器 `jevmanager-flutter-standards-20261005`；通用检查使用源码副本。
- Flutter 3.47.6，提交 `5fc346839b5d0eef006ed8404392afb4dfae428d`；Dart 3.13.5。
- `flutter_lints` 6.0.0，传递依赖 `lints` 6.1.0；容器解析后的 lockfile 与工作区 SHA-256 一致：`1fe5e0ab75922dc0c732092f7de335a2783e5cd972c9e11039bdd7f34f67c345`。
- 检查包含根 lint 配置、`lib`、`test` 和 `benchmarks`。三次归档中，按文件名排序后以“文件名 + NUL + 文件内容”计算的内容 SHA-256 均为 `900596c236858594ab9d011105d2eb88e0294ffeef519ab77dd7461452d84994`。

## 结果

| 检查 | 实际结果 | 本机日志 |
| --- | --- | --- |
| 文档引用 | 10 个本地链接及标题锚点通过 | 检查 AGENTS.md 与两份规范 |
| 脚本语法 | `bash -n scripts/test-container.sh` 通过 | Shell 退出码 0 |
| 静态分析 | 未通过：125 条 info，0 warning、0 error，退出码 1 | `.tooling/container-tests/run-bBSZIM/result.log` |
| 格式检查 | 未通过：52 个文件中 17 个需格式化，退出码 1 | `.tooling/container-tests/run-TfIxzM/result.log` |
| 现有测试 | 109 项全部通过，退出码 0 | `.tooling/container-tests/run-4k1eoT/result.log` |

`format --output=none --set-exit-if-changed` 只检查副本。日志中的 `Changed` 表示需要格式化，不表示工作区源码被改写。

## 启用时的 lint 基线

| 规则 | 数量 |
| --- | ---: |
| `curly_braces_in_flow_control_structures` | 110 |
| `avoid_relative_lib_imports` | 6 |
| `unnecessary_overrides` | 3 |
| `use_null_aware_elements` | 2 |
| `prefer_initializing_formals` | 2 |
| `avoid_print` | 2 |

其中 `lib` 88 条、`test` 31 条、`benchmarks` 6 条。这些是新基线发现的现有源码提示，按明确范围整改；本次保留诊断，静态分析和格式检查尚未通过。

复现使用工程规范中的三个检查命令。完整源码归档和输出保存在各日志的同级目录，均为本机忽略的检查产物。
