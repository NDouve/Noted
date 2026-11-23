import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var cloudFolder: CloudFolder?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    cloudFolder = CloudFolder(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
