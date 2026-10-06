# #20 oMLX 启动门禁修复报告（Lead 直接实施）

日期：2026-10-06 · HEAD：`7f6d9af3c5768140f4a85166d584511b012cfbee`
范围：仅 `lib/omlx_engine.dart`、`test/omlx_engine_test.dart`（#20 授权范围）

## 背景

r61 原生验收（docs/verification/ghostmodeldeck-omlx-native-install-2026-10-06.md）
在真实 macOS 27.0.1 上判 FAILED：成功安装路径上所有候选目录被三处
fail-closed 门禁拒绝，且官方包自身触碰所有权门禁。573 个原生事件零超时、
首次 Python 前死亡、清理模范——缺陷全部在门禁逻辑的事实假设上。

## 三缺陷与修复

### B：sticky 系统目录不可达（lib/omlx_engine.dart `_safeDirectory`）

实测 macOS `stat -f %Lp` 对特殊位只打印低三位：`/private/tmp`（1777）显示为
777。代码本意放行「root 拥有 + sticky 的世界可写系统目录」，但因永远读不到
sticky 位而必然拒绝。

修复：stat 格式改为 `%u:%g:%Mp%Lp:%HT`（`%Mp` 单独打印特殊位数字），
抽取为常量 `_statFields`，`_safeDirectory`、`_builderGate`、
`_bundleOwnership` 三处统一使用。`%f` 是文件标志位而非模式，弃用。

### C：家目录标准 deny ACL 被拒（`_safeDirectory` ACL 分类）

macOS 用户家目录出厂自带 `0: group:everyone deny delete` ACE（防误删），
原实现拒绝任何 ACL 行，使默认安装根
`~/Library/Application Support/GhostModelDeck/engines/omlx` 不可达。

修复：首行目录位检查不变；后续每一行必须精确匹配
`^\s*\d+: (user|group):\S+ deny [a-z_,]+$`（deny-only、无 allow）。
deny ACE 只能收紧不能放宽访问，属于安全；任何 allow 或无法分类的行
仍然 fail-closed（原「ACL」守卫用例继续通过）。

### A：官方包 group-writable CPython 条目触碰所有权门禁（`_bundleOwnership`）

官方 0.7.0 DMG 内含 1206 个 group/other 可写条目（1158×0o664 CPython
stdlib + 48×0o775 含 bin/python3.11、libpython3.11.dylib；
完整清单 .tooling/gmd_r61_bundle_ownership_offenders.json）。门禁本身
正确——外来包必须拒；但 install 是把官方字节复制进自有 0700 私有副本，
正确策略是复制后归一化。

修复：仅 `install` 流程在 ditto 复制 + 逐文件清单比对之后插入
`/bin/chmod -R go-w <私有副本>`，随后 `_inspect` 在归一化后的字节上
复验清单、签名与所有权。外来包路径上的 `inspectLinked` 不做任何归一化，
官方模式外来包仍然 fail-closed（新守卫用例锁定）。

## TDD 证据

- RED：run-Oy2Xuc——恰好 2 个预期失败：sticky 祖先测试挂在
  lib/omlx_engine.dart:331（权限拒绝）、deny-ACL 测试挂在 :340
  （ACL 无法安全分类）；其余 18 个测试（含全部守卫）通过。
  （首轮 run-VOZNaL 为假绿：容器是 Linux，替身路径条件
  `endsWith('/folders')` 不命中 `/tmp` 祖先链；改靶 `/tmp` 后取得真 RED。）
- GREEN：run-vC2pVW 聚焦 21/21 通过。
- 新增 4 用例：sticky 祖先放行、无 sticky 世界可写根仍拒、deny-only ACL
  放行、官方 0o664 外来包仍拒。
- 单元边界如实说明：`_verifyArtifact` 用纯 Dart 对真实文件做 SHA-256，
  替身无法绕过 DMG 哈希门禁，install 全流程（含 chmod 与原生重验顺序）
  不可在单元层模拟；缺陷 A 的最终 GREEN 由原生重验收确认。

## 三道在线闸门（专用容器 ghostmodeldeck-checks-r33b）

| 闸门 | 运行 | 结果 |
|---|---|---|
| format | run-uFjNfp | 62 文件 / 0 需改，exit 0 |
| analyze | run-UOs6R4 | No issues found |
| test（全量） | run-Zv2kUM | 338/338 通过（334 基线 + 4 新增） |

独立闸门校验器 .tooling/gmd_verify_final_gates_r58.py：**PASS**
（.tooling/gmd-final-gate-verification-gatefix.json）——62 Dart 输入
工作区=Git=三归档逐字节相等、338 全量测试计数一致、三条原始在线命令
与退出码核对、基线依赖与运行器未变。

## 如实记录的意外

- 首轮 RED 取证曾假绿一次（替身路径条件在 Linux 容器祖先链上不命中），
  已改靶重取证，未用假绿充当证据。
- format 闸门使用 `--output=none`，容器内格式化不回写宿主；经 base64 取回
  格式化结果并 SHA 核对后写回，复跑 0 changed。

## 未证事项（重验收范围）

成功安装/发布/refresh、生产 CLI/Python/Metal 冒烟、HTTPS 路线均未证——
等待原生重验收对缓存官方 DMG（SHA 2e3bb06a…bce0）重跑 r61 步骤。
