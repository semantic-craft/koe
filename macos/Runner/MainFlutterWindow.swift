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
    DualRecordingBridge.shared.configure(flutterViewController.engine.binaryMessenger)
    WifiConnectivityBridge.configure(binaryMessenger: flutterViewController.engine.binaryMessenger)
    CredentialBridge.configure(binaryMessenger: flutterViewController.engine.binaryMessenger)
    AudioTranscodeBridge.configure(binaryMessenger: flutterViewController.engine.binaryMessenger)
    AppleSpeechBridge.shared.configure(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    AnswerSpeechBridge.shared.configure(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    SystemTasksBridge.configure(binaryMessenger: flutterViewController.engine.binaryMessenger)

    // Unattended acceptance drives Koe through the accessibility API
    // (scripts/mac-ax), which only sees Flutter's widgets once the engine
    // builds its accessibility tree; it normally does that only while
    // VoiceOver is on. Launch with
    // `open --env KOE_ACCESSIBILITY_TREE=1 /Applications/Koe.app`.
    if ProcessInfo.processInfo.environment["KOE_ACCESSIBILITY_TREE"] == "1" {
      // The engine ignores the switch until it is running.
      DispatchQueue.main.async { [weak flutterViewController] in
        flutterViewController?.engine.setValue(true, forKey: "semanticsEnabled")
      }
    }

    super.awakeFromNib()
  }
}
