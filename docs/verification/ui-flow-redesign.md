# 职责与视觉修订

2026-10-05，落实用户对搜索提示、下载配置位置、引擎职责与整体视觉的四项修订。

界面参考 oMLX 的[模型管理列表](https://github.com/jundot/omlx/blob/main/omlx/admin/templates/dashboard/_models.html)与[模型运行设置弹窗](https://github.com/jundot/omlx/blob/main/omlx/admin/templates/dashboard/_modal_model_settings.html)中的标题、辅助灰度、行内操作与区块间隔；保持 Flutter 原生应用及现有真实业务入口。

## 下载流程

设置是下载来源和模型目录的唯一编辑入口。搜索详情选择模型包、格式/量化后启动下载；任务创建时固定来源、目标目录与版本。下载任务页只显示真实当前任务、进度、来源回执、取消/重试。

独立下载配置持久保存且不覆盖旧目录 JSON（run-tExrdm → run-2qKJWp）。代理已收到 3 bytes 后将设置改为直连，取消并重试仍请求代理 Range bytes=3-；新任务才采用新来源与新目录（run-831fIf → run-aLWmZq）。设置真实控件选代理 → 搜索详情选两分片 Q8 → 实际 HTTP 下载 → 任务回执通过（run-qQ5zaG）。八项相关行为最终通过 run-RyBLV3。

共享视觉基础使用标题 24、正文 13、辅助 12、caption 11，独立提示灰度、蓝色主要操作与状态 chips，统一卡片边框、控件高度和区块留白。JevSurface 的装饰背景遮挡 Material ink 在实际 Widget 回归中失败；改为带 shape 的 Material 后相关回归通过。没有为字号或颜色编写同义镜像测试。

## 引擎与运行

引擎页只登记、安装、删除与关联。模型库按模型包/变体运行，在运行弹窗中选实际引擎。外部关联保留原文件，解除关联只改本应用记录；受管安装删除要明确文件范围、确认并先停止使用。

本机 LM Studio 的 2.50.0 包确有独立标准 llama-server。只读实际 --version/help 显示 build 1 / d775ebf / Darwin arm64；发布记录指向官方 b11337。依赖同目录 dylib，无需连接 LM Studio API 才能启动此 binary。

代理直接测试了该 binary 与已全量核验的两份资产：Kev exit 1（expected 322, got 320）；Laya exit 1（head 预期 1024×5248，实际 1024×4096）。标准参数被接受，但两个组合未进入 ready；两个测试进程均退出、模型大小/mtime 未变。LM Studio 自身服务及 runtime 文件没有改动。

这证明可以将当前内置目录登记为本地关联，同时必须保留真实组合兼容性失败；不能用其来源标签推断 typed 支持，也不能因失败拒绝引擎管理的登记功能。此前独立 b11381 与正式提供方的两模型成功证据仍有效。

## 最终业务与原生验收

完整 79 项容器测试通过（run-aRGIdL），分析无问题（run-AQTMEV）。最后原生导航验收将自定义点击区域换成同样视觉的标准 ListTile，恢复真实按钮角色与键盘操作；变更后分析通过（run-q234QX），最终 release 构建成功（43.9 MB）。

正式 Catalog 脚本 `.tooling/implementation/live-engine-catalog.dart` 退出 0：真实关联 LM Studio 2.50 目录并核验版本/本地指纹；运行时选官方 b11381，真实 typed-ready；运行中拒绝引擎删除；停止后准备 61 文件/31,530,649 bytes 的准确删除计划，取消后正式安装保留。选择本地关联版本运行 Kev，准确保留已知 322/320 错误，失败子进程收尾；解除登记后外部 executable 的全量 SHA、大小、mtime 均相同。随后重新登记作为 GUI 可选引擎。没有删除真实安装或 LM 文件。

CUA 实际操作最终应用：

- 搜索页观察灰色 placeholder、标题/正文/辅助灰度与统一留白。
- 设置页只有下载来源和模型目录；任务页为空时显示“暂无下载”，没有来源/目录配置。
- 引擎页仅列真实受管和本地关联两项，提供安装/删除/关联/解除及按需详情；无 LM 连接/token 表单、全部 runtime 清单或模型运行区。
- 模型库筛选 Kev，点击模型行“运行”打开短弹窗；实际下拉可选 b11381 与 LM 本地关联版本，选择官方版本并点击运行，真实结果回到模型行“运行中”，模型行停止后显示“已停止”。

界面已在 Mac 实际截图检查，修订逻辑与真实运行均不由静态样板代替。并发委员会与 MCP 的完整接入仍属于后续实现，以上不表示整份规格完成。
