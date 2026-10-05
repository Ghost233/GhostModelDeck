# 检查环境网络诊断与恢复（进行中）

日期：2026-10-06（Asia/Shanghai）。用户明确要求不使用离线模式；本记录不代表 #15 或整份规格验收完成。

## 紧凑反馈与事实

- 原检查容器配置和实际 resolv.conf 都为 `nameserver 119.29.29.29`，不存在 DNS 配置丢失的证据。
- 原容器的 pub.dev 请求曾 `curl: (28) Operation timed out after 15003 milliseconds with 0 bytes received`；实际 pub get 卡住，原任务被确切识别后终止，未启动 GUI 测试。不能把包网络失败当作业务测试失败。
- 首轮宿主/容器 HTTPS 对照：pub.dev 宿主 HTTP200/1.34s、容器 HTTP200/2.01s；storage.googleapis.com 两边都收到 HTTP400（根 URL 响应，证明链路到达，不表示依赖下载成功）；huggingface.co 宿主 HTTP200/0.40s、容器 TCP5s超时，DNS已解析。并非所有外网都不可访问。
- 原容器 getent 给 Hugging Face `108.160.162.104`。宿主分别用 Google/Cloudflare 的 HTTPS DNS 查询，均得到 `65.8.76.62/.91/.97/.109`。一次只替换 curl 该请求的解析地址，保留 URL、SNI 与 TLS 校验（`--resolve huggingface.co:443:65.8.76.62`），原容器 HTTP200/1.34s。该对照证明此前 Hugging Face 失败与解析路径/地址有关；不把所有外网故障统一归因 DNS，也未修改宿主或其他容器 DNS。
- 宿主系统 HTTP/HTTPS/SOCKS/PAC 均为关闭，宿主及原容器没有 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY 环境值。本项不排除透明网络层；未读取或展示任何认证头、凭据、PAC URL 或用户代理配置文件。

## 独立容器停止事件

实际查询发现旧自有检查容器 `ghostmodeldeck-checks-r24b` stopped，运行时仍 running；它的 inspect 返回 OOMKilled=false、Dead=true、ExitCode0，但缺有效启停时间。来源及部分其他容器同时 stopped，不足以归因某个用户/进程。本线程只停止自身无效的等待任务 bash-745，未启动/重启来源或其他服务。

尝试仅恢复该自有容器失败，原始错误为：

```text
failed to bootstrap container ghostmodeldeck-checks-r24b
container expected to be in created state, got: running
```

原脚本等待 `/workspace/job.exit` 时对停止容器缺少检查，重复报 `Container is not running`。现补上 job 运行期间容器停止则记录日志并 exit1 的护栏，不再无限等；此改动与离线模式无关。此前临时离线开关及建议已撤回，脚本无 `--offline`。

## 自有检查环境恢复

- 新建专用 `ghostmodeldeck-checks-r33b`，没有更改宿主或其他容器。固定 node 镜像 index digest `sha256:363e1587494626837fa7f9a23bdb453d13b0ff3c67c705c2805cfc69c2d2fad7`、linux/arm64、4GiB，仍明确 `--dns 119.29.29.29`。
- 使用相同已核验 SDK/cache，固定 Flutter3.47.6/Dart3.13.5；字体与 SDK 的宿主挂载目录分开，Noto字体单独只读挂载。首次重建 r33 在 apt fonts-noto-cjk 写入只读字体挂载时失败，未作为就绪环境；原始 `/tmp/gmd-checks-r33-bootstrap.log` 保留。未宣称完全查明所有挂载细节。
- 新容器已实测 `.git` 存在、bootstrap就绪、无遗留 job。随后按119.29/1.1.1.1/8.8.8.8分别发 UDP DNS 查询，三者均返回 `198.18.0.10`。这与早期结果不同，可能有透明 DNS/网络环境变化；没有依据声称上游119.29永久修复或具体代理是谁。
- 新容器正常域名/TLS请求（不使用 `--resolve`）：pub.dev HTTP200/1.61s，Hugging Face HTTP200/1.46s，curl均exit0。其连接IP分别198.18.0.5与198.18.0.10；假IP/透明层不能仅凭地址判断不可达，应以实际TLS/HTTP结果为证。

## 当前验收门槛

主线程以原联网依赖解析执行 `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh` 的 GUI测试→format→analyze→完整tests，后台 bash-777 已收集，exit0：GUI2项 run-GfB1hi；format56文件0改动 run-HgmhGR；analyze零诊断 run-4vRxlF；完整166项全部通过 run-xOjIpZ。四个阶段都使用普通联网 pub get，无 `--offline`，也无临时 `--no-pub` 绕过。之前显式离线诊断结果不替代这次用户要求的联网检查。

这些结果只验证 #15 M1 与现有回归，不是原生模型、双版本、请求生命周期或全规格验收。没有升级SDK/依赖，没有训练或加载模型，没有把网络探针当模型Ready。#15保留开放。

## 停止护栏回归与恢复资源收尾

2026-10-06 主线程通过公开脚本 CLI 和可控 Docker I/O 接缝验证停止场景：`python3 .tooling/check-runner-stopped-container-regression.py` exit0，脚本自身预期 exit1，1.94s 内返回 `Test container stopped before the check job completed.`。结果保存在 `.tooling/check-runner-stopped-container-result.json`。这是基础设施护栏的受控测试，没有停止真实容器，没有运行 Flutter 测试或绕过联网解析，不能替代上面的正式联网检查。

已先按确切名称核验以下四个**本线程自有且已停止**的恢复/探针容器，再删除其容器对象：`ghostmodeldeck-checks-r24b`、`ghostmodeldeck-checks-r33`、`ghostmodeldeck-mount-probe-r33`、`ghostmodeldeck-mount-alias-probe-r33`。核验快照 `/tmp/gmd-owned-recovery-containers.json` 保留。不删除宿主 SDK/cache/字体或任何用户模型，不操作来源或其他服务；M2 独占使用的 `ghostmodeldeck-checks-r33b` 未改动。
