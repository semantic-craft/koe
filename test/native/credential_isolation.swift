import Foundation
import Security

// Any Security entry point aborts the process, so a development build that
// reaches the login keychain fails here instead of asking for a password.
@_cdecl("SecItemCopyMatching")
func spyCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
  fatalError("REGRESSION: credential read reached Security")
}

@_cdecl("SecItemUpdate")
func spyUpdate(_ query: CFDictionary, _ values: CFDictionary) -> OSStatus {
  fatalError("REGRESSION: credential update reached Security")
}

@_cdecl("SecItemAdd")
func spyAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
  fatalError("REGRESSION: credential add reached Security")
}

@main
enum CredentialIsolation {
  static func main() throws {
    #if REACHES_SECURITY
    // Falsification check for the spy itself: this build must be intercepted.
    let store = KeychainStore(service: "com.semanticcraft.koe.validation.spy", mode: .system)
    _ = try store.read()
    print("FAIL: the Security spy did not intercept a system read")
    exit(1)
    #else
    let store = KeychainStore()
    guard store.mode == .isolated else { fatalError("Development credentials must stay isolated") }
    guard try store.read() == nil else { fatalError("Unexpected credential") }
    try store.write("{\"qwen\":\"synthetic-only\"}")
    guard try store.read() == "{\"qwen\":\"synthetic-only\"}" else { fatalError("Readback failed") }
    try store.authorize()
    guard store.securityCalls == 0 else { fatalError("Reached the system keychain") }
    print("PASS: development credentials stay inside the process")
    #endif
  }
}
