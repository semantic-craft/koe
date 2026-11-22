// CBCentralManager is initialized with `queue: .main`, so all delegate callbacks arrive on the main thread.
@preconcurrency import CoreBluetooth
import Foundation
import OSLog

@MainActor
public final class BluetoothBridge: NSObject, CBPeripheralDelegate {
    nonisolated public static var d3200ServiceUUID: CBUUID { CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB") }
    nonisolated public static var writeCharacteristicUUID: CBUUID { CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB") }
    nonisolated public static var notifyCharacteristicUUID: CBUUID { CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB") }
    nonisolated public static func isWriteCharacteristic(_ uuid: CBUUID) -> Bool { uuid == writeCharacteristicUUID || uuid.uuidString == "7777" }
    nonisolated static func isWritableD3200Characteristic(_ characteristic: CBCharacteristic) -> Bool {
        isWriteCharacteristic(characteristic.uuid) && !characteristic.properties.isDisjoint(with: [.write, .writeWithoutResponse])
    }
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
    private var scanInitiatedByUser = false
    #if os(iOS)
    var sceneInBackground = false
    var pendingRestoration: (peripherals: [any BlePeripheral], scanServices: [CBUUID])?
    var awaitingStateRestoration = false
    var makeIOSCentral: (CBCentralManagerDelegate, [String: Any]) -> any BleCentral = {
        CBCentralManager(delegate: $0, queue: .main, options: $1)
    }
    #endif
    var central: (any BleCentral)?
    var peripheral: (any BlePeripheral)?
    var reconnectingPeripheral: (any BlePeripheral)?
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
    var notifyReady = false
    var notifyFound = false
    private var pendingServices = 0
    var reportedReady = false
    var connectionID = ""
    private var discoveredName: String?

    public init(store: HostSessionStore? = nil) { self.store = store; super.init() }

    public func activateHost(allowsCoreBluetooth: Bool = true) {
        self.allowsCoreBluetooth = allowsCoreBluetooth
        isHostActivated = true
        if let device = store?.runtimeDevice {
            syncWithRuntimeDevice(device)
            #if os(iOS)
            if awaitingStateRestoration || pendingRestoration != nil { return }
            guard let saved = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
                  UUID(uuidString: saved) != nil else { return }
            #endif
            if device.autoConnect && !device.connected && !reportedReady && !isScanRequested && peripheral == nil && reconnectingPeripheral == nil {
                startScanningIfPoweredOn()
            }
        }
    }

    public func requestScan() {
        if store?.runtimeDevice.autoConnect == false { store?.send(.setBleAutoConnect(enabled: true)) }
        startScanningIfPoweredOn(initiatedByUser: true)
    }

    public func startScanningIfPoweredOn(initiatedByUser: Bool = false) {
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
            central?.cancelPeer(stale)
            resetLinkState()
        }
        if let staleReconnect = reconnectingPeripheral {
            central?.cancelPeer(staleReconnect)
            reconnectingPeripheral = nil
        }
        scanInitiatedByUser = initiatedByUser
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
        #if os(iOS)
        guard pendingRestoration == nil else { return }
        #endif
        if allowsCoreBluetooth && central == nil {
            #if os(iOS)
            central = createIOSCentral()
            #else
            central = CBCentralManager(delegate: self, queue: .main)
            #endif
            return
        }
        centralStateDidChange(central?.state ?? lastCentralState)
    }

    public func disconnect() {
        beginTeardown(for: store?.runtimeDevice, disconnectRuntime: true)
    }

    public func shutdown() {
        isHostActivated = false
        #if os(iOS)
        pendingRestoration = nil
        awaitingStateRestoration = false
        #endif
        scanAfterTeardown = false
        if isScanRequested || reportedReady || peripheral != nil || reconnectingPeripheral != nil {
            disconnect()
        }
        if !teardownPending {
            central?.delegate = nil
            central = nil
        }
    }

    func attachAndConnect(_ target: any BlePeripheral, on central: any BleCentral, displayName: String) {
        peripheral = target
        reconnectingPeripheral = nil
        announceConnection(target, name: displayName)
        target.delegate = self
        central.stopScan()
        central.connectPeer(target)
    }

    func announceConnection(_ target: any BlePeripheral, name: String? = nil) {
        discoveredName = name ?? target.name ?? "soundcore Work"
        connectionID = "\(target.identifier.uuidString):\(UUID().uuidString)"
        emit("connecting")
    }

    func emit(_ event: String) {
        Self.logger.info("D3200 event: \(event, privacy: .public)")
        store?.send(.deviceEvent(
            event: event,
            connectionId: connectionID,
            deviceName: discoveredName
        ))
    }

    func checkReady() {
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
        scanInitiatedByUser = false
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
            guard let pair = String(bytes: bytes[index..<index + 2], encoding: .utf8),
                  let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    nonisolated func onMainActorIsolated(_ body: @MainActor @Sendable @escaping () -> Void) {
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
        #if os(iOS)
        if state == .poweredOn, let central {
            let wasAwaitingWithoutState = awaitingStateRestoration && pendingRestoration == nil
            awaitingStateRestoration = false
            resumeRestoration(on: central)
            if wasAwaitingWithoutState { beginDeferredKnownReconnectIfAvailable() }
        }
        #endif
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
        #if os(iOS)
        let showError = scanInitiatedByUser || peripheral != nil || reconnectingPeripheral != nil || reportedReady
        #endif
        resetLinkState()
        emit("disconnected")
        #if os(iOS)
        guard showError else {
            Self.logger.info("Passive Bluetooth scan ended: \(message, privacy: .public)")
            return
        }
        #endif
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
            #if os(iOS)
            guard self.reconnectingPeripheral !== discovered else { return }
            #endif
            if let pending = self.reconnectingPeripheral, pending !== discovered {
                central.cancelPeer(pending)
                self.reconnectingPeripheral = nil
            }
            self.attachAndConnect(discovered, on: central, displayName: candidate.displayName)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        onMainActorIsolated { self.didConnect(connected, on: central) }
    }

    func didConnect(_ connected: any BlePeripheral, on central: any BleCentral) {
        guard self.central === central, !teardownPending else { return }
        if store?.runtimeDevice.autoConnect == false {
            central.cancelPeer(connected)
            if reconnectingPeripheral === connected { reconnectingPeripheral = nil }
            if peripheral === connected { resetLinkState() }
            return
        }
        if peripheral == nil, reconnectingPeripheral === connected {
            peripheral = connected
            reconnectingPeripheral = nil
            // The restored in-flight connection has already been announced.
            if isScanRequested { announceConnection(connected) }
            central.stopScan()
        }
        guard peripheral === connected else { return }
        connected.delegate = self
        Self.logger.info("Connected to D3200, discovering GATT services")
        connected.discoverServices(nil)
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: (any Error)?) {
        onMainActorIsolated { self.didFailToConnect(failed, on: central, error: error) }
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
            #endif
            reportError("未能重连上次的录音豆，仍在扫描附近设备。", error: error)
            return
        }
        guard peripheral === failed else { return }
        failLink("无法连接录音豆，请确认设备已放入充电仓并短按下方按钮。", error: error)
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral disconnected: CBPeripheral,
                                           error: (any Error)?) {
        onMainActorIsolated {
            guard self.peripheral === disconnected else { return }
            let stopPending = self.teardownPending
            self.resetLinkState()
            self.emit("disconnected")
            if stopPending {
                self.reportError("录音豆已断开，未能确认停录指令写入。", error: error)
            } else if let error {
                self.reportError("录音豆连接中断。", error: error)
            }
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
                if Self.isPrimaryD3200Service(service.uuid), Self.isWritableD3200Characteristic(characteristic) {
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

#if os(iOS)
extension BluetoothBridge: @preconcurrency CBCentralManagerDelegate {}
#else
extension BluetoothBridge: CBCentralManagerDelegate {}
#endif
