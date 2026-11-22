import AVFoundation
import KoeAppleShared
import XCTest
@testable import Koe

@MainActor
final class NativePlaybackIntegrationTests: XCTestCase {
    private func fixture(_ body: @MainActor (HostSessionStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-player-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.send(.setCaptureSystemAudio(enabled: true))
        store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
        let ticket = try XCTUnwrap(store.snapshot.microphone)
        store.send(.microphonePrepared(recordId: ticket.recordId, sessionId: ticket.sessionId, epoch: 0, clockNs: 1_000_000_000))
        for lane in ["microphone", "system"] {
            store.send(.microphoneStarted(
                recordId: ticket.recordId,
                sessionId: ticket.sessionId,
                lane: lane,
                sampleRate: 16000
            ))
            XCTAssertNil(store.snapshot.error)
        }
        for (lane, seq, ns) in [("microphone", UInt64(0), UInt64(1_000_000_000)), ("microphone", 1, 1_100_000_000), ("system", 0, 1_050_000_000)] {
            let receipt = store.ingestMicrophonePCM(
                recordId: ticket.recordId,
                sessionId: ticket.sessionId,
                lane: lane,
                sequence: seq,
                epoch: 0,
                capturedStartNs: ns,
                samples: [Int16](repeating: 100, count: 160)
            )
            XCTAssertEqual(receipt.status, .accepted)
        }
        store.send(.captureAction(action: .end))
        store.send(.microphoneStopped(recordId: ticket.recordId, sessionId: ticket.sessionId, lane: "microphone", sequence: 2, epoch: 0))
        XCTAssertNil(store.snapshot.error)
        store.send(.microphoneStopped(recordId: ticket.recordId, sessionId: ticket.sessionId, lane: "system", sequence: 1, epoch: 0))
        XCTAssertNil(store.snapshot.error)
        store.send(.selectRecord(recordId: ticket.recordId))
        try await body(store)
    }

    private func until(_ label: String, _ predicate: @MainActor () -> Bool, tick: @MainActor () -> Void = {}) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { tick(); await Task.yield() }
        guard predicate() else { XCTFail(label); throw CaptureError(label) }
    }

    func testLateAssetLoadCannotReplaceNewLane() async throws {
        try await fixture { store in
            let pending = PendingPlaybackItems()
            let player = AVPlayer()
            let playback = NativePlayback(player: player, makeItem: pending.make)
            playback.store = store
            defer { playback.stop(); pending.cancelRemaining() }
            playback.tick()
            try await self.until("microphone load pending", { pending.waiters.count == 1 })
            store.send(.selectPlaybackLane(lane: "system"))
            playback.tick()
            try await self.until("system load pending", { pending.waiters.count == 2 })
            let selected = AVPlayerItem(url: URL(fileURLWithPath: try XCTUnwrap(store.snapshot.playback.asset?.audioPath)))
            pending.resolve(1, selected)
            try await self.until("system item installed", { player.currentItem === selected })
            pending.resolve(0, AVPlayerItem(asset: AVMutableComposition()))
            try await self.until("old load completed", { pending.completed == 2 })
            XCTAssertTrue(player.currentItem === selected)
            XCTAssertEqual(store.snapshot.playback.lane, "system")
        }
    }

    func testSeekInsideGapAndLaneSwitchUseCommonPositionWithoutPlayingAudio() async throws {
        try await fixture { store in
            let player = AVPlayer()
            let playback = NativePlayback(player: player)
            playback.store = store
            defer { playback.stop() }
            store.send(.seek(positionMs: 90))
            try await self.until("seek in microphone gap", { player.currentTime().isNumeric && abs(player.currentTime().seconds - 0.09) < 0.0001 }, tick: playback.tick)
            let previous = player.currentItem
            store.send(.selectPlaybackLane(lane: "system"))
            try await self.until("system lane common position", {
                player.currentItem !== previous && player.currentTime().isNumeric && abs(player.currentTime().seconds - 0.09) < 0.0001
            }, tick: playback.tick)
            store.send(.seek(positionMs: 55)); playback.tick()
            store.send(.seek(positionMs: 100)); playback.tick()
            try await self.until("latest seek wins", { player.currentTime().isNumeric && abs(player.currentTime().seconds - 0.1) < 0.0001 }, tick: playback.tick)
            playback.tick()
            XCTAssertEqual(store.snapshot.playback.positionMs, 100)
            XCTAssertFalse(store.snapshot.playback.isPlaying)
            XCTAssertEqual(player.rate, 0)
        }
    }

    func testExplicitPlaybackRequestRetriesFailedLoad() async throws {
        try await fixture { store in
            let player = AVPlayer()
            var attempts = 0
            let playback = NativePlayback(player: player, makeItem: { plan in
                attempts += 1
                if attempts == 1 { throw CaptureError("injected transient read error") }
                return try await NativePlaybackItem.make(plan)
            })
            playback.store = store
            defer { playback.stop() }
            playback.tick()
            try await self.until("load failure reported", { store.nativeError != nil })
            for _ in 0..<10 { playback.tick() }
            XCTAssertEqual(attempts, 1)
            store.send(.seek(positionMs: 100))
            try await self.until("explicit request reloads audio", { player.currentItem != nil }, tick: playback.tick)
            XCTAssertEqual(attempts, 2)
            XCTAssertNil(store.nativeError)
        }
    }

