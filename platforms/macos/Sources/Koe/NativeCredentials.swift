import Foundation
import KoeAppleShared
import Security

final class NativeCredentials: HostCredentials {
    enum Failure: Error { case unavailable }
    private static let lock = NSLock()
    private static let service = "com.semanticcraft.koe.provider.credentials"
    private static let legacyService = "com.semanticcraft.soundcore.credentials"
    private let system: Bool
    private var memory: [String: String] = [:]
    var isolated: Bool { !system }

    static func allowsSystemStorage(debug: Bool, sourceOverride: Bool, workspaceOverride: Bool, trusted: Bool) -> Bool {
        !debug && !sourceOverride && !workspaceOverride && trusted
    }

    init(workspaceOverride: Bool) {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        system = Self.allowsSystemStorage(
            debug: debug,
            sourceOverride: ProcessInfo.processInfo.environment["KOE_CREDENTIAL_SOURCE"] != nil,
            workspaceOverride: workspaceOverride,
            trusted: Self.trustedSignature()
        )
    }

    private static func trustedSignature() -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let rule = """
        anchor apple generic and identifier "com.anker.ankerRecorder" and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "LQAVR62TK2"
        """
        return SecCodeCopySelf([], &code) == errSecSuccess
            && SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }

    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if !system { return try isolatedOperation(operation, reference, value) }
        var wasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(operation == 4) == errSecSuccess else { throw Failure.unavailable }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        switch operation {
        case 0: return try read(reference)
        case 1:
            let id = UUID().uuidString.lowercased()
            var item = query(id)
            item[kSecValueData as String] = Data(value.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
            return id
        case 2:
            guard UUID(uuidString: reference) != nil else { return "" }
            let status = SecItemDelete(query(reference) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
            return ""
        case 3: return try read("engines-v1", legacy: true)
        case 4:
            if reference.isEmpty { _ = try read("engines-v1", legacy: true) }
            else { _ = try read(reference) }
            return ""
        default: throw Failure.unavailable
        }
    }

    private func isolatedOperation(_ operation: UInt32, _ reference: String, _ value: String) throws -> String? {
        switch operation {
        case 0: return memory[reference]
        case 1:
            let id = "isolated-" + UUID().uuidString.lowercased()
            memory[id] = value
            return id
        case 2: memory.removeValue(forKey: reference); return ""
        case 3: return nil
        case 4: return ""
        default: throw Failure.unavailable
        }
    }

    private func query(_ reference: String, legacy: Bool = false) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: legacy ? Self.legacyService : Self.service,
         kSecAttrAccount as String: reference,
         kSecAttrSynchronizable as String: false]
    }

    private func read(_ reference: String, legacy: Bool = false) throws -> String? {
        if !legacy && UUID(uuidString: reference) == nil { return nil }
        var request = query(reference, legacy: legacy)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              data.count <= 65_536, let text = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
        return text
    }
}
