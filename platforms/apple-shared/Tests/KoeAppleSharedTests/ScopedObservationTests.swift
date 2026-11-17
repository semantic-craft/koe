import CKoeHostApi
import Foundation
import Observation
import Testing
@testable import KoeAppleShared

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private func armObservation(_ read: @escaping @MainActor () -> Void) -> ObservationCounter {
    let counter = ObservationCounter()
    withObservationTracking {
        read()
    } onChange: {
        counter.increment()
    }
    return counter
}

@Suite("Scoped @Observable slices, C ABI fast paths, and offscreen gate")
struct ScopedObservationTests {
    @MainActor
    private func createPlayableMeetingRecord(
        in store: HostSessionStore,
        nowEpochSec: UInt64 = 1_800_000_000
    ) throws -> String {
        store.send(.startCaptureMode(mode: .meeting, stayOnPage: true), nowEpochSec: nowEpochSec)
        let mic = try #require(store.snapshot.microphone)
        store.send(.microphonePrepared(recordId: mic.recordId, sessionId: mic.sessionId, epoch: 0, clockNs: 1_000_000_000), nowEpochSec: nowEpochSec)
        store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16_000), nowEpochSec: nowEpochSec)

        let chunkSamples = [Int16](repeating: 1_200, count: 8_000)
        let r0 = store.ingestMicrophonePCM(
            recordId: mic.recordId,
            sessionId: mic.sessionId,
            lane: "microphone",
            sequence: 0,
            epoch: 0,
            capturedStartNs: 1_000_000_000,
            samples: chunkSamples,
            nowEpochSec: nowEpochSec
        )
        #expect(r0.status == .accepted)
        let r1 = store.ingestMicrophonePCM(
            recordId: mic.recordId,
            sessionId: mic.sessionId,
            lane: "microphone",
            sequence: 1,
            epoch: 0,
            capturedStartNs: 1_500_000_000,
            samples: chunkSamples,
            nowEpochSec: nowEpochSec
        )
        #expect(r1.status == .accepted)
        store.refreshSnapshotIfNeeded(minGeneration: r1.generation, nowEpochSec: nowEpochSec)

        store.performCaptureAction(.end)
        store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 2, epoch: 0), nowEpochSec: nowEpochSec + 1)
        return mic.recordId
    }

    @Test("Playback progress fast path updates only playback slice and preserves snapshot parity")
    @MainActor
    func playbackProgressFastPathIsolatesUnrelatedSlices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let nowSec: UInt64 = 1_800_000_100
        let recordId = try createPlayableMeetingRecord(in: store, nowEpochSec: nowSec)
        store.send(.selectRecord(recordId: recordId), nowEpochSec: nowSec + 2)
        store.send(.playback(isPlaying: true), nowEpochSec: nowSec + 2)

        let requestId = store.snapshot.playback.requestId
        #expect(store.snapshot.playback.isPlaying)
        #expect(store.navigation.hasPlayableDetailAsset)

        let sidebarFires = armObservation { _ = store.sidebar }
        let navigationFires = armObservation { _ = store.navigation }
        let todayFires = armObservation { _ = store.today }
        let recordsFires = armObservation { _ = store.records }
        let detailFires = armObservation { _ = store.recordDetail }
        let liveMinutesFires = armObservation { _ = store.liveMinutesWorkspace }
        let snapshotIgnoredFires = armObservation { _ = store.snapshot }

        var playbackFireCount = 0
        for (index, targetMs) in ([250, 500, 750, 1_000] as [UInt64]).enumerated() {
            let tickSec = nowSec + 2 + UInt64(index)
            let playbackProbe = armObservation { _ = store.playback }
            store.reportPlaybackProgress(
                recordId: recordId,
                requestId: requestId,
                positionMs: targetMs,
                isPlaying: true,
                nowEpochSec: tickSec
            )
            playbackFireCount += playbackProbe.count
            #expect(store.playback.positionMs == targetMs)
            #expect(store.snapshot.playback.positionMs == targetMs)
            #expect(store.lastProjectedNowSec == tickSec)
        }
        #expect(playbackFireCount == 4)

        let duplicateProbe = armObservation { _ = store.playback }
        let generationBeforeDuplicate = store.snapshot.generation
        store.reportPlaybackProgress(
            recordId: recordId,
            requestId: requestId,
            positionMs: 1_000,
            isPlaying: true,
            nowEpochSec: nowSec + 5
        )
        #expect(duplicateProbe.count == 0)
        #expect(store.snapshot.generation == generationBeforeDuplicate)

        #expect(sidebarFires.count == 0)
        #expect(navigationFires.count == 0)
        #expect(todayFires.count == 0)
        #expect(recordsFires.count == 0)
        #expect(detailFires.count == 0)
        #expect(liveMinutesFires.count == 0)
        #expect(snapshotIgnoredFires.count == 0)

        let fastPathSnapshot = store.snapshot
        let rawPtr = try #require(koe_host_session_snapshot_json(store.handle, nowSec + 5))
        defer { koe_host_string_free(rawPtr) }
        let authoritative = try JSONDecoder().decode(
            HostSnapshot.self,
            from: Data(String(cString: rawPtr).utf8)
        )
        #expect(fastPathSnapshot == authoritative)

        store.refreshSnapshot(nowEpochSec: 0)
        store.reportPlaybackProgress(
            recordId: recordId,
            requestId: requestId,
            positionMs: 800,
            isPlaying: true,
            nowEpochSec: 0
        )
        #expect(store.lastProjectedNowSec > 0)
        let wallClockPtr = try #require(
            koe_host_session_snapshot_json(store.handle, store.lastProjectedNowSec)
        )
        defer { koe_host_string_free(wallClockPtr) }
        let wallClockAuthoritative = try JSONDecoder().decode(
            HostSnapshot.self,
            from: Data(String(cString: wallClockPtr).utf8)
        )
        #expect(store.snapshot == wallClockAuthoritative)
    }

    @Test("Unapplied playback progress receipt catches up out-of-band Rust generation bumps")
    @MainActor
    func unappliedPlaybackReceiptCatchesUpOutOfBandGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let nowSec: UInt64 = 1_800_000_300
        let recordId = try createPlayableMeetingRecord(in: store, nowEpochSec: nowSec)
        store.send(.selectRecord(recordId: recordId), nowEpochSec: nowSec + 2)
        store.send(.playback(isPlaying: true), nowEpochSec: nowSec + 2)
        let requestId = store.snapshot.playback.requestId
        store.reportPlaybackProgress(
            recordId: recordId,
            requestId: requestId,
            positionMs: 400,
            isPlaying: true,
            nowEpochSec: nowSec + 2
        )
        let staleStoreGeneration = store.snapshot.generation

        let outOfBandCommand = #"{"type":"create_note","title":"Bridge Note","text":"Created out of band","stayOnPage":true}"#
        let outOfBandPtr = outOfBandCommand.withCString { cmdPtr in
            koe_host_session_dispatch_json(store.handle, cmdPtr, nowSec + 2)
        }
        if let outOfBandPtr { koe_host_string_free(outOfBandPtr) }
        let rustGen = koe_host_session_generation(store.handle)
        #expect(rustGen > staleStoreGeneration)
        #expect(store.snapshot.generation == staleStoreGeneration)

        store.reportPlaybackProgress(
            recordId: recordId,
            requestId: requestId,
            positionMs: 400,
            isPlaying: true,
            nowEpochSec: nowSec + 2
        )
        #expect(store.snapshot.generation == rustGen)
        #expect(store.records.contains { $0.title == "Bridge Note" })
    }

    @Test("PCM ingest + batched refresh updates activeCapture and liveMinutesCoverage without invalidating unrelated or stripped workspace slices")
    @MainActor
    func pcmIngestAndCoverageIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let nowSec: UInt64 = 1_800_000_500
        store.send(.startCaptureMode(mode: .meeting, stayOnPage: true), nowEpochSec: nowSec)
        let mic = try #require(store.snapshot.microphone)
        store.send(.microphonePrepared(recordId: mic.recordId, sessionId: mic.sessionId, epoch: 0, clockNs: 2_000_000_000), nowEpochSec: nowSec)
        store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16_000), nowEpochSec: nowSec)

        let bootstrap = store.ingestMicrophonePCM(
            recordId: mic.recordId,
            sessionId: mic.sessionId,
            lane: "microphone",
            sequence: 0,
            epoch: 0,
            capturedStartNs: 2_000_000_000,
            samples: [Int16](repeating: 400, count: 4_000),
            nowEpochSec: nowSec
        )
        #expect(bootstrap.status == .accepted)
        #expect(bootstrap.nextSequence == 1)
        store.refreshSnapshotIfNeeded(minGeneration: bootstrap.generation, nowEpochSec: nowSec)
        #expect(store.activeCapture != nil)
        #expect(store.liveMinutesWorkspace.isActive)
        #expect(store.liveMinutesWorkspace.coverage == nil)
        #expect(store.liveMinutesCoverage?.audioDurationMs == 250)

        let playbackFires = armObservation { _ = store.playback }
        let askFires = armObservation { _ = store.ask }
        let tasksFires = armObservation { _ = store.tasks }
        let memoriesFires = armObservation { _ = store.memories }
        let settingsFires = armObservation { _ = store.settings }
        let deviceFires = armObservation { _ = store.device }
        let liveMinutesWorkspaceFires = armObservation { _ = store.liveMinutesWorkspace }
        let captureStudioFires = armObservation { _ = store.captureStudio }
        let actionsFires = armObservation { _ = store.activeCaptureActions }

        let preBatchCaptureProbe = armObservation { _ = store.activeCapture }
        let snapshotGenBeforeBatch = store.snapshot.generation
        var latestReceipt = bootstrap
        for seq: UInt64 in 1...3 {
            latestReceipt = store.ingestMicrophonePCM(
                recordId: mic.recordId,
                sessionId: mic.sessionId,
                lane: "microphone",
                sequence: seq,
                epoch: 0,
                capturedStartNs: 2_000_000_000 + seq * 250_000_000,
                samples: [Int16](repeating: Int16(600 + seq * 300), count: 4_000),
                nowEpochSec: nowSec
            )
            #expect(latestReceipt.status == .accepted)
            #expect(latestReceipt.nextSequence == seq + 1)
        }
        #expect(store.snapshot.generation == snapshotGenBeforeBatch)
        #expect(preBatchCaptureProbe.count == 0)

        let staleReceipt = store.ingestMicrophonePCM(
            recordId: mic.recordId,
            sessionId: "stale-session-id",
            lane: "microphone",
            sequence: 4,
            epoch: 0,
            capturedStartNs: nil,
            samples: [Int16](repeating: 100, count: 320),
            nowEpochSec: nowSec
        )
        #expect(staleReceipt.status == .staleSession)

        let coverageProbe = armObservation { _ = store.liveMinutesCoverage }
        store.refreshSnapshotIfNeeded(minGeneration: staleReceipt.generation, nowEpochSec: nowSec)

        #expect(preBatchCaptureProbe.count == 1)
        #expect(coverageProbe.count == 1)
        #expect(store.activeCapture?.durationMs == 1_000)
        #expect(store.liveMinutesCoverage?.audioDurationMs == 1_000)
        #expect(store.liveMinutesWorkspace.coverage == nil)

        #expect(liveMinutesWorkspaceFires.count == 0)
        #expect(playbackFires.count == 0)
        #expect(askFires.count == 0)
        #expect(tasksFires.count == 0)
        #expect(memoriesFires.count == 0)
        #expect(settingsFires.count == 0)
        #expect(deviceFires.count == 0)
        #expect(captureStudioFires.count == 0)
        #expect(actionsFires.count == 0)

        store.performCaptureAction(.end)
        store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 4, epoch: 0), nowEpochSec: nowSec + 1)
        store.send(.selectRecord(recordId: mic.recordId), nowEpochSec: nowSec + 1)
        let detail = try #require(store.recordDetail.detail)
        #expect(detail.durationMs == 1_000)
        let audioPath = try #require(detail.audioPath)
        #expect(FileManager.default.fileExists(atPath: audioPath))
    }

    @Test("Offscreen setUISlicesActive(false) suppresses all @Observable invalidations while keeping adapters live, then reconciles on reactivation")
    @MainActor
    func offscreenGateSuppressesSlicesAndReconcilesOnWake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let nowSec: UInt64 = 1_800_001_000
        let playableRecordId = try createPlayableMeetingRecord(in: store, nowEpochSec: nowSec)
        store.send(.selectRecord(recordId: playableRecordId), nowEpochSec: nowSec + 2)
        store.send(.playback(isPlaying: true), nowEpochSec: nowSec + 2)
        let playbackReqId = store.snapshot.playback.requestId

        var callbackGenerations: [UInt64] = []
        store.onSnapshotChanged = { snap in
            callbackGenerations.append(snap.generation)
        }

        store.setUISlicesActive(false)
        #expect(!store.isUISlicesActive)

        let sliceCounters = [
            armObservation { _ = store.navigation },
            armObservation { _ = store.sidebar },
            armObservation { _ = store.today },
            armObservation { _ = store.quickNoteWorkspace },
            armObservation { _ = store.allDayWorkspace },
            armObservation { _ = store.liveMinutesWorkspace },
            armObservation { _ = store.liveMinutesCoverage },
            armObservation { _ = store.recordDetail },
            armObservation { _ = store.records },
            armObservation { _ = store.tasks },
            armObservation { _ = store.memories },
            armObservation { _ = store.trashRecords },
            armObservation { _ = store.ask },
            armObservation { _ = store.captureStudio },
            armObservation { _ = store.device },
            armObservation { _ = store.settings },
            armObservation { _ = store.playback },
            armObservation { _ = store.activeCapture },
            armObservation { _ = store.activeCaptureActions },
            armObservation { _ = store.liveCaption },
            armObservation { _ = store.snapshot },
            armObservation { _ = store.nativeError }
        ]

        store.reportPlaybackProgress(
            recordId: playableRecordId,
            requestId: playbackReqId,
            positionMs: 600,
            isPlaying: true,
            nowEpochSec: nowSec + 2
        )
        #expect(store.snapshot.playback.positionMs == 600)
        #expect(store.playback.positionMs == 0)

        store.send(.createNote(title: "Offscreen Note", text: "Created while window closed.", stayOnPage: true), nowEpochSec: nowSec + 3)
        let noteCard = try #require(store.snapshot.workspaces?.quickNote.cards.first { $0.title == "Offscreen Note" })
        let noteSeg = try #require(noteCard.segments.first)
        store.send(.createTask(recordId: noteCard.id, segmentId: noteSeg.id), nowEpochSec: nowSec + 3)
        store.send(.navigate(section: "tasks"), nowEpochSec: nowSec + 3)
        store.refreshSnapshot(nowEpochSec: nowSec + 3)
        store.reportPlaybackProgress(
            recordId: playableRecordId,
            requestId: playbackReqId,
            positionMs: 700,
            isPlaying: true,
            nowEpochSec: nowSec + 3
        )
        store.reportNativeError("离屏原生错误")

        #expect(store.snapshot.records.count == 2)
        #expect(store.snapshot.tasks.count == 1)
        #expect(store.snapshot.section == "tasks")
        #expect(store.snapshot.playback.positionMs == 700)
        #expect(store.nativeError == "离屏原生错误")
        #expect(callbackGenerations.count >= 5)

        #expect(sliceCounters.allSatisfy { $0.count == 0 })
        #expect(store.records.count == 1)
        #expect(store.tasks.isEmpty)
        #expect(store.playback.positionMs == 0)
        #expect(store.navigation.effectiveError == nil)

        let wakeNavProbe = armObservation { _ = store.navigation }
        let wakeRecordsProbe = armObservation { _ = store.records }
        let wakeTasksProbe = armObservation { _ = store.tasks }
        let wakePlaybackProbe = armObservation { _ = store.playback }

        store.setUISlicesActive(true)
        #expect(store.isUISlicesActive)

        #expect(wakeNavProbe.count == 1)
        #expect(wakeRecordsProbe.count == 1)
        #expect(wakeTasksProbe.count == 1)
        #expect(wakePlaybackProbe.count == 1)

        #expect(store.records.count == 2)
        #expect(store.tasks.count == 1)
        #expect(store.sidebar.section == "tasks")
        #expect(store.navigation.section == "tasks")
        #expect(store.navigation.effectiveError == "离屏原生错误")
        #expect(store.playback.positionMs == 700)

        let cleanCycleProbe = armObservation { _ = store.navigation }
        store.setUISlicesActive(false)
        store.setUISlicesActive(true)
        #expect(cleanCycleProbe.count == 0)
    }
}
