@preconcurrency import CoreBluetooth
import Foundation
import OSLog

public enum BleReconnectState: Equatable, Sendable {
    case idle
    case waitingBackoff(attempt: Int, delaySeconds: TimeInterval)
    case scanning(windowAttempt: Int)
    case suppressedByUser
}

public enum BleReconnectTrigger: Equatable, Sendable {
    case unexpectedDisconnect
    case connectFailed
    case radioPoweredOn
    case hostWake
    case userScan
    case userDisconnectOrRelease
    case autoConnectChanged(Bool)
    case peerReady
}

public enum BleReconnectEffect: Equatable, Sendable {
    case none
    case startImmediate
    case scheduleAfter(TimeInterval)
    case stopAndClear
}

public enum BleReconnectPolicy {
    public static let backoffSchedule: [TimeInterval] = [1, 2, 5, 15, 30, 60]
    public static let defaultScanWindowSeconds: TimeInterval = 10

    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(0, min(attempt, backoffSchedule.count - 1))
        return backoffSchedule[clamped]
    }

    public static func reduce(
        state: BleReconnectState,
        trigger: BleReconnectTrigger,
        autoConnect: Bool,
        hasSavedPeer: Bool,
        teardownPending: Bool,
        isConnectedOrReady: Bool
    ) -> (BleReconnectState, BleReconnectEffect) {
        switch trigger {
        case .userDisconnectOrRelease:
            return (.suppressedByUser, .stopAndClear)

        case let .autoConnectChanged(enabled):
            if !enabled {
                return (.suppressedByUser, .stopAndClear)
            }
            guard state == .suppressedByUser else { return (state, .none) }
            if teardownPending || isConnectedOrReady {
                return (.idle, .none)
            }
            return (.idle, .startImmediate)

        case .peerReady:
            return (.idle, .stopAndClear)

        case .userScan:
            if teardownPending { return (.idle, .none) }
            if isConnectedOrReady { return (.idle, .stopAndClear) }
            return (.scanning(windowAttempt: 0), .startImmediate)

        case .unexpectedDisconnect, .connectFailed:
            guard state != .suppressedByUser else { return (.suppressedByUser, .stopAndClear) }
            guard autoConnect else { return (.suppressedByUser, .stopAndClear) }
            guard !teardownPending, !isConnectedOrReady else { return (.idle, .stopAndClear) }
            if case .waitingBackoff = state { return (state, .none) }
            let attempt: Int
            if case let .scanning(windowAttempt) = state {
                attempt = windowAttempt
            } else {
                attempt = 0
            }
            let delay = Self.delay(forAttempt: attempt)
            return (.waitingBackoff(attempt: attempt, delaySeconds: delay), .scheduleAfter(delay))

        case .radioPoweredOn, .hostWake:
            guard state != .suppressedByUser else { return (.suppressedByUser, .none) }
            guard autoConnect else { return (.suppressedByUser, .stopAndClear) }
            guard !teardownPending, !isConnectedOrReady else { return (.idle, .none) }
            if case .idle = state, !hasSavedPeer { return (.idle, .none) }
            return (.scanning(windowAttempt: 0), .startImmediate)
        }
    }

    public static func onBackoffElapsed(
        state: BleReconnectState,
        autoConnect: Bool,
        teardownPending: Bool,
        isConnectedOrReady: Bool
    ) -> (BleReconnectState, BleReconnectEffect) {
        guard case let .waitingBackoff(attempt, _) = state else { return (state, .none) }
        if !autoConnect { return (.suppressedByUser, .stopAndClear) }
        if teardownPending || isConnectedOrReady { return (.idle, .stopAndClear) }
        return (.scanning(windowAttempt: attempt + 1), .startImmediate)
    }
}

extension BluetoothBridge {
    public var hasSavedPeripheral: Bool {
        defaultsStore.string(forKey: Self.savedPeripheralKey).flatMap(UUID.init(uuidString:)) != nil
    }

    var isLinkHealthyAndReady: Bool {
        reportedReady && (peripheral?.state ?? .connected) == .connected
    }

    var isWaitingOrScanningReconnect: Bool {
        switch reconnectState {
        case .waitingBackoff, .scanning:
            return true
        case .idle, .suppressedByUser:
            return false
        }
    }

    public func reconnectKnownIfAvailable() {
        if let device = store?.runtimeDevice, lastObservedAutoConnect == false, device.autoConnect {
            lastObservedAutoConnect = true
            let (nextState, _) = BleReconnectPolicy.reduce(
                state: reconnectState,
                trigger: .autoConnectChanged(true),
                autoConnect: true,
                hasSavedPeer: hasSavedPeripheral,
                teardownPending: teardownPending,
                isConnectedOrReady: isLinkHealthyAndReady
            )
            reconnectState = nextState
        }
        guard store?.runtimeDevice.autoConnect != false, reconnectState != .suppressedByUser,
              !reportedReady, peripheral == nil, reconnectingPeripheral == nil,
              hasSavedPeripheral else { return }
        startScanningIfPoweredOn()
    }

