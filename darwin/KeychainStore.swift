import Foundation
import Security

/// One item per application, never synchronised to another device or app.
final class KeychainStore {
  /// Where one credential item lives. `isolated` keeps it inside this process
  /// so a development build can never read or migrate the user's credentials.
  enum Mode: String { case isolated, system }

  /// Development builds stay isolated. An ad-hoc signature changes with every
  /// rebuild, so the login keychain would ask for its password on each launch
  /// and the user's saved keys would remain unreachable anyway. macOS ships
  /// credentials only from a build carrying the Developer ID identity, and any
  /// explicitly requested development mode fails closed, including a typo.
  static var defaultMode: Mode {
    if ProcessInfo.processInfo.environment["KOE_CREDENTIAL_SOURCE"] != nil {
      return .isolated
    }
    #if DEBUG
      #if os(macOS)
      return .isolated
      #else
      return .system
      #endif
    #elseif os(macOS)
    var code: SecCode?
    var requirement: SecRequirement?
    let rule = """
      anchor apple generic and identifier "com.anker.ankerRecorder" and \
      certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
      certificate leaf[subject.OU] = "LQAVR62TK2"
      """
    guard SecCodeCopySelf([], &code) == errSecSuccess,
          let code,
          SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .isolated }
    return .system
    #else
    return .system
    #endif
  }

  let mode: Mode
  private var memory: String?
  private(set) var securityCalls = 0
  private let service: String
  init(service: String = "com.semanticcraft.soundcore.credentials", mode: Mode = defaultMode) {
    self.service = service
    self.mode = mode
  }
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: "engines-v1",
     kSecAttrSynchronizable as String: false]
  }
  struct Failure: Error { let status: OSStatus }

  func read() throws -> String? {
    if mode == .isolated { return memory }
    return try silently { try systemRead() }
  }

  private func systemRead() throws -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    securityCalls += 1
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
    if mode == .isolated { memory = text; return }
    try silently { try systemWrite(text) }
  }

  private func systemWrite(_ text: String) throws {
    var values: [String: Any] = [kSecValueData as String: Data(text.utf8)]
    #if os(iOS)
    values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    let request = query
    securityCalls += 1
    var status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var item = request
      values.forEach { item[$0.key] = $0.value }
      securityCalls += 1
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  /// Runs a keychain operation without any authorization prompt. An item whose
  /// access control list predates this build then fails fast, which is what
  /// keeps startup and automatic saves from asking for the keychain password;
  /// the explicit settings action performs that one authorization instead.
  private func silently<T>(_ body: () throws -> T) rethrows -> T {
    #if os(macOS)
    // kSecUseAuthenticationUIFail only covers access-control items; the login
    // keychain dialog for older items ignores it, so the process-wide switch is
    // the one that suppresses it (measured on macOS 26).
    SecKeychainSetUserInteractionAllowed(false)
    defer { SecKeychainSetUserInteractionAllowed(true) }
    #endif
    return try body()
  }

  /// Reads through the system so macOS can present its one-time authorization
  /// for an item written by an earlier build. Only the explicit settings action
  /// calls this; startup and automatic saves stay silent.
  func authorize() throws {
    guard mode == .system else { return }
    #if os(macOS)
    SecKeychainSetUserInteractionAllowed(true)
    #endif
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    securityCalls += 1
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    _ = result
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }
}
