// CBCentralManager is initialized with `queue: .main`, so all delegate callbacks arrive on the main thread.
@preconcurrency import CoreBluetooth
import Foundation
import OSLog

@MainActor
public final class BluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public static var d3200ServiceUUID: CBUUID { CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB") }
    nonisolated public static var writeCharacteristicUUID: CBUUID { CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB") }
    nonisolated public static var notifyCharacteristicUUID: CBUUID { CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB") }
    nonisolated public static func isWriteCharacteristic(_ uuid: CBUUID) -> Bool { uuid == writeCharacteristicUUID || uuid.uuidString == "7777" }
    nonisolated public static func isNotifyCharacteristic(_ uuid: CBUUID) -> Bool { uuid == notifyCharacteristicUUID || uuid.uuidString == "8888" }
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
        return uuid == d3200ServiceUUID || s.hasPrefix("020cf5da") || s == "f5da"
    }
    nonisolated public static func shouldPreferWriteCharacteristic(existingServiceUUID: CBUUID?, candidateServiceUUID: CBUUID) -> Bool {
        guard let existingServiceUUID else { return true }
        return isPrimaryD3200Service(existingServiceUUID) ? isPrimaryD3200Service(candidateServiceUUID) : true
    }
    nonisolated public static func secondaryServiceUUIDForTest(_ string: String) -> CBUUID { CBUUID(string: string) }

    #if os(iOS)
    static let logger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "ble")
    #else
    static let logger = Logger(subsystem: "com.semanticcraft.koe", category: "ble")
    #endif
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
    var writeLink: (any BleWriteLink)?
    var awaitingWriteResponse = false
    var teardownPending = false
    var scanAfterTeardown = false
    var teardownDeadline: Timer?
    var projectedStopFramesHex: [String] = []
    private var lastCentralState: CBManagerState = .unknown
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
        if let device = store?.runtimeDevice {
            syncWithRuntimeDevice(device)
            if device.autoConnect && !device.connected && !reportedReady && !isScanRequested && peripheral == nil && reconnectingPeripheral == nil {
                startScanningIfPoweredOn()
            }
        }
    }

    public func requestScan() {
        if store?.runtimeDevice.autoConnect == false { store?.send(.setBleAutoConnect(enabled: true)) }
        startScanningIfPoweredOn()
    }

    public func startScanningIfPoweredOn() {
        if teardownPending {
            scanAfterTeardown = true
            return
        }
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
        scanWithCurrentState()
    }

    public func reconnectKnownIfAvailable() {
        guard store?.runtimeDevice.autoConnect != false, !reportedReady, peripheral == nil, reconnectingPeripheral == nil,
              let saved = UserDefaults.standard.string(forKey: Self.savedPeripheralKey), UUID(uuidString: saved) != nil else { return }
        startScanningIfPoweredOn()
    }

    private func scanWithCurrentState() {
        if allowsCoreBluetooth && central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        centralStateDidChange(central?.state ?? lastCentralState)
    }

    public func disconnect() {
        beginTeardown(for: store?.runtimeDevice, disconnectRuntime: true)
    }

    public func shutdown() {
        isHostActivated = false
        scanAfterTeardown = false
        if isScanRequested || reportedReady || peripheral != nil || reconnectingPeripheral != nil {
            disconnect()
        }
        if !teardownPending {
            central?.delegate = nil
            central = nil
        }
    }

    private func beginDiscoveryAndReconnect(_ central: CBCentralManager) {
        guard peripheral == nil, reconnectingPeripheral == nil, !central.isScanning else { return }
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
            Self.logger.info("Reconnecting to saved D3200")
            reconnectingPeripheral = known
            known.delegate = self
            central.connect(known, options: nil)
        }
        Self.logger.info("Starting CoreBluetooth discovery")
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
        Self.logger.info("D3200 event: \(event, privacy: .public)")
        store?.send(.deviceEvent(
            event: event,
            connectionId: connectionID,
            deviceName: deviceName ?? discoveredName
        ))
    }

    private func checkReady() {
        guard pendingServices == 0, notifyReady, let characteristic = writeCharacteristic, let peripheral, let central,
              !reportedReady else { return }
        writeLink = GattWriteLink(central, peripheral, characteristic)
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
        reportedReady = true
        emit("ready")
        flushOutboundFrames()
    }

    func resetLinkState() {
        teardownDeadline?.invalidate()
        teardownDeadline = nil
        teardownPending = false
        awaitingWriteResponse = false
        outboundFlushTimer?.invalidate()
        outboundFlushTimer = nil
        outboundQueue.reset()
        projectedStopFramesHex = []
        writeLink = nil
        peripheral = nil
        reconnectingPeripheral = nil
        writeCharacteristic = nil
        notifyReady = false
        notifyFound = false
        pendingServices = 0
        reportedReady = false
        isScanRequested = false
        if scanAfterTeardown {
            scanAfterTeardown = false
            scheduleScanIfIdle()
        }
        if !isHostActivated {
            central?.delegate = nil
            central = nil
        }
    }

    func reportError(_ message: String, error: (any Error)? = nil) {
        Self.logger.error("\(message, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
        store?.reportNativeError(message)
    }

    func failLink(_ message: String, error: (any Error)? = nil) {
        teardownLocalBleLink()
        emit("disconnected")
        reportError(message, error: error)
    }

    public static func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let pair = String(decoding: bytes[index..<index + 2], as: UTF8.self)
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
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
            guard self.central === central else { return }
            self.centralStateDidChange(central.state)
        }
    }

    func centralStateDidChange(_ state: CBManagerState) {
        Self.logger.info("CoreBluetooth manager state=\(state.rawValue)")
        lastCentralState = state
        guard isScanRequested || peripheral != nil || reconnectingPeripheral != nil || reportedReady else { return }
        switch state {
        case .poweredOn:
            if isScanRequested, let central { beginDiscoveryAndReconnect(central) }
        case .poweredOff: unavailable("蓝牙已关闭，请在系统设置中打开。")
        case .unauthorized: unavailable("请在系统设置中允许 Koe 使用蓝牙。")
        case .unsupported: unavailable("这台设备不支持蓝牙连接。")
        case .resetting: unavailable("蓝牙正在重置，请稍后重新扫描。")
        default: break
        }
    }

    private func unavailable(_ message: String) {
        // CoreBluetooth invalidates peripheral handles when the manager leaves poweredOn.
        resetLinkState()
        emit("disconnected")
        reportError(message)
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
            guard self.central === central, self.store?.runtimeDevice.autoConnect != false else { return }
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
            guard self.central === central, !self.teardownPending else { return }
            if self.store?.runtimeDevice.autoConnect == false {
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
            Self.logger.info("Connected to D3200, discovering GATT services")
            connected.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: (any Error)?) {
        onMainActorIsolated {
            if self.reconnectingPeripheral === failed {
                self.reconnectingPeripheral = nil
                self.reportError("未能重连上次的录音豆，仍在扫描附近设备。", error: error)
                return
            }
            guard self.peripheral === failed else { return }
            self.failLink("无法连接录音豆，请确认设备已放入充电仓并短按下方按钮。", error: error)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral disconnected: CBPeripheral,
                                           error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === disconnected else { return }
            let stopPending = self.teardownPending
            self.resetLinkState()
            self.emit("disconnected")
            if stopPending { self.reportError("录音豆已断开，未能确认停录指令写入。", error: error) }
            else if let error { self.reportError("录音豆连接中断。", error: error) }
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didDiscoverServices error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === source else { return }
            guard error == nil, let services = source.services, !services.isEmpty else {
                self.failLink("无法读取录音豆服务，请重新连接。", error: error)
                return
            }
            Self.logger.info("Discovered \(services.count) D3200 GATT services")
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
                self.failLink("无法读取录音豆通信通道，请重新连接。", error: error)
                return
            }
            self.pendingServices = max(0, self.pendingServices - 1)
            for characteristic in service.characteristics ?? [] {
                if Self.isD3200WriteCharacteristic(characteristic.uuid, serviceUUID: service.uuid),
                   !characteristic.properties.intersection([.write, .writeWithoutResponse]).isEmpty {
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
                self.failLink("此设备没有提供支持的录音通信通道。", error: error)
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
                self.failLink("无法订阅录音豆通知，请重新连接。", error: error)
                return
            }
            self.notifyReady = true
            self.checkReady()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                       error: (any Error)?) {
        guard Self.isD3200NotifyCharacteristic(characteristic.uuid, serviceUUID: characteristic.service?.uuid) else { return }
        onMainActorIsolated {
            guard self.peripheral === source, self.reportedReady else { return }
            guard error == nil, let data = characteristic.value else {
                self.failLink("读取录音豆通知失败，请重新连接。", error: error)
                return
            }
            guard !self.teardownPending else { return }
            self.store?.ingestBleChunk(data)
            self.flushOutboundFrames()
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse source: CBPeripheral) {
        onMainActorIsolated {
            guard self.peripheral === source else { return }
            self.pumpOutboundQueue()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                       error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === source, self.writeCharacteristic === characteristic else { return }
            self.writeDidComplete(error: error)
        }
    }
}
