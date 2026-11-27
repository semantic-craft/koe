import CoreBluetooth
import Foundation
import os
import OSLog

public protocol BluetoothDefaultsStore: Sendable {
    func string(forKey defaultName: String) -> String?
    func set(_ value: String, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

public struct SystemBluetoothDefaultsStore: BluetoothDefaultsStore {
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func string(forKey defaultName: String) -> String? {
        defaults.string(forKey: defaultName)
    }

    public func set(_ value: String, forKey defaultName: String) {
        defaults.set(value, forKey: defaultName)
    }

    public func removeObject(forKey defaultName: String) {
        defaults.removeObject(forKey: defaultName)
    }
}

struct BleTeardownResources {
    var central: (any BleCentral)?
    var peripheral: (any BlePeripheral)?
    var reconnectingPeripheral: (any BlePeripheral)?
    var teardownDeadline: Timer?
    var outboundFlushTimer: Timer?
    var reconnectTimer: Timer?
    var scanWindowTimer: Timer?
    var cancelScheduledReconnect: (@MainActor @Sendable () -> Void)?
    var cancelScheduledScanWindow: (@MainActor @Sendable () -> Void)?
}

@MainActor
protocol BleWriteLink: AnyObject {
    var supportsWriteResponse: Bool { get }
    var supportsWriteWithoutResponse: Bool { get }
    var canSendWriteWithoutResponse: Bool { get }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func write(_ data: Data, type: CBCharacteristicWriteType)
    func cancel()
}

@MainActor
final class GattWriteLink: BleWriteLink {
    let central: any BleCentral
    let peripheral: any BlePeripheral
    let characteristic: CBCharacteristic

    init(_ central: any BleCentral, _ peripheral: any BlePeripheral, _ characteristic: CBCharacteristic) {
        self.central = central
        self.peripheral = peripheral
        self.characteristic = characteristic
    }

    var supportsWriteResponse: Bool { characteristic.properties.contains(.write) }
    var supportsWriteWithoutResponse: Bool { characteristic.properties.contains(.writeWithoutResponse) }
    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        peripheral.maximumWriteValueLength(for: type)
    }
    func write(_ data: Data, type: CBCharacteristicWriteType) {
        peripheral.writeValue(data, for: characteristic, type: type)
    }
    func cancel() { central.cancelPeer(peripheral) }
}

extension BluetoothBridge {
    var activeDiagnostics: HostDiagnosticLog { store?.diagnostics ?? .shared }

    func logBleError(_ message: String, error: (any Error)?) {
        if let error {
            activeDiagnostics.error(category: "ble", event: "ble_error", detailPrefix: "\(message) ", error: error)
        } else {
            activeDiagnostics.error(category: "ble", event: "ble_error", detail: message, errorCode: "ble_error")
        }
    }

    nonisolated static func releaseTeardownResources(_ box: OSAllocatedUnfairLock<BleTeardownResources>) {
        let cleanup: @MainActor @Sendable () -> Void = {
            let resources = box.withLockUnchecked { state -> BleTeardownResources in
                let snapshot = state
                state = BleTeardownResources()
                return snapshot
            }
            resources.teardownDeadline?.invalidate()
            resources.outboundFlushTimer?.invalidate()
            resources.reconnectTimer?.invalidate()
            resources.scanWindowTimer?.invalidate()
            resources.cancelScheduledReconnect?()
            resources.cancelScheduledScanWindow?()
            if let central = resources.central {
                if central.isScanning { central.stopScan() }
                central.delegate = nil
            }
            resources.peripheral?.delegate = nil
            resources.reconnectingPeripheral?.delegate = nil
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(cleanup)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(cleanup) }
        }
    }

