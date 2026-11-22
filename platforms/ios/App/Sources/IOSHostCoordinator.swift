import AVFoundation
import KoeAppleCore
import SwiftUI
import UIKit

@MainActor
final class IOSHostCoordinator {
    private let store: HostSessionStore
    private let capture: NativeCapture
    private let localTranscription: NativeLocalTranscription
    private let nowPlaying: IOSNowPlayingController
    private let playback: NativePlayback
    let bluetoothBridge: BluetoothBridge
    typealias BeginBackgroundTask = @MainActor (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let beginBackgroundTask: BeginBackgroundTask
    typealias EndBackgroundTask = @MainActor (UIBackgroundTaskIdentifier) -> Void
    private let endBackgroundTask: EndBackgroundTask
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundInterval: UUID?
    private var interruptionObserver: NSObjectProtocol?
    private var scenePhase: ScenePhase = .background
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    init(store: HostSessionStore, actions: HostBridgeActions, source: MicrophoneSource? = nil,
         audioSession: IOSAudioSession = IOSAudioSession(),
         allowsCoreBluetooth: Bool = true, bluetoothBridge: BluetoothBridge? = nil,
         restoreIdentifiers: [String] = [], mediaCenter: (any IOSMediaCenter)? = nil,
         recognizer: (any LocalSpeechRecognizer)? = nil, allowsLocalSpeech: Bool = true,
         beginBackgroundTask: @escaping BeginBackgroundTask = { name, expire in
             UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expire)
         }, endBackgroundTask: @escaping EndBackgroundTask = { UIApplication.shared.endBackgroundTask($0) },
         nowNanoseconds: @escaping () throws -> UInt64 = HostAudioClock.nowNanoseconds) {
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.store = store
        localTranscription = NativeLocalTranscription(recognizer: recognizer)
        let bridge = bluetoothBridge ?? BluetoothBridge(store: store)
        bridge.store = store
        self.bluetoothBridge = bridge
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
        nowPlaying = IOSNowPlayingController(center: mediaCenter ?? IOSSystemMediaCenter(), refreshPosition: { [weak playback] in
            playback?.tick()
        }) { [weak store, weak playback] command in
            store?.send(command)
            playback?.tick()
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak playback] notification in
            guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { playback?.interrupt() }
        }
        store.bridgeActions = actions
        store.bridgeActions.resumeMicrophone = { [weak capture] in capture?.resume() }
        store.bridgeActions.requestBleScan = { [weak bridge] in bridge?.requestScan() }
        store.bridgeActions.flushBleOutbound = { [weak bridge] in bridge?.flushOutboundFrames() }
        store.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            nowPlaying.sync(snapshot)
            self.bluetoothBridge.syncWithRuntimeDevice(snapshot.device)
            self.bluetoothBridge.flushOutboundFrames()
            updatePolling()
        }
        if allowsLocalSpeech { localTranscription.store = store }
        nowPlaying.sync(store.snapshot)
        bridge.setSceneInBackground(scenePhase != .active)
        if allowsCoreBluetooth {
            bridge.restoreCentralIfNeeded(restoreIdentifiers: restoreIdentifiers)
        }
        bridge.activateHost(allowsCoreBluetooth: allowsCoreBluetooth)
        updatePolling()
    }

    func setScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        bluetoothBridge.setSceneInBackground(phase != .active)
        store.setUISlicesActive(phase == .active)
        playback.tick()
        updatePolling()
    }

    private func updatePolling() {
        let keepAwake = store.lifecycle?.keepAwake == true
        let saving = store.snapshot.activeCapture?.phase == "saving"
        updateBackgroundTask(needed: saving || (scenePhase != .active && keepAwake))
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
                self.localTranscription.apply()
                self.playback.tick()
                self.store.bridgeActions.flushBleOutbound()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateBackgroundTask(needed: Bool) {
        guard needed else {
            backgroundInterval = nil
            finishBackgroundTask()
            return
        }
        guard backgroundInterval == nil else { return }
        let interval = UUID()
        backgroundInterval = interval
        backgroundTask = beginBackgroundTask("KoeSaveRecording") { [weak self] in
            guard let self, self.backgroundInterval == interval else { return }
            // Do not renew an expired grant until a new interval needs background time.
            self.finishBackgroundTask()
        }
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        endBackgroundTask(task)
    }

    func shutdown() {
        updateBackgroundTask(needed: false)
        timer?.invalidate()
        timer = nil
        store.onSnapshotChanged = nil
        nowPlaying.shutdown()
        bluetoothBridge.shutdown()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        playback.stop()
        localTranscription.shutdown()
        capture.shutdown()
        store.bridgeActions = HostBridgeActions()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        timer?.invalidate()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }
}