    func testChangedLaneBeforeNextTickRejectsLateLoadFailure() async throws {
        try await fixture { store in
            let pending = PendingPlaybackItems()
            let player = AVPlayer()
            let playback = NativePlayback(player: player, makeItem: pending.make)
            playback.store = store
            defer { playback.stop(); pending.cancelRemaining() }
            playback.tick()
            try await self.until("old load pending", { pending.waiters.count == 1 })
            store.send(.selectPlaybackLane(lane: "system"))
            store.send(.seek(positionMs: 90))
            store.send(.playback(isPlaying: true))
            let desired = store.snapshot.playback
            pending.reject(0)
            try await self.until("old load failed", { pending.completed == 1 })
            XCTAssertEqual(store.snapshot.playback, desired)
            XCTAssertNil(store.nativeError)
            XCTAssertNil(player.currentItem)
        }
    }

    func testTrashingPlayingRecordStopsPlayerSynchronouslyOnSnapshotChange() async throws {
        try await fixture { store in
            let player = AVPlayer()
            let playback = NativePlayback(player: player)
            let delegate = KoeAppDelegate(playback: playback)
            delegate.store = store
            defer {
                delegate.store = nil
                playback.stop()
            }

            let recordId = try XCTUnwrap(store.snapshot.selectedRecordId)
            store.send(.playback(isPlaying: true))
            try await self.until(
                "player item ready and playing",
                { player.currentItem?.status == .readyToPlay && player.rate > 0 },
                tick: playback.tick
            )

            store.send(.trashRecord(recordId: recordId))
            XCTAssertNil(store.snapshot.playback.recordId)
            XCTAssertFalse(store.snapshot.playback.isPlaying)
            XCTAssertNil(player.currentItem)
            XCTAssertEqual(player.rate, 0)
        }
    }

    func testIdlePlaybackTickIsIdempotent() async throws {
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("koe-player-idle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let emptyStore = HostSessionStore(workspacePath: emptyRoot.path)
        defer { emptyStore.shutdown(); try? FileManager.default.removeItem(at: emptyRoot) }

        let countingPlayer = CountingAVPlayer()
        let idlePlayback = NativePlayback(player: countingPlayer)
        idlePlayback.store = emptyStore
        defer { idlePlayback.stop() }

        XCTAssertNil(emptyStore.snapshot.playback.recordId)
        for _ in 0..<10 { idlePlayback.tick() }
        XCTAssertEqual(countingPlayer.replaceCurrentItemCount, 0)
        XCTAssertEqual(countingPlayer.pauseCount, 0)

        try await fixture { store in
            let activePlayer = CountingAVPlayer()
            let playback = NativePlayback(player: activePlayer)
            let delegate = KoeAppDelegate(playback: playback)
            delegate.store = store
            defer {
                delegate.store = nil
                playback.stop()
            }

            let recordId = try XCTUnwrap(store.snapshot.selectedRecordId)
            try await self.until(
                "player item ready and idle",
                { activePlayer.currentItem?.status == .readyToPlay },
                tick: playback.tick
            )
            XCTAssertFalse(store.snapshot.playback.isPlaying)
            let pausesWhileSelectedIdle = activePlayer.pauseCount
            for _ in 0..<10 { playback.tick() }
            XCTAssertEqual(activePlayer.pauseCount, pausesWhileSelectedIdle)

            store.send(.playback(isPlaying: true))
            try await self.until(
                "player item ready and playing",
                { activePlayer.currentItem?.status == .readyToPlay && activePlayer.rate > 0 },
                tick: playback.tick
            )

            let replacesBeforeTrash = activePlayer.replaceCurrentItemCount
            store.send(.trashRecord(recordId: recordId))
            XCTAssertNil(store.snapshot.playback.recordId)
            XCTAssertNil(activePlayer.currentItem)
            XCTAssertEqual(activePlayer.replaceCurrentItemCount, replacesBeforeTrash + 1)

            let replacesAfterTrash = activePlayer.replaceCurrentItemCount
            let pausesAfterTrash = activePlayer.pauseCount
            for _ in 0..<5 { playback.tick() }
            XCTAssertEqual(activePlayer.replaceCurrentItemCount, replacesAfterTrash)
            XCTAssertEqual(activePlayer.pauseCount, pausesAfterTrash)
        }
    }

}

private final class CountingAVPlayer: AVPlayer {
    var pauseCount = 0
    var replaceCurrentItemCount = 0

    override func pause() {
        MainActor.assumeIsolated { pauseCount += 1 }
        super.pause()
    }

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        MainActor.assumeIsolated { replaceCurrentItemCount += 1 }
        super.replaceCurrentItem(with: item)
    }
}

@MainActor
private final class PendingPlaybackItems {
    var waiters: [CheckedContinuation<AVPlayerItem, Error>?] = []
    var completed = 0
    func make(_ plan: PlaybackAssetSnapshot) async throws -> AVPlayerItem {
        defer { completed += 1 }
        let item: AVPlayerItem = try await withCheckedThrowingContinuation { waiters.append($0) }
        return item
    }
    func resolve(_ index: Int, _ item: AVPlayerItem) { waiters[index]?.resume(returning: item); waiters[index] = nil }
    func reject(_ index: Int) { waiters[index]?.resume(throwing: CaptureError("old load failed")); waiters[index] = nil }
    func cancelRemaining() {
        for index in waiters.indices { waiters[index]?.resume(throwing: CancellationError()); waiters[index] = nil }
    }
}
