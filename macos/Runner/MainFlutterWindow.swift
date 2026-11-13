import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var inputBridge: RemoteInputBridge?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    inputBridge = RemoteInputBridge(messenger: flutterViewController.engine.binaryMessenger)
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
      object: nil, queue: nil) { [weak self] _ in self?.inputBridge?.shutdown() }

    super.awakeFromNib()
  }
}