    public func handleHostWillSleep() {
        guard isHostActivated, !teardownPending, !isLinkHealthyAndReady else { return }
        guard isWaitingOrScanningReconnect || isScanRequested || reconnectingPeripheral != nil else { return }
        cancelReconnectTimers()
        stopScanning()
        if let pending = reconnectingPeripheral {
            central?.cancelPeer(pending)
            reconnectingPeripheral = nil
        }
        isScanRequested = false
    }

    public func handleHostWake() {
        guard isHostActivated else { return }
        applyReconnectTrigger(.hostWake)
    }

    func applyReconnectTrigger(
        _ trigger: BleReconnectTrigger,
        deferAutoEnableScan: Bool = false,
        treatAsHavingPeer: Bool = false
    ) {
        let autoConnect = store?.runtimeDevice.autoConnect ?? true
        let (nextState, effect) = BleReconnectPolicy.reduce(
            state: reconnectState,
            trigger: trigger,
            autoConnect: autoConnect,
            hasSavedPeer: hasSavedPeripheral || treatAsHavingPeer,
            teardownPending: teardownPending,
            isConnectedOrReady: isLinkHealthyAndReady
        )
        reconnectState = nextState
        executeReconnectEffect(effect, deferScan: deferAutoEnableScan)
    }

    func executeReconnectEffect(_ effect: BleReconnectEffect, deferScan: Bool = false) {
        switch effect {
        case .none:
            break
        case .stopAndClear:
            cancelReconnectTimers()
        case .startImmediate:
            cancelReconnectTimers()
            guard isHostActivated else { return }
            if deferScan {
                scheduleScanIfIdle()
            } else {
                beginScanAttempt(initiatedByUser: false, boundedScanWindow: true)
            }
        case let .scheduleAfter(delay):
            cancelReconnectTimers()
            guard isHostActivated else { return }
            scheduleBackoffTimer(after: delay)
        }
    }

    func cancelReconnectTimers() {
        cancelReconnectTimerOnly()
        cancelScanWindowTimerOnly()
    }

