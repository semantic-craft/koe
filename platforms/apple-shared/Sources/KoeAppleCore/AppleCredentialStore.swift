import Foundation
import os
import Security

public enum AppleCredentialFailure: Error, Equatable, Sendable {
    case invalidReference
    case unsupportedOperation
    case keychainError(OSStatus)
}

public enum AppleCredentialOperation: UInt32, Sendable {
    case read = 0
    case create = 1
    case delete = 2
    case readLegacy = 3
    case authorize = 4
    case prepare = 5
}

public enum AppleCredentialMode: Equatable, Sendable {
    case productionKeychain
    case isolated
    case environment(qwen: String?, deepseek: String?)

    public static func resolve(
        environment: [String: String],
        allowsSystemStorage: @autoclosure () -> Bool
    ) -> AppleCredentialMode {
        if environment["KOE_CREDENTIAL_SOURCE"] == "environment" {
            return .environment(
                qwen: cleanEnvironmentSecret(environment["DASHSCOPE_API_KEY"]),
                deepseek: cleanEnvironmentSecret(environment["DEEPSEEK_API_KEY"])
            )
        }
        return allowsSystemStorage() ? .productionKeychain : .isolated
    }

    private static func cleanEnvironmentSecret(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum AppleKeychainAccessibility: Equatable, Sendable {
    case platformDefault
    case afterFirstUnlockThisDeviceOnly
}

public struct AppleKeychainQuery: Equatable, Sendable {
    public let service: String
    public let account: String
    public let accessibility: AppleKeychainAccessibility

    public init(
        service: String,
        account: String,
        accessibility: AppleKeychainAccessibility = .platformDefault
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
    }
}

public enum AppleKeychainReadResult: Equatable, Sendable {
    case found(Data)
    case notFound
    case failure(OSStatus)
}

public protocol AppleKeychainInteractionGate: Sendable {
    func run(interactive: Bool, _ body: () -> Void) -> OSStatus
}

public protocol AppleKeychainBackend: Sendable {
    func copyData(for query: AppleKeychainQuery, interactive: Bool) -> AppleKeychainReadResult
    func add(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus
    func update(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus
    func delete(for query: AppleKeychainQuery, interactive: Bool) -> OSStatus
}

public struct SystemAppleKeychainBackend: AppleKeychainBackend {
    private let interactionGate: (any AppleKeychainInteractionGate)?

    public init(interactionGate: (any AppleKeychainInteractionGate)? = nil) {
        self.interactionGate = interactionGate
    }

    public func copyData(for query: AppleKeychainQuery, interactive: Bool) -> AppleKeychainReadResult {
        var request = baseQuery(query)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var readResult: AppleKeychainReadResult = .notFound
        let gateStatus = runUnderGate(interactive: interactive) {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &item)
            if status == errSecItemNotFound {
                readResult = .notFound
            } else if status == errSecSuccess, let data = item as? Data {
                readResult = .found(data)
            } else if status == errSecSuccess {
                readResult = .failure(errSecDecode)
            } else {
                readResult = .failure(status)
            }
        }
        guard gateStatus == errSecSuccess else { return .failure(gateStatus) }
        return readResult
    }

    public func add(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
        var item = baseQuery(query)
        applyAccessibility(query.accessibility, to: &item)
        item[kSecValueData as String] = data
        var status: OSStatus = errSecSuccess
        let gateStatus = runUnderGate(interactive: interactive) {
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return gateStatus == errSecSuccess ? status : gateStatus
    }

    public func update(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
        let match = baseQuery(query)
        var attributes: [String: Any] = [kSecValueData as String: data]
        applyAccessibility(query.accessibility, to: &attributes)
        var status: OSStatus = errSecSuccess
        let gateStatus = runUnderGate(interactive: interactive) {
            status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        }
        return gateStatus == errSecSuccess ? status : gateStatus
    }

    public func delete(for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
        let match = baseQuery(query)
        var status: OSStatus = errSecSuccess
        let gateStatus = runUnderGate(interactive: interactive) {
            status = SecItemDelete(match as CFDictionary)
        }
        return gateStatus == errSecSuccess ? status : gateStatus
    }

    private func runUnderGate(interactive: Bool, _ body: () -> Void) -> OSStatus {
        guard let interactionGate else {
            body()
            return errSecSuccess
        }
        return interactionGate.run(interactive: interactive, body)
    }

    private func baseQuery(_ query: AppleKeychainQuery) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: query.service,
            kSecAttrAccount as String: query.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func applyAccessibility(_ accessibility: AppleKeychainAccessibility, to dictionary: inout [String: Any]) {
        switch accessibility {
        case .platformDefault:
            break
        case .afterFirstUnlockThisDeviceOnly:
            dictionary[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

public final class AppleCredentialStore: HostCredentials {
    public static let service = "com.semanticcraft.koe.provider.credentials"
    public static let legacyService = "com.semanticcraft.soundcore.credentials"
    public static let legacyAccount = "engines-v1"
    public static let maxSecretBytes = 65_536

    private static let maxReferenceBytes = 128
    private static let envQwenPrefix = "isolated-environment-qwen-"
    private static let envDeepSeekPrefix = "isolated-environment-deepseek-"
    private static let isolatedPrefix = "isolated-"
    private static let keychainLock = OSAllocatedUnfairLock()

    private struct IsolatedState: Sendable {
        var memory: [String: String] = [:]
        var deleted: Set<String> = []
    }

    private let mode: AppleCredentialMode
    private let accessibility: AppleKeychainAccessibility
    private let keychain: any AppleKeychainBackend
    private let isolatedState = OSAllocatedUnfairLock(initialState: IsolatedState())

    public var isolated: Bool {
        if case .productionKeychain = mode { return false }
        return true
    }

    public init(
        mode: AppleCredentialMode,
        accessibility: AppleKeychainAccessibility = .platformDefault,
        keychain: any AppleKeychainBackend = SystemAppleKeychainBackend()
    ) {
        self.mode = mode
        self.accessibility = accessibility
        self.keychain = keychain
    }

    public func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        guard let op = AppleCredentialOperation(rawValue: operation) else {
            throw AppleCredentialFailure.unsupportedOperation
        }
        if isolated {
            return try performIsolated(op, reference: reference, value: value)
        }
        if op == .prepare {
            return UUID().uuidString.lowercased()
        }
        return try Self.keychainLock.withLock {
            try performKeychain(op, reference: reference, value: value)
        }
    }

    private func performIsolated(_ op: AppleCredentialOperation, reference: String, value: String) throws -> String? {
        try isolatedState.withLock { state in
            switch op {
            case .read:
                guard isValidIsolatedReadReference(reference) else {
                    throw AppleCredentialFailure.invalidReference
                }
                if let stored = state.memory[reference] { return stored }
                guard case .environment(let qwen, let deepseek) = mode,
                      !state.deleted.contains(reference) else {
                    return nil
                }
                if reference.hasPrefix(Self.envQwenPrefix) { return qwen }
                if reference.hasPrefix(Self.envDeepSeekPrefix) { return deepseek }
                return nil
            case .create:
                guard isValidIsolatedWriteReference(reference, for: value) else {
                    throw AppleCredentialFailure.invalidReference
                }
                state.memory[reference] = value
                state.deleted.remove(reference)
                return reference
            case .delete:
                guard isValidIsolatedNamespaceReference(reference) else {
                    throw AppleCredentialFailure.invalidReference
                }
                state.memory.removeValue(forKey: reference)
                state.deleted.insert(reference)
                return ""
            case .readLegacy:
                guard case .environment(let qwen, let deepseek) = mode else { return nil }
                var payload: [String: String] = [:]
                if let qwen { payload["qwen"] = qwen }
                if let deepseek { payload["deepseek"] = deepseek }
                guard !payload.isEmpty else { return nil }
                let encoded = try JSONEncoder().encode(payload)
                guard let text = String(bytes: encoded, encoding: .utf8) else {
                    throw AppleCredentialFailure.keychainError(errSecDecode)
                }
                return text
            case .authorize:
                return ""
            case .prepare:
                return isolatedReferencePrefix(slot: reference, value: value) + UUID().uuidString.lowercased()
            }
        }
    }

    private func performKeychain(_ op: AppleCredentialOperation, reference: String, value: String) throws -> String? {
        switch op {
        case .read:
            guard UUID(uuidString: reference) != nil else { throw AppleCredentialFailure.invalidReference }
            return try readKeychain(query: itemQuery(account: reference, legacy: false), interactive: false)
        case .create:
            guard UUID(uuidString: reference) != nil else { throw AppleCredentialFailure.invalidReference }
            let query = itemQuery(account: reference, legacy: false)
            let data = Data(value.utf8)
            let status = keychain.add(data, for: query, interactive: false)
            if status == errSecDuplicateItem {
                let updateStatus = keychain.update(data, for: query, interactive: false)
                guard updateStatus == errSecSuccess else { throw AppleCredentialFailure.keychainError(updateStatus) }
                return reference
            }
            guard status == errSecSuccess else { throw AppleCredentialFailure.keychainError(status) }
            return reference
        case .delete:
            if isValidIsolatedNamespaceReference(reference) {
                return ""
            }
            guard UUID(uuidString: reference) != nil else { throw AppleCredentialFailure.invalidReference }
            let status = keychain.delete(for: itemQuery(account: reference, legacy: false), interactive: false)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppleCredentialFailure.keychainError(status)
            }
            return ""
        case .readLegacy:
            return try readKeychain(query: itemQuery(account: Self.legacyAccount, legacy: true), interactive: false)
        case .authorize:
            if reference.isEmpty {
                _ = try readKeychain(query: itemQuery(account: Self.legacyAccount, legacy: true), interactive: true)
            } else if isValidIsolatedNamespaceReference(reference) {
                return ""
            } else {
                guard UUID(uuidString: reference) != nil else { throw AppleCredentialFailure.invalidReference }
                _ = try readKeychain(query: itemQuery(account: reference, legacy: false), interactive: true)
            }
            return ""
        case .prepare:
            return UUID().uuidString.lowercased()
        }
    }

    private func itemQuery(account: String, legacy: Bool) -> AppleKeychainQuery {
        AppleKeychainQuery(
            service: legacy ? Self.legacyService : Self.service,
            account: account,
            accessibility: accessibility
        )
    }

    private func readKeychain(query: AppleKeychainQuery, interactive: Bool) throws -> String? {
        switch keychain.copyData(for: query, interactive: interactive) {
        case .notFound:
            return nil
        case .found(let data):
            guard data.count <= Self.maxSecretBytes,
                  let text = String(data: data, encoding: .utf8) else {
                throw AppleCredentialFailure.keychainError(errSecDecode)
            }
            return text
        case .failure(let status):
            throw AppleCredentialFailure.keychainError(status)
        }
    }

    private func isValidIsolatedNamespaceReference(_ reference: String) -> Bool {
        guard reference.hasPrefix(Self.isolatedPrefix),
              reference.utf8.count <= Self.maxReferenceBytes else {
            return false
        }
        let suffix = reference.dropFirst(Self.isolatedPrefix.count)
        guard !suffix.isEmpty else { return false }
        return suffix.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
        }
    }

    private func isValidIsolatedReadReference(_ reference: String) -> Bool {
        for prefix in [Self.envQwenPrefix, Self.envDeepSeekPrefix, Self.isolatedPrefix] where reference.hasPrefix(prefix) {
            return UUID(uuidString: String(reference.dropFirst(prefix.count))) != nil
        }
        return false
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
        guard reference.hasPrefix(Self.isolatedPrefix) else { return false }
        return UUID(uuidString: String(reference.dropFirst(Self.isolatedPrefix.count))) != nil
    }

    private func isolatedReferencePrefix(slot: String, value: String) -> String {
        if case .environment(let qwen, let deepseek) = mode {
            if slot == "qwen" {
                return qwen == value ? Self.envQwenPrefix : Self.isolatedPrefix
            }
            if slot == "deepseek" {
                return deepseek == value ? Self.envDeepSeekPrefix : Self.isolatedPrefix
            }
            if deepseek == value { return Self.envDeepSeekPrefix }
            if qwen == value { return Self.envQwenPrefix }
        }
        return Self.isolatedPrefix
    }
}
