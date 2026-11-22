import Foundation
import KoeAppleShared
import os
import Security

final class NativeCredentials: HostCredentials {
    enum Failure: Error { case unavailable }
    private enum Source: Sendable {
        case productionKeychain
        case isolated
        case environment(qwen: String?, deepseek: String?)
    }
    private struct IsolatedState: Sendable {
        var memory: [String: String] = [:]
        var deleted: Set<String> = []
    }
    private static let lock = NSLock()
    private static let service = "com.semanticcraft.koe.provider.credentials"
    private static let legacyService = "com.semanticcraft.soundcore.credentials"
    private static let environmentQwenReferencePrefix = "isolated-environment-qwen-"
    private static let environmentDeepSeekReferencePrefix = "isolated-environment-deepseek-"
    private let source: Source
    private let isolatedState = OSAllocatedUnfairLock(initialState: IsolatedState())
    var isolated: Bool {
        if case .productionKeychain = source { return false }
        return true
    }

    static func allowsSystemStorage(debug: Bool, sourceOverride: Bool, workspaceOverride: Bool, trusted: Bool) -> Bool {
        !debug && !sourceOverride && !workspaceOverride && trusted
    }

    init(workspaceOverride: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        if environment["KOE_CREDENTIAL_SOURCE"] == "environment" {
            let clean: (String?) -> String? = { raw in
                guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                    return nil
                }
                return trimmed
            }
            source = .environment(
                qwen: clean(environment["DASHSCOPE_API_KEY"]),
                deepseek: clean(environment["DEEPSEEK_API_KEY"])
            )
        } else if Self.allowsSystemStorage(
            debug: debug,
            sourceOverride: environment["KOE_CREDENTIAL_SOURCE"] != nil,
            workspaceOverride: workspaceOverride,
            trusted: Self.trustedSignature()
        ) {
            source = .productionKeychain
        } else {
            source = .isolated
        }
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
        if isolated { return try isolatedOperation(operation, reference, value) }
        if operation == 5 { return UUID().uuidString.lowercased() }
        var wasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(operation == 4) == errSecSuccess else { throw Failure.unavailable }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        switch operation {
        case 0: return try read(reference)
        case 1:
            guard UUID(uuidString: reference) != nil else { throw Failure.unavailable }
            var item = query(reference)
            item[kSecValueData as String] = Data(value.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
            return reference
        case 2:
            guard UUID(uuidString: reference) != nil else { return "" }
            let status = SecItemDelete(query(reference) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
            return ""
        case 3: return try read("engines-v1", legacy: true)
        case 4:
            if reference.isEmpty {
                _ = try read("engines-v1", legacy: true)
            } else {
                _ = try read(reference)
            }
            return ""
        default: throw Failure.unavailable
        }
    }

    private func isolatedOperation(_ operation: UInt32, _ reference: String, _ value: String) throws -> String? {
        try isolatedState.withLock { state in
            switch operation {
            case 0:
                if let value = state.memory[reference] { return value }
                guard case .environment(let qwen, let deepseek) = source,
                      !state.deleted.contains(reference) else { return nil }
                if reference.hasPrefix(Self.environmentQwenReferencePrefix),
                   UUID(uuidString: String(reference.dropFirst(Self.environmentQwenReferencePrefix.count))) != nil {
                    return qwen
                }
                if reference.hasPrefix(Self.environmentDeepSeekReferencePrefix),
                   UUID(uuidString: String(reference.dropFirst(Self.environmentDeepSeekReferencePrefix.count))) != nil {
                    return deepseek
                }
                return nil
            case 1:
                guard isValidIsolatedReference(reference, for: value) else { throw Failure.unavailable }
                state.memory[reference] = value
                return reference
            case 2:
                state.memory.removeValue(forKey: reference)
                state.deleted.insert(reference)
                return ""
            case 3:
                guard case .environment(let qwen, let deepseek) = source else { return nil }
                var payload: [String: String] = [:]
                if let qwen { payload["qwen"] = qwen }
                if let deepseek { payload["deepseek"] = deepseek }
                guard !payload.isEmpty else { return nil }
                guard let encoded = String(bytes: try JSONEncoder().encode(payload), encoding: .utf8) else {
                    throw Failure.unavailable
                }
                return encoded
            case 4: return ""
            case 5: return isolatedPrefix(value: value, slot: reference) + UUID().uuidString.lowercased()
            default: throw Failure.unavailable
            }
        }
    }

    private func isValidIsolatedReference(_ reference: String, for value: String) -> Bool {
        if reference.hasPrefix(Self.environmentQwenReferencePrefix) {
            guard case .environment(let qwen, _) = source, qwen == value else { return false }
            return UUID(uuidString: String(reference.dropFirst(Self.environmentQwenReferencePrefix.count))) != nil
        }
        if reference.hasPrefix(Self.environmentDeepSeekReferencePrefix) {
            guard case .environment(_, let deepseek) = source, deepseek == value else { return false }
            return UUID(uuidString: String(reference.dropFirst(Self.environmentDeepSeekReferencePrefix.count))) != nil
        }
        guard reference.hasPrefix("isolated-") else { return false }
        return UUID(uuidString: String(reference.dropFirst("isolated-".count))) != nil
    }

    private func isolatedPrefix(value: String, slot: String = "") -> String {
        if case .environment(let qwen, let deepseek) = source {
            if slot == "qwen" {
                return qwen == value ? Self.environmentQwenReferencePrefix : "isolated-"
            }
            if slot == "deepseek" {
                return deepseek == value ? Self.environmentDeepSeekReferencePrefix : "isolated-"
            }
            if deepseek == value { return Self.environmentDeepSeekReferencePrefix }
            if qwen == value { return Self.environmentQwenReferencePrefix }
        }
        return "isolated-"
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
