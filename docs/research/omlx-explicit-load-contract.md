# oMLX 显式加载与 API 就绪路由的可行边界

调查日期：2026-10-05（Asia/Shanghai）。对应 [核实 oMLX 显式加载与 API 就绪路由的可行边界](https://github.com/Ghost233/GhostModelDeck/issues/9)。仅核对官方 `v0.7.0` 固定源码 [4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40](https://github.com/jundot/omlx/commit/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40)；没有安装、下载权重、运行服务或改应用/上游代码。

用户已决定：统一的本机 API；模型由 App 显式启动；API 只调用已就绪模型，不隐式加载；首期提供通用 Chat 与 SSE。本调查不能把这些决定改成按需加载。

## 结论

**原生 oMLX chat 不满足该策略；独立受管后端配合网关可实现这一边界。** 可行条件是 App 控制该进程全部模型生命周期和引擎构造配置，显式启用模型保持 pinned，网关只放行当前进程中已核验就绪的启用集合。若接入任意外部共享 oMLX，其他管理者可在状态检查后卸载或改配置，现有 HTTP 接口没有原子的“只租用已加载模型”操作，严格不隐式加载的承诺仍有阻塞。

这是源码支持的实施推论，尚待真实 Mac 验证；不是已经通过验收的实现。

## 官方源码事实

| 核验点 | 固定版本事实 | 精确证据 |
|---|---|---|
| Chat 加载链 | chat 调用 `get_engine_for_model(..., lease=...)`，再调用模型池 `get_engine`；没有已加载模型时会执行 `_load_engine` | [chat 入口](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L4047)、[包装器](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L1591)、[实际加载](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L2392) |
| 身份/配置切换 | 先解析 alias/profile；允许配置的默认模型 fallback。profile 的构造设置不同可先卸载已加载引擎再加载另一运行变体 | [身份解析与 fallback](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L1376)、[运行变体重载](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L2134) |
| 已加载租用 | loaded 快路径在模型池事件循环上不执行 await，校验引擎并增加 `in_use`；处于 loading、pending unload 或 unloading 时不走该快路径 | [原子快路径](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L2028)。此内部操作不是外部 HTTP 状态检查能取得的租约 |
| LRU/TTL | LRU 跳过 pinned、在途租约及活动请求；TTL 跳过 pinned，未设模型 TTL 时继承全局 idle timeout | [LRU](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L2486)、[TTL](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L4027) |
| pin 的边界 | pin 防止这些自动回收；不能防止管理卸载/设置重载。内存紧急处理仍可能中止 pinned 模型请求，但该分支保留模型 loaded | [内存紧急分支](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/process_memory_enforcer.py#L1817)、[设置变更重载](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/admin/routes.py#L3435) |
| pin 配置 | `PUT /admin/api/models/{model_id}/settings` 支持 `is_pinned`，需 admin 认证，并立即更新池条目；没有证据表明只改 pin 会执行显式 load | [路由与认证](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/admin/routes.py#L2713)、[更新 pin](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/admin/routes.py#L3319) |
| 独立配置 | `--base-path` 可隔离数据；其 `model_settings.json` 存各模型设置，启动时读取 pinned 集合并预加载 | [CLI](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/cli.py#L1338)、[文件位置](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/model_settings.py#L597)、[启动读取](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L2245)、[预加载](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L624) |
| 状态与管理 | 模型状态有 `id/model_path/loaded/is_loading/pinned`；公开 `/v1/models/{id}/load` 等待加载，但卸载直接停止引擎。admin 卸载另走 pending/abort 流程，接口语义不同 | [状态字段](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/engine_pool.py#L3933)、[公开 load/unload](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L3463)、[admin 卸载](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/admin/routes.py#L2595) |

`/v1/models/status` 是快照，不暴露每个条目的全部 pending/unloading 条件，也不能阻止读取后开始卸载。`/health` 的启动预加载完成标志在 finally 设置，不能证明每个 pinned 模型都成功加载。[预加载完成逻辑](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/server.py#L624)

## 最小网关策略（实施推论）

1. **受管配置与入口。** 用 App 独立的数据目录和受管进程；公开给客户端的是统一网关。后端地址与管理凭据用于内部通信，不把原生 oMLX API 当成满足本产品策略的入口。App 控制启用模型的 pin、配置变更、刷新和卸载；关闭 `model_fallback`，只映射明确的物理模型 ID，不把任意 alias/profile/default 或上游管理路径透传给客户端。全局 fallback 默认 false，但仍应核验自己的配置。[默认配置](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/settings.py#L261)
2. **启动。** App 显式启用操作设置 pin 并调用公开 load，或在 App 明确启动进程前写入仅对应启用集合的独立 pinned 配置。等待并核验目标 `id/model_path/loaded=true/is_loading=false/pinned=true`，以及当前进程身份，才建立 Ready 状态。不要把启动时自动预加载已有配置当作客户端请求的加载授权；进程重启后 Ready 全部失效并由 App 重新确认。
3. **入场。** 网关按 App 的启用集合、当前进程代次和 Ready 状态拒绝未知、未启用、Loading、Stopping、故障模型。每个接受的 chat 取得 App 的在途许可，持续到非流式响应结束或 SSE 结束/取消；放行前再核验后端状态。发现未加载只撤销 Ready 并拒绝，不用 chat 试探或自动重试来恢复模型。仅“GET status → POST chat”无法代替生命周期协调。
4. **停止/变更。** 与请求入场共享每模型生命周期协调：先撤销 Ready、停止接受新请求，再等待已有请求结束或按 App 已定义的取消策略取消；之后才调用卸载或变更引擎配置。卸载完成后核验 loaded=false。SSE 客户端断开必须使上游请求取消、最终释放在途许可。不能在流仍运行时直接调用公开 unload 然后声称它保证优雅排空。

在上述所有者边界内，pin 防止普通 LRU/TTL 在状态检查和 chat 租用之间回收目标，App 协调阻止自己的并发卸载，固定物理 ID/配置阻止 chat 触发 profile 重载。出现后端退出、内存拒绝等故障时网关返回失败并关闭就绪入口，不能隐藏故障后重新请求而触发加载。

**未满足的边界：** 任意共享/接入实例可被外部管理者卸载、取消 pin、刷新模型或修改构造配置；网关无法用当前公开 HTTP 接口原子约束这些操作。若该类实例也必须具有同样严格保证，需要先解决外部生命周期协调或上游 loaded-only 协议，不能靠增加轮询次数承诺成功。pin 也不是保证推理永远成功的内存预留。

## 最小验收（未执行）

- 已发现但未启用/未加载模型请求被网关拒绝，后端状态和日志证明没有 `_load_engine`；App 显式启用后 Chat 与 SSE 均成功。错误 ID 不落到默认模型，profile 请求不引起引擎切换。
- TTL/另一模型加载造成的压力下，启用模型保持 pinned；内存拒绝/紧急中止被作为失败返回，不自动重载或换模型。
- 并发 chat/SSE 与停止、设置变更、客户端断开：入口关闭、请求排空/取消、卸载结果及许可回收一致；后端崩溃/重启不得沿用旧 Ready。
- 留存实际版本、配置、原始 HTTP/SSE、加载/卸载日志和状态快照。原生状态与管理调用的超时、认证、内存回收耗时，以及这些协调策略在真实 Mac 上的行为仍未验证。
