---
name: deploy-release
description: 使用当前仓库的标准入口发布正式版本、跟踪 CI 与 GitHub Release，或维护发布流程。
---

# deploy-release

读取当前仓库的 `docs/agents/release.md`。版本规则、仓库身份、tag、workflow 和产物名称均以该文档及其引用为准。统一执行入口是 `scripts/release.sh`。共同流程写在本 skill，项目差异留在发布文档。维护共同流程时，同步两个仓库的副本。

## 流程

1. 沿用用户已确定的发布范围、版本和授权；缺少必要信息时再询问。维护 skill、脚本或 CI 时完成编辑与验证。
2. 按改动范围完成验证，复用输入与环境未变的成功结果。审查并提交发布内容，更新和同步用户当前工作区的 main。
3. 运行 `scripts/release.sh --dry-run`，核对版本、tag 和完整提交。检查通过且当前请求已授权发布时，直接运行 `scripts/release.sh`。
4. 按输出的 tag 和完整提交跟踪对应 workflow。已有远端 tag 时跟踪既有运行；标签推送成功表示受理，管线与 Release 验收通过才表示发布完成。
5. 核对正式 Release、版本、发布提交与三件套资产，以及本地 main/tag 和实际远端。优先使用本次 CI 的校验证据和 GitHub 资产元数据；需要独立复核或排障时再下载完整 DMG。证据齐全后报告 Release 链接。

失败恢复按当前仓库的发布文档执行，保留原错误。发布脚本负责创建和推送 tag；版本修改、提交、main 同步和产物构建使用仓库已有入口。
