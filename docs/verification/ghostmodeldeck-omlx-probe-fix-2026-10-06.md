# oMLX 身份探针修复验证（缺陷 D，#21）

日期：2026-10-06 · 源码提交：`6e897eb7224ffc13f5f089d5996e89c7ce2f3474` · 父级独立校验：`.tooling/gmd-final-gate-verification-probefix.json`（PASS）

## 缺陷与证据来源

r62 原生重验收（[ghostmodeldeck-omlx-native-reinstall-2026-10-06.md](ghostmodeldeck-omlx-native-reinstall-2026-10-06.md)，commit 4a83815，证据 digest `926a136e…9b52`）在 #20 三缺陷修复全部原生生效后实测：生产身份探针 `importlib.metadata.version('omlx')` 在两轮完整安装中均 exit 1（`PackageNotFoundError: No package metadata was found for omlx`）。pristine 只读挂载同形探针同样失败；官方工件静态确认无 `omlx-*.dist-info`，omlx 仅源码包（`_version.py` `__version__="0.7.0"`）。其余四包（mlx/mlx-lm/fastapi/transformers）dist-info 均在。

## 修复

`lib/omlx_engine.dart` `_identityProbe`：omlx 版本改读 `omlx.__version__`；其余四包保留 dist-info 断言。Dart 侧全部既有身份断言不变（python 3.11.10 / arm64 / prefix / paths / origins / gpu `[[19,22],[43,50]]` / versions 五项）。

## TDD 证据

- **RED**：替身 `_ValidBundleIO` 编码工件事实——探针脚本不含 `omlx.__version__` 时以冻结的 PackageNotFoundError 形态 exit 1。聚焦运行恰好 6 个既有用例失败，全部 `oMLX 原生验证失败`（`_run` 探针 exit≠0 路径），与原生证据同构；15 个早期门禁用例不受影响。
- **GREEN**：探针修复后聚焦 21/21（run-gXWDbX）。

## 三道在线闸门（容器 ghostmodeldeck-checks-r33b，全部真实联网命令）

| 闸门 | 运行 | 结果 |
|---|---|---|
| format `--set-exit-if-changed` lib test benchmarks | run-hOBfzV | exit 0，62 文件 0 需改 |
| analyze | run-VLg4TI | exit 0，No issues found |
| 全量 test | run-o6r27c | exit 0，**338/338** |

父级独立校验器 `.tooling/gmd_verify_final_gates_r58.py` 复核三归档与 Git/工作区逐字节一致、命令与退出码如实、338 动态计数匹配：**PASS @ 6e897eb**。

## 未证事项（如实记录）

- 缺陷 D 的真 GREEN 是 **r63 原生重验收**：完整安装/发布/refreshInstallation 身份一致、探针整体通过、Metal 实测——单元层替身只是工件事实的编码，不能替代原生证据。
- HTTPS 下载路由、M3+ 池/服务范围仍全部未证。
