import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let nativeChannel = FlutterMethodChannel(
      name: "com.ghost233.ghostmodeldeck/native",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.shutdownChannel = nativeChannel
    nativeChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickLibraryDirectory" || call.method == "pickEngineDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let window = self else {
        result(nil)
        return
      }
      let panel = NSOpenPanel()
      panel.title = call.method == "pickEngineDirectory" ? "引擎目录" : "模型目录"
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.beginSheetModal(for: window) { response in
        result(response == .OK ? panel.url?.path : nil)
      }
    }

    self.isReleasedWhenClosed = false
    self.contentMinSize = NSSize(width: 900, height: 560)
    let available = self.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    self.setContentSize(NSSize(width: min(1100, available.width - 60), height: min(700, available.height - 80)))
    self.center()

    super.awakeFromNib()
  }
}
