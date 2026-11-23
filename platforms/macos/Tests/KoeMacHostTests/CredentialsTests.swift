import Foundation
import KoeMacUI
import os
import Security
import Testing
@testable import Koe

private final class FixtureCredentials: HostCredentials {
    private struct State: Sendable {
        var items: [String: String] = [:]
        var failRead = false
        var operations: [UInt32] = []
        var afterCreate: (@Sendable () -> Void)?
    }

    let isolated = false
    private let state = OSAllocatedUnfairLock(initialState: State())

    var items: [String: String] {
        get { state.withLock(\.items) }
        set { state.withLock { $0.items = newValue } }
    }
    var failRead: Bool {
        get { state.withLock(\.failRead) }
        set { state.withLock { $0.failRead = newValue } }
    }
    var operations: [UInt32] {
        state.withLock(\.operations)
    }
    var afterCreate: (@Sendable () -> Void)? {
        get { state.withLock(\.afterCreate) }
        set { state.withLock { $0.afterCreate = newValue } }
    }

    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        let (result, callback): (String?, (@Sendable () -> Void)?) = try state.withLock { state in
            state.operations.append(operation)
            switch operation {
            case 0:
                if state.failRead { throw NativeCredentials.Failure.keychainError(errSecAuthFailed) }
                return (state.items[reference], nil)
            case 1:
                state.items[reference] = value
                return (reference, state.afterCreate)
            case 2:
                state.items.removeValue(forKey: reference)
                return ("", nil)
            case 3: return (nil, nil)
            case 4: return ("", nil)
            case 5: return (UUID().uuidString.lowercased(), nil)
            default: throw NativeCredentials.Failure.unsupportedOperation
            }
        }
        callback?()
        return result
    }
}

