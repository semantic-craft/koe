#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

enum CredentialBridge {
  static func configure(binaryMessenger: FlutterBinaryMessenger) {
    let store = KeychainStore()
    let channel = FlutterMethodChannel(
      name: "com.semanticcraft.soundcore/credentials", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "mode": result(store.mode.rawValue)
        case "diagnostics":
          result(["mode": store.mode.rawValue, "securityCalls": store.securityCalls])
        case "authorize":
          try store.authorize()
          result(nil)
        case "read": result(try store.read())
        case "write":
          guard let value = call.arguments as? String else {
            result(FlutterError(code: "invalid_argument", message: "Invalid credential data", details: nil))
            return
          }
          try store.write(value)
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch {
        // Do not include arguments, OS descriptions or credential contents.
        result(FlutterError(code: "credential_storage", message: "System credential storage unavailable", details: nil))
      }
    }
  }
}
