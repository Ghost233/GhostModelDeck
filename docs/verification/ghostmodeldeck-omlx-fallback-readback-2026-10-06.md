# oMLX fallback 读回形态修复验证（#22，2026-10-06）

## 来源与缺陷

- #16 M3b 原生池验收（ghostmodeldeck-omlx-pool-native-2026-10-06.md，fcb3163）实测：真实打包 oMLX 0.7.0 的
  `POST /admin/api/global-settings {model_fallback:false}` 返回 `200 {"success":true,"runtime_applied":["model_fallback"]}`，
  不回显 `model` 设置；旧 `_enforceFallback` 按 r49 源提交契约期待 POST 回显嵌套 `model.model_fallback`，导致 startRuntime 必败（漂移 D1）。
- 探针坐实 `GET /admin/api/global-settings` 响应含嵌套 `model.model_fallback` 可读回（证据 .tooling/gmd_r66_admin_shape_probe.json，gitignored）。

## 修复（HEAD 本提交前驱 6f7f8d4）

- `_enforceFallback`（lib/omlx_engine.dart）：POST 后校验 `success==true` 且 `runtime_applied` 含 `model_fallback`，否则拒绝；
  再经 `GET /admin/api/global-settings` 读回嵌套 `model.model_fallback`，非 `false` 或形态不明仍 fail-closed。
- GET 原始响应含真实凭据：仅内存投影嵌套布尔，原始文本不进异常/日志/快照/证据；`_admin` 非 200 错误面仍经 `pool.redact`。
- `_admin` body 改可空，GET 不带请求体。
- 行为记录 D2（`model_fallback=false` 不禁止已知模型按需加载，冷拒绝靠引擎 admission 栅栏）不在本修复范围，已记入 #22。

## 公开 TDD 证据（专用容器 ghostmodeldeck-checks-r33b，原始在线）

- RED run-UXfsZL：替身 POST 改真实形态 `{success,runtime_applied}` 后 13 用例失败（startRuntime 全线受阻），证明替身冻结了真实漂移形态。
- GREEN run-Hu9euS：test/omlx_pool_test.dart 14/14 通过。
- format run-44b8MD：63 文件 0 需改（容器内格式化写回经逐文件 SHA256 核对，526536655233fdc85936fc6297bb094562c2a9b2ae677c2c60145a9a414565c5）。
- analyze run-3vx0Ah：No issues found。
- 全量 test run-NsNPGd：352/352。
- 泄漏回归：替身 GET 响应携带诱饵 api_key/secret_key，测试断言凭据不出现在任何错误面，且 GET 恰好 1 次（仅读回用途）。

## 独立校验

`.tooling/gmd_verify_final_gates_r58.py run-44b8MD run-3vx0Ah run-NsNPGd` → PASS exit0
（.tooling/gmd-final-gate-verification-d1fix.json）：63 Dart 输入当前=GitBlob=三归档，352 全量，三道原始在线命令归档绑定。

## 边界与未证

- 线缆级 M3b 证据（fcb3163）仍有效；D1 修复后需原生重验收生产路径 startRuntime→加载→推理→停止 全链路（判据 2–7）方可关闭 #22。
- 探针证据文件曾捕获一条已失效代际原始凭据，已事后擦除为 SHA-256（scrubbed-post-hoc）；该文件 gitignored 未入库，凭据代际已随池销毁。
- HTTPS 下载路由、模型管理 CRUD、停止后重试语义仍未原生验证。
