# 引擎来源与实例管理交付记录

## 唯一当前状态

2026-10-13。规格为 [产品职责与实例管理](../requirements/product-scope-and-launch-instances-spec.md)，来源 #82–#96，包含用户补充的默认 60 秒 JEV 请求预算。主线程推进，没有子代理、容器或正式发布。

| 项目 | 当前状态 |
| --- | --- |
| 候选 | 阶段 D 分支 `codex/product-instances-stage-4`，起点 `58f452b4546acf186a86dc4315b335bb9b1d4134`，代码已收齐、待提交 |
| 有效作业 | 无；最终 `run-uCS7B1` 已结束，960 项、格式与分析全部通过，退出 0、完成标记有效、716 份输入前后及当前一致 |
| 未关闭问题 | 无已知产品 P0/P1/P2；剩余固定提交复审、阶段 PR/dev 集成和总 PR ready |
| 下一动作 | 提交固定候选并分别复审 Standards/Spec，阶段 PR 合入 dev，再完成总审查及 dev→main ready PR |
| 原生产物 | `stage-d-root-final-macos-build.log` 退出 0；应用、FlutterMacOS、App.framework 实际均 arm64；后续仅根路由 lint 原因注释和测试/文档变更，运行行为未变，原生产物复用 |
| 服务 | Kev 唯一运行，保存预算 60 秒、原模型/引擎/CLI；恢复身份 app26711/engine42511/native56352/public54841 已通知 Wiki 继续开发 |

## 当前工作分类

- **未实现：** 无本次规格的剩余产品功能。
- **未验证：** 固定提交复审、总提交范围与跨阶段审查、最终 PR 状态及本地/远端同步。
- **已验证待提交：** 阶段 D 新对象、预算和根路由修复，完整门禁及原生记录均已收齐；A/B/C 已提交并集成，不列为待办。
- **历史问题：** 字形损坏尚无本轮复现或根因结论；此次黑屏已精确复现为重复下拉激活弹出桌面根路由并释放服务，定点和原生修复通过，不扩展为所有旧图形事件已修复。

## 已完成阶段

| 阶段 | 验证 | 集成 |
| --- | --- | --- |
| A #83–#86 | `run-70BRLY` 925 项；多目录/文件链接/非阻塞安装与源码构建真实证据 | [PR #97](https://github.com/Ghost233/GhostModelDeck/pull/97) 已合入 dev；[复审](product-scope-stage-a-review.md) |
| B #87–#89 | `run-dDSmSQ` 935 项；保存快照/公开名/实际启动停止及短 HTTP | [PR #98](https://github.com/Ghost233/GhostModelDeck/pull/98) 已合入 dev；[复审](product-scope-stage-b-review.md) |
| C #90–#94 | `run-AGOOpq` 954 项；Splash/oMLX、失效资源、草稿隔离、委员会及文件入口真实证据 | [PR #99](https://github.com/Ghost233/GhostModelDeck/pull/99) 已合入 dev `58f452b4546acf186a86dc4315b335bb9b1d4134`；[复审](product-scope-stage-c-review.md) |
| D #95/#96 | `run-uCS7B1` 960 项；公开新对象、完整计划/取消/历史、默认及显式预算、原生对象选择 | 待固定提交复审及阶段 PR；[审查记录](product-scope-stage-d-review.md) |

## 阶段 D 验证与限制

- 保存实例的公开对象查询与评测锁统一接线，冷实例不自动加载。实际运行的资产/引擎/启动修订用于身份；下一次重绑不改当前已运行选择，停止后原选择失效。
- 普通 HTTP/MCP 的保存实例和委员会、完整 400 题计划、整批取消及历史持久化由应用图和外部引擎 I/O 夹具验证。五项完整题集、Jevman 100 局及已有调度/评分/报告没有重开发，不要求每模型真实跑题集。
- 用户补充的 JEV 默认预算为 60 秒；实例显式预算持久化、复制和改名保持，两种公开通道读同一值。实际 60 秒超时、取消及清理 `run-qjYlIK`，UI 保存 `run-rjtZPi`，125 项模块 `run-F6ScQ7` 通过。Jevman 固定 2 秒决策/30 秒 warmup 保持；其他能力和引擎探测期限不在该补充范围。
- 黑屏原生现场、系统日志及短栈保留。最小复现 `run-0rbcly` → 根路由保护 `run-j4UMXZ`；52 项回归 `run-xVzztG` 通过。根路由的局部 must_call_super 例外已说明：拒绝完成根路由与基类完成方法冲突。用户直接确认重复选择后窗口正常，AX 核对选中 Kev 及根页面保留；工具点击失效另记，不算应用失败。
- `run-gZVV07` 原完整失败保留：956 通过、4 失败、退出 1。生产布局夹具改为使用真实路由工厂，委员会/客户端断言按新默认值更新；字体、可点击、资源及精确时限断言全部保留。`run-VHqGnj` 四个原失败、`run-p2o9Le` 三个模块 79 项通过后，最终 `run-uCS7B1` 全部通过。测试/文档修正没有重复构建或重启模型。

证据位于 `.scratch/product-scope-20261012/`；门禁详细输入/命令/退出/完成判定在 `.tooling/host-tests/`。原生收据为 `stage-d-final-native-receipt.json`；预算实际生效为 `stage-d-budget-native/record.json` 和原始 `response.json`。

## 服务交接

已获用户授权向「设计标准化 Wiki 构建流程」回复与恢复通知，并核对该会话的直接用户授权。Kev 使用精确 GGUF SHA `33ae6b18926502b2209a1bf7d3b61a350d65938441515c686bb87d226a19eff9`、保存 ID `instance-1791853429727769-2217734541`、公开号 `kev-4b-q4-k-m`、b11381；原 ctx65536/batch4096/ubatch4096/parallel1/GPU99/MTL0/reasoning off 保持。

GUI 已保存 `jev_request_timeout_seconds=60` / revision2，唯一最小公开 HTTP 返回 200、实际 `timeout_us=60000000`、0.188 秒。已通知 Wiki 继续开发，不自动撤销其业务测试暂停。StartLux 保存配置在本轮前已不存在，按当前配置保留，不自动重建。此前 StartLux 原生 501、代表请求非精确重放及 Wiki 业务失败均是独立历史，不作为产品成绩前置。

## 交付约束

只编译、打包和提供 macOS arm64。固定 Flutter/Dart SDK、原 lockfile、联网解析及宿主检查；字体与布局断言保持。主线程、同作业一份、长作业 sleep 300 后收取。保留其他会话修改，不正式发布。

阶段 PR 合入 dev，最终 dev→main 总 PR 保持 ready，等待用户合并。最终核对所有涉及本地及远端完整 hash，不将远端更新单独算完成。完整 JSON 使用文件路径和 Finder，UI 分批展示摘要；原生题目、固定 submodule、五项完整基准、100 局和无快速试跑保持。

阶段 D 过程历史见 [快照](archive/product-scope-stage-d-progress-history.md)，此前过程见 [历史记录](archive/engine-sources-and-installation-2026-10-12-progress-history.md)，不将历史旧状态当作当前待办。
