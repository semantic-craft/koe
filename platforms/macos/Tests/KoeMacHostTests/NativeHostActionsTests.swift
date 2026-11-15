import Foundation
import KoeAppleShared
import Testing
@testable import Koe

@Suite("Voice input application actions")
@MainActor
struct NativeHostActionsTests {
    @Test("Entry opens Responsay once and failed launch can be retried")
    func opensOnceAndRetriesFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path)
        defer { store.shutdown() }
        var opened: [String] = []
        var succeeds = false
        let adapter = NativeHostActions(openURL: {
            opened.append($0.absoluteString)
            return succeeds
        })
        store.send("prepare_voice_input")
        store.send("prepare_voice_input")
        adapter.apply(to: store)
        adapter.apply(to: store)
        #expect(opened == ["responsay://connect-koe"])
        #expect(store.nativeError != nil)
        #expect(store.snapshot.section == "voice_input")
        #expect(store.snapshot.activeCapture == nil)
        succeeds = true
        store.send("prepare_voice_input")
        adapter.apply(to: store)
        #expect(opened == ["responsay://connect-koe", "responsay://connect-koe"])
        #expect(store.nativeError == nil)
        #expect(store.snapshot.workspaces?.voiceInput.deviceName == "Soundcore Work")
    }
}
