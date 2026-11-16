import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Native product contract")
struct KoeAppleSharedTests {
    @Test("An older snapshot cannot replace the current state")
    @MainActor
    func rejectsStaleSnapshot() {
        var gate = ViewRequestGeneration()
        let acceptedFirst = gate.acceptRustGeneration(4)
        let acceptedStale = gate.acceptRustGeneration(3)
        let acceptedNext = gate.acceptRustGeneration(5)
        #expect(acceptedFirst)
        #expect(!acceptedStale)
        #expect(acceptedNext)
    }

    @Test("Invalid payload exposes an error without replacing the last usable snapshot")
    @MainActor
    func invalidSnapshotIsVisible() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let before = store.snapshot
        store.applySnapshotJSON("{invalid}")
        #expect(store.nativeError != nil)
        #expect(store.snapshot == before)
    }

    @Test("Separate notes keep their text and source identity through review and reopen")
    @MainActor
    func recordReviewAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        #expect(store.handle != 0)
        #expect(store.snapshot.records.isEmpty)
        store.send("create_note", ["title": "Architecture", "text": "The engine owns recording state."])
        let first = try #require(store.snapshot.detail)
        let segment = try #require(first.segments.first)
        store.send("create_task", ["recordId": first.id, "segmentId": segment.id])
        let task = try #require(store.snapshot.tasks.first)
        store.send("review_item", ["itemId": task.id, "decision": "accept"])
        store.send("complete_task", ["itemId": task.id, "completed": true])
        store.send("create_note", ["title": "Notebook", "text": "The notebook is on the shelf."])
        let second = try #require(store.snapshot.detail)
        #expect(second.id != first.id)
        store.send("select_record", ["recordId": first.id])
        #expect(store.snapshot.detail?.segments == first.segments)
        store.send("ask", ["question": "recording state", "scope": "record", "recordId": first.id])
        let answer = try #require(store.snapshot.ask.messages.last)
        #expect(answer.mode == "retrieval")
        #expect(!answer.sources.isEmpty)
        #expect(answer.sources.allSatisfy { $0.recordId == first.id })
        let source = try #require(answer.sources.first)
        store.send("open_source", ["recordId": source.recordId, "segmentId": source.segmentId])
        #expect(store.snapshot.focusSegmentId == segment.id)
        store.shutdown()
        let restored = HostSessionStore(workspacePath: directory.path)
        defer { restored.shutdown() }
        #expect(restored.snapshot.records.count == 2)
        #expect(restored.snapshot.tasks.first(where: { $0.id == task.id })?.completed == true)
        restored.send("select_record", ["recordId": second.id])
        #expect(restored.snapshot.detail?.segments == second.segments)
        #expect(restored.snapshot.error == nil)
        #expect(restored.nativeError == nil)
    }

    @Test("Connect guide, backward-compatible device snapshot, and product WebP assets")
    @MainActor
    func connectGuideAndProductAssets() throws {
        let legacyJSON = """
        {
          "version": 2,
          "generation": 10,
          "section": "today",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [],
          "detail": null,
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": false, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(decoded.device.phase == "disconnected")
        #expect(decoded.device.deviceName == "Soundcore Work")
        #expect(decoded.device.guide == nil)
        #expect(decoded.device.transferPhase == "idle")
        #expect(decoded.device.liveDurationMs == 0)
        #expect(decoded.device.liveBytes == 0)
        #expect(decoded.device.liveRecordId == nil)
        #expect(decoded.playback.requestId == 0)
        #expect(decoded.playback.lanes.isEmpty)
        #expect(decoded.playback.asset == nil)

        let liveJSON = """
        {
          "version": 2,
          "generation": 11,
          "section": "today",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [
            {
              "id": "rec-live-1",
              "title": "实时录音",
              "createdAtEpochSec": 1700000000,
              "durationMs": 15000,
              "source": "录音豆",
              "status": "转写中",
              "segmentCount": 1,
              "preview": "正在讨论实时转写进度"
            }
          ],
          "detail": null,
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": {
            "state": "正在录音",
            "connected": true,
            "busy": true,
            "recording": true,
            "transferPhase": "streaming_realtime",
            "liveDurationMs": 15000,
            "liveBytes": 4800,
            "liveRecordId": "rec-live-1",
            "files": [{ "id": 7, "title": "录音 7", "durationMs": 62000 }],
            "progress": 0.0
          },
          "provider": { "configured": true, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let liveDecoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(liveJSON.utf8))
        #expect(liveDecoded.device.transferPhase == "streaming_realtime")
        #expect(liveDecoded.device.liveDurationMs == 15000)
        #expect(liveDecoded.device.liveBytes == 4800)
        #expect(liveDecoded.device.liveRecordId == "rec-live-1")
        #expect(liveDecoded.device.files.first?.fileId == 7)
        #expect(liveDecoded.activeLiveRecord?.id == "rec-live-1")
        #expect(liveDecoded.activeLiveRecord?.preview == "正在讨论实时转写进度")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        store.send("device_open_guide")
        #expect(store.snapshot.device.guide?.mode == "connect_guide")
        #expect(store.snapshot.device.guide?.highlightTarget == "case_button")
        store.send("device_close_guide")
        #expect(store.snapshot.device.guide == nil)

        for asset in ["guide_connect_case", "guide_connect_device", "guide_record", "guide_mark", "guide_wear", "guide_sync"] {
            #expect(ProductAssetImage.resolveImageURL(named: asset) != nil)
        }
    }

    @Test("Capture studio snapshots and activity across navigation")
    @MainActor
    func captureStudioAndActivity() throws {
        let legacyMicJSON = """
        {
          "version": 2, "generation": 1, "section": "today", "canGoBack": false,
          "selectedRecordId": null, "focusSegmentId": null, "records": [],
          "detail": null, "tasks": [], "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "microphone": {
            "recordId": "m-1", "sessionId": "s-1", "lane": "microphone", "inputId": "",
            "phase": "recording", "nextSequence": 1, "durationMs": 5000,
            "error": null, "interruption": null, "epoch": 0, "clockNs": 1000,
            "lanes": { "microphone": { "nextSequence": 1, "sampleRate": 16000, "started": true, "stopped": false, "error": null, "interruption": null } }
          },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": false, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null, "notice": null
        }
        """
        let legacyDecoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(legacyMicJSON.utf8))
        #expect(legacyDecoded.capture == .empty)
        #expect(legacyDecoded.microphone?.level == 0.0)
        #expect(legacyDecoded.microphone?.inputLabel == "Mac 麦克风")
        #expect(legacyDecoded.microphone?.inputBadge == "系统默认")
        #expect(legacyDecoded.microphone?.phaseSummaryLabel == "正在录音")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        #expect(store.snapshot.captureModes.count == 4)
        #expect(store.snapshot.captureModes.allSatisfy { $0.available })

        store.reportNativeError("麦克风权限未开启")
        store.send("sync_audio_inputs", ["inputs": [
            ["id": "macbook-mic", "name": "MacBook Pro 麦克风", "transport": "built_in", "isDefault": true],
            ["id": "airpods-pro", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": false]
        ]])
        #expect(store.nativeError == "麦克风权限未开启")
        store.clearError()
        #expect(store.nativeError == nil)
        #expect(store.snapshot.capture.selectedSource == "input:airpods-pro")
        #expect(store.snapshot.capture.selectedBadge == "Mac 蓝牙")
        #expect(store.snapshot.captureModes.allSatisfy { $0.sourceLabel == "AirPods Pro" })

        store.send("select_capture_source", ["source": "bean"])
        #expect(store.snapshot.capture.selectedSource == "bean")
        #expect(store.snapshot.capture.canStart == false)
        #expect(store.snapshot.captureModes.allSatisfy { !$0.available })

        store.send("navigate", ["section": "capture"])
        #expect(store.snapshot.section == "capture")
        store.send("select_capture_source", ["source": "input:airpods-pro"])
        store.send("start_microphone", ["inputId": store.snapshot.capture.selectedInputId, "clockNs": 1_000_000_000])
        let mic = try #require(store.snapshot.microphone)
        #expect(mic.inputLabel == "AirPods Pro")
        #expect(mic.inputBadge == "Mac 蓝牙")
        #expect(mic.phaseSummaryLabel == "等待权限")
        #expect(store.snapshot.activeCapture?.phase == "starting")
        store.send("navigate", ["section": "notes"])
        #expect(store.snapshot.section == "notes")
        #expect(store.snapshot.microphone?.sessionId == mic.sessionId)
        store.send("microphone_started", ["recordId": mic.recordId, "sessionId": mic.sessionId, "lane": "microphone", "sampleRate": 16000])
        store.send("microphone_chunk", [
            "recordId": mic.recordId, "sessionId": mic.sessionId, "lane": "microphone",
            "sequence": 0, "samples": [Int16](repeating: 4096, count: 320),
            "timing": ["epoch": 0, "capturedStartNs": 1_000_000_000]
        ])
        #expect((store.snapshot.microphone?.level ?? 0) > 0.4)
        #expect(store.snapshot.activeCapture?.actions.contains(.pause) == true)
        store.send("cancel_microphone")
        #expect(store.snapshot.microphone?.level == 0.0)
        #expect(store.snapshot.microphone?.phaseSummaryLabel == "正在取消")
        #expect(store.snapshot.activeCapture?.phase == "cancelling")
        store.send("microphone_stopped", ["recordId": mic.recordId, "sessionId": mic.sessionId, "lane": "microphone", "sequence": 1, "epoch": 0])
        #expect(store.snapshot.microphone == nil)
    }

    @Test("System audio toggle is local-only by default, locked while recording and adds a meeting lane")
    @MainActor
    func systemAudioToggle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        #expect(!store.snapshot.capture.includeSystemAudio && store.snapshot.capture.canIncludeSystemAudio)
        store.send("set_capture_system_audio", ["enabled": true])
        store.startCapture(.meeting, stayOnPage: true)
        let mic = try #require(store.snapshot.microphone)
        #expect(mic.lanes.keys.sorted() == ["microphone", "system"])
        store.send("set_capture_system_audio", ["enabled": false])
        #expect(store.snapshot.error != nil && store.snapshot.capture.includeSystemAudio)
        store.performCaptureAction(.cancel)
        ["microphone", "system"].forEach { store.send("microphone_stopped", ["recordId": mic.recordId, "sessionId": mic.sessionId, "lane": $0, "sequence": 0]) }
        store.send("select_capture_source", ["source": "bean"])
        #expect(store.snapshot.microphone == nil && !store.snapshot.capture.canIncludeSystemAudio)
    }

    @Test("SummarySectionItem.keyed avoids collisions when an item already ends with a #N suffix")
    func summarySectionItemKeyedAvoidsCollisions() {
        let x1 = SummarySnapshot(title: "t", text: "x", sources: [])
        let x2 = SummarySnapshot(title: "t", text: "x", sources: [])
        let xHash2 = SummarySnapshot(title: "t", text: "x#2", sources: [])
        let items = SummarySectionItem.keyed([x1, x2, xHash2])
        #expect(items.count == 3)
        #expect(Set(items.map(\.id)).count == 3)
        #expect(items.map(\.section) == [x1, x2, xHash2])

        let reversed = SummarySectionItem.keyed([xHash2, x1, x2])
        #expect(reversed.count == 3)
        #expect(Set(reversed.map(\.id)).count == 3)
        #expect(reversed.map(\.section) == [xHash2, x1, x2])
    }
}