@Suite("Secure credential adapter and host bridge")
@MainActor
struct CredentialsTests {
    @Test("The host callback restores saved credentials, reports failures and persists clear")
    func restart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-credentials-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FixtureCredentials()
        let first = HostSessionStore(workspacePath: root.path, credentials: vault)
        first.send(.configureProvider(apiKey: "fixture-only-secret", deepseekApiKey: "fixture-ds-secret", model: "deepseek-flash"))
        #expect(first.snapshot.provider.qwenConfigured)
        #expect(first.snapshot.provider.asrConfigured)
        #expect(first.snapshot.provider.deepseekConfigured)
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.model == "deepseek-flash")
        #expect(first.nativeError == nil)
        first.shutdown()
        let reopened = HostSessionStore(workspacePath: root.path, credentials: vault)
        #expect(reopened.snapshot.provider.qwenConfigured)
        #expect(reopened.snapshot.provider.deepseekConfigured)
        #expect(reopened.snapshot.provider.configured)
        #expect(reopened.snapshot.provider.model == "deepseek-flash")
        let data = try Data(contentsOf: root.appendingPathComponent("product-workspace.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-only-secret"))
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-ds-secret"))
        let snapshot = try JSONEncoder().encode(reopened.snapshot)
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("fixture-only-secret"))
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("fixture-ds-secret"))
        vault.failRead = true
        reopened.send(.retryProviderCredentials())
        #expect(reopened.snapshot.provider.credentialState == "unavailable")
        #expect(reopened.snapshot.provider.deepseekCredentialState == "unavailable")
        #expect(!reopened.snapshot.provider.configured)
        vault.failRead = false
        reopened.send(.retryProviderCredentials(authorize: true))
        #expect(reopened.snapshot.provider.qwenConfigured)
        #expect(reopened.snapshot.provider.configured)
        #expect(vault.operations.contains(4))
        reopened.send(.clearProviderCredential())
        #expect(!reopened.snapshot.provider.qwenConfigured)
        #expect(reopened.snapshot.provider.configured)
        reopened.send(.clearProviderCredential(provider: "deepseek"))
        #expect(!reopened.snapshot.provider.configured)
        reopened.shutdown()
        let cleared = HostSessionStore(workspacePath: root.path, credentials: vault)
        defer { cleared.shutdown() }
        #expect(cleared.snapshot.provider.credentialState == "cleared")
        #expect(cleared.snapshot.provider.deepseekCredentialState == "cleared")
        #expect(vault.items.isEmpty)
    }

    @Test("A secure item created before a crashed workspace commit is reclaimed on reopen")
    func crashOrphanReclaimed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("koe-orphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("crashed"), other = base.appendingPathComponent("other")
        let vault = FixtureCredentials()
        let neighbour = HostSessionStore(workspacePath: other.path, credentials: vault)
        neighbour.send(.configureProvider(apiKey: "other-fixture-secret", model: "other-model"))
        #expect(neighbour.snapshot.provider.qwenConfigured)
        neighbour.shutdown()
        let file = root.appendingPathComponent("product-workspace.json")
        let crashed = OSAllocatedUnfairLock<Data?>(initialState: nil)
        vault.afterCreate = { crashed.withLock { $0 = try? Data(contentsOf: file) } }
        let first = HostSessionStore(workspacePath: root.path, credentials: vault)
        first.send(.configureProvider(apiKey: "orphan-fixture-secret", model: "fixture-model"))
        #expect(first.snapshot.provider.qwenConfigured)
        first.shutdown()
        vault.afterCreate = nil
        // Replay the disk state captured at the moment the item was created.
        try? FileManager.default.removeItem(at: file)
        if let crashedData = crashed.withLock({ $0 }) { try crashedData.write(to: file) }
        #expect(vault.items.values.contains("orphan-fixture-secret"))
        let reopened = HostSessionStore(workspacePath: root.path, credentials: vault)
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.provider.credentialState == "missing")
        #expect(reopened.nativeError == nil)
        #expect(Array(vault.items.values) == ["other-fixture-secret"])
        let neighbourReopened = HostSessionStore(workspacePath: other.path, credentials: vault)
        defer { neighbourReopened.shutdown() }
        #expect(neighbourReopened.snapshot.provider.qwenConfigured)
    }

    @Test("An explicit workspace uses session-only credentials through the real native adapter")
    func isolatedNativeAdapter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-isolated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = NativeCredentials(workspaceOverride: true, environment: ["DASHSCOPE_API_KEY": "ignored-fixture", "DEEPSEEK_API_KEY": "ignored-ds"])
        #expect(native.isolated)
        let first = HostSessionStore(workspacePath: root.path, credentials: native)
        #expect(!first.snapshot.provider.configured)
        #expect(!first.snapshot.provider.qwenConfigured)
        first.send(.configureProvider(apiKey: "isolated-fixture", deepseekApiKey: "isolated-ds", model: "deepseek-flash"))
        #expect(first.snapshot.provider.qwenConfigured)
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.isolated)
        first.shutdown()
        let second = HostSessionStore(workspacePath: root.path, credentials: NativeCredentials(
            workspaceOverride: true, environment: ["KOE_CREDENTIAL_SOURCE": "isolated", "DASHSCOPE_API_KEY": "ignored-fixture", "DEEPSEEK_API_KEY": "ignored-ds"]))
        defer { second.shutdown() }
        #expect(!second.snapshot.provider.configured)
        #expect(!second.snapshot.provider.qwenConfigured)
        #expect(second.snapshot.provider.model == "deepseek-flash")
        second.send(.clearProviderCredential())
        #expect(second.snapshot.provider.credentialState == "cleared")
    }

    @Test("Explicit environment credentials configure a new workspace, survive restart and respect clear")
    func environmentLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "KOE_CREDENTIAL_SOURCE": "environment",
            "DASHSCOPE_API_KEY": "environment-fixture-secret",
            "DEEPSEEK_API_KEY": "environment-deepseek-secret"
        ]
        let first = HostSessionStore(workspacePath: root.path,
                                     credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        #expect(first.snapshot.provider.qwenConfigured)
        #expect(first.snapshot.provider.asrConfigured)
        #expect(first.snapshot.provider.deepseekConfigured)
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.isolated)
        #expect(first.nativeError == nil)
        first.shutdown()

        let missing = HostSessionStore(workspacePath: root.path, credentials: NativeCredentials(
            workspaceOverride: true, environment: ["KOE_CREDENTIAL_SOURCE": "environment"]))
        #expect(!missing.snapshot.provider.qwenConfigured)
        #expect(!missing.snapshot.provider.configured)
        #expect(missing.snapshot.provider.credentialState == "missing_saved")
        #expect(missing.snapshot.provider.deepseekCredentialState == "missing_saved")
        missing.shutdown()

        let reopened = HostSessionStore(workspacePath: root.path,
                                        credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.provider.qwenConfigured)
        #expect(reopened.snapshot.provider.configured)
        let workspace = try String(contentsOf: root.appendingPathComponent("product-workspace.json"), encoding: .utf8)
        #expect(!workspace.contains("environment-fixture-secret"))
        #expect(!workspace.contains("environment-deepseek-secret"))
        let snapshot = try JSONEncoder().encode(reopened.snapshot)
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("environment-fixture-secret"))
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("environment-deepseek-secret"))
        reopened.send(.configureProvider(apiKey: "environment-fixture-secret", model: "deepseek-flash"))
        #expect(reopened.snapshot.provider.model == "deepseek-flash")
        reopened.send(.configureProvider(apiKey: "manual-fixture-secret", model: "deepseek-v4-pro"))
        #expect(reopened.snapshot.provider.qwenConfigured)
        #expect(reopened.snapshot.provider.model == "deepseek-v4-pro")
        reopened.send(.retryProviderCredentials())
        #expect(reopened.snapshot.provider.qwenConfigured)
        reopened.shutdown()

        let manual = HostSessionStore(workspacePath: root.path,
                                      credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        #expect(!manual.snapshot.provider.qwenConfigured)
        #expect(manual.snapshot.provider.configured)
        #expect(manual.snapshot.provider.model == "deepseek-v4-pro")
        #expect(manual.snapshot.provider.credentialState == "missing_saved")
        manual.send(.clearProviderCredential())
        #expect(manual.snapshot.provider.credentialState == "cleared")
        manual.shutdown()

        let cleared = HostSessionStore(workspacePath: root.path,
                                       credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        defer { cleared.shutdown() }
        #expect(!cleared.snapshot.provider.qwenConfigured)
        #expect(cleared.snapshot.provider.credentialState == "cleared")
    }

    @Test("Environment credential slots stay isolated when values collide or include surrounding whitespace")
    func environmentSlotIsolationAndTrimming() throws {
        // 1. Identical values across DASHSCOPE_API_KEY and DEEPSEEK_API_KEY must bind to their own slots.
        let sameRoot = FileManager.default.temporaryDirectory.appendingPathComponent("koe-env-same-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sameRoot) }
        let sameEnv = [
            "KOE_CREDENTIAL_SOURCE": "environment",
            "DASHSCOPE_API_KEY": "shared-fixture-secret",
            "DEEPSEEK_API_KEY": "shared-fixture-secret"
        ]
        let first = HostSessionStore(
            workspacePath: sameRoot.path,
            credentials: NativeCredentials(workspaceOverride: true, environment: sameEnv)
        )
        #expect(first.snapshot.provider.qwenConfigured)
        #expect(first.snapshot.provider.deepseekConfigured)
        first.shutdown()

        let qwenRemoved = HostSessionStore(
            workspacePath: sameRoot.path,
            credentials: NativeCredentials(
                workspaceOverride: true,
                environment: [
                    "KOE_CREDENTIAL_SOURCE": "environment",
                    "DEEPSEEK_API_KEY": "rotated-deepseek-secret"
                ]
            )
        )
        defer { qwenRemoved.shutdown() }
        #expect(!qwenRemoved.snapshot.provider.qwenConfigured)
        #expect(qwenRemoved.snapshot.provider.credentialState == "missing_saved")
        #expect(qwenRemoved.snapshot.provider.deepseekConfigured)
        #expect(qwenRemoved.snapshot.provider.configured)

        // 2. Surrounding whitespace in environment variables must still persist environment references across reopen.
        let padRoot = FileManager.default.temporaryDirectory.appendingPathComponent("koe-env-pad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: padRoot) }
        let paddedEnv = [
            "KOE_CREDENTIAL_SOURCE": "environment",
            "DASHSCOPE_API_KEY": "  padded-qwen-secret\n",
            "DEEPSEEK_API_KEY": "  padded-deepseek-secret\n"
        ]
        let paddedFirst = HostSessionStore(
            workspacePath: padRoot.path,
            credentials: NativeCredentials(workspaceOverride: true, environment: paddedEnv)
        )
        #expect(paddedFirst.snapshot.provider.qwenConfigured)
        #expect(paddedFirst.snapshot.provider.deepseekConfigured)
        paddedFirst.shutdown()

        let paddedReopened = HostSessionStore(
            workspacePath: padRoot.path,
            credentials: NativeCredentials(workspaceOverride: true, environment: paddedEnv)
        )
        defer { paddedReopened.shutdown() }
        #expect(paddedReopened.snapshot.provider.qwenConfigured)
        #expect(paddedReopened.snapshot.provider.deepseekConfigured)
        #expect(paddedReopened.snapshot.provider.configured)
    }

    @Test("NativeCredentials rejects invalid isolated references on read and delete consistently with iOS")
    func isolatedInvalidReferencesThrowOnReadAndDelete() throws {
        let credentials = NativeCredentials(workspaceOverride: true, environment: [:])
        #expect(credentials.isolated)

        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try credentials.perform(operation: 0, reference: "bad-ref", value: "")
        }
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try credentials.perform(operation: 2, reference: "bad-ref", value: "")
        }
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try credentials.perform(operation: 0, reference: UUID().uuidString.lowercased(), value: "")
        }
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try credentials.perform(operation: 2, reference: UUID().uuidString.lowercased(), value: "")
        }
        #expect(throws: NativeCredentials.Failure.unsupportedOperation) {
            _ = try credentials.perform(operation: 99, reference: "", value: "")
        }
    }

    @Test("NativeCredentials matches iOS across isolated rewrite-after-delete, environment, and mock Keychain 6-op matrix")
    func macNativeCredentialsFullParityMatrix() throws {
        #expect(NativeCredentials.allowsSystemStorage(debug: false, sourceOverride: false, workspaceOverride: false, trusted: true))
        #expect(!NativeCredentials.allowsSystemStorage(debug: true, sourceOverride: false, workspaceOverride: false, trusted: true))
        #expect(!NativeCredentials.allowsSystemStorage(debug: false, sourceOverride: true, workspaceOverride: false, trusted: true))
        #expect(!NativeCredentials.allowsSystemStorage(debug: false, sourceOverride: false, workspaceOverride: true, trusted: true))
        #expect(!NativeCredentials.allowsSystemStorage(debug: false, sourceOverride: false, workspaceOverride: false, trusted: false))

        let isolated = NativeCredentials(workspaceOverride: true, environment: [:])
        let ref = try #require(try isolated.perform(operation: 5, reference: "qwen", value: "sk-1"))
        #expect(try isolated.perform(operation: 1, reference: ref, value: "sk-1") == ref)
        #expect(try isolated.perform(operation: 2, reference: ref, value: "") == "")
        #expect(try isolated.perform(operation: 0, reference: ref, value: "") == nil)
        #expect(try isolated.perform(operation: 1, reference: ref, value: "sk-2") == ref)
        #expect(try isolated.perform(operation: 0, reference: ref, value: "") == "sk-2")
        #expect(try isolated.perform(operation: 2, reference: "isolated-1234-999-1", value: "") == "")

        let env = NativeCredentials(
            workspaceOverride: true,
            environment: [
                "KOE_CREDENTIAL_SOURCE": "environment",
                "DASHSCOPE_API_KEY": "sk-env-qwen",
                "DEEPSEEK_API_KEY": "sk-env-ds",
            ]
        )
        let envRef = try #require(try env.perform(operation: 5, reference: "qwen", value: "sk-env-qwen"))
        #expect(try env.perform(operation: 2, reference: envRef, value: "") == "")
        #expect(try env.perform(operation: 0, reference: envRef, value: "") == nil)
        #expect(try env.perform(operation: 1, reference: envRef, value: "sk-env-qwen") == envRef)
        #expect(try env.perform(operation: 0, reference: envRef, value: "") == "sk-env-qwen")

        final class MacMockKeychain: AppleKeychainBackend {
            private struct State: Sendable {
                var items: [String: Data] = [:]
                var accessibilities: [AppleKeychainAccessibility] = []
                var interactiveFlags: [Bool] = []
            }
            private let state = OSAllocatedUnfairLock(initialState: State())
            var accessibilities: [AppleKeychainAccessibility] { state.withLock(\.accessibilities) }
            var interactiveFlags: [Bool] { state.withLock(\.interactiveFlags) }
            private func key(_ query: AppleKeychainQuery) -> String { "\(query.service)::\(query.account)" }

            func copyData(for query: AppleKeychainQuery, interactive: Bool) -> AppleKeychainReadResult {
                state.withLock { state in
                    state.accessibilities.append(query.accessibility)
                    state.interactiveFlags.append(interactive)
                    return state.items[key(query)].map(AppleKeychainReadResult.found) ?? .notFound
                }
            }
            func add(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
                state.withLock { state in
                    state.accessibilities.append(query.accessibility)
                    state.interactiveFlags.append(interactive)
                    let k = key(query)
                    if state.items[k] != nil { return errSecDuplicateItem }
                    state.items[k] = data
                    return errSecSuccess
                }
            }
            func update(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
                state.withLock { state in
                    state.accessibilities.append(query.accessibility)
                    state.interactiveFlags.append(interactive)
                    let k = key(query)
                    guard state.items[k] != nil else { return errSecItemNotFound }
                    state.items[k] = data
                    return errSecSuccess
                }
            }
            func delete(for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
                state.withLock { state in
                    state.accessibilities.append(query.accessibility)
                    state.interactiveFlags.append(interactive)
                    return state.items.removeValue(forKey: key(query)) != nil ? errSecSuccess : errSecItemNotFound
                }
            }
        }

        let backend = MacMockKeychain()
        let production = NativeCredentials(mode: .productionKeychain, keychain: backend)
        #expect(!production.isolated)
        let uuid = try #require(try production.perform(operation: 5, reference: "qwen", value: "v1"))
        #expect(UUID(uuidString: uuid) != nil)
        #expect(try production.perform(operation: 1, reference: uuid, value: "v1") == uuid)
        #expect(try production.perform(operation: 1, reference: uuid, value: "v2") == uuid)
        #expect(try production.perform(operation: 0, reference: uuid, value: "") == "v2")
        #expect(try production.perform(operation: 4, reference: uuid, value: "") == "")
        #expect(try production.perform(operation: 2, reference: uuid, value: "") == "")
        #expect(try production.perform(operation: 0, reference: uuid, value: "") == nil)
        let backendCallsBeforeIsolatedNoOp = backend.accessibilities.count
        #expect(try production.perform(operation: 2, reference: "isolated-\(uuid)", value: "") == "")
        #expect(try production.perform(operation: 4, reference: "isolated-\(uuid)", value: "") == "")
        #expect(try production.perform(operation: 2, reference: "isolated-1234-999-1", value: "") == "")
        #expect(try production.perform(operation: 4, reference: "isolated-1234-999-1", value: "") == "")
        #expect(backend.accessibilities.count == backendCallsBeforeIsolatedNoOp)
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try production.perform(operation: 0, reference: "bad-uuid", value: "")
        }
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try production.perform(operation: 1, reference: "bad-uuid", value: "v")
        }
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try production.perform(operation: 2, reference: "bad-uuid", value: "")
        }
        #expect(throws: NativeCredentials.Failure.invalidReference) {
            _ = try production.perform(operation: 4, reference: "bad-uuid", value: "")
        }
        #expect(backend.accessibilities.allSatisfy { $0 == .platformDefault })
        #expect(backend.interactiveFlags.contains(true))
    }
}
