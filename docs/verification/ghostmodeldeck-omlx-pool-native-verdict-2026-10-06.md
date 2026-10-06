# oMLX 池层原生终裁（M3b / r66+r67+r68）

日期：2026-10-06。执行：独立原生验收代理（线缆驱动+生产路径驱动），Lead 独立复核终裁。本文件汇总 M3b 全部原生证据与裁决。

## 总体裁决：**PASS**

生产路径完整链（install→receipt→refresh→library.scan→startRuntime→pin/fallback→物理加载→非流式/SSE/取消推理→stop→stopManaged 回收→证据卫生）在固定 HEAD `e6b9d21ea657e8dccd8148b4f7d4adcab1ef87a9` 上原生实测 **26/26 全 PASS、0 FAIL**（r68b attempt#7，20:47:54 完成，`.tooling/gmd_r68b_driver_attempt7.log`，Lead 逐行复核）。

## 范围收缩声明（用户直接指令）

2026-10-06 20:50 用户指令：「omlx不要加载模型,模型都太大了,跳过这个步骤」。关键时序：r68b attempt#7 的 26/26 全 PASS 完成于 **20:47:54，先于该指令**，全部原生推理证据合法有效。指令生效后未再安排任何原生加载/推理；r68 后续重试（attempt8）与 r67 run2 的孤儿进程已全部终止清理，不影响既有结论。

## 判据裁决总表（#16 M3 原生验收）

| 判据 | 结果 | 证据 |
| --- | --- | --- |
| a 完整安装链（install→receipt→refresh） | PASS | r66（fcb3163）、r63（202f8f2）、attempt7 install.* |
| b 权限归一化（0700/0600/去全局写） | PASS | r63（202f8f2，30/30 抽查+全量 sweep 0 残留）+ attempt7 pool.settings |
| c 签名/公证（chmod 后独立复核） | PASS | r63（202f8f2） |
| d 池启动+鉴权+pin/fallback+加载+推理（非流式/SSE/取消） | PASS | **attempt7 26/26**（pool.ready 生产 startRuntime 全链；infer.text/sse/sseWire/cancel 全过） |
| e stopManaged 清理（SIGTERM/端口/PID/权重不变/资产保留） | PASS | attempt7 stop.* + r66（fcb3163） |
| f 损坏 DMG fail-closed | PASS | r62/r63（202f8f2，0 原生事件） |
| g 证据卫生（凭据不入证据） | PASS | attempt7 evidence.hygiene + 全套模式扫描零命中 |

### attempt7 关键实测项（HEAD e6b9d21，生产路径）

