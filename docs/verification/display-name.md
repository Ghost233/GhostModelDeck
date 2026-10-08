# Ghost Model Deck 显示名验证

2026-10-08，用户要求将应用名称改为 `Ghost Model Deck`。修改应用内品牌文字、托盘菜单与无障碍标签、SDK 自报显示名、macOS PRODUCT_NAME、启动脚本和打包说明。侧栏品牌允许两行显示，适应新增空格后的名称长度。

稳定 bundle id、Dart package、配置目录、仓库名和 DMG 资产文件名沿用原值；读取原有配置不需要迁移。源码版本仍是 0.1.3，本次未修改已发布的 v0.1.3 tag 或正式资产。

| 检查 | 实际结果 |
| --- | --- |
| 格式检查 | exit 0，90 文件、零改动。 |
| 静态分析 | exit 0，零诊断。 |
| 全量应用测试 | exit 0，540 项通过，包括品牌可见性和 SDK 显示名断言。 |
| `python3 -B scripts/test_release.py` | exit 0，9 项通过。 |
| 受影响 Shell 脚本 `bash -n` | exit 0。 |
| 完整 Mac Release 构建及真实 DMG 预检 | exit 0；产物为 `Ghost Model Deck.app`。 |
| 只读挂载后包内检查 | exit 0；CFBundleName、CFBundleExecutable 均为 `Ghost Model Deck`，bundle id 保持 `com.ghost233.ghostmodeldeck`，安装布局与 SHA 校验通过。 |
| `git diff --check` | exit 0。 |

原始日志、退出码及最终门禁输入 SHA 清单保存在 `.tooling/display-name/`。本机已安装的旧应用未被替换或重启；本次验证的是源码、测试和本地新构建，桌面运行效果沿用下一次安装后的名称。
