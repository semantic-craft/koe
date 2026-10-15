import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Open the recording workspace with room for the library and reader.
    // Narrow windows retain the compact navigation layout.
    self.contentMinSize = NSSize(width: 520, height: 720)
    self.setContentSize(NSSize(width: 1240, height: 820))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
