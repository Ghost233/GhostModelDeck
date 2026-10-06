# oMLX SSE keepalive 修复验证（#23，2026-10-06）

## 来源与缺陷

- #16 M3b 重跑段（r67）实测：生产路径 streamText 对真实 oMLX 0.7.0@4d4f5a2 必败——
  `oMLX 流无效：文本流响应无法绑定到所选实例`（lib/omlx_engine.dart ← lib/chat_protocol.dart:118 model 绑定检查）。
- 根因（bundle 源码实证）：oMLX 默认 `sse_keepalive_mode="chunk"`（settings.py:198）；每条流式 chat 无条件先吐 keepalive 帧
  `model:"keepalive"`、空 content delta（server.py:2521–2546 `_chat_keepalive_chunk`，2648–2651 "Send initial keepalive immediately"），
  stall 时每 10s 重复。真实数据帧 model 绑定正确，唯 keepalive 帧不匹配 → 解码器立即抛错。非流式不受影响。
- 潜伏原因：r66 线缆探针不校验帧 model；r66 生产路径因 D1 从未跑到 streamText。

## 修复（19c22a2）

- 方案 (a)（Lead 决策）：引擎自有 settings.json 模板 server 块加 `'sse_keepalive_mode': 'off'`
  （lib/omlx_engine.dart `_spawnPool`；settings.py:245 from_dict 支持，合法值 {chunk,comment,off}）。
- TextStreamDecoder 保持严格逐事件 model 绑定不变（规格不变量），不为 keepalive 帧开口子；冻结 argv 未动。

## 公开 TDD 证据（专用容器 ghostmodeldeck-checks-r33b，原始在线）

- RED run-7764pf：替身按真实行为编码（settings 无 off → 首帧 `model:'keepalive'` 空 delta keepalive）后恰好 2 用例失败
  （streaming 绑定错误 + settings 断言），证明替身冻结了真实形态。
- GREEN run-fNPeT7：test/omlx_pool_test.dart 14/14。
- format run-ymTQUY：63 文件 0 需改（容器内格式化写回经逐文件 diff 核对；首次 analyze run-9n84Lu 因容器格式化写回时差存档旧内容，
  已重跑 run-TZahKM 绑定最终内容，如实记录）。
- analyze run-TZahKM：No issues found。
- 全量 test run-hjzGYP：352/352。

## 独立校验

`.tooling/gmd_verify_final_gates_r58.py run-ymTQUY run-TZahKM run-hjzGYP` → PASS exit0
（.tooling/gmd-final-gate-verification-d3fix.json）：63 Dart 输入当前=GitBlob=三归档，352 全量。

## 边界与未证

- 验收标准 2（r67 原生重跑生产路径 SSE：真实增量+finish+usage+[DONE]）待原生验收代理在新 HEAD 上实测。
- keepalive 关闭后长 stall 流无活跃性帧；请求超时/取消由引擎既有机制承担。
