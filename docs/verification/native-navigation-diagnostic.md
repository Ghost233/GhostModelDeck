# 原生导航会话诊断

2026-10-05，在 Mac 锁屏恢复后的最终预览中，PID 43015 的应用停留在“发现模型”；点击引擎导航及 Tab 输入没有改变页面，ps 观察 CPU 约 89%。不能把该静态窗口视为交互通过。

反馈循环通过 CUA 对真实按钮执行点击，再检查实际 AX 页面标题：

```js
await jevApp.click(engineButtonIndex);
const state = await jevApp.getAXState({emit: false, disableDiffing: true});
if (!/\d+ text \(settable\) 引擎管理(?:\n|$)/.test(state)) {
  throw new Error('Native navigation did not change the page heading');
}
```

旧进程运行该循环实际为 failed。只读 sample 显示主线程正在 Flutter 的键盘事件处理与原生 responder 路径；采样不能单独证明根因。

通过原生 Quit 正常结束 PID 43015，没有强制终止或改代码；同一路径、同一构建重新启动为 PID 54729。App.framework SHA-256 保持 `2b1ff21816c2f934b589efa4e6c0fabd03951f57b0ed3c3af10aa33035043920`。新进程启动后 ps CPU 为 3.5%，相同点击/标题断言 passed，页面实际显示两项已安装/关联的 llama.cpp 及管理操作。

这证明当前会话恢复，排除“此构建每次都无法导航”的解释；不称为已定位或永久修复锁屏/输入问题。重启后约五分钟再次 ps，CPU 为 0.0%，RSS 76,128 KiB；不是完整性能基准。精确触发条件尚未确定，也没有为此改 Flutter SDK、系统设置或生产代码。旧进程 sample 保存在忽略的 `.tooling/implementation/native-ui-sample.txt`。

Mac 常用 1100×700 内容窗口已实际查看。窗口边缘拖动未成功改变原生尺寸，不将其计为900×560原生实测；该最小尺寸、浅深色及1.5倍文字的生产Widget布局另见 [布局记录](desktop-layout.md)。
