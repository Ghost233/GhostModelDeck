import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

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
      if call.method == "setEntryManaged" {
        guard let managed = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_argument", message: "managed 必须为布尔值", details: nil))
          return
        }
        result((NSApp.delegate as? AppDelegate)?.setEntryManaged(managed) ?? false)
        return
      }
      if call.method == "activateMainWindow" {
        guard let delegate = NSApp.delegate as? AppDelegate,
              delegate.mainFlutterWindow != nil else {
          result(FlutterError(code: "window_unavailable", message: "主窗口不可用", details: nil))
          return
        }
        delegate.showMainWindow(nil)
        result(nil)
        return
      }
      if call.method == "revealInFinder" {
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String,
              path.hasPrefix("/"), !path.utf16.contains(0) else {
          result(FlutterError(code: "invalid_argument", message: "path 必须是完整文件路径", details: nil))
          return
        }
        guard FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "file_unavailable", message: "文件或目录不存在", details: nil))
          return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        result(nil)
        return
      }
      guard call.method == "pickLibraryDirectory" || call.method == "pickEngineDirectory" || call.method == "pickParameterFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let window = self else {
        result(nil)
        return
      }
      let panel = NSOpenPanel()
      let chooseFile = call.method == "pickParameterFile"
      panel.title = chooseFile ? "选择参数文件" : call.method == "pickEngineDirectory" ? "引擎目录" : "模型目录"
      panel.canChooseDirectories = !chooseFile
      panel.canChooseFiles = chooseFile
      if chooseFile,
         let arguments = call.arguments as? [String: Any],
         let extensions = arguments["extensions"] as? [String],
         !extensions.isEmpty {
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
      }
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
    DispatchQueue.main.async { [weak self] in
      guard let window = self, let delegate = NSApp.delegate as? AppDelegate else { return }
      delegate.configureWindow(window)
    }
  }
}
