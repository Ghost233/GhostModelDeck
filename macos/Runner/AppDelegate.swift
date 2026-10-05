import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var shutdownChannel: FlutterMethodChannel?
  private var terminating = false

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let channel = shutdownChannel else { return .terminateNow }
    if terminating { return .terminateLater }
    terminating = true
    channel.invokeMethod("prepareToQuit", arguments: nil) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let finished = result as? Bool == true
        if !finished {
          self.terminating = false
          let alert = NSAlert()
          alert.messageText = "退出未完成"
          alert.informativeText = (result as? FlutterError)?.message ?? "受管服务尚未完成收尾。"
          alert.runModal()
        }
        sender.reply(toApplicationShouldTerminate: finished)
      }
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(self)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
