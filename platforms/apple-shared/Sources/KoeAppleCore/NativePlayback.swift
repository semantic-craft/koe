import AVFoundation
import os

public final class NotificationToken {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    public init(center: NotificationCenter = .default, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

@MainActor
public final class NativePlayback {
    public weak var store: HostSessionStore?
    public var currentItem: AVPlayerItem? { player.currentItem }
    private let player: AVPlayer
    private let logger: Logger
    private let setSessionActive: (Bool) throws -> Void
    private let makeItem: (PlaybackAssetSnapshot) async throws -> AVPlayerItem
    private var loadedRecordId: String?
    private var loadedPlan: PlaybackAssetSnapshot?
    private var lastReportedPosition: UInt64?
    private var appliedRequest: UInt64?
    private var seekRequest: UInt64?
    private var failedRequest: UInt64?
    private var loadTask: Task<Void, Never>?
    private var itemObservers: [NotificationToken] = []
    private var statusObservation: NSKeyValueObservation?
    private var sessionActive = false
    private var isSyncingPlayback = false

    public init(player: AVPlayer = AVPlayer(),
                logger: Logger = Logger(subsystem: "com.semanticcraft.koe", category: "playback"),
                setSessionActive: @escaping (Bool) throws -> Void = { _ in },
                makeItem: @escaping (PlaybackAssetSnapshot) async throws -> AVPlayerItem = NativePlaybackItem.make) {
        self.player = player
        self.logger = logger
        self.setSessionActive = setSessionActive
        self.makeItem = makeItem
    }

    private var selected: PlaybackSnapshot? {
        guard let desired = store?.playbackRequest, desired.recordId == loadedRecordId,
              desired.asset == loadedPlan else { return nil }
        return desired
    }

    private func settledPosition(for desired: PlaybackSnapshot) -> UInt64 {
        guard selected != nil, appliedRequest == desired.requestId, seekRequest == nil else { return desired.positionMs }
        return position()
    }

    public func tick() {
        guard !isSyncingPlayback, let desired = store?.playbackRequest else { return }
        isSyncingPlayback = true
        defer { isSyncingPlayback = false }
        do {
            guard let id = desired.recordId, let plan = desired.asset else {
                if desired.isPlaying, desired.recordId != nil {
                    throw CaptureError("找不到录音文件。")
                }
                unload()
                try updateSession(false)
                return
            }
            if loadedRecordId != id || loadedPlan != plan || failedRequest.map({ $0 != desired.requestId }) == true {
                unload()
                loadedRecordId = id
                loadedPlan = plan
                try updateSession(false)
                load(plan)
            }
            guard failedRequest == nil, let item = player.currentItem else { return }
            if item.status == .failed {
                throw item.error ?? CaptureError("音频文件无法读取。")
            }
            guard item.status == .readyToPlay else { return }
            if !desired.isPlaying {
                if player.rate != 0 { player.pause() }
                try updateSession(false)
            }
            if let request = seekRequest {
                if request == desired.requestId { return }
                seekRequest = nil
                item.cancelPendingSeeks()
            }
            let currentMs = position()
            if appliedRequest != desired.requestId {
                appliedRequest = desired.requestId
                if currentMs != desired.positionMs {
                    seek(item, to: desired)
                    return
                }
            }
            if desired.isPlaying {
                if item.duration.isNumeric && player.currentTime() >= item.duration {
                    ended(item)
                    return
                }
                try updateSession(true)
                if player.rate == 0 { player.play() }
            }
            if currentMs != lastReportedPosition { report(desired, currentMs, playing: desired.isPlaying) }
        } catch {
            fail(error)
        }
    }

    private func load(_ plan: PlaybackAssetSnapshot) {
        logger.info("正在加载回放音频，分段数 \(plan.segments.count)")
        loadTask = Task { [weak self, makeItem] in
            do {
                let item = try await makeItem(plan)
                guard !Task.isCancelled, let self, self.selected != nil else { return }
                self.loadTask = nil
                self.observe(item)
                self.player.replaceCurrentItem(with: item)
                self.tick()
            } catch {
                guard !Task.isCancelled, let self, self.selected != nil else { return }
                self.loadTask = nil
                self.fail(error)
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        itemObservers = [
            NotificationToken(center: center, token: center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                MainActor.assumeIsolated { if let item { self?.ended(item) } }
            }),
            NotificationToken(center: center, token: center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] note in
                let noteError = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self, let item, item === self.player.currentItem, self.selected != nil else { return }
                    self.fail(noteError ?? item.error ?? CaptureError("播放意外终止。"))
                }
            }),
        ]
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.selected != nil else { return }
                self.tick()
            }
        }
    }

    private func seek(_ item: AVPlayerItem, to desired: PlaybackSnapshot) {
        let request = desired.requestId
        let target = desired.positionMs
        player.pause()
        seekRequest = request
        logger.debug("回放定位到 \(target) ms")
        player.seek(to: CMTime(value: Int64(target), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.seekRequest == request else { return }
                self.seekRequest = nil
                guard self.selected?.requestId == request else { return }
                guard finished else { self.fail(CaptureError("无法定位到指定播放位置。")); return }
                self.lastReportedPosition = target
                self.tick()
            }
        }
    }

    private func ended(_ item: AVPlayerItem) {
        guard player.currentItem === item, let desired = selected, desired.isPlaying,
              desired.requestId == appliedRequest, seekRequest == nil,
              item.duration.isNumeric, player.currentTime() >= item.duration else { return }
        logger.info("回放结束，位置 \(self.position()) ms")
        finish(desired, at: position())
    }

    public func interrupt() {
        guard let desired = store?.playbackRequest, desired.isPlaying else { return }
        logger.info("音频会话中断，暂停回放")
        finish(desired, at: settledPosition(for: desired))
    }

    private func position() -> UInt64 {
        let time = player.currentTime()
        return time.isNumeric && time >= .zero ? UInt64(CMTimeConvertScale(time, timescale: 1000, method: .roundTowardZero).value) : 0
    }

    private func report(_ desired: PlaybackSnapshot, _ position: UInt64, playing: Bool) {
        guard let id = desired.recordId else { return }
        lastReportedPosition = position
        store?.reportPlaybackProgress(recordId: id, requestId: desired.requestId, positionMs: position, isPlaying: playing)
    }

    private func updateSession(_ active: Bool) throws {
        guard sessionActive != active else { return }
        try setSessionActive(active)
        sessionActive = active
    }

    private func finish(_ desired: PlaybackSnapshot, at position: UInt64) {
        player.pause()
        do {
            try updateSession(false)
            report(desired, position, playing: false)
        } catch {
            fail(error)
        }
    }

    private var activeDiagnostics: HostDiagnosticLog { store?.diagnostics ?? .shared }

    private func fail(_ error: Error) {
        let desired = store?.playbackRequest
        let current = desired.map(settledPosition) ?? 0
        discardItem()
        failedRequest = desired?.requestId
        activeDiagnostics.error(category: "playback", event: "playback_failed", error: error)
        var message = "无法播放这段音频：\(error.localizedDescription)"
        do {
            try updateSession(false)
        } catch {
            activeDiagnostics.warning(category: "playback", event: "session_deactivate_failed", error: error)
            message += " 停用音频会话失败：\(error.localizedDescription)"
        }
        if let desired { report(desired, current, playing: false) }
        store?.reportNativeError(message)
    }

    private func discardItem() {
        loadTask?.cancel()
        loadTask = nil
        statusObservation = nil
        itemObservers.removeAll()
        if player.currentItem != nil {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        seekRequest = nil
        appliedRequest = nil
    }

    private func unload() {
        discardItem()
        loadedRecordId = nil
        loadedPlan = nil
        failedRequest = nil
        lastReportedPosition = nil
    }

    public func stop() {
        let desired = store?.playbackRequest
        let current = desired.map(settledPosition) ?? 0
        isSyncingPlayback = true
        defer { isSyncingPlayback = false }
        unload()
        do {
            try updateSession(false)
            if let desired, desired.isPlaying { report(desired, current, playing: false) }
        } catch {
            fail(error)
        }
    }
}
