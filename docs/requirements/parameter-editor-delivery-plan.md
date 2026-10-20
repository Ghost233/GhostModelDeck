# 参数编辑需求拆解与完成状态

2026-10-20。父项：[A 方案：实例参数控件、生成默认值与显式草稿模型](https://github.com/Ghost233/GhostModelDeck/issues/118)。用户已批准 13 项垂直切片和 15 条依赖，现已发布并回读核验。复用原有 9 个子工单，新增 4 个；父规格的标题、正文和开放状态保持原样。

本轮实施已接受 [llama.cpp 范围调整](parameter-editor-llama-adjustment.md)：按当前官方 CLI 配置和启动，各模式真实配对不再作为验收门槛。原生决定运行结果，GMD 不再增加草稿活跃状态门槛。

**交付进行中。** 13 个切片的实现和局部回归已整合，真实 Splash、llama.cpp 普通 draft、compact、认证及原生桌面流程已有验证。独立首审及补核共发现 5 项 P2，修复后的最终完整宿主门禁 1155 项全部通过，正式 arm64 构建及原生界面复查通过。已提交候选复审、阶段集成、工单结项及总 PR 交付仍须完成；旧候选的测试结果不代替当前结果。

## 本轮修复与剩余交付

- 响应长度、Top P/Min P 和惩罚均区分继承、关闭和显式数值；关闭映射到原生中性值。未知继承温度不显示虚构滑块位置。
- 加载资源、缓存、ANE、compact 和调度控件已补联动、适用状态与参数帮助；Splash 按所选 CLI 的参数识别，llama.cpp 遵循已确认的官方参数适配范围。
- 两引擎的认证覆盖状态、发现、监控和推理，凭据绑定运行实例并隔离。调试信息在最终展示边界脱敏，保留合法业务字段；原始失败及受影响模块已回归。
- 两份真实 Splash 组合、compact 验证与正常回退、原生文件选择和桌面配置到请求均有证据，见[验证记录](../verification/parameter-editor-a.md)。llama.cpp 各模式真实配对按用户要求免验收。
- 余项为独立审查与复盘、阶段合入 `dev`、工单结项及总 PR ready。本轮不包含正式发布、改版本或替换已安装应用。

## 实施子项与依赖

以下顺序是用户批准的切片编号。GitHub 已建立原生子项和 `blocked_by` 关系；所有子项仍开放，负责人均为 Ghost233。每项的完整验收标准以对应工单为准。

| 编号 | 子项 | 开始前须完成 | 分类 |
| --- | --- | --- | --- |
| 01 | [在 A 面板配置加载资源并验证下次启动生效](https://github.com/Ghost233/GhostModelDeck/issues/119) | 无工单前置依赖 | `ready-for-agent` |
| 02 | [配置 Splash 缓存和服务预算并验证原生结果](https://github.com/Ghost233/GhostModelDeck/issues/128) | 无工单前置依赖 | `ready-for-agent` |
| 03 | [配置 Splash ANE、功耗和编码器并显示适用状态](https://github.com/Ghost233/GhostModelDeck/issues/129) | 无工单前置依赖 | `ready-for-agent` |
| 04 | [保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121) | 无工单前置依赖 | `ready-for-agent` |
| 05 | [用控件启停采样、惩罚和通用优化](https://github.com/Ghost233/GhostModelDeck/issues/120) | [保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121) | `ready-for-agent` |
| 06 | [保存停止条件和 Schema 并通过公开请求使用](https://github.com/Ghost233/GhostModelDeck/issues/130) | 无工单前置依赖 | `ready-for-agent` |
| 07 | [配置思考、模板和 Splash 调度并验证下一次请求](https://github.com/Ghost233/GhostModelDeck/issues/131) | [保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121) | `ready-for-agent` |
| 08 | [启用引擎访问控制后仍能查看状态和推理](https://github.com/Ghost233/GhostModelDeck/issues/126) | 无工单前置依赖 | `ready-for-agent` |
| 09 | [选择原始 Splash 草稿并完成实际短生成](https://github.com/Ghost233/GhostModelDeck/issues/123) | 无工单前置依赖 | `ready-for-agent` |
| 10 | [配置 llama.cpp 草稿模式与路径并遵循原生启动结果](https://github.com/Ghost233/GhostModelDeck/issues/124) | 无工单前置依赖 | `ready-for-agent` |
| 11 | [选择 compact ranking 并核实实际使用或回退](https://github.com/Ghost233/GhostModelDeck/issues/125) | [选择原始 Splash 草稿并完成实际短生成](https://github.com/Ghost233/GhostModelDeck/issues/123) | `ready-for-agent` |
| 12 | [修改运行中实例并保持实际来源与正确生效阶段](https://github.com/Ghost233/GhostModelDeck/issues/122) | [保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121)、[在 A 面板配置加载资源并验证下次启动生效](https://github.com/Ghost233/GhostModelDeck/issues/119)、[选择原始 Splash 草稿并完成实际短生成](https://github.com/Ghost233/GhostModelDeck/issues/123)、[配置 llama.cpp 草稿模式与路径并遵循原生启动结果](https://github.com/Ghost233/GhostModelDeck/issues/124) | `ready-for-agent` |
| 13 | [在原生桌面完成配置、调用与退出并交付最终候选](https://github.com/Ghost233/GhostModelDeck/issues/127) | [用控件启停采样、惩罚和通用优化](https://github.com/Ghost233/GhostModelDeck/issues/120)、[修改运行中实例并保持实际来源与正确生效阶段](https://github.com/Ghost233/GhostModelDeck/issues/122)、[选择 compact ranking 并核实实际使用或回退](https://github.com/Ghost233/GhostModelDeck/issues/125)、[启用引擎访问控制后仍能查看状态和推理](https://github.com/Ghost233/GhostModelDeck/issues/126)、[配置 Splash 缓存和服务预算并验证原生结果](https://github.com/Ghost233/GhostModelDeck/issues/128)、[配置 Splash ANE、功耗和编码器并显示适用状态](https://github.com/Ghost233/GhostModelDeck/issues/129)、[保存停止条件和 Schema 并通过公开请求使用](https://github.com/Ghost233/GhostModelDeck/issues/130)、[配置思考、模板和 Splash 调度并验证下一次请求](https://github.com/Ghost233/GhostModelDeck/issues/131) | `ready-for-agent` |

## 需求覆盖映射

下表对应父规格的 42 条用户故事，全部至少由一个切片承接。编号采用上表的切片编号；覆盖表示已有验收要求，不表示已经实现或验收通过。

| 切片 | 用户故事编号 |
| --- | --- |
| 01 · [在 A 面板配置加载资源并验证下次启动生效](https://github.com/Ghost233/GhostModelDeck/issues/119) | 1、2、3、4、5、8、12、13、14、15、21、22 |
| 02 · [配置 Splash 缓存和服务预算并验证原生结果](https://github.com/Ghost233/GhostModelDeck/issues/128) | 3、4、5、8、12、13、22 |
| 03 · [配置 Splash ANE、功耗和编码器并显示适用状态](https://github.com/Ghost233/GhostModelDeck/issues/129) | 3、4、5、8、12、22、31 |
| 04 · [保存温度和响应长度并让下一次请求生效](https://github.com/Ghost233/GhostModelDeck/issues/121) | 5、6、8、13、14、16、17、18、19、20 |
| 05 · [用控件启停采样、惩罚和通用优化](https://github.com/Ghost233/GhostModelDeck/issues/120) | 5、7、8、16、17、20、35 |
| 06 · [保存停止条件和 Schema 并通过公开请求使用](https://github.com/Ghost233/GhostModelDeck/issues/130) | 8、9、10、16、17、20、40 |
| 07 · [配置思考、模板和 Splash 调度并验证下一次请求](https://github.com/Ghost233/GhostModelDeck/issues/131) | 8、12、16、17、18、20 |
| 08 · [启用引擎访问控制后仍能查看状态和推理](https://github.com/Ghost233/GhostModelDeck/issues/126) | 3、4、8、12、22、39、40 |
| 09 · [选择原始 Splash 草稿并完成实际短生成](https://github.com/Ghost233/GhostModelDeck/issues/123) | 11、23、24、27、28、29、30、31、32、36、38、42 |
| 10 · [配置 llama.cpp 草稿模式与路径并遵循原生启动结果](https://github.com/Ghost233/GhostModelDeck/issues/124) | 11、23、25、26、27、28、29、30、31、32、36、38、42 |
| 11 · [选择 compact ranking 并核实实际使用或回退](https://github.com/Ghost233/GhostModelDeck/issues/125) | 3、4、8、11、12、33、34、36、42 |
| 12 · [修改运行中实例并保持实际来源与正确生效阶段](https://github.com/Ghost233/GhostModelDeck/issues/122) | 13、14、15、16、17、18、23、28、29、32、36、37、38、40 |
| 13 · [在原生桌面完成配置、调用与退出并交付最终候选](https://github.com/Ghost233/GhostModelDeck/issues/127) | 1、2、11、12、13、20、22、36、37、38、39、40、41、42 |

## 执行与结项

无工单前置依赖的切片为 01、02、03、04、06、08、09 和 10。切片 10 按用户已明确的官方参数适配范围推进，不再等待真实配对；切片 11 已有真实 ranking 和原生验证前置证据。二者均改为 `ready-for-agent`，尚未结项。

参数目录、控件、保存、请求或启动适配随各条用户路径验收。复用已有工作区代码，逐项修正；共用的可选数值契约由 04 先交付，再用于 05 和 07。

最终交付切片 13 直接依赖 02、03、05、06、07、08、11 和 12，其余前提由这些切片传递。每条路径需要真实可核对的结果，旧候选的测试数量和构建结果不能替代新候选验收。

已补齐的资源和原生路径见验证记录，仍未完成的交付步骤以本文开头及当前作业入口为准。业务候选已提交并建立阶段草稿 PR；审查修复后的最终门禁、复审及工单结项仍在执行。

历史旧范围仍以其原工单为准：[引擎启动参数配置：文本优先、模型独立配置与最终命令预览规格](https://github.com/Ghost233/GhostModelDeck/issues/44)、[Splash 本地引擎接入：启动参数、模型绑定与文本运行](https://github.com/Ghost233/GhostModelDeck/issues/57)。本次不自动关闭或改写这些旧工单。
