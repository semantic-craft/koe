import Foundation
import Testing
@testable import KoeAppleShared

@Suite("LiveMinutes and VoiceInput mode workspaces")
struct ModeWorkspacesLiveVoiceTests {
    @Test("LiveMinutes workspace resolves coverage, retrospective meeting switching, legacy fallback, and meeting Markdown export")
    @MainActor
    func liveMinutesRetrospectiveCoverageAndExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        func captureMeetingRecord(nowEpochSec: UInt64) throws -> String {
            store.send("start_capture_mode", ["mode": "meeting", "stayOnPage": true], nowEpochSec: nowEpochSec)
            let mic = try #require(store.snapshot.microphone)
            store.send("microphone_prepared", [
                "recordId": mic.recordId,
                "sessionId": mic.sessionId,
                "epoch": 0,
                "clockNs": 1_000_000_000
            ], nowEpochSec: nowEpochSec)
            store.send("microphone_started", [
                "recordId": mic.recordId,
                "sessionId": mic.sessionId,
                "lane": "microphone",
                "sampleRate": 16000
            ], nowEpochSec: nowEpochSec)
            store.send("microphone_chunk", [
                "recordId": mic.recordId,
                "sessionId": mic.sessionId,
                "lane": "microphone",
                "sequence": 0,
                "samples": [Int16](repeating: 180, count: 320),
                "timing": ["epoch": 0, "capturedStartNs": 1_000_000_000]
            ], nowEpochSec: nowEpochSec)
            store.performCaptureAction(.end)
            store.send("microphone_stopped", [
                "recordId": mic.recordId,
                "sessionId": mic.sessionId,
                "lane": "microphone",
                "sequence": 1,
                "epoch": 0
            ], nowEpochSec: nowEpochSec)
            return mic.recordId
        }

        let firstMeetingId = try captureMeetingRecord(nowEpochSec: 1_800_000_000)
        let secondMeetingId = try captureMeetingRecord(nowEpochSec: 1_800_000_060)

        let initialLive = try #require(store.snapshot.workspaces?.liveMinutes)
        #expect(initialLive.pastMeetings.count == 2)
        #expect(firstMeetingId != secondMeetingId)

        store.send("select_live_minutes_record", ["recordId": firstMeetingId])
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

    @Test("VoiceInput 6-step actions dispatch truthful commands and cursor input evaluator distinguishes manual typing from companion stream")
    @MainActor
    func voiceInputStepsAndCursorStreamEvaluator() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let initialVoice = try #require(store.snapshot.workspaces?.voiceInput)
        #expect(!initialVoice.sessionEnabled)
        let step2 = try #require(initialVoice.steps.first(where: { $0.id == "standby_stream" }))
        let command = try #require(step2.actionCommand)
        store.performVoiceInputStepAction(command)

        let enabledVoice = try #require(store.snapshot.workspaces?.voiceInput)
        #expect(enabledVoice.sessionEnabled)
        #expect(store.drainHostActions().isEmpty)

        store.performVoiceInputStepAction("open_responsay_app")
        let hostActions = store.drainHostActions()
        #expect(hostActions.count == 1)

        let idleEval = enabledVoice.evaluateCursorTest(
            text: "   ",
            baselineEpoch: enabledVoice.companionEpoch,
            baselineAudioFrames: enabledVoice.forwardedAudioFrames,
            baselineDictationText: enabledVoice.lastDictationText
        )
        #expect(idleEval.state == .idle)
        #expect(idleEval.statusBadge == "待测试")

        let manualEval = enabledVoice.evaluateCursorTest(
            text: "手动敲入的测试句子",
            baselineEpoch: enabledVoice.companionEpoch,
            baselineAudioFrames: enabledVoice.forwardedAudioFrames,
            baselineDictationText: enabledVoice.lastDictationText
        )
        #expect(manualEval.state == .manualInputOnly)
        #expect(manualEval.statusBadge == "仅检测到手动输入")

        let streamedFixture = VoiceInputWorkspaceSnapshot(
            sessionEnabled: true,
            canToggleSession: true,
            standbyReady: true,
            deviceConnected: true,
            deviceName: "Soundcore Work",
            batteryPercent: 85,
            captureActive: false,
            companionSubscribers: 1,
            companionEpoch: "ep-0",
            companionSequence: 4,
            forwardedAudioFrames: 2,
            lastDictationText: "语音上屏结果",
            bridgeSocketPath: "/tmp/koe.sock",
            boundaryNote: enabledVoice.boundaryNote,
            steps: enabledVoice.steps
        )
        let streamEval = streamedFixture.evaluateCursorTest(
            text: "语音上屏结果",
            baselineEpoch: "ep-0",
            baselineAudioFrames: 0,
            baselineDictationText: nil
        )
        #expect(streamEval.state == .streamVerified)
        #expect(streamEval.statusBadge == "已观测伴侣流")

        _ = VoiceInputView(store: store).body
    }

    @Test("Legacy idle fallback, stayOnPage quick note creation, workspace canStart, and epoch-aware cursor evaluator")
    @MainActor
    func legacyIdleStayOnPageCanStartAndEpochCursorEvaluator() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send("navigate", ["section": "notes"])
        store.send("create_note", [
            "title": "闪记页直存",
            "text": "单条指令留在本页",
            "stayOnPage": true
        ])
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

        let controlEdgeOnly = VoiceInputWorkspaceSnapshot(
            sessionEnabled: true,
            canToggleSession: true,
            standbyReady: true,
            deviceConnected: true,
            deviceName: "Soundcore Work",
            batteryPercent: 80,
            captureActive: false,
            companionSubscribers: 1,
            companionEpoch: "ep-1",
            companionSequence: 5,
            forwardedAudioFrames: 0,
            lastDictationText: nil,
            bridgeSocketPath: "/tmp/koe.sock",
            boundaryNote: idleWs.voiceInput.boundaryNote,
            steps: idleWs.voiceInput.steps
        )
        let edgeEval = controlEdgeOnly.evaluateCursorTest(
            text: "纯手动输入无音频帧",
            baselineEpoch: "ep-1",
            baselineAudioFrames: 0,
            baselineDictationText: nil
        )
        #expect(edgeEval.state == .manualInputOnly)

        let reconnectedStream = VoiceInputWorkspaceSnapshot(
            sessionEnabled: true,
            canToggleSession: true,
            standbyReady: true,
            deviceConnected: true,
            deviceName: "Soundcore Work",
            batteryPercent: 80,
            captureActive: false,
            companionSubscribers: 1,
            companionEpoch: "ep-2",
            companionSequence: 1,
            forwardedAudioFrames: 3,
            lastDictationText: nil,
            bridgeSocketPath: "/tmp/koe.sock",
            boundaryNote: idleWs.voiceInput.boundaryNote,
            steps: idleWs.voiceInput.steps
        )
        let reconnectEval = reconnectedStream.evaluateCursorTest(
            text: "蓝牙重连后语音上屏",
            baselineEpoch: "ep-1",
            baselineAudioFrames: 12,
            baselineDictationText: nil
        )
        #expect(reconnectEval.state == .streamVerified)
    }
}
