import Foundation
import Security

/// Drives one synthetic credential item through the real system keychain, so a
/// rebuilt executable can be checked against the access the previous build had.
@main
enum KeychainUpgrade {
  #if UPGRADE_SECOND
  static let buildMarker = "upgrade-second"
  #elseif BUILD_FIRST
  static let buildMarker = "adhoc-first"
  #elseif BUILD_SECOND
  static let buildMarker = "adhoc-second"
  #else
  static let buildMarker = "upgrade-first"
  #endif

  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3,
          arguments[2].hasPrefix("com.semanticcraft.koe.validation.") else {
      fatalError("A synthetic validation service is required")
    }
    let service = arguments[2]
    let store = KeychainStore(service: service, mode: .system)
    switch arguments[1] {
    case "write":
      try store.write("{\"qwen\":\"synthetic-upgrade-credential\"}")
    case "read":
      guard try store.read() == "{\"qwen\":\"synthetic-upgrade-credential\"}" else {
        fatalError("Readback failed")
      }
    case "delete":
      let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "engines-v1"] as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        fatalError("Cleanup failed")
      }
    default:
      fatalError("Unknown action")
    }
    print("PASS: \(arguments[1]) [\(buildMarker)]")
  }
}
