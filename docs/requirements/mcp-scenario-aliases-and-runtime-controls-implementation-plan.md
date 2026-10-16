# 场景配置与实例运行控制实现工单

2026-10-16。用户已批准 9 个垂直切片及依赖关系，已使用 Ghost233 发布并回读核对。

父规格：[场景配置、表格管理与实例运行控制规格 #102](https://github.com/Ghost233/GhostModelDeck/issues/102)。

发布时 9 个子工单均为 OPEN，分类仅为 ready-for-agent。每张已设原生父子关系，阻塞使用 GitHub 原生依赖；发布时未改变父工单正文、标题、状态或标签。当前实施进度统一见 [交付记录](../verification/scenario-runtime-controls-delivery.md)。

| 草案编号 | 规范工单 | 被什么阻塞 | 父规格验收覆盖 |
| --- | --- | --- | --- |
| 01 | [配置四个场景并通过统一模型名字调用实例 #103](https://github.com/Ghost233/GhostModelDeck/issues/103) | 无，可立即开始 | A01、A02、A03、A04、A06、A07 |
| 02 | [将场景绑定委员会并发布稳定的最小上下文 #104](https://github.com/Ghost233/GhostModelDeck/issues/104) | [配置四个场景并通过统一模型名字调用实例 #103](https://github.com/Ghost233/GhostModelDeck/issues/103) | A02、A03、A04、A05、A06、A07、A08 |
| 03 | [预览参数影响并在实例重启后更新关联容量 #105](https://github.com/Ghost233/GhostModelDeck/issues/105) | [将场景绑定委员会并发布稳定的最小上下文 #104](https://github.com/Ghost233/GhostModelDeck/issues/104) | A08、A09 |
| 04 | [用表格查询和操作模型引擎与实例 #106](https://github.com/Ghost233/GhostModelDeck/issues/106) | 无，可立即开始 | A10、A11 |
| 05 | [以两行格子显示实例并发阶段和排队 #107](https://github.com/Ghost233/GhostModelDeck/issues/107) | 无，可立即开始 | A12、A13、A14、A16 |
| 06 | [显示实例最近一分钟平均速度并隔离运行代次 #108](https://github.com/Ghost233/GhostModelDeck/issues/108) | 无，可立即开始 | A14、A15、A16 |
| 07 | [通过总开关取消全部实例工作并释放受管资源 #109](https://github.com/Ghost233/GhostModelDeck/issues/109) | 无，可立即开始 | A17、A18、A21 |
| 08 | [保存独立自启动设置并并发启动所选实例 #110](https://github.com/Ghost233/GhostModelDeck/issues/110) | [通过总开关取消全部实例工作并释放受管资源 #109](https://github.com/Ghost233/GhostModelDeck/issues/109) | A19、A20、A21 |
| 09 | [完成 macOS arm64 集成和原生短流程验收 #111](https://github.com/Ghost233/GhostModelDeck/issues/111) | [预览参数影响并在实例重启后更新关联容量 #105](https://github.com/Ghost233/GhostModelDeck/issues/105)、[用表格查询和操作模型引擎与实例 #106](https://github.com/Ghost233/GhostModelDeck/issues/106)、[以两行格子显示实例并发阶段和排队 #107](https://github.com/Ghost233/GhostModelDeck/issues/107)、[显示实例最近一分钟平均速度并隔离运行代次 #108](https://github.com/Ghost233/GhostModelDeck/issues/108)、[保存独立自启动设置并并发启动所选实例 #110](https://github.com/Ghost233/GhostModelDeck/issues/110) | A22 |

当前没有阻塞的工单为 [配置四个场景并通过统一模型名字调用实例 #103](https://github.com/Ghost233/GhostModelDeck/issues/103)、[用表格查询和操作模型引擎与实例 #106](https://github.com/Ghost233/GhostModelDeck/issues/106)、[以两行格子显示实例并发阶段和排队 #107](https://github.com/Ghost233/GhostModelDeck/issues/107)、[显示实例最近一分钟平均速度并隔离运行代次 #108](https://github.com/Ghost233/GhostModelDeck/issues/108)、[通过总开关取消全部实例工作并释放受管资源 #109](https://github.com/Ghost233/GhostModelDeck/issues/109)。

最终集成只直接依赖 03、04、05、06、08。01、02 经 03 传递覆盖，07 经 08 传递覆盖，不增加冗余边。两行监控和一分钟指标各自可通过现有界面交付，不互设硬阻塞。

没有需要单列的大范围预重构。后续仍由主线程推进，不启动子代理；独立工单表示产品依赖就绪，不改变执行约束。

保留前一轮 Splash 自动准备、draft 修复、删除未关联启动配置及其他会话改动。小修复定点检查，代码收齐后集中门禁；不重复跑未受影响的成功题集。

本索引保留工单发布时的依赖与覆盖关系。后续阶段、候选、检查、PR 及剩余工作仅在交付记录维护，不以本索引的发布快照作为完成证据。
