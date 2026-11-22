import KoeAppleCore
import MediaPlayer

enum IOSRemoteCommand: CaseIterable { case play, pause, toggle, seek, skipBackward, skipForward }
typealias IOSRemoteHandler = @MainActor @Sendable (Double?) -> MPRemoteCommandHandlerStatus

@MainActor
protocol IOSMediaCenter: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    func setEnabled(_ value: Bool, for command: IOSRemoteCommand)
    func addTarget(for command: IOSRemoteCommand, handler: @escaping IOSRemoteHandler) -> Any
    func removeTarget(_ token: Any, for command: IOSRemoteCommand)
}

@MainActor
final class IOSSystemMediaCenter: IOSMediaCenter {
    typealias TargetBinder = (MPRemoteCommand, @escaping @Sendable (Double?) -> MPRemoteCommandHandlerStatus) -> Any
    private let bindTarget: TargetBinder

    init(bindTarget: @escaping TargetBinder = { remote, invoke in
        remote.addTarget { @Sendable event in
            invoke((event as? MPChangePlaybackPositionCommandEvent)?.positionTime)
        }
    }) {
        self.bindTarget = bindTarget
    }

    var nowPlayingInfo: [String: Any]? {
        get { MPNowPlayingInfoCenter.default().nowPlayingInfo }
        set { MPNowPlayingInfoCenter.default().nowPlayingInfo = newValue }
    }

    private func remote(_ command: IOSRemoteCommand) -> MPRemoteCommand {
        let center = MPRemoteCommandCenter.shared()
        switch command {
        case .play: return center.playCommand
        case .pause: return center.pauseCommand
        case .toggle: return center.togglePlayPauseCommand
        case .seek: return center.changePlaybackPositionCommand
        case .skipBackward: return center.skipBackwardCommand
        case .skipForward: return center.skipForwardCommand
        }
    }

    func setEnabled(_ value: Bool, for command: IOSRemoteCommand) {
        remote(command).isEnabled = value
    }

    func addTarget(for command: IOSRemoteCommand, handler: @escaping IOSRemoteHandler) -> Any {
        let remote = remote(command)
        if let skip = remote as? MPSkipIntervalCommand { skip.preferredIntervals = [15] }
        return bindTarget(remote) { @Sendable seconds in
            if Thread.isMainThread { return MainActor.assumeIsolated { handler(seconds) } }
            Task { @MainActor in _ = handler(seconds) }
            return .success
        }
    }

    func removeTarget(_ token: Any, for command: IOSRemoteCommand) {
        remote(command).removeTarget(token)
    }
}

@MainActor
final class IOSNowPlayingController {
    // Cache only the projection published to MediaPlayer. Rust owns playback state.
    private struct Info: Equatable {
        let title: String
        let durationSeconds: Double
        let durationMs: UInt64
        let positionMs: UInt64
        let isPlaying: Bool

        init?(_ snapshot: HostSnapshot) {
            let playback = snapshot.playback
            guard let id = playback.recordId else { return nil }
            let detail = snapshot.detail.flatMap { $0.id == id ? $0 : nil }
            let record = detail == nil ? snapshot.records.first { $0.id == id } : nil
            title = detail?.title ?? record?.title ?? "Koe 录音"
            if let asset = playback.asset {
                let ns = UInt64(max(0, asset.durationNs))
                durationSeconds = Double(ns) / 1_000_000_000
                durationMs = ns / 1_000_000
            } else {
                durationMs = detail?.durationMs ?? record?.durationMs ?? 0
                durationSeconds = Double(durationMs) / 1000
            }
            positionMs = playback.positionMs
            isPlaying = playback.isPlaying
        }

        var dictionary: [String: Any] {
            [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: "Koe",
             MPMediaItemPropertyPlaybackDuration: durationSeconds,
             MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
             MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        }
    }

    private let center: any IOSMediaCenter
    private let refreshPosition: () -> Void
    private let send: (HostCommand) -> Void
    private var targets: [IOSRemoteCommand: Any] = [:]
    private var info: Info?
    private var isShutdown = false

    init(center: any IOSMediaCenter, refreshPosition: @escaping () -> Void = {},
         send: @escaping (HostCommand) -> Void) {
        self.center = center
        self.refreshPosition = refreshPosition
        self.send = send
        center.nowPlayingInfo = nil
        for command in IOSRemoteCommand.allCases {
            center.setEnabled(false, for: command)
            targets[command] = center.addTarget(for: command) { [weak self] seconds in
                self?.handle(command, seconds: seconds) ?? .noActionableNowPlayingItem
            }
        }
    }

    func sync(_ snapshot: HostSnapshot) {
        guard !isShutdown else { return }
        let next = Info(snapshot)
        guard next != info else { return }
        if (next == nil) != (info == nil) {
            for command in IOSRemoteCommand.allCases { center.setEnabled(next != nil, for: command) }
        }
        info = next
        center.nowPlayingInfo = next?.dictionary
    }

    private func handle(_ command: IOSRemoteCommand, seconds: Double?) -> MPRemoteCommandHandlerStatus {
        guard !isShutdown, info != nil else { return .noActionableNowPlayingItem }
        // Background playback can advance while Rust's foreground poll timer sleeps.
        refreshPosition()
        guard let info else { return .noActionableNowPlayingItem }
        switch command {
        case .play: send(.playback(isPlaying: true))
        case .pause: send(.playback(isPlaying: false))
        case .toggle: send(.playback(isPlaying: !info.isPlaying))
        case .seek:
            guard let seconds, seconds.isFinite else { return .commandFailed }
            let millis = max(0, seconds) * 1000
            send(.seek(positionMs: millis >= Double(info.durationMs) ? info.durationMs : UInt64(millis)))
        case .skipBackward:
            let target = info.positionMs - min(15_000, info.positionMs)
            send(.seek(positionMs: min(target, info.durationMs)))
        case .skipForward:
            let position = min(info.positionMs, info.durationMs)
            send(.seek(positionMs: position + min(15_000, info.durationMs - position)))
        }
        return .success
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        info = nil
        center.nowPlayingInfo = nil
        for (command, token) in targets {
            center.setEnabled(false, for: command)
            center.removeTarget(token, for: command)
        }
        targets.removeAll()
    }

    isolated deinit { shutdown() }
}
