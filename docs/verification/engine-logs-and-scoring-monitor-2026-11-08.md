# 引擎日志与评分任务监控验收

## 范围

本次发布版本为 0.3.5，由用户手动确定。验证平台为 macOS arm64，使用固定 Flutter 3.47.6 和 Dart 3.13.5。功能修改从 main 的 `12376b565f60a2e5ef07778beb5cf8fe28994690` 开始。

运行监控新增混合引擎日志，汇总 Splash、llama.cpp 和 oMLX 的标准输出与错误输出。每个引擎及混合列表最多保留 1,000 条。日志只保存在内存中，认证凭据在写入前脱敏。UTF-8 解码和分行保留跨分块内容，过长的整行直接省略。

H2O 读取 `encoder_requests`，按真实任务显示排队、处理中和评分中。固定卡片数量取自 `features.encoder_submit_batch_limit`。原生评分批次上限、生成模型槽位和 HTTP 接纳容量保持独立。任务多于单批上限时扩展列表，避免隐藏排队任务。

GMD 启动 llama.cpp 时启用 `--metrics`，读取队列与累计统计。未上报的字段继续保持未知。

## 真实模型与窗口

功能验收使用与发布候选相同的功能源码。版本号确定后，另行构建 0.3.5 应用并预检安装镜像。

| 运行组合 | 实际观察 |
| --- | --- |
| Splash / H2O Lightning Q8_0 | 空闲时保留 4 张评分卡片。一次 8,478-token 评分显示 1 张“评分中”、3 张“空闲”。结束后恢复 4 张空闲卡片，累计评分数增加。 |
| Splash / Axion | 真实请求在生成卡片显示 `decode` 和 `158 token`，请求结束后恢复空闲。原生采样捕捉到 queued、prefill 和 decode 阶段。 |
| llama.cpp b12110 / EmbeddingGemma | 开启 metrics 后，队列显示 0。一次 Embedding 请求返回 768 维向量，累计输入为 8 tokens。 |
| oMLX | 进程接缝检查覆盖标准输出、错误输出、密钥与 Cookie 脱敏，以及配置实例重建后的共享日志。此次未启动真实 oMLX 模型。 |

原生窗口已确认 Splash 与 llama.cpp 的日志进入同一列表。H2O 评分结束后，活动任务列表清空。用户配置文件的摘要在本地更新前后保持一致。

H2O 验收使用的外部 Splash Build ID 为：

```text
src-c5c34e386583ad5ee6030b9a397813c090659f21680f71ba4b5dae5f7dc4dad8
```

二进制 SHA-256 为：

```text
a68adc96c0999d1fe8c1d38e6f1603b8e72419fa5d40d32b98cb48849c042b56
```

Splash 会话另行验证了排队任务、取消标记、结束清理和后续评分恢复。GMD 只接入这些状态，不改写原生评分执行过程。

## 本地定点检查

以下命令均返回 0。环境由 `scripts/test-host.sh prepare` 核验，依赖在线解析后保持现有 lockfile。

```sh
scripts/test-host.sh test test/engine_logs_test.dart test/runtime_monitor_test.dart test/runtime_monitor_page_test.dart --concurrency=1
scripts/test-host.sh test test/llama_engine_test.dart test/splash_engine_test.dart test/omlx_pool_test.dart --name 'native logs|managed llama enables native monitoring metrics|normal startup verifies health|configured oMLX instances share' --concurrency=1
python3 -B scripts/test_release.py
bash -n scripts/release.sh scripts/build-release.sh
```

前两组共 31 项检查通过。发布脚本另有 10 项本地回归通过。13 个改动的 Dart 文件通过逐文件静态分析；实现文件和新增测试文件通过格式检查。既有大型测试文件仅格式化新增段落，保留原有内容。

本地证据位于 `.tooling/host-tests/run-e7X2dw` 和 `.tooling/host-tests/run-Bvh1Fa`。发布脚本、静态分析及构建日志以 `.tooling/host-tests/release-v0.3.5-` 为前缀。真实状态和窗口记录位于 `.tooling/queue-progress-fix` 与 `.tooling/h2o-cards`。这些本地目录不进入发行包。

## 发布候选预检

0.3.5 应用在独立目录构建成功。主程序、App.framework 和 FlutterMacOS.framework 均为 arm64，应用版本与根 pubspec 一致。应用通过严格嵌套签名校验。

`scripts/build-release.sh --app-path <候选应用> --output-dir .tooling/release-precheck/v0.3.5` 实际生成了 DMG、manifest.json 和 SHA256SUMS。清单字段、两项 SHA-256 和 `hdiutil verify` 均校验通过，命令退出码为 0。

这些文件只用于本地发布前预检。正式资产由发布 tag 对应的 GitHub Actions 重新构建，正式发布结果按远端管线与资产元数据验收。

## 兼容边界

旧版 Splash 的已有累计统计继续可读。实时评分阶段需要 `encoder_requests`，固定卡片需要 `encoder_submit_batch_limit`。`prompt_processed` 为 null 时只显示输入总量，保持已处理比例未知。

外部 Splash 二进制不包含在 GMD 安装包中。用户需单独更新关联引擎，再重启实例。此次未运行完整测试套件、基准或评测集，也未以构建成功替代真实模型验收。
