import AVFoundation
import KoeAppleCore
import SwiftUI
import UIKit

@MainActor
final class IOSHostCoordinator {
    private let store: HostSessionStore
    private let capture: NativeCapture
    private let playback: NativePlayback
    private var interruptionObserver: NSObjectProtocol?
    private var scenePhase: ScenePhase = .background
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    init(store: HostSessionStore, actions: HostBridgeActions, source: MicrophoneSource? = nil,
         audioSession: IOSAudioSession = IOSAudioSession(),
         nowNanoseconds: @escaping () throws -> UInt64 = HostAudioClock.nowNanoseconds) {
        self.store = store
        let microphone = source ?? IOSAudioSource(audioSession: audioSession) { [weak store] message in
            Task { @MainActor in store?.reportNativeError(message) }
        }
        capture = NativeCapture(source: microphone, logger: IOSAudioSource.logger,
                                nowNanoseconds: nowNanoseconds)
        capture.store = store
        playback = NativePlayback(logger: IOSAudioSession.playbackLogger, setSessionActive: {
            try audioSession.setActive($0, for: .playback)
        })
        playback.store = store
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak playback] notification in
            guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { playback?.interrupt() }
        }
        store.bridgeActions = actions
        store.bridgeActions.resumeMicrophone = { [weak capture] in capture?.resume() }
        store.onSnapshotChanged = { [weak self] _ in self?.updatePolling() }
        updatePolling()
    }

    func setScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        store.setUISlicesActive(phase == .active)
        playback.tick()
        updatePolling()
    }

    private func updatePolling() {
        let keepAwake = store.lifecycle?.keepAwake == true
        if UIApplication.shared.isIdleTimerDisabled != keepAwake {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        guard scenePhase == .active || keepAwake else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }

        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = UInt64(max(0, now - self.lastTick) * 1000)
                self.lastTick = now
                self.store.pollTimers(elapsedMs: elapsed)
                self.capture.apply()
                self.playback.tick()
                self.store.bridgeActions.flushBleOutbound()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        store.onSnapshotChanged = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        playback.stop()
        capture.shutdown()
        store.bridgeActions = HostBridgeActions()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        timer?.invalidate()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }
}
