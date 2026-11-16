import Foundation
import KoeAppleShared
import Testing
@testable import Koe

@Suite("Voice input application actions")
@MainActor
struct NativeHostActionsTests {
    @Test("Preparing voice input arms standby session without launching external apps")
    func preparesVoiceInputWithoutExternalLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path)
        defer { store.shutdown() }
        let adapter = NativeHostActions()
        store.send("prepare_voice_input")
        store.send("prepare_voice_input")
        adapter.apply(to: store)
        #expect(store.drainHostActions().isEmpty)
        #expect(store.nativeError == nil)
        #expect(store.snapshot.section == "voice_input")
        #expect(store.snapshot.activeCapture == nil)
        #expect(store.snapshot.workspaces?.voiceInput.sessionEnabled == true)
        #expect(store.snapshot.workspaces?.voiceInput.deviceName == "Soundcore Work")
    }
}
