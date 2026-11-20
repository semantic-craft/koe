import KoeAppleCore
import SwiftUI
import UIKit

@MainActor
final class IOSHostCoordinator {
    private let store: HostSessionStore
    private var scenePhase: ScenePhase = .background
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    init(store: HostSessionStore, actions: HostBridgeActions) {
        self.store = store
        store.bridgeActions = actions
        store.onSnapshotChanged = { [weak self] _ in self?.updatePolling() }
        updatePolling()
    }

    func setScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        store.setUISlicesActive(phase == .active)
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
        store.bridgeActions = HostBridgeActions()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit { timer?.invalidate() }
}
