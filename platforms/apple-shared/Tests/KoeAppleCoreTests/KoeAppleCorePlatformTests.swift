import CKoeHostApi
import Foundation
import KoeAppleCore
import Testing

@Suite("KoeAppleCore cross-platform contract")
struct KoeAppleCorePlatformTests {
    @Test func reviewDecisionsEncodeRustVerbs() throws {
        for (decision, verb) in [(ReviewDecision.accept, "accept"), (.dismiss, "dismiss"), (.reset, "reset")] {
            let data = try JSONEncoder().encode(HostCommand.reviewItem(itemId: "item", decision: decision))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(json == ["type": "review_item", "itemId": "item", "decision": verb])
        }
    }

    @Test func legacyPlatformSnapshotsInferNativeSpeech() throws {
        for (id, supported) in [("android", false), ("ios", true), ("macos", true)] {
            let json = #"{"id":"\#(id)","hostDisplayName":"Host","supportsSystemAudio":false,"supportsSelfUpdate":false,"nativeSpeechLabel":"本机"}"#
            let platform = try JSONDecoder().decode(HostPlatformSnapshot.self, from: Data(json.utf8))
            #expect(platform.supportsNativeSpeech == supported)
        }
    }

    @Test("syncAppMetadata projects iOS host profile, disables system audio, and sets this_device bean control")
    @MainActor
    func syncAppMetadataProjectsIOSPlatformAndBeanControl() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        #expect(store.platform == .macosDefault)
        #expect(store.today.beanControlState == "this_device")
        #expect(store.sidebar.beanControlState == "this_device")

        store.send(
            .syncAppMetadata(
                version: "2.6.0",
                build: "15",
                platform: "ios",
                hostDisplayName: "iPhone",
                supportsSystemAudio: false,
                supportsSelfUpdate: false,
                nativeSpeechLabel: "Apple 本机"
            )
        )

        #expect(store.platform.id == "ios")
        #expect(store.platform.hostDisplayName == "iPhone")
        #expect(store.platform.supportsSystemAudio == false)
        #expect(store.platform.supportsSelfUpdate == false)
        #expect(store.platform.nativeSpeechLabel == "Apple 本机")
        #expect(store.captureStudio.studio.canIncludeSystemAudio == false)
        #expect(store.today.beanControlState == "this_device")
        #expect(store.sidebar.beanControlState == "this_device")
    }

    @Test("deviceRelease flips beanControlState to released on today and sidebar slices")
    @MainActor
    func deviceReleaseFlipsBeanControlState() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        #expect(store.today.beanControlState == "this_device")
        #expect(store.sidebar.beanControlState == "this_device")

        store.send(.deviceRelease)

        #expect(store.today.beanControlState == "released")
        #expect(store.sidebar.beanControlState == "released")
        #expect(store.today.picker?.beanControlState == "released")
    }

#if DEBUG
    @Test("loadDebugSnapshotFixtureJSON loads real Rust v2 snapshot JSON and rejects version != 2 or invalid JSON")
    @MainActor
    func debugFixtureLoaderAcceptsV2AndRejectsInvalidPayloads() throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let targetDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: targetDir)
        }

        let sourceStore = HostSessionStore(workspacePath: sourceDir.path)
        defer { sourceStore.shutdown() }
        sourceStore.send(
            .syncAppMetadata(
                version: "2.6.0",
                build: "15",
                platform: "ios",
                hostDisplayName: "iPhone",
                supportsSystemAudio: false,
                supportsSelfUpdate: false,
                nativeSpeechLabel: "Apple 本机"
            )
        )
        sourceStore.send(.createNote(title: "Fixture Note", text: "Loaded from real Rust v2 snapshot."))
        sourceStore.send(.navigate(section: "records"))

        let rawPtr = try #require(koe_host_session_snapshot_json(sourceStore.handle, 1_800_000_000))
        defer { koe_host_string_free(rawPtr) }
        let fixtureJSON = String(cString: rawPtr)

        let targetStore = HostSessionStore(workspacePath: targetDir.path)
        defer { targetStore.shutdown() }
        #expect(targetStore.platform == .macosDefault)
        #expect(targetStore.records.isEmpty)

        let accepted = targetStore.loadDebugSnapshotFixtureJSON(fixtureJSON)
        #expect(accepted == true)
        #expect(targetStore.nativeError == nil)
        #expect(targetStore.platform.id == "ios")
        #expect(targetStore.platform.hostDisplayName == "iPhone")
        #expect(targetStore.navigation.section == "records")
        #expect(targetStore.records.count == 1)
        #expect(targetStore.records.first?.title == "Fixture Note")

        let beforeReject = targetStore.records
        var wrongVersionObj = try #require(
            JSONSerialization.jsonObject(with: Data(fixtureJSON.utf8)) as? [String: Any]
        )
        wrongVersionObj["version"] = 1
        let wrongVersionData = try JSONSerialization.data(withJSONObject: wrongVersionObj)
        let wrongVersionJSON = try #require(String(data: wrongVersionData, encoding: .utf8))

        let rejectedVersion = targetStore.loadDebugSnapshotFixtureJSON(wrongVersionJSON)
        #expect(rejectedVersion == false)
        #expect(targetStore.nativeError != nil)
        #expect(targetStore.records == beforeReject)

        let rejectedInvalid = targetStore.loadDebugSnapshotFixtureJSON("{invalid-json")
        #expect(rejectedInvalid == false)
        #expect(targetStore.nativeError != nil)
        #expect(targetStore.records == beforeReject)
    }
#endif

    @Test("exportTraceJSON caps at 20 entries and never leaks secrets or transcript contents")
    @MainActor
    func traceRingBufferCapsAtTwentyAndRedactsPayloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let qwenSecret = "sk-unit-test-do-not-leak"
        let deepseekSecret = "sk-deepseek-unit-test-secret"
        let transcriptSecret = "confidential-transcript-payload-xyz"

        store.send(
            .configureProvider(
                apiKey: qwenSecret,
                deepseekApiKey: deepseekSecret,
                model: "deepseek-flash"
            )
        )
        store.send(.createNote(title: "Private Title", text: transcriptSecret))

        let immediateJSON = store.exportTraceJSON()
        #expect(immediateJSON.contains("configure_provider"))
        #expect(immediateJSON.contains("create_note"))
        #expect(!immediateJSON.contains(qwenSecret))
        #expect(!immediateJSON.contains(deepseekSecret))
        #expect(!immediateJSON.contains(transcriptSecret))
        #expect(!immediateJSON.contains("Private Title"))

        let sections = ["today", "records", "tasks", "settings"]
        for idx in 0..<25 {
            store.send(.navigate(section: sections[idx % sections.count]))
        }

        #expect(store.recentTraceEntries.count == 20)
        let cappedJSON = store.exportTraceJSON()
        #expect(!cappedJSON.contains(qwenSecret))
        #expect(!cappedJSON.contains(deepseekSecret))
        #expect(!cappedJSON.contains(transcriptSecret))

        let decoded = try JSONDecoder().decode([HostTraceEntry].self, from: Data(cappedJSON.utf8))
        #expect(decoded.count == 20)
        #expect(decoded.allSatisfy { $0.kind == "command" && $0.name == "navigate" })
    }
}
