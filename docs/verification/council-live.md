# 两席委员会成功路径验收

2026-10-05。正式 `CouncilController` 与桌面 `CouncilPage` 共用入口；没有在原生脚本另写一套综合算法。

容器全库 85 项通过（run-WJqasQ），分析无问题（run-WYPFEB）。公共入口先 RED 后 GREEN，真实 ModelLibrary/Catalog/LlamaEngine，替身只位于外部 process/loopback HTTP：两个请求都到达后才释放响应，证明并发派发；给定 0.75/0.25 与 0.25/0.75 得到 0.5/0.5，保留全部并列、votes 1/1 和分歧 0.5。候选重排、配置变更时的不可变快照、完整元数据与页面操作均有行为证据。

## 真实调用

`.tooling/implementation/live-council.dart` 读取用户已保存目录，对两份固定权重完整核验，通过正式 b11381 管理入口启动并取得 ready，配置两席，再调用正式 `consult`。没有咨询时临时加载或替换另一实例。

实际 request_id：`ee3b3089ff0ddcd5fcd4842fcc98d512`，status=ok，scope=ensemble。英文合成规则案例为“确认重复扣款，规则要求退款”，候选 ID 为 refund/investigate。

| 席位 | 固定资产 revision | 原始 refund | 原始 investigate | 派发相对时间 | 完成相对时间 |
| --- | --- | ---: | ---: | ---: | ---: |
| Kev Q8，PID 62994 | e551e319d483ff57e1ff208924b349d397cffc1c | 0.9904589808039479 | 0.009541019196052226 | 124 µs | 57970 µs |
| Laya Q8，PID 63007 | da4b4753d62197659d8c90103cd4c43bef9afea6 | 0.9362442233096444 | 0.06375577669035551 | 360 µs | 40443 µs |

两席派发均先于最早完成。综合 refund=0.9633516020567962，investigate=0.03664839794320387；最高项 refund，票数 2/0，分歧 0。原始 response 的 model alias 分别对应各自真实实例，输入 49/50 token、生成输出 0。

整轮实际 58560 µs；这是一次预热英文功能探测，不称延迟基准、中文质量、校准正确率或委员会收益，也不因请求并发承诺 GPU 同时执行。

完整原始结果、模型完整 SHA、引擎信息与时序在 `.tooling/implementation/live-council.jsonl`。脚本退出 0，两个实例通过持有句柄的正式管理入口停止，状态 stopped；模型大小与修改时间前后相同。

## 后续范围

整轮默认 10 秒、取消、晚到隔离、无效输出和部分失败由 #17 补齐；本次不以全成功窄验收宣称这些行为完成。真实 Codex MCP、退出生命周期与中文表现仍须后续验收。
