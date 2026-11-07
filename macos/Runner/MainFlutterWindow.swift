import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var folderAccess: MediaFolderAccess?
  private var appearanceChannel: FlutterMethodChannel?
  private var accessibilityObserver: NSObjectProtocol?

  deinit {
    if let observer = accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 420, height: 480)

    folderAccess = MediaFolderAccess(messenger: flutterViewController.engine.binaryMessenger)
    let appearance = FlutterMethodChannel(name: "dev.orvex/appearance", binaryMessenger: flutterViewController.engine.binaryMessenger)
    appearanceChannel = appearance
    appearance.setMethodCallHandler { call, result in
      guard call.method == "accessibilityPreferences" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result([
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      ])
    }
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak appearance] _ in appearance?.invokeMethod("accessibilityChanged", arguments: nil) }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
