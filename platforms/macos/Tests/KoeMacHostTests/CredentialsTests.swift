import Foundation
import KoeAppleShared
import os
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
                if state.failRead { throw NativeCredentials.Failure.unavailable }
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
            default: throw NativeCredentials.Failure.unavailable
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
        reopened.send(.clearProviderCredential)
        #expect(!reopened.snapshot.provider.qwenConfigured)
        #expect(reopened.snapshot.provider.configured)
        reopened.send(.clearProviderCredentialFor(provider: "deepseek"))
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
        second.send(.clearProviderCredential)
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
        manual.send(.clearProviderCredential)
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
}