    public func syncWithRuntimeDevice(_ device: DeviceSnapshot) {
        let wasAutoConnectDisabled = lastObservedAutoConnect == false
        lastObservedAutoConnect = device.autoConnect
        let explicitDisconnectCount = store?.explicitDeviceDisconnectCount ?? lastObservedExplicitDisconnectCount
        let receivedExplicitDisconnect = explicitDisconnectCount != lastObservedExplicitDisconnectCount
        lastObservedExplicitDisconnectCount = explicitDisconnectCount
        let hasLocalLink = reportedReady || isScanRequested || peripheral != nil || reconnectingPeripheral != nil

        if !device.autoConnect { defaultsStore.removeObject(forKey: Self.savedPeripheralKey) }
        if teardownPending {
            if receivedExplicitDisconnect {
                scanAfterTeardown = false
                resumeReconnectOnPowerOn = false
                applyReconnectTrigger(.userDisconnectOrRelease)
            } else if !device.autoConnect {
                scanAfterTeardown = false
                resumeReconnectOnPowerOn = false
                applyReconnectTrigger(.autoConnectChanged(false))
            } else if wasAutoConnectDisabled {
                scanAfterTeardown = true
                applyReconnectTrigger(.autoConnectChanged(true), deferAutoEnableScan: true)
            }
            return
        }
        let disabledAutoConnect = !device.autoConnect && !wasAutoConnectDisabled
        if disabledAutoConnect {
            resumeReconnectOnPowerOn = false
            scanAfterTeardown = false
            applyReconnectTrigger(.autoConnectChanged(false))
            if hasLocalLink {
                beginTeardown(for: device, disconnectRuntime: device.phase != "disconnected")
                return
            }
        } else if !device.autoConnect && !hasLocalLink {
            resumeReconnectOnPowerOn = false
            scanAfterTeardown = false
            applyReconnectTrigger(.autoConnectChanged(false))
        }
        if receivedExplicitDisconnect || (hasLocalLink && device.phase == "disconnected") {
            resumeReconnectOnPowerOn = false
            scanAfterTeardown = false
            applyReconnectTrigger(.userDisconnectOrRelease)
            if hasLocalLink {
                beginTeardown(for: device, disconnectRuntime: false)
            }
            return
        }
        // Rust clears the projection when it accepts a disconnect or a release.
        projectedStopFramesHex = device.teardownStopFramesHex
        if wasAutoConnectDisabled && device.autoConnect {
            let wasSuppressed = reconnectState == .suppressedByUser
            applyReconnectTrigger(.autoConnectChanged(true), deferAutoEnableScan: true)
            if !wasSuppressed && device.phase == "disconnected" { scheduleScanIfIdle() }
        }
    }

    func scheduleScanIfIdle() {
        guard isHostActivated else { return }
        let previousScanCount = scanStartCount
        Task { @MainActor [weak self] in
            guard let self, self.isHostActivated, self.scanStartCount == previousScanCount,
                  self.store?.runtimeDevice.autoConnect == true, !self.isScanRequested,
                  !self.reportedReady, self.peripheral == nil, self.reconnectingPeripheral == nil else { return }
            self.startScanningIfPoweredOn()
        }
    }

    func beginTeardown(for device: DeviceSnapshot?, disconnectRuntime: Bool) {
        let error = prepareTeardown(for: device)
        if disconnectRuntime { store?.send(.deviceDisconnect) }
        if let error { reportError(error) }
    }

