import Foundation
import Security

/// One item per application, never synchronised to another device or app.
final class KeychainStore {
  private let service: String
  init(service: String = "com.semanticcraft.soundcore.credentials") {
    self.service = service
  }
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: "engines-v1",
     kSecAttrSynchronizable as String: false]
  }
  struct Failure: Error { let status: OSStatus }

  func read() throws -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    guard let data = result as? Data,
          let text = String(data: data, encoding: .utf8) else {
      throw Failure(status: errSecDecode)
    }
    return text
  }

  func write(_ text: String) throws {
    var values: [String: Any] = [kSecValueData as String: Data(text.utf8)]
    #if os(iOS)
    values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      values.forEach { item[$0.key] = $0.value }
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }
}
