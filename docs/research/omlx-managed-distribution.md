# oMLX 受管安装与前台启动分发证据

调查日期：2026-10-05（Asia/Shanghai）。对应 [核实 oMLX 受管安装与前台启动分发方案](https://github.com/Ghost233/GhostModelDeck/issues/11)。基线为官方 `v0.7.0/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40`；主线程已核验目标机为 M5 Pro/64GB、macOS 27.0.1。这里只读发布元数据与固定源码，没有下载/挂载 DMG、安装或启动程序。

## 结论与候选分发物

**可把完整官方 `.app` 作为私有引擎包候选，直接调用其 CLI wrapper 的 `serve`，由 GhostModelDeck 管理前台子进程。** 固定源码有明确的随包 Python/框架布局和相对路径启动器，无须先启动 Swift 菜单栏 app 或操作 Homebrew 服务。仍必须在安装验收时验证发布 DMG 的真实布局、签名、重定位与启动；当前只有源码意图和发布元数据证据。

目标系统对应的官方资产是 [oMLX-0.7.0-macos26-27.dmg](https://github.com/jundot/omlx/releases/download/v0.7.0/oMLX-0.7.0-macos26-27.dmg)：**830,879,938 B**，GitHub 发布元数据 digest 为 **`sha256:2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0`**。发布于 2026-09-30，release 的 target_commitish 是上述完整 SHA。[固定 release](https://github.com/jundot/omlx/releases/tag/v0.7.0)、[release API](https://api.github.com/repos/jundot/omlx/releases/tags/v0.7.0)

## 官方源码事实

- 打包配置导出 arm64 的 **CPython 3.11.10** runtime 与 `framework-mlx-base` 框架层；框架包含 MLX、mlx-lm、FastAPI、transformers 等依赖。[venvstacks 配置](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/packaging/venvstacks.toml#L13)、[层说明](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/packaging/README.md#L49)
- `build.sh` 把两层完整复制到 `Contents/Resources/Python/`，把 oMLX 源码包复制到 `Contents/Resources/omlx/`，并生成 `_engine_commits.json`。原生 custom kernel 是否包含取决于构建选项，不能从默认脚本推出发布 DMG 的全部扩展内容。[复制层](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/apps/omlx-mac/Scripts/build.sh#L572)、[源码与扩展资源](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/apps/omlx-mac/Scripts/build.sh#L607)
- 脚本生成可执行 **`oMLX.app/Contents/MacOS/omlx-cli`**：用自身 `realpath` 定位资源，设置 `PYTHONHOME`、`PYTHONDONTWRITEBYTECODE=1` 和含资源/框架的 `PYTHONPATH`，最终 `exec` 随包 Python 执行 `-m omlx.cli`，所有参数原样传入。[完整 wrapper](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/apps/omlx-mac/Scripts/build.sh#L631)
- Swift 自己也直接启动 `python -m omlx.cli serve --base-path ... --port ...`；CLI 的 `serve` 支持 `--model-dir`、`--host`、`--port`、`--base-path`。因此所需运行入口是前台 `serve`，不是 app/Homebrew 的 `start/stop/restart` 控制命令。[Swift 参数](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/apps/omlx-mac/Sources/Server/ServerProcess.swift#L550)、[CLI 参数](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/cli.py#L1156)、[base-path](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/omlx/cli.py#L1337)
- 固定打包脚本支持选择 macOS 26 的 `mlx`/`mlx-metal` wheels，并说明该目标包括 M5 专用加速路径；源依赖固定 `mlx==0.32.2`。这是打包/运行依赖意图，不是目标机性能实测。[平台 wheel 处理](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/packaging/build.py#L134)、[依赖](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/pyproject.toml#L41)

**证据边界：** 打包 README 明确 DMG 来自维护者的仓库外流水线，仓内 `build.sh` 只产生 staged `.app`。[说明](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/packaging/README.md#L69)。发布资产的实际 Python/MLX/Metal 二进制、签名、路径和依赖版本必须解包后核实，不能仅靠源码保证它与 staged 包逐项相同。

## 最小受管安装/启动契约（实施推论）

安装工单可采用：下载上述固定资产并重算 digest；从 DMG 复制**整个** `oMLX.app` 到 GhostModelDeck 拥有的版本化引擎目录（示例：`Application Support/GhostModelDeck/engines/omlx/v0.7.0/oMLX.app`），保留内部文件、相对布局、可执行位和原有签名。不要拆取某个 Python、`.so` 或 site-packages 作为完整运行器。解包空间须测量，不能把 DMG 压缩大小当安装占用。

安装验收至少检查以下预期路径：

```text
oMLX.app/Contents/MacOS/omlx-cli
oMLX.app/Contents/Resources/Python/cpython-3.11/bin/python3
oMLX.app/Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages/
oMLX.app/Contents/Resources/omlx/
```

随后由 App 直接启动并记录 PID、退出状态和 stdout/stderr，参数契约为：

```text
<engine-root>/oMLX.app/Contents/MacOS/omlx-cli serve
  --base-path <App-owned-instance-state>
  --model-dir <selected-model-directory>
  --host 127.0.0.1 --port <internal-backend-port>
```

独立 base-path 用于把 oMLX 自身配置与实例状态放到 App 目录，模型目录单独指定；实际缓存/日志写入位置仍应在安装验收中核对。客户端走统一网关。子进程环境应使用 App 明确提供的配置，避免继承其他 Python 路径或其他 oMLX 实例变量影响身份。不要设置原生 app 专用的 `OMLX_SUPERVISED=menubar` 来冒充原生菜单栏监督者，也不需要安装 `~/.omlx/bin` shim；这些属于另一生命周期。[原生监督者环境](https://github.com/jundot/omlx/blob/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40/apps/omlx-mac/Sources/Server/PythonRuntime.swift#L104)

官方还发布 [CPython 3.11 wheel](https://github.com/jundot/omlx/releases/download/v0.7.0/omlx-0.7.0-cp311-cp311-macosx_15_0_universal2.whl)，39,571,729 B，digest `sha256:a25b0fbf86579512ced2a45b9aba420a51e6e8f3ee9ea3832ea1b9111d2cc4a7`。该 wheel 是 oMLX 包，不能代替整个 CPython/MLX 运行环境。若真实 DMG 布局或私有运行验收失败，固定源码/该 wheel 配合私有 CPython 3.11 venv 是后备方向，但还缺完整依赖锁、每个分发物哈希和原生依赖兼容验证，不能直接宣称可安装完成。

## 待真实验收

尚未验证下载字节哈希、DMG 内容、应用签名/系统启动校验、私有目录重定位、随包运行器版本与 MLX/Metal 加载、固定小型 MLX fixture 的真实 Chat/SSE、退出/回收及无全局服务介入。安装工单应先验证这些条件；若包缺预期 wrapper/资源或无法直接运行，应记录具体阻塞并停止采用该包，不能改用全局 app/Homebrew 服务来掩盖失败。
