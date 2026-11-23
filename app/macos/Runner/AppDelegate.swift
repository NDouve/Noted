import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var cloudFolder: CloudFolder?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.registerCloudFolder() }
  }

  private func registerCloudFolder() {
    let controller = NSApp.windows.compactMap { $0.contentViewController as? FlutterViewController }.first
    guard let messenger = controller?.engine.binaryMessenger else { return }
    cloudFolder = CloudFolder(messenger: messenger)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
