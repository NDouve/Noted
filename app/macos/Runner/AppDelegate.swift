import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var documentRender: DocumentRender?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = NSApplication.shared.windows.compactMap({ $0.contentViewController as? FlutterViewController }).first {
      documentRender = DocumentRender(messenger: controller.engine.binaryMessenger)
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
