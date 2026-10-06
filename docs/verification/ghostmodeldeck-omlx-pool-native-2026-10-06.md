# oMLX 原生池验收（M3b，生产代码 + 真实服务 + 真实 MLX 模型）

- 日期：2026-10-06；代理轮次：r66；验收工单：#16 M3b
- 源码基线：main @ `a04139a`（验收期间未改任何 tracked 源码/测试；收尾 `git status` 干净）
- 真实环境：macOS Apple Silicon（arm64）；官方 DMG 缓存 `.tooling/engine-artifacts/oMLX-0.7.0-macos26-27.dmg`（830879938 B，SHA-256 `2e3bb06a…e3bce0`，与 `OmlxEngine.dmgDigest` 一致）
- 真实模型资产：`/private/var/folders/…/gmd-real-mlx-r42-p0rh2W/mlx-community/Qwen2.5-0.5B-Instruct-4bit/`（9 文件；权重 `model.safetensors` SHA-256 `ddffab9c…26d153`，验收前后复验一致）
- 驱动与证据（`.tooling/` 被 .gitignore 排除，按 r62 先例不入库）：
  - `.tooling/gmd_omlx_pool_native_driver_r66.dart`：生产路径驱动（`OmlxEngine.install` → `ModelLibrary.scan/verify` → 冷请求栅栏 → `startRuntime`），进程 IO 全程记录 → `.tooling/gmd_r66_pool_native_evidence.json`（3381 条进程调用记录，exit code / 耗时 / argv 哈希；凭据只记 SHA-256）
  - `.tooling/gmd_r66_admin_shape_probe.dart`：漂移点线缆形态探针 → `.tooling/gmd_r66_admin_shape_probe.json`
  - `.tooling/gmd_r66_wire_probe.dart`：全链路线缆级原生验证（15 项检查）→ `.tooling/gmd_r66_wire_probe.json`
  - 探针以引擎冻结 argv（`serve --model-dir <root> --host 127.0.0.1 --port <owned> --base-path <owned> --no-hf-cache`，env 仅 PATH/HOME/LC_ALL）与引擎同款 settings.json（0600，schema version "1.0"）启动自有 serve 进程，复用生产安装出的 bundle。

## 总结论

**M3b 生产代码路径 FAIL（被真实服务线缆漂移阻断），但阻断点之后的全部验收目标已在线缆级原生验证中实测通过。**

- 生产路径 9 项检查：8 PASS，1 FAIL（`fallback.readback`，见漂移 D1）。
- 线缆级原生验证 15 项检查：14 PASS，1 项为如实记录的行为发现（漂移 D2，非脚本缺陷）。
- 没有任何凭据进入证据/日志/文档（仅 SHA-256 哈希）；未改源码；无残留进程；安装与权重处置符合预期。

## 判据逐项

| # | 判据 | 结果 | 证据 |
|---|------|------|------|
| 1 | 生产安装：`OmlxEngine.install` 对缓存 DMG 全新安装到自有验收根（0700），receipt 校验 | **PASS** | 驱动 evidence `install.root/install.state/install.files/install.refresh`；安装总耗时约 353 s（codesign 13.7 s、spctl 6.5 s、ditto 22.0 s 等 3381 条记录在案）；`refreshInstallation()` 复扫 receipt 通过；0.7.0/build 2987/python 3.11.10/arm64 严校成立 |
| 2 | 池启动：冻结 argv、settings.json 0600、health→healthy | **部分 PASS**：argv 冻结形态与 settings 0600 在线缆探针实测成立；health 200 healthy 成立。生产路径在 `_spawnPool` 内启动 serve 成功、login 成功后于 `_enforceFallback` 中止（D1），引擎随后回收子进程，无残留 | 驱动 evidence `pool.spawned/pool.healthy/pool.settings`；探针 `health.transition` PASS、settings mode `rw-------` |
| 3 | 鉴权负样本：无凭据 /v1→401、错 Bearer→401、无 cookie /admin→401、错 api_key login→401 | **PASS**（真实服务，线缆级） | 探针 `auth.noCredential/auth.wrongBearer/auth.noCookie/auth.wrongLogin` 全部 401；正确 api_key login 200 + `omlx_admin_session` cookie |
| 4 | 启用+加载：pin、model_fallback=false 嵌套读回、物理 load、状态行核对 | **线缆级 PASS / 生产路径未到达**。`model_fallback:false` 经 POST 应用且 GET 读回 `model.model_fallback==false`；PUT pin 200 且响应 `settings.is_pinned==true`（与引擎 `_pin` 读回形态兼容）；POST `/v1/models/{id}/load` 200，842 ms 物理加载；状态行 `id/model_path(canonical)==loaded=true/is_loading=false/pinned=true` 逐项相符 | 探针 `fallback.applied/pin.exchange/load.physical/status.row` |
| 5 | 真实推理：非流式 + SSE + 流中取消 | **PASS**（真实服务、真实权重、真实 token） | 见下方实测数据 |
| 6 | 冷拒绝 | **引擎侧 PASS / 服务侧发现漂移 D2**。生产引擎 admission 栅栏在运行前拒绝请求（`OmlxRequestException(kind: notReady, '未知 oMLX 实例')`，0 次转发）。但真实服务在 unload 后收到 `/v1/chat/completions` 返回 200 并**重新按需加载**该模型（status 复核 loaded=true）——`model_fallback=false` 不阻止按需加载，冷拒绝只能由引擎栅栏保证 | 驱动 evidence `cold.preStart`；探针 `cold.afterUnload`（记为 FAIL 以标记行为差异，实为发现） |
| 7 | 停止：unload、进程退出、端口释放、PID 消失、资产保留 | **PASS**（线缆级；引擎 `stop`/`stopManaged` 因 D1 未到达）。POST unload 200 且 loaded=false；SIGTERM 后进程真实退出（exitCode=-15，<20 s，无 SIGKILL 兜底需要）；端口可重新绑定；PID 消失；权重 SHA-256 前后一致 | 探针 `unload.physical/teardown.process/teardown.assets` |
| 8 | 如实记录漂移 | 见下节 | — |

