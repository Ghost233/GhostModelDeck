# Ghost Model Deck 0.2.0 正式发布验收

2026-10-14。用户明确要求提交和正式发布，并手动选择0.2.0。按照deploy-release skill、`docs/agents/release.md`和版本规则执行唯一入口`scripts/release.sh`。

## 正式结果

- Release：[v0.2.0](https://github.com/Ghost233/GhostModelDeck/releases/tag/v0.2.0)，正式版本，非draft／prerelease。
- 源码／tag提交：`a4fcf10998f1677a315b1bdf77bcf4bc0424cec5`。
- [Actions 38545935332](https://github.com/Ghost233/GhostModelDeck/actions/runs/38545935332)，对应v0.2.0／完整源码提交，全部步骤成功。
- 根pubspec、tag、manifest及应用版本均为0.2.0；CI构建号15。
- 下载正式三件套，大小与Release一致，`SHA256SUMS`验证DMG和manifest通过，manifest中DMG的大小与SHA匹配。
- 正常只读挂载DMG，核对bundle ID为`com.ghost233.ghostmodeldeck`。主程序、App.framework和FlutterMacOS.framework实际均仅arm64，随后正常卸载；没有安装或启动这个新版本。

| 资产 | bytes | SHA-256 |
| --- | --- | --- |
| GhostModelDeck-0.2.0.dmg | 23102670 | `4b0cede84214f63f0120c0bde392643b93f9e7761360fb6ad8167d4af4a91160` |
| manifest.json | 174 | `630dd1481b308eda79640e1f2ef566fe9879e7b9e0ac59dfaa5bf72405918d39` |
| SHA256SUMS | 171 | `7d0f9876cf7addec73ead88d2027f1d7e6271eff183c54a1ed4c762531de7045` |

## 本地前置与真实证据

固定Flutter3.47.6／Dart3.13.5，Mac arm64宿主、现有lockfile、联网解析，沿用已核验字体。唯一作业完成统一准备、全仓格式与静态分析、1003项完整测试（`run-yXSnmE`）、发布流程回归、真实arm64构建、DMG预检，全部退出0，最终源码与门禁快照一致。完整门禁中的题目规模测试验证历史文件与分页契约，不是模型评测；未重复模型题集。

q14复用[Splash修复记录](splash-temporary-readiness-2026-10-14.md)：真实首次临时未就绪失败保留，修复后的运行对象没有永久失败。重试只新增1次真实Kev请求，复用已成功的Qwen响应，HTTP200，`failure_loop`预期与实际均为attention；没有重跑完整36条，也不将单题等同完整质量验收。

源码修改和身份校验经过主线程固定候选及固定提交复审，无未关闭P0/P1/P2。提交／推送前后本地main、dev及跟踪／实际远端同步，未创建分支或worktree，没有stash、reset或覆盖他人文件。发布记录的后续文档提交不改变tag或应用源码。

## 运行服务与范围

现有GMD PID61160以及Qwen、Kev服务没有重启，正式运行应用仍是用户原版本；本次发布不代表运行进程已经应用修复，也没有清除旧Kev失败状态。

另按Wiki会话直接用户授权，在同一GMD中保存并加载已有EmbeddingGemma2 F16。公开入口`http://127.0.0.1:54841/v1/embeddings`，model `embeddinggemma-2-f16`，768维，mean pooling和L2归一化，输入原样转发。单条／三条批量float请求通过；这使用既有0.1.9功能，没有新增应用代码、启动第二个GMD、停止其他模型或修改Wiki文件／向量。交接JSON和模型身份保存在`.scratch/wiki-gmd-embedding-20261014/`，旧LMStudio向量等价未声明。

完整发布、资产、挂载和同步证据保存在`.scratch/release-0.2.0/`。仅一次tag发布；执行前空跑通过。辅助回读错误和提交清单保护错误保留：前者使用了错误cwd，后者遇到输出空白处理及自身生成的Python字节码。只清理自身缓存并禁用字节码后继续，没有把工具错误计为门禁成功，也没有因这些错误重复模型、完整门禁、构建或发布。
