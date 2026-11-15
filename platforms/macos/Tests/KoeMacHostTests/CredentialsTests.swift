import Foundation
import KoeAppleShared
import Testing
@testable import Koe

private final class FixtureCredentials: HostCredentials {
    let isolated = false
    var items: [String: String] = [:]
    var failRead = false
    var operations: [UInt32] = []
    var afterCreate: (() -> Void)?
    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        operations.append(operation)
        switch operation {
        case 0:
            if failRead { throw NativeCredentials.Failure.unavailable }
            return items[reference]
        case 1:
            items[reference] = value
            afterCreate?()
            return reference
        case 2: items.removeValue(forKey: reference); return ""
        case 3: return nil
        case 4: return ""
        case 5: return UUID().uuidString.lowercased()
        default: throw NativeCredentials.Failure.unavailable
        }
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
        first.send("configure_provider", ["apiKey": "fixture-only-secret", "model": "fixture-model"])
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.model == "fixture-model")
        #expect(first.nativeError == nil)
        first.shutdown()
        let reopened = HostSessionStore(workspacePath: root.path, credentials: vault)
        #expect(reopened.snapshot.provider.configured)
        #expect(reopened.snapshot.provider.model == "fixture-model")
        let data = try Data(contentsOf: root.appendingPathComponent("product-workspace.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-only-secret"))
        let snapshot = try JSONEncoder().encode(reopened.snapshot)
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("fixture-only-secret"))
        vault.failRead = true
        reopened.send("retry_provider_credentials")
        #expect(reopened.snapshot.provider.credentialState == "unavailable")
        #expect(!reopened.snapshot.provider.configured)
        vault.failRead = false
        reopened.send("retry_provider_credentials", ["authorize": true])
        #expect(reopened.snapshot.provider.configured)
        #expect(vault.operations.contains(4))
        reopened.send("clear_provider_credential")
        #expect(!reopened.snapshot.provider.configured)
        reopened.shutdown()
        let cleared = HostSessionStore(workspacePath: root.path, credentials: vault)
        defer { cleared.shutdown() }
        #expect(cleared.snapshot.provider.credentialState == "cleared")
        #expect(vault.items.isEmpty)
    }

    @Test("A secure item created before a crashed workspace commit is reclaimed on reopen")
    func crashOrphanReclaimed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("koe-orphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("crashed"), other = base.appendingPathComponent("other")
        let vault = FixtureCredentials()
        let neighbour = HostSessionStore(workspacePath: other.path, credentials: vault)
        neighbour.send("configure_provider", ["apiKey": "other-fixture-secret", "model": "other-model"])
        #expect(neighbour.snapshot.provider.configured)
        neighbour.shutdown()
        let file = root.appendingPathComponent("product-workspace.json")
        var crashed: Data?
        vault.afterCreate = { crashed = try? Data(contentsOf: file) }
        let first = HostSessionStore(workspacePath: root.path, credentials: vault)
        first.send("configure_provider", ["apiKey": "orphan-fixture-secret", "model": "fixture-model"])
        #expect(first.snapshot.provider.configured)
        first.shutdown()
        vault.afterCreate = nil
        // Replay the disk state captured at the moment the item was created.
        try? FileManager.default.removeItem(at: file)
        if let crashed { try crashed.write(to: file) }
        #expect(vault.items.values.contains("orphan-fixture-secret"))
        let reopened = HostSessionStore(workspacePath: root.path, credentials: vault)
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.provider.credentialState == "missing")
        #expect(reopened.nativeError == nil)
        #expect(Array(vault.items.values) == ["other-fixture-secret"])
        let neighbourReopened = HostSessionStore(workspacePath: other.path, credentials: vault)
        defer { neighbourReopened.shutdown() }
        #expect(neighbourReopened.snapshot.provider.configured)
    }

    @Test("An explicit workspace uses session-only credentials through the real native adapter")
    func isolatedNativeAdapter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-isolated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = NativeCredentials(workspaceOverride: true, environment: ["DASHSCOPE_API_KEY": "ignored-fixture"])
        #expect(native.isolated)
        let first = HostSessionStore(workspacePath: root.path, credentials: native)
        #expect(!first.snapshot.provider.configured)
        first.send("configure_provider", ["apiKey": "isolated-fixture", "model": "isolated-model"])
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.isolated)
        first.shutdown()
        let second = HostSessionStore(workspacePath: root.path, credentials: NativeCredentials(
            workspaceOverride: true, environment: ["KOE_CREDENTIAL_SOURCE": "isolated", "DASHSCOPE_API_KEY": "ignored-fixture"]))
        defer { second.shutdown() }
        #expect(!second.snapshot.provider.configured)
        #expect(second.snapshot.provider.model == "isolated-model")
        second.send("clear_provider_credential")
        #expect(second.snapshot.provider.credentialState == "cleared")
    }

    @Test("Explicit environment credentials configure a new workspace, survive restart and respect clear")
    func environmentLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["KOE_CREDENTIAL_SOURCE": "environment", "DASHSCOPE_API_KEY": "environment-fixture-secret"]
        let first = HostSessionStore(workspacePath: root.path,
                                     credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.isolated)
        #expect(first.nativeError == nil)
        first.shutdown()

        let missing = HostSessionStore(workspacePath: root.path, credentials: NativeCredentials(
            workspaceOverride: true, environment: ["KOE_CREDENTIAL_SOURCE": "environment"]))
        #expect(!missing.snapshot.provider.configured)
        #expect(missing.snapshot.provider.credentialState == "missing_saved")
        missing.shutdown()

        let reopened = HostSessionStore(workspacePath: root.path,
                                        credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.provider.configured)
        let workspace = try String(contentsOf: root.appendingPathComponent("product-workspace.json"), encoding: .utf8)
        #expect(!workspace.contains("environment-fixture-secret"))
        let snapshot = try JSONEncoder().encode(reopened.snapshot)
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("environment-fixture-secret"))
        reopened.send("configure_provider", ["apiKey": "environment-fixture-secret", "model": "environment-model"])
        #expect(reopened.snapshot.provider.model == "environment-model")
        reopened.send("configure_provider", ["apiKey": "manual-fixture-secret", "model": "manual-model"])
        #expect(reopened.snapshot.provider.configured)
        #expect(reopened.snapshot.provider.model == "manual-model")
        reopened.send("retry_provider_credentials")
        #expect(reopened.snapshot.provider.configured)
        reopened.shutdown()

        let manual = HostSessionStore(workspacePath: root.path,
                                      credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        #expect(!manual.snapshot.provider.configured)
        #expect(manual.snapshot.provider.model == "manual-model")
        #expect(manual.snapshot.provider.credentialState == "missing_saved")
        manual.send("clear_provider_credential")
        #expect(manual.snapshot.provider.credentialState == "cleared")
        manual.shutdown()

        let cleared = HostSessionStore(workspacePath: root.path,
                                       credentials: NativeCredentials(workspaceOverride: true, environment: environment))
        defer { cleared.shutdown() }
        #expect(!cleared.snapshot.provider.configured)
        #expect(cleared.snapshot.provider.credentialState == "cleared")
    }
}
