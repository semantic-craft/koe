import AVFoundation
import Foundation
import KoeAppleShared

@MainActor
final class NativePlayback {
    weak var store: HostSessionStore?
    private let player = AVPlayer()
    private var loadedRecordId: String?
    private var loadedPath: String?
    private var lastReportedPosition: UInt64?
    private var seeking = false
    private var reportedFailure = false
    private var requestGeneration: UInt64 = 0

    func tick() {
        guard let store else { return }
        let desired = store.snapshot.playback
        guard let detail = store.snapshot.detail, let path = detail.audioPath,
              desired.recordId == detail.id else {
            player.pause()
            return
        }
        if loadedRecordId != detail.id || loadedPath != path {
            player.pause()
            loadedRecordId = detail.id
            loadedPath = path
            reportedFailure = false
            seeking = false
            lastReportedPosition = nil
            requestGeneration += 1
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        }
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            if !reportedFailure {
                reportedFailure = true
                store.send("playback", ["isPlaying": false])
                store.reportNativeError("无法播放这段音频。原始文件可能不可用，或格式不受支持。")
            }
            return
        }
        guard item.status == .readyToPlay, !seeking else { return }
        let currentMs = position()
        if lastReportedPosition != desired.positionMs && abs(Double(currentMs) - Double(desired.positionMs)) > 40 {
            seeking = true
            let generation = requestGeneration
            let target = desired.positionMs
            player.seek(to: CMTime(value: Int64(target), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.requestGeneration == generation else { return }
                    self.seeking = false
                    self.lastReportedPosition = target
                }
            }
            return
        }
        let duration = item.duration.seconds
        if desired.isPlaying, duration.isFinite, duration > 0, player.currentTime().seconds >= duration - 0.02 {
            player.pause()
            report(currentMs, playing: false)
            return
        }
        if desired.isPlaying { player.play() } else { player.pause() }
        if currentMs != lastReportedPosition { report(currentMs, playing: desired.isPlaying) }
    }
    private func position() -> UInt64 {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? UInt64(seconds * 1000) : 0
    }
    private func report(_ position: UInt64, playing: Bool) {
        lastReportedPosition = position
        store?.send("playback_progress", ["positionMs": position, "isPlaying": playing])
    }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
}
