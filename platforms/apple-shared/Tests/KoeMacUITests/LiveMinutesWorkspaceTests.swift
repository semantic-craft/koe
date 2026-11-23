import Foundation
import Testing
@testable import KoeMacUI

@Suite("LiveMinutes mode workspace")
struct LiveMinutesWorkspaceTests {
    @Test("LiveMinutes workspace resolves coverage, retrospective meeting switching, legacy fallback, and meeting Markdown export")
    @MainActor
    func liveMinutesRetrospectiveCoverageAndExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        func captureMeetingRecord(nowEpochSec: UInt64) throws -> String {
            store.send(.startCaptureMode(mode: .meeting, stayOnPage: true), nowEpochSec: nowEpochSec)
            let mic = try #require(store.snapshot.microphone)
            store.send(.microphonePrepared(recordId: mic.recordId, sessionId: mic.sessionId, epoch: 0, clockNs: 1_000_000_000), nowEpochSec: nowEpochSec)
            store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16000), nowEpochSec: nowEpochSec)
            let ingest = store.ingestMicrophonePCM(
                recordId: mic.recordId,
                sessionId: mic.sessionId,
                lane: "microphone",
                sequence: 0,
                epoch: 0,
                capturedStartNs: 1_000_000_000,
                samples: [Int16](repeating: 180, count: 320),
                nowEpochSec: nowEpochSec
            )
            #expect(ingest.status == .accepted)
            store.performCaptureAction(.end)
            store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 1, epoch: 0), nowEpochSec: nowEpochSec)
            return mic.recordId
        }

        let firstMeetingId = try captureMeetingRecord(nowEpochSec: 1_800_000_000)
        let secondMeetingId = try captureMeetingRecord(nowEpochSec: 1_800_000_060)

        let initialLive = try #require(store.snapshot.workspaces?.liveMinutes)
        #expect(initialLive.pastMeetings.count == 2)
        #expect(firstMeetingId != secondMeetingId)

        store.send(.selectLiveMinutesRecord(recordId: firstMeetingId))
        let switchedLive = try #require(store.snapshot.workspaces?.liveMinutes)
        #expect(switchedLive.selectedRecordId == firstMeetingId)
        #expect(switchedLive.coverage != nil)

        let exportReq = WorkspaceExportRequest.forMeeting(
            recordId: firstMeetingId,
            title: "架构/周会",
            includeAnalysis: true,
            includeSources: true
        )
        #expect(exportReq.suggestedFilename == "架构-周会.md")
        let exportURL = directory.appendingPathComponent(exportReq.suggestedFilename)
        store.send(exportReq.command(path: exportURL.path))
        #expect(store.snapshot.error == nil)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))

        _ = LiveMinutesView(store: store).body
    }

    @Test("Legacy idle fallback, stayOnPage quick note creation, and workspace canStart")
    @MainActor
    func legacyIdleStayOnPageAndCanStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send(.navigate(section: "notes"))
        store.send(.createNote(title: "闪记页直存", text: "单条指令留在本页", stayOnPage: true))
        #expect(store.snapshot.section == "notes")
        #expect(store.snapshot.notice == "记录已保存")

        let idleWs = try #require(store.snapshot.workspaces)
        #expect(idleWs.quickNote.canStart)
        #expect(idleWs.allDay.canStart)
        #expect(idleWs.liveMinutes.canStart)

        store.startCapture(.quickNote, stayOnPage: true)
        let activeWs = try #require(store.snapshot.workspaces)
        #expect(!activeWs.quickNote.canStart)
        #expect(!activeWs.allDay.canStart)
        #expect(!activeWs.liveMinutes.canStart)
        store.performCaptureAction(.cancel)

        let minimalPayload = """
        {
          "version": 2,
          "generation": 4,
          "section": "live_minutes",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [],
          "detail": null,
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": true, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let minimalDecoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(minimalPayload.utf8))
        let emptyLiveMinutes = minimalDecoded.workspaces?.liveMinutes ?? .empty
        #expect(!emptyLiveMinutes.isActive)
        #expect(emptyLiveMinutes.activeRecordId == nil)
    }
}
