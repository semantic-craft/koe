import Foundation
import KoeAppleCore
import os
import Security

final class NativeCredentialsiOS: HostCredentials {
    enum Failure: Error, Equatable {
        case invalidReference
        case unsupportedOperation
        case keychainError(OSStatus)
    }

    private enum Mode: Sendable {
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
    private static let envQwenPrefix = "isolated-environment-qwen-"
    private static let envDeepSeekPrefix = "isolated-environment-deepseek-"

    private let mode: Mode
    private let isolatedState = OSAllocatedUnfairLock(initialState: IsolatedState())

    var isolated: Bool {
        if case .productionKeychain = mode { return false }
        return true
    }

    init(
        workspaceOverride: Bool = false,
        forceIsolated: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        if environment["KOE_CREDENTIAL_SOURCE"] == "environment" {
            let clean: (String?) -> String? = { raw in
                guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                    return nil
                }
                return trimmed
            }
            mode = .environment(
                qwen: clean(environment["DASHSCOPE_API_KEY"]),
                deepseek: clean(environment["DEEPSEEK_API_KEY"])
            )
        } else if forceIsolated || isDebug || workspaceOverride || environment["KOE_CREDENTIAL_SOURCE"] != nil {
            mode = .isolated
        } else {
            mode = .productionKeychain
        }
    }

    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if isolated {
            return try performIsolated(operation: operation, reference: reference, value: value)
        }
        return try performKeychain(operation: operation, reference: reference, value: value)
    }

    private func performIsolated(operation: UInt32, reference: String, value: String) throws -> String? {
        try isolatedState.withLock { state in
            switch operation {
            case 0:
                guard !reference.isEmpty, isValidIsolatedReadReference(reference) else {
                    throw Failure.invalidReference
                }
                if let stored = state.memory[reference] { return stored }
                guard case .environment(let qwen, let deepseek) = mode, !state.deleted.contains(reference) else {
                    return nil
                }
                if reference.hasPrefix(Self.envQwenPrefix) { return qwen }
                if reference.hasPrefix(Self.envDeepSeekPrefix) { return deepseek }
                return nil
            case 1:
                guard isValidIsolatedWriteReference(reference, for: value) else {
                    throw Failure.invalidReference
                }
                state.memory[reference] = value
                state.deleted.remove(reference)
                return reference
            case 2:
                guard isValidIsolatedReadReference(reference) else {
                    throw Failure.invalidReference
                }
                state.memory.removeValue(forKey: reference)
                state.deleted.insert(reference)
                return ""
            case 3:
                guard case .environment(let qwen, let deepseek) = mode else { return nil }
                var payload: [String: String] = [:]
                if let qwen { payload["qwen"] = qwen }
                if let deepseek { payload["deepseek"] = deepseek }
                guard !payload.isEmpty else { return nil }
                let encoded = try JSONEncoder().encode(payload)
                guard let text = String(bytes: encoded, encoding: .utf8) else {
                    throw Failure.keychainError(errSecDecode)
                }
                return text
            case 4:
                return ""
            case 5:
                return isolatedPrefix(slot: reference, value: value) + UUID().uuidString.lowercased()
            default:
                throw Failure.unsupportedOperation
            }
        }
    }

    private func performKeychain(operation: UInt32, reference: String, value: String) throws -> String? {
        switch operation {
        case 0:
            guard UUID(uuidString: reference) != nil else { throw Failure.invalidReference }
            return try readKeychain(reference: reference, legacy: false)
        case 1:
            guard UUID(uuidString: reference) != nil else { throw Failure.invalidReference }
            var item = keychainQuery(reference: reference, legacy: false)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = Data(value.utf8)
            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                let query = keychainQuery(reference: reference, legacy: false)
                let update: [String: Any] = [
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: Data(value.utf8),
                ]
                let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
                guard updateStatus == errSecSuccess else { throw Failure.keychainError(updateStatus) }
                return reference
            }
            guard status == errSecSuccess else { throw Failure.keychainError(status) }
            return reference
        case 2:
            guard UUID(uuidString: reference) != nil else { throw Failure.invalidReference }
            let status = SecItemDelete(keychainQuery(reference: reference, legacy: false) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychainError(status)
            }
            return ""
        case 3:
            return try readKeychain(reference: "engines-v1", legacy: true)
        case 4:
            if reference.isEmpty {
                _ = try readKeychain(reference: "engines-v1", legacy: true)
            } else {
                guard UUID(uuidString: reference) != nil else { throw Failure.invalidReference }
                _ = try readKeychain(reference: reference, legacy: false)
            }
            return ""
        case 5:
            return UUID().uuidString.lowercased()
        default:
            throw Failure.unsupportedOperation
        }
    }

    private func keychainQuery(reference: String, legacy: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy ? Self.legacyService : Self.service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func readKeychain(reference: String, legacy: Bool) throws -> String? {
        var request = keychainQuery(reference: reference, legacy: legacy)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychainError(status) }
        guard let data = result as? Data,
              data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else {
            throw Failure.keychainError(errSecDecode)
        }
        return text
    }

    private func isValidIsolatedReadReference(_ reference: String) -> Bool {
        if reference.hasPrefix(Self.envQwenPrefix) {
            return UUID(uuidString: String(reference.dropFirst(Self.envQwenPrefix.count))) != nil
        }
        if reference.hasPrefix(Self.envDeepSeekPrefix) {
            return UUID(uuidString: String(reference.dropFirst(Self.envDeepSeekPrefix.count))) != nil
        }
        guard reference.hasPrefix("isolated-") else { return false }
        return UUID(uuidString: String(reference.dropFirst("isolated-".count))) != nil
    }

    private func isValidIsolatedWriteReference(_ reference: String, for value: String) -> Bool {
        if reference.hasPrefix(Self.envQwenPrefix) {
            guard case .environment(let qwen, _) = mode, qwen == value else { return false }
            return UUID(uuidString: String(reference.dropFirst(Self.envQwenPrefix.count))) != nil
        }
        if reference.hasPrefix(Self.envDeepSeekPrefix) {
            guard case .environment(_, let deepseek) = mode, deepseek == value else { return false }
            return UUID(uuidString: String(reference.dropFirst(Self.envDeepSeekPrefix.count))) != nil
        }
        guard reference.hasPrefix("isolated-") else { return false }
        return UUID(uuidString: String(reference.dropFirst("isolated-".count))) != nil
    }

    private func isolatedPrefix(slot: String, value: String) -> String {
        if case .environment(let qwen, let deepseek) = mode {
            if slot == "qwen" {
                return qwen == value ? Self.envQwenPrefix : "isolated-"
            }
            if slot == "deepseek" {
                return deepseek == value ? Self.envDeepSeekPrefix : "isolated-"
            }
            if deepseek == value { return Self.envDeepSeekPrefix }
            if qwen == value { return Self.envQwenPrefix }
        }
        return "isolated-"
    }
}