## 漂移发现（对 r49 契约 / M3a 替身层）

### D1（阻断性）：`POST /admin/api/global-settings` 响应无顶层 `model` 回显

- 契约/引擎期望（`lib/omlx_engine.dart:1689` `_enforceFallback`）：POST 响应含 `{"model":{"model_fallback":false}}`，否则抛「oMLX model_fallback 读回失败」并中止 `startRuntime`。
- 真实 oMLX 0.7.0：POST 返回 `200 {"success":true,"message":"Settings saved successfully.","runtime_applied":["model_fallback"]}`，无 `model` 键；**设置实际生效**（随后 GET `/admin/api/global-settings` 返回 `model.model_fallback==false`）。
- 后果：真实服务下 `OmlxEngine.startRuntime` 必然在池启动阶段失败（`_spawnPool` catch → SIGKILL 子进程 → 抛异常）。M3a 替身层按契约回显 `model`，故单测全绿而原生首跑即断。
- 修复方向（不在本验收内执行，属新 bug 票）：POST 后改为 GET `/admin/api/global-settings` 读回 `model.model_fallback`（真实线缆已验证该 GET 形态可用）；`_pin` 无需改——真实 PUT 响应含 `settings.is_pinned`（探针 `pin.exchange` 已证兼容）。

### D2（行为性）：`model_fallback=false` 下服务仍按需加载已注册模型

- 预期（r49 §8「冷请求不触发加载」）：停用/未加载模型的公开请求应被拒。
- 实测：unload 后 `POST /v1/chat/completions`（有效 Bearer）返回 200 且模型被重新加载（status loaded=true）。`model_fallback` 语义是「找不到模型时是否回退其他模型」，不是「禁止按需加载」。
- 影响：GhostModelDeck 的冷拒绝保证只能来自引擎 admission 栅栏（已实测有效）；服务层不提供该保证。验收判据 6 的「原生侧保持未加载」在服务直发场景不成立，引擎路径下由栅栏拦截、不转发，仍然成立。

## 实测数据（线缆探针，真实 Qwen2.5-0.5B-Instruct-4bit）

- 物理加载：842 ms（POST load 200 → status loaded=true 单跳确认）。
- 非流式 `POST /v1/chat/completions`（max_tokens=64，temperature=0）：1628 ms；`finish_reason=length`；`usage={prompt 35, completion 64, total 99, prompt_eval 1.13 s/31.04 tok/s, generation 0.15 s/428.42 tok/s}`；正文为真实中文生成（黄山简介）。
- SSE（`stream:true` + `stream_options.include_usage`）：166 ms；3 个增量 data 帧（文本与非流式一致）→ finish 帧（`finish_reason=length`）→ usage 帧（35/64/99）→ `data: [DONE]`；无伪造终止。
- 流中取消（max_tokens=512）：收到第 1 个真实增量帧后客户端中止连接；未收到 `[DONE]`、未伪造终帧；服务端存活且模型保持 loaded（取消后 status 复核 loaded=true）。
- 冷请求（unload 后）：200 + 重新加载（漂移 D2 的实测记录）。
- 停止：SIGTERM → exitCode=-15（信号退出，未用 SIGKILL），端口释放、PID 消失、`ps` 无残留 omlx 进程；权重 SHA-256 `ddffab9c…26d153` 前后一致。

## 未证事项（如实记录）

1. **生产代码路径下的判据 4–7**（经 `OmlxEngine.startRuntime` 的 pin/load/推理/SSE/取消/stop）：被 D1 阻断，当前源码下不可达。待 D1 修复票落地后需重跑 `.tooling/gmd_omlx_pool_native_driver_r66.dart` 全量 19 项。
2. **两模型 stop 隔离的原生版**：仅一个已验证模型资产在场，不可行；M3a 替身层已覆盖该判据，原生层记为未覆盖。
3. 引擎 `_checkPhysicalRow`/`_probe`/`generateText`/`streamText`/`stop` 的内部断言未在原生环境执行；其下游线缆形态（status 行、chat/completions 非流式与 SSE 帧序列、unload）已逐项实测与引擎解析逻辑兼容，D1 修复后预期可通，但属预期而非实测。
4. `GET /admin/api/global-settings` 响应含 auth 段，证据中一律红action；服务是否自行掩码未评估（管理端点、cookie 保护、仅 loopback）。

## 合规确认

- 未修改任何 tracked 源码/测试；`git status` 收尾干净（`.tooling/` 为 gitignore 目录，证据与驱动按 r62 先例留在工作区）。
- 模型资产只读使用，未移动/改名/覆写；未触碰 `~/.omlx` 或全局服务；杀掉的进程均为本验收自有子进程。
- 未 push、未关票、未动 #16 评论。