    func cancelReconnectTimerOnly() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        let cancel = teardownBox.withLockUnchecked { state -> (@MainActor @Sendable () -> Void)? in
            let current = state.cancelScheduledReconnect
            state.cancelScheduledReconnect = nil
            return current
        }
        cancel?()
    }

    func cancelScanWindowTimerOnly() {
        scanWindowTimer?.invalidate()
        scanWindowTimer = nil
        let cancel = teardownBox.withLockUnchecked { state -> (@MainActor @Sendable () -> Void)? in
            let current = state.cancelScheduledScanWindow
            state.cancelScheduledScanWindow = nil
            return current
        }
        cancel?()
    }

    private enum ReconnectTimerSlot {
        case backoff
        case scanWindow
    }

    func scheduleBackoffTimer(after delay: TimeInterval) {
        scheduleTimer(after: delay, slot: .backoff) { [weak self] in
            self?.handleBackoffTimerFired()
        }
    }

    func armScanWindowIfNeeded() {
        #if !os(iOS)
        let shouldBound: Bool
        if case let .scanning(windowAttempt) = reconnectState {
            shouldBound = isBoundedReconnectScan || windowAttempt > 0
        } else {
            shouldBound = false
        }
        guard shouldBound, !scanInitiatedByUser, isHostActivated, isScanRequested,
              peripheral == nil, !reportedReady, !teardownPending,
              central?.state == .poweredOn else { return }
        scheduleTimer(after: reconnectScanWindowSeconds, slot: .scanWindow) { [weak self] in
            self?.handleScanWindowTimerFired()
        }
        #endif
    }

    private func scheduleTimer(
        after delay: TimeInterval,
        slot: ReconnectTimerSlot,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        switch slot {
        case .backoff: cancelReconnectTimerOnly()
        case .scanWindow: cancelScanWindowTimerOnly()
        }
        if let scheduler = scheduleReconnectTimer {
            let cancel = scheduler(delay, action)
            teardownBox.withLockUnchecked { state in
                switch slot {
                case .backoff: state.cancelScheduledReconnect = cancel
                case .scanWindow: state.cancelScheduledScanWindow = cancel
                }
            }
            return
        }
        let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { _ in
            MainActor.assumeIsolated(action)
        }
        RunLoop.main.add(timer, forMode: .common)
        switch slot {
        case .backoff: reconnectTimer = timer
        case .scanWindow: scanWindowTimer = timer
        }
    }

    private func handleBackoffTimerFired() {
        cancelReconnectTimerOnly()
        guard isHostActivated else { return }
        let autoConnect = store?.runtimeDevice.autoConnect ?? true
        let (nextState, effect) = BleReconnectPolicy.onBackoffElapsed(
            state: reconnectState,
            autoConnect: autoConnect,
            teardownPending: teardownPending,
            isConnectedOrReady: isLinkHealthyAndReady
        )
        reconnectState = nextState
        executeReconnectEffect(effect)
    }

    private func handleScanWindowTimerFired() {
        cancelScanWindowTimerOnly()
        guard isHostActivated, isScanRequested, peripheral == nil, !reportedReady, !teardownPending else { return }
        stopScanning()
        if let pending = reconnectingPeripheral {
            central?.cancelPeer(pending)
            reconnectingPeripheral = nil
        }
        isScanRequested = false
        emit("disconnected")
        applyReconnectTrigger(.connectFailed)
    }

    func centralStateDidChange(_ state: CBManagerState) {
        Self.logger.info("CoreBluetooth manager state=\(state.rawValue)")
        let previousState = lastCentralState
        lastCentralState = state
        #if os(iOS)
        if state == .poweredOn, let central {
            let wasAwaitingWithoutState = awaitingStateRestoration && pendingRestoration == nil
            awaitingStateRestoration = false
            resumeRestoration(on: central)
            if wasAwaitingWithoutState { beginDeferredKnownReconnectIfAvailable() }
        }
        #endif
        if state == .poweredOn {
            if isScanRequested, let central {
                resumeReconnectOnPowerOn = false
                beginDiscoveryAndReconnect(central)
                armScanWindowIfNeeded()
                return
            }
            let wasRadioInterrupted = previousState == .poweredOff || previousState == .resetting || resumeReconnectOnPowerOn
            let shouldResume = resumeReconnectOnPowerOn
            resumeReconnectOnPowerOn = false
            if wasRadioInterrupted, isHostActivated, peripheral == nil, reconnectingPeripheral == nil, !reportedReady {
                applyReconnectTrigger(.radioPoweredOn, treatAsHavingPeer: shouldResume)
            }
            return
        }

        let hasLocalLink = isScanRequested || peripheral != nil || reconnectingPeripheral != nil || reportedReady
        let hasReconnectActivity = isWaitingOrScanningReconnect
        guard hasLocalLink || hasReconnectActivity else { return }
        switch state {
        case .poweredOff:
            if reconnectState != .suppressedByUser && store?.runtimeDevice.autoConnect != false {
                resumeReconnectOnPowerOn = true
            }
            handleRadioUnavailable("蓝牙已关闭，请在系统设置中打开。", hadLocalLink: hasLocalLink)
        case .unauthorized:
            resumeReconnectOnPowerOn = false
            handleRadioUnavailable("请在系统设置中允许 Koe 使用蓝牙。", hadLocalLink: hasLocalLink)
        case .unsupported:
            resumeReconnectOnPowerOn = false
            handleRadioUnavailable("这台设备不支持蓝牙连接。", hadLocalLink: hasLocalLink)
        case .resetting:
            if reconnectState != .suppressedByUser && store?.runtimeDevice.autoConnect != false {
                resumeReconnectOnPowerOn = true
            }
            handleRadioUnavailable("蓝牙正在重置，请稍后重新扫描。", hadLocalLink: hasLocalLink)
        default:
            break
        }
    }

    private func handleRadioUnavailable(_ message: String, hadLocalLink: Bool) {
        if !hadLocalLink {
            cancelReconnectTimers()
            if reconnectState != .suppressedByUser {
                reconnectState = .idle
            }
            return
        }
        // CoreBluetooth invalidates peripheral handles when the manager leaves poweredOn.
        #if os(iOS)
        let showError = scanInitiatedByUser || peripheral != nil || reconnectingPeripheral != nil || reportedReady
        #endif
        stopScanning()
        resetLinkState()
        if reconnectState != .suppressedByUser {
            reconnectState = .idle
        }
        emit("disconnected")
        #if os(iOS)
        guard showError else {
            Self.logger.info("Passive Bluetooth scan ended: \(message, privacy: .public)")
            return
        }
        #endif
        reportError(message)
    }

    func didFailToConnect(_ failed: any BlePeripheral, on central: any BleCentral, error: (any Error)?) {
        guard self.central === central else { return }
        if reconnectingPeripheral === failed {
            reconnectingPeripheral = nil
            #if os(iOS)
            if isHostActivated, store?.runtimeDevice.autoConnect != false, central.state == .poweredOn, !central.isScanning {
                isScanRequested = true
                emit("scanning")
                scan(central)
            }
            reportError("未能重连上次的录音豆，仍在扫描附近设备。", error: error)
            #else
            stopScanning()
            cancelScanWindowTimerOnly()
            isScanRequested = false
            emit("disconnected")
            reportError("未能重连上次的录音豆，将在稍后自动重试。", error: error)
            applyReconnectTrigger(.connectFailed)
            #endif
            return
        }
        guard peripheral === failed else { return }
        failLink(
            "无法连接录音豆，请确认设备已放入充电仓并短按下方按钮。",
            error: error,
            reconnectTrigger: .connectFailed
        )
    }

    func didDisconnect(_ disconnected: any BlePeripheral, on central: any BleCentral, error: (any Error)?) {
        guard self.central === central, self.peripheral === disconnected else { return }
        let stopPending = teardownPending
        resetLinkState()
        emit("disconnected")
        if stopPending {
            reportError("录音豆已断开，未能确认停录指令写入。", error: error)
            return
        }
        if let error {
            reportError("录音豆连接中断。", error: error)
        }
        #if !os(iOS)
        applyReconnectTrigger(.unexpectedDisconnect)
        #endif
    }
}
