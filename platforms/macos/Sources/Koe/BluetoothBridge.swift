import CoreBluetooth
import Foundation
import KoeAppleShared

@MainActor
public final class BluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public static var writeCharacteristicUUID: CBUUID { CBUUID(string: "7777") }
    nonisolated public static var notifyCharacteristicUUID: CBUUID { CBUUID(string: "8888") }
    public weak var store: HostSessionStore?
    public private(set) var isScanRequested = false
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingWrites: [Data] = []
    private var notifyReady = false
    private var notifyFound = false
    private var pendingServices = 0
    private var reportedReady = false
    private var awaitingWrite = false
    private var connectionID = ""

    public init(store: HostSessionStore? = nil) { self.store = store; super.init() }

    public func startScanningIfPoweredOn() {
        guard peripheral == nil else { return }
        isScanRequested = true
        connectionID = UUID().uuidString
        emit("scanning")
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if central?.state == .poweredOn { central?.scanForPeripherals(withServices: nil) }
    }

    private func emit(_ event: String) {
        store?.send("device_event", ["event": event, "connectionId": connectionID])
    }

    private func checkReady() {
        guard notifyReady, writeCharacteristic != nil, !reportedReady else { return }
        reportedReady = true
        emit("ready")
        flushOutboundFrames()
    }

    public func flushOutboundFrames() {
        guard reportedReady, let peripheral, let characteristic = writeCharacteristic else { return }
        for hex in store?.drainOutboundBleFramesHex() ?? [] {
            guard let data = Self.decodeHex(hex) else {
                store?.reportNativeError("设备指令格式无效，请重新连接。")
                continue
            }
            let mode: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            let limit = max(peripheral.maximumWriteValueLength(for: mode), 1)
            var offset = 0
            while offset < data.count {
                let end = min(offset + limit, data.count)
                pendingWrites.append(data.subdata(in: offset..<end))
                offset = end
            }
        }
        if characteristic.properties.contains(.writeWithoutResponse) {
            while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
                peripheral.writeValue(pendingWrites.removeFirst(), for: characteristic, type: .withoutResponse)
            }
        } else if !awaitingWrite, let frame = pendingWrites.first {
            awaitingWrite = true
            peripheral.writeValue(frame, for: characteristic, type: .withResponse)
        }
    }

    private func disconnected(_ message: String? = nil) {
        emit("disconnected")
        peripheral = nil
        writeCharacteristic = nil
        notifyReady = false
        notifyFound = false
        pendingServices = 0
        reportedReady = false
        awaitingWrite = false
        pendingWrites.removeAll()
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

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.isScanRequested { central.scanForPeripherals(withServices: nil) }
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

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover discovered: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = discovered.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.localizedCaseInsensitiveContains("soundcore") || name.localizedCaseInsensitiveContains("D3200") else { return }
        Task { @MainActor in
            guard self.isScanRequested, self.peripheral == nil else { return }
            self.peripheral = discovered
            self.connectionID = "\(discovered.identifier.uuidString):\(UUID().uuidString)"
            self.emit("connecting")
            discovered.delegate = self
            central.stopScan()
            central.connect(discovered)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral === connected else { return }
            connected.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: (any Error)?) {
        Task { @MainActor in
            guard self.peripheral === failed else { return }
            self.disconnected("无法连接录音豆，请确认设备已开机且未被其他应用占用。")
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral disconnected: CBPeripheral,
                                           error: (any Error)?) {
        Task { @MainActor in
            guard self.peripheral === disconnected else { return }
            self.disconnected()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didDiscoverServices error: (any Error)?) {
        Task { @MainActor in
            guard self.peripheral === source else { return }
            guard error == nil, let services = source.services, !services.isEmpty else {
                self.store?.reportNativeError("无法读取录音豆服务，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.pendingServices = services.count
            for service in services {
                source.discoverCharacteristics([Self.writeCharacteristicUUID, Self.notifyCharacteristicUUID], for: service)
            }
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                      error: (any Error)?) {
        Task { @MainActor in
            guard self.peripheral === source else { return }
            guard error == nil else {
                self.store?.reportNativeError("无法读取录音豆通信通道，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            self.pendingServices = max(0, self.pendingServices - 1)
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.writeCharacteristicUUID { self.writeCharacteristic = characteristic }
                if characteristic.uuid == Self.notifyCharacteristicUUID {
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
        Task { @MainActor in
            guard self.peripheral === source, characteristic.uuid == Self.notifyCharacteristicUUID else { return }
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
        guard error == nil, characteristic.uuid == Self.notifyCharacteristicUUID, let data = characteristic.value else { return }
        Task { @MainActor in
            guard self.peripheral === source, self.reportedReady else { return }
            self.store?.ingestBleChunk(data)
            self.flushOutboundFrames()
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse source: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral === source else { return }
            self.flushOutboundFrames()
        }
    }

    nonisolated public func peripheral(_ source: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                      error: (any Error)?) {
        Task { @MainActor in
            guard self.peripheral === source, self.awaitingWrite else { return }
            self.awaitingWrite = false
            guard error == nil else {
                self.store?.reportNativeError("设备指令发送失败，请重新连接。")
                self.central?.cancelPeripheralConnection(source)
                return
            }
            if !self.pendingWrites.isEmpty { self.pendingWrites.removeFirst() }
            self.flushOutboundFrames()
        }
    }
}
