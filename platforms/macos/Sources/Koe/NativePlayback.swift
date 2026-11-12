import AVFoundation
import Foundation
import KoeAppleShared

@MainActor
final class NativePlayback {
    weak var store: HostSessionStore?
    private let player: AVPlayer
    private let makeItem: (PlaybackAssetSnapshot) async throws -> AVPlayerItem
    private var loadedRecordId: String?
    private var loadedPlan: PlaybackAssetSnapshot?
    private var lastReportedPosition: UInt64?
    private var appliedRequest: UInt64?
    private var seekRequest: UInt64?
    private var failedRequest: UInt64?
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var isSyncingPlayback = false

    init(player: AVPlayer = AVPlayer(), makeItem: @escaping (PlaybackAssetSnapshot) async throws -> AVPlayerItem = NativePlaybackItem.make) {
        self.player = player
        self.makeItem = makeItem
    }

    func tick() {
        guard !isSyncingPlayback, let store else { return }
        isSyncingPlayback = true
        defer { isSyncingPlayback = false }
        let desired = store.snapshot.playback
        guard let id = desired.recordId, let plan = desired.asset else {
            stop()
            return
        }
        if loadedRecordId != id || loadedPlan != plan || failedRequest.map({ $0 != desired.requestId }) == true {
            stop()
            loadedRecordId = id
            loadedPlan = plan
            let generation = loadGeneration
            loadTask = Task { [weak self, makeItem] in
                do {
                    let item = try await makeItem(plan)
                    guard let self, self.loadGeneration == generation, !Task.isCancelled,
                          self.store?.snapshot.playback.recordId == id,
                          self.store?.snapshot.playback.asset == plan else { return }
                    self.player.replaceCurrentItem(with: item)
                    self.loadTask = nil
                } catch {
                    guard let self, self.loadGeneration == generation, !Task.isCancelled,
                          self.store?.snapshot.playback.recordId == id,
                          self.store?.snapshot.playback.asset == plan else { return }
                    self.loadTask = nil
                    self.fail()
                }
            }
        }
        guard let item = player.currentItem else { return }
        if item.status == .failed { fail(); return }
        guard item.status == .readyToPlay else { return }
        if let request = seekRequest {
            if request == desired.requestId { return }
            seekRequest = nil
            item.cancelPendingSeeks()
        }
        let currentMs = position()
        if appliedRequest != desired.requestId {
            appliedRequest = desired.requestId
            if currentMs != desired.positionMs {
                player.pause()
                seekRequest = desired.requestId
                let generation = loadGeneration
                let request = desired.requestId
                let target = desired.positionMs
                player.seek(to: CMTime(value: Int64(target), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, self.loadGeneration == generation, self.seekRequest == request else { return }
                        self.seekRequest = nil
                        guard self.store?.snapshot.playback.requestId == request else { return }
                        if finished { self.lastReportedPosition = target } else { self.fail() }
                    }
                }
                return
            }
        }
        if desired.isPlaying, item.duration.isNumeric, player.currentTime() >= item.duration {
            player.pause()
            report(currentMs, playing: false)
            return
        }
        if desired.isPlaying {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
        if currentMs != lastReportedPosition { report(currentMs, playing: desired.isPlaying) }
    }

    private func position() -> UInt64 {
        let time = player.currentTime()
        return time.isNumeric && time >= .zero ? UInt64(CMTimeConvertScale(time, timescale: 1000, method: .roundTowardZero).value) : 0
    }
    private func report(_ position: UInt64, playing: Bool) {
        guard let desired = store?.snapshot.playback, let id = desired.recordId else { return }
        lastReportedPosition = position
        store?.send("playback_progress", ["recordId": id, "requestId": desired.requestId, "positionMs": position, "isPlaying": playing])
    }
    private func fail() {
        guard failedRequest == nil else { return }
        if player.rate != 0 { player.pause() }
        player.replaceCurrentItem(with: nil)
        failedRequest = store?.snapshot.playback.requestId
        report(store?.snapshot.playback.positionMs ?? 0, playing: false)
        store?.reportNativeError("无法播放这段音频。原始文件可能不可用，或格式不受支持。")
    }
    func stop() {
        if loadedRecordId == nil && loadedPlan == nil && loadTask == nil && player.currentItem == nil
            && appliedRequest == nil && seekRequest == nil && lastReportedPosition == nil && failedRequest == nil {
            return
        }
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedRecordId = nil
        loadedPlan = nil
        appliedRequest = nil
        seekRequest = nil
        lastReportedPosition = nil
        failedRequest = nil
    }
}
