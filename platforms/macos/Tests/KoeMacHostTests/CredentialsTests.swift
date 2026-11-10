import Foundation
import KoeAppleShared
import Testing
@testable import Koe

private final class FixtureCredentials: HostCredentials {
    let isolated = false
    var items: [String: String] = [:]
    var failRead = false
    var operations: [UInt32] = []
    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        operations.append(operation)
        switch operation {
        case 0:
            if failRead { throw NativeCredentials.Failure.unavailable }
            return items[reference]
        case 1:
            let id = UUID().uuidString.lowercased()
            items[id] = value
            return id
        case 2: items.removeValue(forKey: reference); return ""
        case 3: return nil
        case 4: return ""
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

    @Test("An explicit workspace uses session-only credentials through the real native adapter")
    func isolatedNativeAdapter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-isolated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = NativeCredentials(workspaceOverride: true)
        #expect(native.isolated)
        let first = HostSessionStore(workspacePath: root.path, credentials: native)
        first.send("configure_provider", ["apiKey": "isolated-fixture", "model": "isolated-model"])
        #expect(first.snapshot.provider.configured)
        #expect(first.snapshot.provider.isolated)
        first.shutdown()
        let second = HostSessionStore(workspacePath: root.path, credentials: NativeCredentials(workspaceOverride: true))
        defer { second.shutdown() }
        #expect(!second.snapshot.provider.configured)
        #expect(second.snapshot.provider.model == "isolated-model")
        second.send("clear_provider_credential")
        #expect(second.snapshot.provider.credentialState == "cleared")
    }
}
