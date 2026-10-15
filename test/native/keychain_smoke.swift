import Foundation
import Security

@main
enum KeychainSmoke {
  static func main() throws {
    let service = "com.semanticcraft.koe.validation.\(UUID().uuidString)"
    let store = KeychainStore(service: service)
    defer {
      SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                     kSecAttrService as String: service,
                     kSecAttrAccount as String: "engines-v1"] as CFDictionary)
    }
    guard try store.read() == nil else { fatalError("Unexpected initial item") }
    try store.write("{\"qwen\":\"synthetic-first\"}")
    guard try store.read() == "{\"qwen\":\"synthetic-first\"}" else { fatalError("Readback failed") }
    try store.write("{\"qwen\":\"synthetic-second\"}")
    guard try store.read() == "{\"qwen\":\"synthetic-second\"}" else { fatalError("Replacement failed") }
    try store.write("{\"qwen\":null}")
    guard try store.read() == "{\"qwen\":null}" else { fatalError("Clear failed") }
    print("macOS system Keychain synthetic write/read/replace/clear: PASS")
  }
}
