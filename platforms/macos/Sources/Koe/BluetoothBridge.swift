// CBCentralManager is initialized with `queue: .main`, so all delegate callbacks arrive on the main thread.
@preconcurrency import CoreBluetooth
import Foundation
import KoeAppleShared

@MainActor
public final class BluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public static var d3200ServiceUUID: CBUUID { CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB") }
    nonisolated public static var writeCharacteristicUUID: CBUUID { CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB") }
    nonisolated public static var notifyCharacteristicUUID: CBUUID { CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB") }
    nonisolated public static func isWriteCharacteristic(_ uuid: CBUUID) -> Bool { uuid.uuidString.lowercased().contains("7777") }
    nonisolated public static func isNotifyCharacteristic(_ uuid: CBUUID) -> Bool { uuid.uuidString.lowercased().contains("8888") }
    nonisolated public static func isD3200WriteCharacteristic(_ uuid: CBUUID, serviceUUID: CBUUID?) -> Bool {
        guard let serviceUUID, isPrimaryD3200Service(serviceUUID) else { return false }
        return isWriteCharacteristic(uuid)
    }
    nonisolated public static func isD3200NotifyCharacteristic(_ uuid: CBUUID, serviceUUID: CBUUID?) -> Bool {
        guard let serviceUUID, isPrimaryD3200Service(serviceUUID) else { return false }
        return isNotifyCharacteristic(uuid)
    }
    nonisolated public static func isPrimaryD3200Service(_ uuid: CBUUID) -> Bool {
        let s = uuid.uuidString.lowercased()
        return uuid == d3200ServiceUUID || s.contains("020cf5da") || s == "f5da"
    }
    nonisolated public static func shouldPreferWriteCharacteristic(existingServiceUUID: CBUUID?, candidateServiceUUID: CBUUID) -> Bool {
        guard let existingServiceUUID else { return true }
        return isPrimaryD3200Service(existingServiceUUID) ? isPrimaryD3200Service(candidateServiceUUID) : true
    }
    nonisolated public static func secondaryServiceUUIDForTest(_ string: String) -> CBUUID { CBUUID(string: string) }

    static let savedPeripheralKey = "koe.ble.lastPeripheralUUID"
    public weak var store: HostSessionStore?
    public private(set) var isHostActivated = false
    public private(set) var allowsCoreBluetooth = true
    public internal(set) var scanStartCount = 0
    public internal(set) var isScanRequested = false
    var central: CBCentralManager?
    var peripheral: CBPeripheral?
    var reconnectingPeripheral: CBPeripheral?
    var writeCharacteristic: CBCharacteristic?
    var outboundQueue = BleOutboundQueue()
    var outboundFlushTimer: Timer?
    public internal(set) var lastTeardownStopFrames: [Data] = []
    public internal(set) var lastObservedAutoConnect: Bool?
    private var notifyReady = false
    private var notifyFound = false
    private var pendingServices = 0
    var reportedReady = false
    private var connectionID = ""
    private var discoveredName: String?

    public init(store: HostSessionStore? = nil) { self.store = store; super.init() }

    public func activateHost(allowsCoreBluetooth: Bool = true) {
        self.allowsCoreBluetooth = allowsCoreBluetooth
        isHostActivated = true
        if let device = store?.snapshot.device {
            syncWithRuntimeDevice(device)
            if device.autoConnect && !device.connected && !reportedReady && !isScanRequested && peripheral == nil && reconnectingPeripheral == nil {
                startScanningIfPoweredOn()
            }
        }
    }

    public func startScanningIfPoweredOn() {
        if reportedReady, peripheral?.state == .connected {
            store?.send(.deviceRefresh)
            flushOutboundFrames()
            return
        }
        if let stale = peripheral {
            central?.cancelPeripheralConnection(stale)
            resetLinkState()
        }
        if let staleReconnect = reconnectingPeripheral {
            central?.cancelPeripheralConnection(staleReconnect)
            reconnectingPeripheral = nil
        }
        isScanRequested = true
        connectionID = UUID().uuidString
        scanStartCount += 1
        emit("scanning")
        guard allowsCoreBluetooth else { return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if let central, central.state == .poweredOn {
            beginDiscoveryAndReconnect(central)
        }
    }

    public func reconnectKnownIfAvailable() {
        guard store?.snapshot.device.autoConnect != false, !reportedReady, peripheral == nil, reconnectingPeripheral == nil else { return }
        guard let savedString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              UUID(uuidString: savedString) != nil else { return }
        isScanRequested = true
        connectionID = UUID().uuidString
        guard allowsCoreBluetooth else { return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if let central, central.state == .poweredOn {
            beginDiscoveryAndReconnect(central)
        }
    }

    func teardownLocalBleLink() {
        central?.stopScan()
        if let active = peripheral {
            central?.cancelPeripheralConnection(active)
        }
        if let pending = reconnectingPeripheral {
            central?.cancelPeripheralConnection(pending)
            reconnectingPeripheral = nil
        }
        resetLinkState()
        isScanRequested = false
    }

    public func disconnect() {
        if let device = store?.snapshot.device {
            writeProjectedTeardownStopFramesIfReady(for: device)
        }
        teardownLocalBleLink()
        store?.send(.deviceDisconnect)
    }

    private func beginDiscoveryAndReconnect(_ central: CBCentralManager) {
        let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [
            Self.d3200ServiceUUID,
            CBUUID(string: "F5DA")
        ])
        if let existing = connectedPeripherals.first {
            attachAndConnect(existing, on: central, displayName: existing.name ?? "soundcore Work")
            return
        }
        if let savedString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
           let savedUUID = UUID(uuidString: savedString),
           let known = central.retrievePeripherals(withIdentifiers: [savedUUID]).first
        {
            reconnectingPeripheral = known
            known.delegate = self
            central.connect(known, options: nil)
        }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func attachAndConnect(_ target: CBPeripheral, on central: CBCentralManager, displayName: String) {
        peripheral = target
        reconnectingPeripheral = nil
        discoveredName = displayName
        connectionID = "\(target.identifier.uuidString):\(UUID().uuidString)"
        emit("connecting", deviceName: displayName)
        target.delegate = self
        central.stopScan()
        central.connect(target, options: nil)
    }

    private func emit(_ event: String, deviceName: String? = nil) {
        store?.send(.deviceEvent(
            event: event,
            connectionId: connectionID,
            deviceName: deviceName ?? discoveredName
        ))
    }

    private func checkReady() {
        guard notifyReady, writeCharacteristic != nil, !reportedReady else { return }
        if let peripheral {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
        }
        reportedReady = true
        emit("ready")
        flushOutboundFrames()
    }

    public func flushOutboundFrames() {
        guard reportedReady, let peripheral, let characteristic = writeCharacteristic else { return }
        let mode: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let limit = max(peripheral.maximumWriteValueLength(for: mode), 1)
        var frames: [Data] = []
        for data in store?.drainOutboundBleFrames() ?? [] {
            var offset = 0
            while offset < data.count {
                let end = min(offset + limit, data.count)
                frames.append(data.subdata(in: offset..<end))
                offset = end
            }
        }
        outboundQueue.enqueue(frames)
        pumpOutboundQueue()
    }

    private func pumpOutboundQueue() {
        outboundFlushTimer?.invalidate()
        outboundFlushTimer = nil
        guard reportedReady, let peripheral, let writeChar = writeCharacteristic else { return }
        let writeType: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        while let frame = outboundQueue.popReady(now: Date()) {
            peripheral.writeValue(frame, for: writeChar, type: writeType)
        }
        if let delay = outboundQueue.delayUntilNextReady(now: Date()) {
            let timer = Timer.scheduledTimer(withTimeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.pumpOutboundQueue() }
            }
            RunLoop.main.add(timer, forMode: .common)
            outboundFlushTimer = timer
        }
    }

    func resetLinkState() {
        outboundFlushTimer?.invalidate()
        outboundFlushTimer = nil
        outboundQueue.reset()
        peripheral = nil
        writeCharacteristic = nil
        notifyReady = false
        notifyFound = false
        pendingServices = 0
        reportedReady = false
    }

    private func disconnected(_ message: String? = nil) {
        emit("disconnected")
        resetLinkState()
        reconnectingPeripheral = nil
        isScanRequested = false
        if let message { store?.reportNativeError(message) }
    }

    public static func decodeHex(_ hex: String) -> Data? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    private nonisolated func onMainActorIsolated(_ body: @MainActor @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(body)
            }
        }
    }

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onMainActorIsolated {
            switch central.state {
            case .poweredOn:
                if self.isScanRequested { self.beginDiscoveryAndReconnect(central) }
            case .poweredOff:
                self.disconnected("蓝牙已关闭，请在系统设置中打开。")
            case .unauthorized:
                self.disconnected("请在系统设置中允许 Koe 使用蓝牙。")
            case .unsupported:
                self.disconnected("这台设备不支持蓝牙连接。")
            default: break
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover discovered: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let candidate = BleAdvertisementCandidate.match(
            peripheralName: discovered.name,
            advertisementData: advertisementData
        ) else { return }
        onMainActorIsolated {
            guard self.store?.snapshot.device.autoConnect != false else { return }
            guard self.isScanRequested, self.peripheral == nil else { return }
            if let pending = self.reconnectingPeripheral, pending !== discovered {
                central.cancelPeripheralConnection(pending)
                self.reconnectingPeripheral = nil
            }
            self.attachAndConnect(discovered, on: central, displayName: candidate.displayName)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        onMainActorIsolated {
            if self.store?.snapshot.device.autoConnect == false {
                central.cancelPeripheralConnection(connected)
                if self.reconnectingPeripheral === connected {
                    self.reconnectingPeripheral = nil
                }
                if self.peripheral === connected {
                    self.resetLinkState()
                }
                return
            }
            if self.peripheral == nil, self.reconnectingPeripheral === connected {
                self.peripheral = connected
                self.reconnectingPeripheral = nil
                let name = connected.name ?? "soundcore Work"
                self.discoveredName = name
                self.connectionID = "\(connected.identifier.uuidString):\(UUID().uuidString)"
                self.emit("connecting", deviceName: name)
                central.stopScan()
            }
            guard self.peripheral === connected else { return }
            connected.delegate = self
            connected.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: (any Error)?) {
        onMainActorIsolated {
            if self.reconnectingPeripheral === failed {
                self.reconnectingPeripheral = nil
                return
            }
            guard self.peripheral === failed else { return }
            self.disconnected("无法连接录音豆，请确认设备已放入充电仓并短按下方按钮。")
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral disconnected: CBPeripheral,
                                           error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === disconnected else { return }
            self.disconnected()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didDiscoverServices error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === source else { return }
            guard error == nil, let services = source.services, !services.isEmpty else {
                self.store?.reportNativeError("无法读取录音豆服务，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.pendingServices = services.count
            for service in services {
                source.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                       error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === source else { return }
            guard error == nil else {
                self.store?.reportNativeError("无法读取录音豆通信通道，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.pendingServices = max(0, self.pendingServices - 1)
            for characteristic in service.characteristics ?? [] {
                if Self.isD3200WriteCharacteristic(characteristic.uuid, serviceUUID: service.uuid) {
                    if Self.shouldPreferWriteCharacteristic(
                        existingServiceUUID: self.writeCharacteristic?.service?.uuid,
                        candidateServiceUUID: service.uuid
                    ) {
                        self.writeCharacteristic = characteristic
                    }
                }
                if Self.isD3200NotifyCharacteristic(characteristic.uuid, serviceUUID: service.uuid) {
                    self.notifyFound = true
                    source.setNotifyValue(true, for: characteristic)
                }
            }
            if self.pendingServices == 0 && (self.writeCharacteristic == nil || !self.notifyFound) {
                self.store?.reportNativeError("此设备没有提供支持的录音通信通道。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.checkReady()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                       error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === source,
                  Self.isD3200NotifyCharacteristic(characteristic.uuid, serviceUUID: characteristic.service?.uuid) else { return }
            guard error == nil, characteristic.isNotifying else {
                self.store?.reportNativeError("无法订阅录音豆通知，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.notifyReady = true
            self.checkReady()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                       error: (any Error)?) {
        guard error == nil,
              Self.isD3200NotifyCharacteristic(characteristic.uuid, serviceUUID: characteristic.service?.uuid),
              let data = characteristic.value else { return }
        onMainActorIsolated {
            guard self.peripheral === source, self.reportedReady else { return }
            self.store?.ingestBleChunk(data)
            self.flushOutboundFrames()
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse source: CBPeripheral) {
        onMainActorIsolated {
            guard self.peripheral === source else { return }
            self.flushOutboundFrames()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                       error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === source else { return }
            guard error == nil else {
                self.store?.reportNativeError("设备指令发送失败，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.flushOutboundFrames()
        }
    }
}
