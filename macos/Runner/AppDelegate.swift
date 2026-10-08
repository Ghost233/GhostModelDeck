import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var shutdownChannel: FlutterMethodChannel?
  private var terminating = false
  private var statusItem: NSStatusItem?

  func configureWindow(_ window: NSWindow) {
    mainFlutterWindow = window
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(named: NSImage.applicationIconName)?.copy() as? NSImage
      image?.size = NSSize(width: 18, height: 18)
      button.image = image ?? NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "GhostModelDeck")
      button.toolTip = "GhostModelDeck"
      button.setAccessibilityLabel("GhostModelDeck")
    }
    let menu = NSMenu()
    let openItem = NSMenuItem(title: "打开 GhostModelDeck", action: #selector(showMainWindow(_:)), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(title: "退出 GhostModelDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    item.menu = menu
    statusItem = item
    NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: window)
  }

  @objc private func mainWindowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  @objc func showMainWindow(_ sender: Any?) {
    guard let window = mainFlutterWindow else { return }
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized { window.deminiaturize(sender) }
    window.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

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
          NSApp.activate(ignoringOtherApps: true)
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
    showMainWindow(sender)
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
