# 标准发布流程本地验证

日期：2026-10-08。基于 `591067e5e0d3aeae138595e5c73f245776fa66fd` 的工作区改动；发布工具和文档尚未提交。未修改根 `pubspec.yaml` 的 `0.1.2`，未创建或推送本项目 tag，未触发 GitHub Release。

## 检查结果

| 检查 | 实际结果 |
| --- | --- |
| `python3 -B scripts/test_release.py` | exit 0，9 项通过，13.068 秒；使用临时仓库与本地裸仓库，不访问 GitHub。 |
| `bash -n scripts/release.sh scripts/build-release.sh` | exit 0。 |
| release.yml YAML、触发条件及 5 个 shell 步骤语法 | exit 0；触发条件精确为 `push.tags: [v*]`。 |
| 当前工作区 `scripts/release.sh --dry-run` | exit 1，正确提示「必须在 main 分支执行」；当前为开发分支，未切分支或暂存文件。 |
| 已构建应用的真实 DMG 打包 | exit 0；产物放在独立的 `.tooling/release-flow-precheck-20261008`。 |
| `shasum -a 256 -c SHA256SUMS` | exit 0，DMG 和 manifest.json 均为 OK。 |
| manifest 与实际 DMG 的大小和 SHA | 一致，24,557,543 字节。 |
| `git diff --check` | exit 0。 |

测试覆盖空跑无副作用、tag 指向与重试、GitHub 有效身份和实际 Git 凭据、工作树/分支/仓库护栏、版本格式和已有 tag、本地/远端 main 一致性，以及预构建应用版本不匹配时拒绝打包。

DMG 为 `GhostModelDeck-0.1.2.dmg`，SHA256：`7b9186909b039d04c6598003a4213cf97a5e2680535abb38f531569a8ad84dd5`。打包命令：

```sh
scripts/build-release.sh \
  --app-path "$PWD/build/macos/Build/Products/Release/GhostModelDeck.app" \
  --output-dir "$PWD/.tooling/release-flow-precheck-20261008"
```

打包和当前工作区空跑的原始日志及退出码保存在 `.scratch/release-flow/`。最终静态校验曾因系统 Ruby 不支持 `filter_map` 而失败；检查命令改用 `map.compact` 后通过，workflow 输入未改动。

这些结果证明本地入口和打包路径通过；远端 workflow 与正式资产仍需在明确发版时验收。当前开发分支与 origin 缓存均为 `591067e5e0d3aeae138595e5c73f245776fa66fd`，本地 main 与 origin/main 缓存均为 `b1e4aad044344a91849b0ec309b8e9c325455a4d`；本次未执行远端写操作。
