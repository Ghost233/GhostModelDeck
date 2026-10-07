# #33 阶段审查修复与复盘

阶段固定点：`888b41490ccc303dee62fbadea564c4ffd1aed60`。首轮审查候选：`21f8cfb3c156b4753a6b5baec0d3cec8fe1c6817`。来源为 [命名 JEV 模型路由与标准结果工单](https://github.com/Ghost233/GhostModelDeck/issues/33)。最终门禁的源码清单、命令、退出码和后续复审证据见 [阶段验证记录](ghostmodeldeck-named-jev-model-routing-r33.md) 与阶段 PR。

## 首轮审查修复

Standards 轴按原顺序发现两项 P2：原生正常结果返回前的取消窗口；配置持久化没有纳入退出排空。Spec 轴按原顺序发现两项 P2：编辑器静默丢失已移除的绑定；相同的原生取消窗口。两轴保持独立，共三个实际缺陷。

| 缺陷 | 公开边界验证与修复 |
| --- | --- |
| 原生结果通知期间取消 | `engine.changes` 的结果通知取消本次 token。原始红 `run-H5VFhz`；首个检查点修复仍失败 `run-s3LhuV`；完成边界复核后 `run-yAGgMM` 退出 0，相关文件 `run-zZ4P15` 28 项通过。 |
| 持久化退出排空 | 仅替换文件 I/O，以公开保存、删除、恢复、shutdown、close 驱动真实登记队列。红 `run-OBQITw` → 绿 `run-cqaDFs`；`run-YlPp6G` 四项验证等待已接纳写入/删除/恢复、拒绝新修改及错误传播，退出 0。异步关闭调用方同步适配。 |
| 编辑时保留不可用成员 | 真实模型库删除已保存成员后，编辑器保留并显示该绑定；改名/预算明确拒绝，原磁盘配置保留；显式移除后才保存。红 `run-pmAmye` → 绿 `run-hB0n0w`；原文件回归 `run-gVRNE7` 通过。清理接口适配后重新执行 `run-CeaNGC`，两项通过，退出 0。 |

七个受影响测试文件的 `run-Jgu8VU` 为 39 项通过、退出 0。随后变化的页面清理输入由 `run-CeaNGC` 单独覆盖；旧页面绿不代替新输入验证。这些是应用业务与外部 I/O 替身证据，真实模型和客户端验收属于后续 #37。

## Retro 发现与处理

复盘读取本阶段真实失败日志、检查入口、CI 和 hook 状态；只修本次交付相关 P0/P1/P2。

1. **P2：未校验的作业上传能产生假成功。** 现有脚本校验源码归档，但直接发布 `job.sh`；已记录的零字节拷贝故障会让空脚本退出 0。外部 Docker 传输故障用例在旧脚本取得内部退出 0 与空日志，未执行检查。修复把 bootstrap、源码和作业先上传到临时文件，核对 SHA-256 后再发布最终文件名；校验失败记录原错误并清理暂存文件。相同故障用例现在内部退出 1，明确 `Upload verification failed`，没有发布或执行作业，暂存已清理。该故障用例是脚本回归，不能作为产品门禁通过。
2. **P2：桌面启动保护漏掉已安装实例。** 实际 `/Applications/GhostModelDeck.app` 正在运行，旧脚本仍尝试外部 Flutter 构建调用；受控 Flutter 替身退出 73，未实际构建或打开应用。修复匹配任意 GhostModelDeck.app 的真实可执行路径；相同实际进程条件下现在退出 1，显示 Cmd+Q 提示，未尝试构建。干跑没有关闭应用或启动模型。
3. **P3 后续候选：接入 PR 自动门禁。** 当前只有 Release workflow，既无 PR format/analyze/test job，也无活动 pre-commit/pre-push hook（core.hooksPath 未设置）。已有 tag 时 Release 可跳过构建。本次采用已要求的最终本地门禁；CI 接入留作后续环境改进。

两个修改的 shell 脚本 `bash -n` 与 `git diff --check` 实际退出 0。真实 Socktainer 作业干跑及完整工程检查记录在上述阶段验证文件。

修复后脚本 SHA-256：

```text
2287146911a50228bf0d7f4036dac5945096c8d4cbd9fc287be1026ad5d9ce34  scripts/test-container.sh
bb368ffb477a027fe248b5d41e24a994f0be18c60227761c1ec7bdf845c8a0e6  scripts/run-desktop.sh
```

故障与干跑 JSON 证据保留在本机 `.tooling/verification/stage33-retro/`，不包含模型或用户配置。结果中的预期退出 1 是保护生效，不是正式格式/分析/测试通过。