    private func prepareTeardown(for device: DeviceSnapshot?) -> String? {
        guard !teardownPending else { return nil }
        let current = device?.teardownStopFramesHex ?? []
        let hex = current.isEmpty ? projectedStopFramesHex : current
        guard reportedReady, !hex.isEmpty else {
            teardownLocalBleLink()
            return nil
        }
        let frames = hex.compactMap(Self.decodeHex)
        guard frames.count == hex.count, !frames.contains(where: \.isEmpty) else {
            teardownLocalBleLink()
            return "无法读取录音豆停录指令。"
        }
        lastTeardownStopFrames = frames
        guard let writeLink else {
            teardownLocalBleLink()
            return "录音豆写入通道已关闭，未能发送停录指令。"
        }
        teardownPending = true
        isScanRequested = false
        stopScanning()
        outboundQueue.discardPending()
        enqueue(frames, on: writeLink)
        // Keep the bridge alive through the final ACK even if the host is shutting down.
        teardownDeadline = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                teardownLocalBleLink()
                reportError("等待录音豆停录指令写入超时。")
            }
        }
        pumpOutboundQueue()
        return nil
    }

    func teardownLocalBleLink() {
        Self.logger.info("Disconnecting local D3200 link")
        stopScanning()
        if let writeLink {
            writeLink.cancel()
        } else if let peripheral {
            central?.cancelPeer(peripheral)
        }
        if let pending = reconnectingPeripheral { central?.cancelPeer(pending) }
        resetLinkState()
    }

    func stopScanning() {
        if let central, central.isScanning { central.stopScan() }
    }

    public func flushOutboundFrames() {
        guard reportedReady, !teardownPending, let writeLink else { return }
        enqueue(store?.drainOutboundBleFrames() ?? [], on: writeLink)
        pumpOutboundQueue()
    }

    private func writeType(for link: any BleWriteLink) -> CBCharacteristicWriteType {
        if teardownPending && link.supportsWriteResponse { return .withResponse }
        return link.supportsWriteWithoutResponse ? .withoutResponse : .withResponse
    }

    private func enqueue(_ frames: [Data], on link: any BleWriteLink) {
        guard !frames.isEmpty else { return }
        let limit = max(link.maximumWriteValueLength(for: writeType(for: link)), 1)
        for frame in frames {
            for offset in stride(from: 0, to: frame.count, by: limit) {
                outboundQueue.enqueue([frame.subdata(in: offset..<min(offset + limit, frame.count))])
            }
        }
    }

    func pumpOutboundQueue() {
        outboundFlushTimer?.invalidate()
        outboundFlushTimer = nil
        guard let writeLink, !awaitingWriteResponse else { return }
        let mode = writeType(for: writeLink)
        if !outboundQueue.pendingFrames.isEmpty, mode == .withoutResponse, !writeLink.canSendWriteWithoutResponse { return }
        let now = Date()
        if let frame = outboundQueue.popReady(now: now) {
            awaitingWriteResponse = mode == .withResponse
            writeLink.write(frame, type: mode)
            if teardownPending {
                Self.logger.info("Submitted D3200 stop frame (\(frame.count) bytes, ACK requested=\(self.awaitingWriteResponse))")
            }
            if awaitingWriteResponse { return }
        }

        var delay = outboundQueue.delayUntilNextReady(now: now)
        if teardownPending && delay == nil {
            // A write without response has no completion callback. Allow the last packet its send interval.
            if mode == .withoutResponse, let last = outboundQueue.lastWriteDate {
                delay = max(0, outboundQueue.spacingSeconds - now.timeIntervalSince(last))
            }
            if (delay ?? 0) <= 0 {
                teardownLocalBleLink()
                return
            }
        }
        if let delay {
            let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.pumpOutboundQueue() }
            }
            RunLoop.main.add(timer, forMode: .common)
            outboundFlushTimer = timer
        }
    }

    func writeDidComplete(error: (any Error)?) {
        guard awaitingWriteResponse else { return }
        awaitingWriteResponse = false
        if let error {
            failLink("设备指令发送失败，请重新连接。", error: error)
            return
        }
        pumpOutboundQueue()
    }

    func didDiscoverServices(for source: any BlePeripheral, error: (any Error)?) {
        guard peripheral === source else { return }
        guard error == nil, let services = source.services, !services.isEmpty else {
            failLink("无法读取录音豆服务，请重新连接。", error: error)
            return
        }
        Self.logger.info("Discovered \(services.count) D3200 GATT services")
        pendingServices = services.count
        for service in services {
            source.discoverCharacteristics(nil, for: service)
        }
    }

    func didDiscoverCharacteristics(for source: any BlePeripheral, service: CBService, error: (any Error)?) {
        guard peripheral === source else { return }
        guard error == nil else {
            failLink("无法读取录音豆通信通道，请重新连接。", error: error)
            return
        }
        pendingServices = max(0, pendingServices - 1)
        for characteristic in service.characteristics ?? [] {
            if Self.isPrimaryD3200Service(service.uuid), Self.isWritableD3200Characteristic(characteristic) {
                if Self.shouldPreferWriteCharacteristic(
                    existingServiceUUID: writeCharacteristic?.service?.uuid,
                    candidateServiceUUID: service.uuid
                ) {
                    writeCharacteristic = characteristic
                }
            }
            if Self.isD3200NotifyCharacteristic(characteristic.uuid, serviceUUID: service.uuid) {
                notifyFound = true
                source.setNotifyValue(true, for: characteristic)
            }
        }
        if pendingServices == 0 && (writeCharacteristic == nil || !notifyFound) {
            failLink("此设备没有提供支持的录音通信通道。", error: error)
            return
        }
        checkReady()
    }

    func didUpdateNotificationState(for source: any BlePeripheral, characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === source,
              Self.isD3200NotifyCharacteristic(characteristic.uuid, serviceUUID: characteristic.service?.uuid) else { return }
        guard error == nil, source.isNotifying(characteristic) else {
            failLink("无法订阅录音豆通知，请重新连接。", error: error)
            return
        }
        notifyReady = true
        checkReady()
    }

    func didUpdateValue(for source: any BlePeripheral, characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === source, reportedReady else { return }
        guard error == nil, let data = characteristic.value else {
            failLink("读取录音豆通知失败，请重新连接。", error: error)
            return
        }
        guard !teardownPending else { return }
        store?.ingestBleChunk(data)
        flushOutboundFrames()
    }
}
