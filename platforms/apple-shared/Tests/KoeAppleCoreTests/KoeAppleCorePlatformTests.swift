import CKoeHostApi
import CoreBluetooth
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
                version: "2.7.1",
                build: "17",
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
    @Test("Opening a synced fixture row resumes the real workspace")
    @MainActor
    func fixtureRecordOpensLiveDetail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path)
        defer { store.shutdown() }
        store.send(.createNote(title: "Synced", text: "Real note", stayOnPage: true))
        let id = try #require(store.records.first?.id)
        let raw = try #require(koe_host_session_snapshot_json(store.handle, 1))
        defer { koe_host_string_free(raw) }
        var fixture = try #require(JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any])
        fixture["generation"] = 10000
        fixture["detail"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: fixture)
        #expect(store.loadDebugSnapshotFixtureJSON(String(decoding: data, as: UTF8.self), resumeLiveOnCommand: true))
        store.send(.selectRecord(recordId: id))
        #expect(store.recordDetail.detail?.title == "Synced")
    }

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
                version: "2.7.1",
                build: "17",
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

    @Test("D3200 manufacturer data matches sound/scor markers even when followed by non-UTF8 bytes")
    func bleManufacturerMarkerMatchesWithTrailingNonUTF8Bytes() throws {
        let soundPayload = Data([
            0x00, 0x00,
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
            0x00, 0x00,
            0x73, 0x6F, 0x75, 0x6E, 0x64, 0xFF,
        ])
        let soundMatch = try #require(
            BleAdvertisementCandidate.match(
                peripheralName: nil,
                advertisementData: [CBAdvertisementDataManufacturerDataKey: soundPayload]
            )
        )
        #expect(soundMatch.matchedByManufacturerData)
        #expect(soundMatch.macAddress == "AA:BB:CC:DD:EE:FF")

        let scorPayload = Data([
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
            0x00, 0x00,
            0x73, 0x63, 0x6F, 0x72, 0x80, 0xFF,
        ])
        let scorMatch = try #require(
            BleAdvertisementCandidate.match(
                peripheralName: nil,
                advertisementData: [CBAdvertisementDataManufacturerDataKey: scorPayload]
            )
        )
        #expect(scorMatch.matchedByManufacturerData)
        #expect(scorMatch.macAddress == "11:22:33:44:55:66")
    }

    @Test("WorkspaceExportRequest sanitizes path separators, control characters, dotfiles, and empty stems")
    func workspaceExportRequestSanitizesUnsafeTitles() throws {
        let cardJSON = """
        {
          "id": "qn-1",
          "title": "a\\\\b:c/d\\u0000e",
          "createdAtEpochSec": 1700000000,
          "durationMs": 0,
          "source": "文字记录",
          "status": "就绪",
          "archived": false,
          "project": null,
          "isInbox": true,
          "minutesStale": false,
          "canSummarize": false,
          "segments": [],
          "gist": null,
          "topics": [],
          "nextSteps": []
        }
        """
        let quickNoteCard = try JSONDecoder().decode(QuickNoteCardSnapshot.self, from: Data(cardJSON.utf8))
        #expect(WorkspaceExportRequest.forQuickNote(quickNoteCard).suggestedFilename == "a-b-c-d-e.md")
        #expect(WorkspaceExportRequest.forMeeting(recordId: "m-1", title: "...").suggestedFilename == "实时纪要.md")
        #expect(WorkspaceExportRequest.forMeeting(recordId: "m-2", title: ".hidden").suggestedFilename == "hidden.md")
        #expect(WorkspaceExportRequest.forMeeting(recordId: "m-3", title: "/:\\\0").suggestedFilename == "实时纪要.md")
        #expect(WorkspaceExportRequest.forMeeting(recordId: "m-4", title: "   \n\t  ").suggestedFilename == "实时纪要.md")
        #expect(WorkspaceExportRequest.forMeeting(recordId: "m-5", title: "架构/周会").suggestedFilename == "架构-周会.md")
        #expect(WorkspaceExportRequest.forAllDay(date: "2026/11:15\\0").suggestedFilename == "全天听记-2026-11-15-0.md")
    }
}
