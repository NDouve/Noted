import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var cloudFolder: CloudFolder?
  private var documentRender: DocumentRender?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    cloudFolder = CloudFolder(messenger: flutterViewController.engine.binaryMessenger)
    documentRender = DocumentRender(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
