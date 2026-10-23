import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let modelStorage = FlutterMethodChannel(name: "com.semanticcraft.koe/model_storage",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    modelStorage.setMethodCallHandler { call, result in
      guard call.method == "excludeBackup",
        let args = call.arguments as? [String: Any], let path = args["path"] as? String
      else { result(FlutterMethodNotImplemented); return }
      do {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
          in: .userDomainMask, appropriateFor: nil, create: true)
        var url = URL(fileURLWithPath: path).standardizedFileURL
        let expected = support.appendingPathComponent("AnkerRecorder/diarization_models").standardizedFileURL
        guard url.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath() else {
          result(FlutterError(code: "invalid_path", message: "模型目录无效", details: nil)); return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "storage", message: "无法设置模型备份策略", details: nil))
      }
    }
    WifiConnectivityBridge.configure(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    CredentialBridge.configure(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    SystemTasksBridge.configure(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    AudioTranscodeBridge.configure(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    AppleSpeechBridge.shared.configure(
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    AnswerSpeechBridge.shared.configure(
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    RecordingShortcutBridge.shared.configure(
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}