- `pool.ready`：startRuntime 生产全链（pin+fallback+加载+状态行+身份探针）通过——D1 修复（6f7f8d4）端到端生效。
- `pool.settings`：真实 settings.json 0600/schema 1.0/fallback false/**sse_keepalive_mode off**（D3 修复 19c22a2 在真实服务落地）。
- `pool.argv`/`pool.singleLaunch`/`pool.process`：argv 冻结形态、单实例、进程标题重写后仍正确识别、端口私有。
- `auth.negatives`：401 ×4。
- `infer.text`：非流式真实推理 finish/usage。
- `infer.sse`：真实增量帧，终止事件仅在 [DONE] 后，真实 finish/usage。
- `infer.sseWire`：**线缆级逐帧审计——每帧 model 绑定所选模型、零 keepalive 帧（D3 修复生产路径实证）**、finish+usage+[DONE] 齐全。
- `infer.cancel`：流中取消真实生效，无伪造终止帧。
- `stop.unload`/`cold.postStop`/`stop.recycle`/`stop.assetsKept`/`weights.preserved`：卸载、冷拒栅栏、SIGTERM exit -15 无 SIGKILL 兜底、端口释放、资产与 9 个权重文件 SHA 前后一致。
- `evidence.hygiene`：证据无原始凭据。

### 并发事故与证据完整性（如实记录）

多代理并发执行期间发生事故：attempt#7 的证据 JSON（`.tooling/gmd_r68_pool_native_evidence.json`）于 20:48:32 被另一运行器的失败证据覆盖销毁，**26/26 的序列化证据实体不存**；幸存记录为 attempt7 驱动日志（27 行，26 PASS/0 FAIL 逐条在案）与 r67 段独立证据（见下）。此后双方停止并发，未再重跑（用户指令）。结论依赖：驱动日志完整性 + r66/r67 独立证据交叉印证 + r63 安装链 PASS。另：r68 执行者误 detach 过 r67 run2 的活动 DMG 挂载，双方均已确认无持续损害。

### r67 段独立证据（HEAD 7f845c7，D1 修复后/D3 修复前）

- `gmd_r67_pool_native_evidence_run1.json`：run1 15/18 PASS（2 FAIL 为驱动脚本自身缺陷已修补；1 FAIL = D3）。startRuntime 7874ms 全链 PASS、非流式 685ms/64tok/finish=length 真实中文生成。
- `gmd_r67_sse_probe.json`（default 模式）：首帧 model:"keepalive"、bindingFailureCount=1——D3 抓在案。
- `gmd_r67_sse_probe_ka-off.json`（off 模式）：6 帧全绑定、finish=length、usage 39/16、[DONE]、bindingFailureCount=0——修复机制实证。
- `gmd_r67_d3_decoder_proof.out`：解码器单元级证明。

## 缺陷链与修复绑定

| 缺陷 | 票 | 修复提交 | 原生验证 |
| --- | --- | --- | --- |
| A 所有权批扫误判 / B 安装校验 / C 刷新目录边界 | #20 | 7f6d9af | r63 PASS（202f8f2） |
| D 身份探针 `md.version('omlx')` 无 dist-info | #21 | 6e897eb（`omlx.__version__`） | r63 PASS + attempt7 |
| D1 POST global-settings 无 model 回显 | #22 | 6f7f8d4（success+runtime_applied+GET 读回） | r67 run1 + attempt7 pool.ready PASS |
| D2 fallback=false 不禁止按需加载 | 行为记录（fcb3163） | 无需修复：冷拒绝由引擎 admission 栅栏承担 | attempt7 cold.preStart/cold.postStop PASS |
| D3 SSE keepalive 首帧（model:"keepalive"） | #23 | 19c22a2（settings 模板 sse_keepalive_mode:'off'） | attempt7 infer.sse/sseWire PASS（零 keepalive 帧）+ ka-off 探针 |

## 证据清单（gitignored .tooling/，凭据仅记 SHA-256）

- r66：`gmd_r66_pool_native_evidence.json` / `gmd_r66_wire_probe.json` / `gmd_r66_admin_shape_probe.json`（fcb3163）
- r67：上述 4 文件
- r68b：`.tooling/gmd_r68b_driver_attempt7.log`（26/26 幸存记录）；attempt1 安装链证据 `gmd_r68_pool_native_evidence.json` 已被并发覆盖，现存内容为失败运行残留（如实标注）
- 事后擦除记录：`gmd_r66_admin_shape_probe.json` api_key → `SHA256:b972127629acea3e(scrubbed-post-hoc)`；失效代际 admin cookie → `SHA256:6518555e1b5b(scrubbed-post-hoc)`。全套 r66/r67/r68 证据模式扫描（JWT/k-|s-48hex/Bearer/cookie）零命中。

## 环境备注

- 用户进程 splash serve-native（pid 51745，RSS≈26GB）全程在场未触碰；其内存压力曾致 r68b attempt1–6 的 infer.* prefill 400（非引擎缺陷），attempt7 在内存窗口（free 83%）内完成。
- 模型权重 SHA-256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153` 全程前后复验一致（attempt7 weights.preserved）。

## 未证事项（如实记录）

- HTTPS 下载路由（全程使用缓存官方 DMG）。
- 已安装重试与移除路径。
